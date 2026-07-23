#!/system/bin/sh
##########################################################
unset LD_LIBRARY_PATH

# 强制使用系统 ip 命令，避免 KernelSU 环境下 busybox 导致 uidrange/table ID 解析出错
ip() {
    /system/bin/ip "$@"
}
# apply_rules.sh — App Net Router 核心路由规则引擎
#
# 配置格式: pkg:wifi_flag:cell_flag (1=启用 0=禁用)
# 未在配置中的 app 默认 wifi=1 cell=0
#
# 场景:
#   wifi=0 cell=1 → 路由到蜂窝
#   wifi=1 cell=1 → 两个都可用（不做特殊处理）
#   wifi=0 cell=0 → 禁止网络 (iptables DROP)
#   wifi=1 cell=0 → 默认，不需要规则
#
# WireGuard:
#   自动管理 wg0 接口，通过蜂窝 IPv6 连接服务器
#   endpoint: 通过 DDNS 域名动态解析 ←→ wg0(10.10.10.0/24)
#

##########################################################

MODDIR=${MODDIR:-/data/adb/modules/app_net_router}
CONF="$MODDIR/config/apps.conf"
LOGDIR="$MODDIR/logs"
RULE_PRIO=7990
LAN_PRIO=7989
PACKAGES_LIST="/data/system/packages.list"

# === WireGuard 配置 ===
WG_BIN="/data/data/com.termux/files/usr/bin/wg"
WG_CONF="/data/data/com.termux/files/usr/etc/wireguard/wg0.conf"
WG_DOMAIN="myhome2026.online"
WG_ENDPOINT_V6=""  # 运行时通过域名解析填充
WG_SUBNET="10.10.10.0/24"
WG_CLIENT_IP="10.10.10.2/24"
WG_PRIO=9000
WG_EP_CACHE="$MODDIR/logs/.wg_endpoint_cache"

# 解析域名获取 IPv6 地址（多级回退）
resolve_wg_endpoint() {
    # 方法1: Termux dig/host 查询 AAAA（最可靠）
    local TERMUX_BIN="/data/data/com.termux/files/usr/bin"
    if [ -x "$TERMUX_BIN/dig" ]; then
        WG_ENDPOINT_V6=$(LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib "$TERMUX_BIN/dig" AAAA "$WG_DOMAIN" +short 2>/dev/null | grep -E '^[0-9a-f]+:' | head -1)
    elif [ -x "$TERMUX_BIN/host" ]; then
        WG_ENDPOINT_V6=$(LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib "$TERMUX_BIN/host" -t AAAA "$WG_DOMAIN" 2>/dev/null | grep 'IPv6' | awk '{print $NF}' | head -1)
    fi

    # 方法2: ping6 从蜂窝接口
    if [ -z "$WG_ENDPOINT_V6" ] && [ -n "$CELL_IF" ]; then
        WG_ENDPOINT_V6=$(ping6 -c1 -W3 -I "$CELL_IF" "$WG_DOMAIN" 2>/dev/null | head -1 | grep -oE '[0-9a-f:]{4,}:[0-9a-f:]+' | head -1)
    fi

    # 方法3: ping6 默认路由
    [ -z "$WG_ENDPOINT_V6" ] && WG_ENDPOINT_V6=$(ping6 -c1 -W3 "$WG_DOMAIN" 2>/dev/null | head -1 | grep -oE '[0-9a-f:]{4,}:[0-9a-f:]+' | head -1)

    # 方法4: 缓存文件（最终回退，打破 DNS 死锁）
    [ -z "$WG_ENDPOINT_V6" ] && [ -f "$WG_EP_CACHE" ] && WG_ENDPOINT_V6=$(cat "$WG_EP_CACHE" | tr -d '[:space:]' | grep -E '^[0-9a-f]+:.*:')

    if [ -n "$WG_ENDPOINT_V6" ]; then
        log "WG endpoint: $WG_DOMAIN → $WG_ENDPOINT_V6"
        echo "$WG_ENDPOINT_V6" > "$WG_EP_CACHE"
    else
        log "⚠ WG endpoint 解析失败: $WG_DOMAIN"
    fi
}



log() {
    local today=$(date '+%Y-%m-%d')
    local ts=$(date '+%H:%M:%S')
    echo "[$ts] [rules] $1" >> "$LOGDIR/anr_${today}.log" 2>/dev/null
    echo "[$ts] $1"
}

