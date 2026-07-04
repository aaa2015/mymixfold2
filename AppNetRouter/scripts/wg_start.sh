#!/system/bin/sh
# WireGuard 隧道启动脚本
# 电信蜂窝 IPv6 直连到 Mac macmini

WG="/data/data/com.termux/files/usr/bin/wg"
WG_CONF="/data/data/com.termux/files/usr/etc/wireguard/wg0.conf"
PRIV_KEY_FILE="/data/local/tmp/wg_priv.key"

# WireGuard 配置
CLIENT_PRIV=$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$WG_CONF")
SERVER_PUB=$(sed -n 's/^PublicKey[[:space:]]*=[[:space:]]*//p' "$WG_CONF")
ENDPOINT=$(sed -n 's/^Endpoint[[:space:]]*=[[:space:]]*//p' "$WG_CONF")
ALLOWED_IPS=$(sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*//p' "$WG_CONF")
CLIENT_PSK=$(sed -n 's/^PresharedKey[[:space:]]*=[[:space:]]*//p' "$WG_CONF")
MTU=$(sed -n 's/^MTU[[:space:]]*=[[:space:]]*//p' "$WG_CONF")

# log() function defined after variables
log() { echo "[WG] \$(date '+%H:%M:%S') \$1"; }

start() {
    # 检查是否已运行
    ip link show wg0 >/dev/null 2>&1 && {
        log "wg0 已运行"
        $WG show
        return 0
    }

    # 创建接口
    ip link del wg0 2>/dev/null
    ip link add wg0 type wireguard

    # 设置私钥
    echo "$CLIENT_PRIV" > "$PRIV_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"
    $WG set wg0 private-key "$PRIV_KEY_FILE"
    rm -f "$PRIV_KEY_FILE"

    # 设置 peer 和 PSK
    if [ -n "$CLIENT_PSK" ]; then
        local psk_file="/data/local/tmp/wg_psk.key"
        echo "$CLIENT_PSK" > "$psk_file"
        chmod 600 "$psk_file"
        $WG set wg0 peer "$SERVER_PUB" \
            endpoint "$ENDPOINT" \
            allowed-ips "$ALLOWED_IPS" \
            preshared-key "$psk_file" \
            persistent-keepalive 25
        rm -f "$psk_file"
    else
        $WG set wg0 peer "$SERVER_PUB" \
            endpoint "$ENDPOINT" \
            allowed-ips "$ALLOWED_IPS" \
            persistent-keepalive 25
    fi

    # 配置地址并启动
    ip addr add 10.10.10.2/24 dev wg0
    if [ -n "$MTU" ]; then
        ip link set dev wg0 mtu "$MTU"
    else
        ip link set dev wg0 mtu 1280
    fi
    ip link set wg0 up

    # 添加路由以支持内网访问
    ip route add 10.10.10.0/24 dev wg0 2>/dev/null || true
    ip route add 192.168.88.0/24 dev wg0 2>/dev/null || true

    log "WireGuard 已启动"
    $WG show

    # 启动后台健康检测 daemon
    nohup sh "$0" daemon >/dev/null 2>&1 &
}

stop() {
    ip link del wg0 2>/dev/null
    # 杀掉后台 daemon 进程以防资源泄漏与并发冲突
    local pids=$(pgrep -f "wg_start.sh daemon" | grep -v "$$")
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi
    log "WireGuard 已停止"
}

status() {
    ip link show wg0 >/dev/null 2>&1 && {
        $WG show
    } || {
        log "WireGuard 未运行"
    }
}

is_wifi_direct() {
    # 1. 检查 10.10.10.1 是否直接在 main 表中通过 wlan 路由
    if ip route show 10.10.10.1 2>/dev/null | grep -q -E "dev wlan[0-9]"; then
        return 0
    fi
    # 2. 检查 11998 规则指向的路由表是否通过 wlan 路由
    local table_id=$(ip -4 rule show 2>/dev/null | grep "11998:" | sed -n 's/.*lookup //p' | tr -d '[:space:]')
    if [ -n "$table_id" ]; then
        if ip route show table "$table_id" 2>/dev/null | grep -q -E "dev wlan[0-9]"; then
            return 0
        fi
    fi
    return 1
}

daemon() {
    local today
    local ts
    local SCRIPT_DIR="/data/adb/modules/app_net_router/scripts"
    
    daemon_log() {
        today=$(date '+%Y-%m-%d')
        ts=$(date '+%H:%M:%S')
        echo "[$ts] [wg_health] $1" >> "/data/adb/modules/app_net_router/logs/anr_${today}.log" 2>/dev/null
    }

    daemon_log "健康检测守护进程启动"
    DAEMON_START=$(date +%s)

    while true; do
        sleep 30
        if ! ip link show wg0 >/dev/null 2>&1; then
            daemon_log "wg0 接口已关闭，守护进程退出"
            exit 0
        fi

        # 如果处于家庭局域网直连状态，跳过检测
        if is_wifi_direct; then
            continue
        fi

        HANDSHAKE=$(LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib $WG show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
        NOW=$(date +%s)
        
        if [ -n "$HANDSHAKE" ]; then
            if [ "$HANDSHAKE" -gt 0 ]; then
                AGE=$((NOW - HANDSHAKE))
                if [ "$AGE" -gt 120 ]; then
                    daemon_log "⚠ WireGuard 握手超时 (${AGE}s)，重新启动隧道"
                    sh "$SCRIPT_DIR/wg_start.sh" restart
                    exit 0
                fi
            else
                # 未检测到初始握手，检查启动时间
                UP_TIME=$((NOW - DAEMON_START))
                if [ "$UP_TIME" -gt 120 ]; then
                    daemon_log "⚠ 未检测到初始握手 (${UP_TIME}s)，重新启动隧道"
                    sh "$SCRIPT_DIR/wg_start.sh" restart
                    exit 0
                fi
            fi
        fi
    done
}

case "$1" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    restart) stop; sleep 1; sh "/data/adb/modules/app_net_router/scripts/apply_rules.sh" ;;
    daemon)  daemon ;;
    *)  echo "用法: $0 {start|stop|status|restart|daemon}" ;;
esac