clean_rules() {
    log "清理旧规则..."
    while ip -4 rule del priority $LAN_PRIO 2>/dev/null; do :; done
    while ip -6 rule del priority $LAN_PRIO 2>/dev/null; do :; done
    while ip -4 rule del priority $RULE_PRIO 2>/dev/null; do :; done
    while ip -6 rule del priority $RULE_PRIO 2>/dev/null; do :; done

    # 彻底清理可能残留的 priority 8000 干扰规则 (来自系统/其他 VPN 抢占)
    while ip -4 rule del priority 8000 2>/dev/null; do :; done
    while ip -6 rule del priority 8000 2>/dev/null; do :; done

    # 清理 WireGuard 路由规则
    ip -4 rule del to $WG_SUBNET 2>/dev/null
    ip route del 10.10.10.1 2>/dev/null
    # 清理 endpoint 路由 (priority 100)
    while ip -6 rule del priority 100 2>/dev/null; do :; done

    # 清理 INPUT 链中的蜂窝入站跳转规则
    while iptables -D INPUT -i rmnet_+ -j ANR_CELL_INPUT 2>/dev/null; do :; done
    while ip6tables -D INPUT -i rmnet_+ -j ANR_CELL_INPUT 2>/dev/null; do :; done

    # 清理 iptables 链
    for chain in ANR_BLOCK ANR_CELL_GUARD ANR_CELL_INPUT; do
        iptables -D OUTPUT -j $chain 2>/dev/null
        iptables -F $chain 2>/dev/null
        iptables -X $chain 2>/dev/null
        ip6tables -D OUTPUT -j $chain 2>/dev/null
        ip6tables -F $chain 2>/dev/null
        ip6tables -X $chain 2>/dev/null
    done
    log "规则已清理"
}

detect_cellular() {
    # === 多级检测：精确选择主数据 SIM 卡接口 ===
    # 双卡手机上可能存在多个 rmnet_data 接口：
    #   - 主数据 SIM: 有 INTERNET 能力 + IPv4 地址 + IPv6 地址
    #   - VoLTE/IMS: 仅有 IPv6，无 IPv4，无 INTERNET 能力
    #   - 残留接口: 旧 SIM 卡拔掉后 modem 未清除的 IMS 通道

    CELL_IF=""

    # 方法1: dumpsys connectivity 找 INTERNET 能力的蜂窝（最可靠）
    CELL_IF=$(LD_LIBRARY_PATH="" dumpsys connectivity 2>/dev/null \
        | grep "MOBILE.*CONNECTED.*INTERNET" \
        | grep -o "InterfaceName: [^ ]*" \
        | head -1 | cut -d' ' -f2)

    # 方法2: 找有 IPv4 地址的 rmnet_data（只有主数据卡有 IPv4）
    if [ -z "$CELL_IF" ]; then
        CELL_IF=$(ip -4 addr show 2>/dev/null \
            | grep -B1 "inet [0-9]" \
            | grep "rmnet_data" \
            | awk -F'[ :@]' '{for(i=1;i<=NF;i++) if($i ~ /rmnet_data/) {print $i; exit}}')
        [ -n "$CELL_IF" ] && log "蜂窝检测: 通过 IPv4 地址选中 $CELL_IF"
    fi

    # 方法3: 找有 IPv6 默认路由 + IPv4 默认路由的 rmnet_data（排除纯 IMS）
    if [ -z "$CELL_IF" ]; then
        local v4_ifaces=$(ip -4 route show table all 2>/dev/null | grep "default.*dev rmnet_data" | sed 's/.*dev \(rmnet_data[0-9]*\).*/\1/' | sort -u)
        local v6_ifaces=$(ip -6 route show table all 2>/dev/null | grep "default.*dev rmnet_data" | sed 's/.*dev \(rmnet_data[0-9]*\).*/\1/' | sort -u)
        for iface in $v4_ifaces; do
            echo "$v6_ifaces" | grep -q "^${iface}$" && {
                CELL_IF="$iface"
                log "蜂窝检测: 通过双栈默认路由选中 $CELL_IF"
                break
            }
        done
    fi

    # 方法4: 最后回退——有 IPv6 全局地址 + 默认路由的 rmnet_data
    if [ -z "$CELL_IF" ]; then
        local candidates=$(ip -6 addr show 2>/dev/null | grep -B2 'scope global' | grep 'rmnet_data' | awk -F'[ @]' '{print $2}' | sort -u)
        for iface in $candidates; do
            ip -6 route show table "$iface" 2>/dev/null | grep -q "^default" && {
                CELL_IF="$iface"
                log "蜂窝检测: 通过 IPv6 全局地址+路由选中 $CELL_IF"
                break
            }
        done
    fi

    [ -z "$CELL_IF" ] && return 1

    # IPv6: 找含有蜂窝接口默认路由的表
    CELL_TABLE_V6=$(ip -6 route show table all 2>/dev/null | grep "default.*dev $CELL_IF" | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="table") print $(i+1)}')
    # IPv4: 同样查找
    CELL_TABLE_V4=$(ip -4 route show table all 2>/dev/null | grep "default.*dev $CELL_IF" | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="table") print $(i+1)}')
    # IPv4 回退: 任意 rmnet_data 接口
    if [ -z "$CELL_TABLE_V4" ]; then
        CELL_TABLE_V4=$(ip -4 route show table all 2>/dev/null | grep "default.*dev rmnet_data" | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="table") print $(i+1)}')
    fi

    log "蜂窝接口: $CELL_IF | IPv6表: ${CELL_TABLE_V6:-无} | IPv4表: ${CELL_TABLE_V4:-无}"
    return 0
}

get_uid() {
    local pkg=$1
    local uid=""
    if [ -f "$PACKAGES_LIST" ]; then
        uid=$(grep "^$pkg " "$PACKAGES_LIST" | awk '{print $2}')
    fi
    if [ -z "$uid" ]; then
        uid=$(pm list packages -U 2>/dev/null | grep "$pkg" | sed 's/.*uid://')
    fi
    echo "$uid"
}

apply_rules() {
    if [ ! -f "$CONF" ]; then
        log "配置文件不存在: $CONF"
        return 1
    fi

    detect_cellular
    local has_cell=$?

    local wifi_up=$(ip link show wlan0 2>/dev/null | grep -c 'UP')

    # 检测 Wi-Fi 是否真正连接且获得 IP (wlan0/wlan1)，并主动探测网关连通性以防弱信号断流
    local wifi_connected=0
    local wifi_if=""
    if ip -4 addr show wlan0 2>/dev/null | grep -q 'inet '; then
        wifi_if="wlan0"
    elif ip -4 addr show wlan1 2>/dev/null | grep -q 'inet '; then
        wifi_if="wlan1"
    fi

    if [ -n "$wifi_if" ]; then
        local gateway=$(ip route show table all 2>/dev/null | grep "default via .* dev $wifi_if" | awk '{print $3}' | head -1)
        [ -z "$gateway" ] && gateway=$(ip route show table "$wifi_if" 2>/dev/null | grep default | awk '{print $3}' | head -1)
        [ -z "$gateway" ] && gateway=$(ip route show dev "$wifi_if" 2>/dev/null | grep default | awk '{print $3}' | head -1)
        if [ -n "$gateway" ]; then
            if ping -c 1 -W 1 -I "$wifi_if" "$gateway" >/dev/null 2>&1; then
                wifi_connected=1
            else
                log "⚠️ Wi-Fi 网关 $gateway 不可达，判定为弱信号失效，回退至纯蜂窝模式"
            fi
        fi
    fi

    # 强制关闭 Wi-Fi 节能模式以降低延迟和丢包率
    if [ "$wifi_connected" -eq 1 ] && [ -n "$wifi_if" ]; then
        if command -v iw >/dev/null 2>&1; then
            iw dev "$wifi_if" set power_save off >/dev/null 2>&1 || true
            log "⚡ 已强制关闭 Wi-Fi 节能模式 ($wifi_if)"
        fi
    fi

    # 强制关闭系统级后台 WLAN 扫描与蓝牙扫描以防止延迟抖动 (持久化设置，无需在每次网络切换时重复执行，避免 JVM 启动开销)
    # settings put global wifi_scan_always_enabled 0 >/dev/null 2>&1 || true
    # settings put global ble_scan_always_enabled 0 >/dev/null 2>&1 || true

    # 强制关闭 Google 位置信息精确度 (Network Location Services)
    # content insert --uri content://com.google.settings/partner --bind name:s:network_location_opt_in --bind value:s:0 >/dev/null 2>&1 || true
    # content insert --uri content://com.google.settings/partner --bind name:s:use_location_for_services --bind value:s:0 >/dev/null 2>&1 || true

    # 强制关闭系统级与小米高精度定位服务 (仅使用 GPS 定位)
    # settings put secure location_mode 1 >/dev/null 2>&1 || true
    # settings put secure xiaomi_high_precise_location 0 >/dev/null 2>&1 || true

    clean_rules

    # rp_filter 松散模式
    if [ "$has_cell" -eq 0 ] && [ -n "$CELL_IF" ]; then
        [ -f /proc/sys/net/ipv4/conf/$CELL_IF/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/$CELL_IF/rp_filter
        [ -f /proc/sys/net/ipv4/conf/wlan0/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/wlan0/rp_filter
        [ -f /proc/sys/net/ipv4/conf/all/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter
    fi

    # ============================================================
    # WireGuard 完整管理
    # 架构: Android --[wg0]--> 服务器 (10.10.10.1)
    #         endpoint 通过 DDNS 域名解析，蜂窝 IPv6 直连
    #         wg0 子网 10.10.10.0/24 走 main 表
    # ============================================================
    log "=== WireGuard 配置 ==="

    # 0. 解析 endpoint 域名
    resolve_wg_endpoint

    # 1. WG 路由策略: 确保目标为 WG 子网和内网 LAN 的流量，以及源为 WG 子网的流量走 main 表 (wg0 接口)
    ip -4 rule del to $WG_SUBNET 2>/dev/null
    ip -4 rule add to $WG_SUBNET table main priority $WG_PRIO
    ip -4 rule del to 192.168.88.0/24 2>/dev/null
    ip -4 rule add to 192.168.88.0/24 table main priority $WG_PRIO
    ip -4 rule del from $WG_SUBNET 2>/dev/null
    ip -4 rule add from $WG_SUBNET table main priority 99

    # 2. WG endpoint IPv6 路由: 确保蜂窝可达
    if [ -n "$WG_ENDPOINT_V6" ]; then
        # 显式清理历史残留的 priority 100 规则，保证幂等性并避免旧 IP 残留
        while ip -6 rule del priority 100 2>/dev/null; do :; done
        if [ "$has_cell" -eq 0 ] && [ -n "$CELL_TABLE_V6" ]; then
            ip -6 rule add to $WG_ENDPOINT_V6 table "$CELL_TABLE_V6" priority 100
            log "WG endpoint $WG_ENDPOINT_V6 → $CELL_IF (table $CELL_TABLE_V6)"
        fi
    fi

    # 3. wg0 接口自动拉起 (如果已配置且未运行)
    if [ -f "$WG_CONF" ] && [ -x "$WG_BIN" ]; then
        local newly_started=0
        if ! ip link show wg0 >/dev/null 2>&1; then
            log "WG: wg0 未运行，自动启动..."
            sh "$MODDIR/scripts/wg_start.sh" start >/dev/null 2>&1
            sleep 1
            if ip link show wg0 >/dev/null 2>&1; then
                log "WG: wg0 已自动拉起 ✅"
                newly_started=1
            else
                log "WG: wg0 启动失败 ⚠"
            fi
        else
            log "WG: wg0 已运行 ✅"
        fi

        # 无论新启动还是已运行，只要有解析出来的 IP 并且 wg0 存在，就确保 peer 和 endpoint 配置正确
        if ip link show wg0 >/dev/null 2>&1 && [ -n "$WG_ENDPOINT_V6" ]; then
            local peer=$(LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib $WG_BIN show wg0 peers 2>/dev/null | head -1)
            # 如果没有配置 peer（例如因为 DNS 失败），根据 wg0.conf 重新设置 peer
            if [ -z "$peer" ]; then
                local server_pub=$(sed -n 's/^PublicKey[[:space:]]*=[[:space:]]*//p' "$WG_CONF")
                local allowed_ips=$(sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*//p' "$WG_CONF")
                local client_psk=$(sed -n 's/^PresharedKey[[:space:]]*=[[:space:]]*//p' "$WG_CONF")
                if [ -n "$server_pub" ] && [ -n "$allowed_ips" ]; then
                    if [ -n "$client_psk" ]; then
                        local psk_file="/data/local/tmp/wg_psk.key"
                        echo "$client_psk" > "$psk_file"
                        chmod 600 "$psk_file"
                        LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib $WG_BIN set wg0 peer "$server_pub" \
                            endpoint "[$WG_ENDPOINT_V6]:51820" \
                            allowed-ips "$allowed_ips" \
                            preshared-key "$psk_file" \
                            persistent-keepalive 25
                        rm -f "$psk_file"
                    else
                        LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib $WG_BIN set wg0 peer "$server_pub" \
                            endpoint "[$WG_ENDPOINT_V6]:51820" \
                            allowed-ips "$allowed_ips" \
                            persistent-keepalive 25
                    fi
                    log "WG: 重新建立 Peer 关联并绑定 Endpoint ✅"
                    peer=$server_pub
                fi
            else
                # 如果已有 peer，只更新 endpoint
                LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib $WG_BIN set wg0 peer "$peer" endpoint "[$WG_ENDPOINT_V6]:51820" 2>/dev/null
            fi
            
            # 如果不是全新启动的（即原来就在运行，需要重置 link 来刷新 socket 并应用路由）
            if [ "$newly_started" -eq 0 ]; then
                ip link set wg0 down 2>/dev/null
                ip link set wg0 up 2>/dev/null
                ip route add 10.10.10.0/24 dev wg0 2>/dev/null || true
                ip route add 192.168.88.0/24 dev wg0 2>/dev/null || true
                log "WG: 已刷新 endpoint + 重置接口 + 重置路由"
            fi
        fi
    else
        log "WG: 未找到配置或 wg 二进制，跳过自动启动"
    fi

    # 4. 确保 wg0 接口的反向路径过滤处于松散模式（rp_filter=2），解决 macOS 诊断手机网络时因反向路径校验失败而被丢弃入站包的问题
    if ip link show wg0 >/dev/null 2>&1; then
        [ -f /proc/sys/net/ipv4/conf/wg0/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/wg0/rp_filter
        [ -f /proc/sys/net/ipv4/conf/all/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter
    fi


    # 4. WG 防火墙: 保护 WG UDP 流量不被其他规则影响
    #    WG 使用 kernel socket (UID 0) 发送 UDP 到 endpoint
    #    在蜂窝守卫中已放行 UID 0 的 UDP
    log "WG: 防火墙规则已通过蜂窝守卫链放行"

    # === 5. 局域网直连路由分流 ===
    # 当手机连接家庭 Wi-Fi (192.168.88.x) 且 RB5009 (192.168.88.1) 可达时，
    # 设置 10.10.10.1 (主路由的 WG IP) 直接走 Wi-Fi 局域网，避免通过蜂窝和公网加密隧道绕行，大幅降低延迟。
    ip route del 10.10.10.1 2>/dev/null
    if [ "$wifi_connected" -eq 1 ] && [ -n "$wifi_if" ]; then
        local my_wifi_ip=$(ip -4 addr show "$wifi_if" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
        
        # 尝试获取当前连接的 SSID 辅助校验
        local current_ssid=""
        if command -v cmd >/dev/null 2>&1; then
            current_ssid=$(cmd wifi status 2>/dev/null | grep -i "SSID:" | head -1 | awk -F': ' '{print $2}' | tr -d '"' | tr -d '[:space:]')
        fi
        [ -z "$current_ssid" ] && current_ssid=$(dumpsys wifi 2>/dev/null | grep -oE "SSID: [^\,]*" | head -1 | cut -d' ' -f2 | tr -d '"' | tr -d '[:space:]')

        case "$my_wifi_ip" in
            192.168.88.*)
                # 先行删除可能存在的冲突路由，否则 ping 也会失败
                ip route del 192.168.88.0/24 dev wg0 2>/dev/null || true
                if ping -c 1 -W 1 -I "$wifi_if" 192.168.88.1 >/dev/null 2>&1; then
                    ip route add 10.10.10.1 via 192.168.88.1 dev "$wifi_if"
                    log "✓ 检测到处于家庭局域网 (SSID: ${current_ssid:-未知})，已将 10.10.10.1 重定向至 $wifi_if，并已移除 wg0 的 LAN 路由，改为物理直连。"
                fi
                ;;
        esac
    fi




    # 创建 iptables 链（用于禁网场景）
    iptables -N ANR_BLOCK 2>/dev/null
    ip6tables -N ANR_BLOCK 2>/dev/null

    local count_cell=0
    local count_block=0

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed 's/#.*//' | tr -d '[:space:]')
        [ -z "$line" ] && continue

        # 解析 pkg:wifi:cell 格式
        local pkg=$(echo "$line" | cut -d: -f1)
        local wifi_flag=$(echo "$line" | cut -d: -f2)
        local cell_flag=$(echo "$line" | cut -d: -f3)

        [ -z "$pkg" ] && continue

        # 兼容旧格式（只有包名，无冒号）
        if [ -z "$wifi_flag" ]; then
            wifi_flag=0
            cell_flag=1
        fi

        local uid=$(get_uid "$pkg")
        if [ -z "$uid" ]; then
            log "⚠ 未找到包: $pkg"
            continue
        fi

        # wifi=1 cell=0 → 默认，不需要规则
        if [ "$wifi_flag" = "1" ] && [ "$cell_flag" = "0" ]; then
            continue
        fi

        # wifi=0 cell=1 → 走蜂窝（局域网仍走 WiFi）
        if [ "$wifi_flag" = "0" ] && [ "$cell_flag" = "1" ]; then
            if [ "$has_cell" -eq 0 ]; then
                # 局域网例外: 优先级更高(11999)，局域网流量走 main 表(WiFi)
                ip -4 rule add uidrange "$uid-$uid" to 192.168.0.0/16 table main priority $LAN_PRIO
                ip -4 rule add uidrange "$uid-$uid" to 10.0.0.0/8 table main priority $LAN_PRIO
                ip -4 rule add uidrange "$uid-$uid" to 172.16.0.0/12 table main priority $LAN_PRIO
                ip -6 rule add uidrange "$uid-$uid" to fe80::/10 table main priority $LAN_PRIO
                # 公网流量走蜂窝
                if [ -n "$CELL_TABLE_V6" ]; then
                    ip -6 rule add uidrange "$uid-$uid" table "$CELL_TABLE_V6" priority $RULE_PRIO
                fi
                if [ -n "$CELL_TABLE_V4" ]; then
                    ip -4 rule add uidrange "$uid-$uid" table "$CELL_TABLE_V4" priority $RULE_PRIO
                fi
                log "✓ $pkg (UID $uid) → 蜂窝(公网) + WiFi(局域网) + WireGuard"
                count_cell=$((count_cell + 1))
            else
                log "⚠ $pkg 需要蜂窝但蜂窝未连接"
            fi
            continue
        fi

        # wifi=1 cell=1 → 两个都启用，不需要特殊规则
        if [ "$wifi_flag" = "1" ] && [ "$cell_flag" = "1" ]; then
            log "✓ $pkg (UID $uid) → WiFi+蜂窝"
            continue
        fi

        # wifi=0 cell=0 → 禁止网络
        if [ "$wifi_flag" = "0" ] && [ "$cell_flag" = "0" ]; then
            iptables -A ANR_BLOCK -m owner --uid-owner "$uid" -j DROP 2>/dev/null
            ip6tables -A ANR_BLOCK -m owner --uid-owner "$uid" -j DROP 2>/dev/null
            log "✗ $pkg (UID $uid) → 禁止网络"
            count_block=$((count_block + 1))
            continue
        fi
    done < "$CONF"

    # 激活 iptables 链
    if [ $count_block -gt 0 ]; then
        iptables -I OUTPUT -j ANR_BLOCK
        ip6tables -I OUTPUT -j ANR_BLOCK
    fi

    log "完成: ${count_cell} 个走蜂窝, ${count_block} 个禁网"

    # === 蜂窝守卫: 仅在 Wi-Fi 在线且双网共存时，为了防止偷跑流量才启用 ===
    # === 如果 Wi-Fi 离线，说明只有蜂窝可用，此时必须放行所有 app 以便正常上网 ===
    if [ "$wifi_connected" -eq 1 ] && [ "$has_cell" -eq 0 ] && [ -n "$CELL_IF" ]; then
        iptables -N ANR_CELL_GUARD 2>/dev/null
        ip6tables -N ANR_CELL_GUARD 2>/dev/null

        # 收集所有允许蜂窝的 UID
        local cell_uids=""
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(echo "$line" | sed 's/#.*//' | tr -d '[:space:]')
            [ -z "$line" ] && continue
            local pkg=$(echo "$line" | cut -d: -f1)
            local cell_flag=$(echo "$line" | cut -d: -f3)
            local wifi_flag=$(echo "$line" | cut -d: -f2)
            [ -z "$cell_flag" ] && cell_flag=1  # 旧格式兼容
            if [ "$cell_flag" = "1" ]; then
                local uid=$(get_uid "$pkg")
                [ -n "$uid" ] && cell_uids="$cell_uids $uid"
            fi
        done < "$CONF"

        # 放行: WireGuard 内核模块流量（无 UID owner，需用端口匹配）
        local wg_port=$($WG_BIN show wg0 listen-port 2>/dev/null)
        if [ -n "$wg_port" ]; then
            ip6tables -A ANR_CELL_GUARD -o "$CELL_IF" -p udp --sport "$wg_port" -j RETURN 2>/dev/null
            iptables -A ANR_CELL_GUARD -o "$CELL_IF" -p udp --sport "$wg_port" -j RETURN 2>/dev/null
        fi
        # 放行: UID 0 系统流量（DNS 等）
        ip6tables -A ANR_CELL_GUARD -o "$CELL_IF" -m owner --uid-owner 0 -j RETURN 2>/dev/null
        iptables -A ANR_CELL_GUARD -o "$CELL_IF" -m owner --uid-owner 0 -j RETURN 2>/dev/null

        # 放行: 配置中允许蜂窝的 app
        for uid in $cell_uids; do
            iptables -A ANR_CELL_GUARD -o "$CELL_IF" -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
            ip6tables -A ANR_CELL_GUARD -o "$CELL_IF" -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
        done

        # 拦截: 其他所有 app 走蜂窝的流量
        iptables -A ANR_CELL_GUARD -o "$CELL_IF" -j DROP 2>/dev/null
        ip6tables -A ANR_CELL_GUARD -o "$CELL_IF" -j DROP 2>/dev/null

        iptables -I OUTPUT -j ANR_CELL_GUARD
        ip6tables -I OUTPUT -j ANR_CELL_GUARD
        log "🛡 蜂窝守卫: 仅允许 UID [0(root)${cell_uids}] 使用 $CELL_IF"
    fi

    # === 蜂窝入站守卫: 防止公网通过 IPv6/IPv4 攻击暴露端口 ===
    log "=== 蜂窝入站安全防护 ==="
    iptables -N ANR_CELL_INPUT 2>/dev/null
    ip6tables -N ANR_CELL_INPUT 2>/dev/null

    iptables -F ANR_CELL_INPUT
    ip6tables -F ANR_CELL_INPUT

    # 1. 允许 ESTABLISHED,RELATED 状态（确保主动发起的出站连接如网页、WireGuard 等能正常回包）
    iptables -A ANR_CELL_INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A ANR_CELL_INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # 2. 丢弃所有新的 TCP/UDP 连接请求 (入站)
    iptables -A ANR_CELL_INPUT -p tcp -j DROP
    ip6tables -A ANR_CELL_INPUT -p tcp -j DROP
    iptables -A ANR_CELL_INPUT -p udp -j DROP
    ip6tables -A ANR_CELL_INPUT -p udp -j DROP

    # 3. 拦截所有蜂窝接口 (rmnet_+) 的入站流量并跳转到安全链
    iptables -I INPUT -i rmnet_+ -j ANR_CELL_INPUT
    ip6tables -I INPUT -i rmnet_+ -j ANR_CELL_INPUT
    log "🔒 蜂窝入站守卫已激活：禁止所有外部 TCP/UDP 入站连接 (rmnet_+)"

    echo "$CELL_TABLE_V6" > "$MODDIR/logs/.cell_table_v6" 2>/dev/null
    echo "$CELL_TABLE_V4" > "$MODDIR/logs/.cell_table_v4" 2>/dev/null
    echo "$CELL_IF" > "$MODDIR/logs/.cell_if" 2>/dev/null

    return 0
}

mkdir -p "$MODDIR/logs"

case "$1" in
    --clean) clean_rules ;;
    *) apply_rules ;;
esac
