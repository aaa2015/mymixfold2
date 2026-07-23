#!/system/bin/sh
##########################################################
unset LD_LIBRARY_PATH
# net_monitor.sh — 蜂窝接口与 Wi-Fi 状态变化监听守护进程
#
# 功能: 检测蜂窝数据接口(rmnet_data)编号变化以及 Wi-Fi 在线状态变化，
#       自动重启 WireGuard 并重新应用路由规则
#
# 用法: sh net_monitor.sh start|stop|status
##########################################################

MODDIR=${MODDIR:-/data/adb/modules/app_net_router}
LOGDIR="$MODDIR/logs"
PIDFILE="$LOGDIR/.net_monitor.pid"
LOGFILE="$LOGDIR/net_monitor.log"
SCRIPTS="$MODDIR/scripts"
CHECK_INTERVAL=5  # 检查间隔(秒)

log() {
    echo "[NetMon] $(date '+%H:%M:%S') $1" >> "$LOGFILE"
    echo "[NetMon] $(date '+%H:%M:%S') $1"
}

# 获取当前主蜂窝数据接口 (有 INTERNET 能力的)
get_current_cell() {
    # 方法1: dumpsys connectivity
    local iface=$(LD_LIBRARY_PATH="" dumpsys connectivity 2>/dev/null \
        | grep "MOBILE.*CONNECTED.*INTERNET" \
        | grep -o "InterfaceName: [^ ]*" \
        | head -1 | cut -d' ' -f2)
    if [ -n "$iface" ]; then
        echo "$iface"
        return
    fi
    # 方法2: 有 IPv4 的 rmnet_data
    iface=$(ip -4 addr show 2>/dev/null \
        | grep -B1 "inet [0-9]" \
        | grep "rmnet_data" \
        | awk -F'[ :@]' '{for(i=1;i<=NF;i++) if($i ~ /rmnet_data/) {print $i; exit}}')
    [ -n "$iface" ] && echo "$iface"
}

# 获取当前 Wi-Fi 在线状态 (是否获得了 IP 地址)
get_wifi_status() {
    if ip -4 addr show wlan0 2>/dev/null | grep -q 'inet ' || ip -4 addr show wlan1 2>/dev/null | grep -q 'inet '; then
        echo "1"
    else
        echo "0"
    fi
}

# 获取 WG 当前使用的 endpoint 出口接口
get_wg_route_iface() {
    ip -6 rule 2>/dev/null | grep "priority 100" | awk '{print $NF}' | head -1
}

# 系统通知提醒 (利用 Android cmd notification post)
send_notification() {
    local title="$1"
    local text="$2"
    local tag="${3:-AppNetRouter}"

    if command -v cmd >/dev/null 2>&1; then
        cmd notification post -S bigtext "$tag" "$title" "$text" >/dev/null 2>&1 || true
    fi
}

# 根据 UID 查找包名
get_pkg_by_uid() {
    local target_uid=$1
    local pkg=""
    if [ -f "/data/system/packages.list" ]; then
        pkg=$(grep " $target_uid " /data/system/packages.list | awk '{print $1}' | head -1)
    fi
    if [ -z "$pkg" ]; then
        pkg=$(pm list packages -U 2>/dev/null | grep "uid:$target_uid" | sed 's/package://' | cut -d' ' -f1 | head -1)
    fi
    echo "${pkg:-UID $target_uid}"
}

# 监控双网模式下是否有 App 正在使用/尝试使用蜂窝流量并进行通知提醒
LAST_NOTIFY_TIME=0

check_cellular_traffic_alert() {
    local cell_if="$1"
    local now=$(date +%s)

    # 冷却时间：60 秒内最多通知一次，避免打扰
    if [ $((now - LAST_NOTIFY_TIME)) -lt 60 ]; then
        return
    fi

    local guard_stats=$(iptables -v -L ANR_CELL_GUARD -n -x 2>/dev/null)
    [ -z "$guard_stats" ] && return

    echo "$guard_stats" | grep "owner UID match" | while read -r line; do
        local bytes=$(echo "$line" | awk '{print $2}')
        local uid=$(echo "$line" | grep -oE "owner UID match [0-9]+" | awk '{print $4}')

        # 忽略 Root (UID 0)
        if [ -n "$uid" ] && [ "$uid" -ne 0 ] && [ "$bytes" -gt 1024 ]; then
            local kb=$((bytes / 1024))
            local pkg=$(get_pkg_by_uid "$uid")
            log "🔔 [双网消费提醒] 应用 $pkg (UID $uid) 正在使用蜂窝流量 (${kb} KB)"
            send_notification "【蜂窝流量消费提醒】" "手机连接 Wi-Fi 时，应用 $pkg (UID $uid) 正在使用蜂窝数据 (${kb} KB)" "cell_traffic_$uid"
            LAST_NOTIFY_TIME=$now
            break
        fi
    done
}

do_reapply() {
    log "🔄 网络状态变化，重新配置..."

    # 仅在 wg0 不在线时重启 WG（避免端口变化导致 CELL_GUARD 不匹配）
    if ! ip link show wg0 2>/dev/null | grep -q "UP"; then
        log "wg0 不在线，重启 WG..."
        sh "$SCRIPTS/wg_start.sh" restart >> "$LOGFILE" 2>&1
    fi

    # 重新应用路由规则（会读取当前 WG listen-port）
    sh "$SCRIPTS/apply_rules.sh" >> "$LOGFILE" 2>&1

    log "✅ 重新配置完成，当前接口: $2"
}

monitor_loop() {
    local last_iface=""
    local last_wifi="init"
    local fail_count=0

    log "===== 监听启动 ====="
    log "检查间隔: ${CHECK_INTERVAL}s"

    while true; do
        local current=$(get_current_cell)
        local current_wifi=$(get_wifi_status)

        if [ -z "$current" ]; then
            fail_count=$((fail_count + 1))
            if [ $fail_count -ge 6 ]; then
                log "⚠️ 连续 ${fail_count} 次无蜂窝接口"
                fail_count=0
            fi
            sleep "$CHECK_INTERVAL"
            continue
        fi
        fail_count=0

        # 首次运行: 无条件重新配置，确保 WG/路由与当前接口一致
        if [ -z "$last_iface" ] || [ "$last_wifi" = "init" ]; then
            last_iface="$current"
            last_wifi="$current_wifi"
            log "初始网络状态: 蜂窝=$current, Wi-Fi=$current_wifi，执行完整配置..."
            do_reapply "init" "$current"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # 接口变化或 Wi-Fi 联接状态变化检测（去抖：等3秒确认稳定）
        if [ "$current" != "$last_iface" ] || [ "$current_wifi" != "$last_wifi" ]; then
            sleep 3
            current=$(get_current_cell)
            current_wifi=$(get_wifi_status)
            [ -z "$current" ] && { sleep "$CHECK_INTERVAL"; continue; }
            if [ "$current" != "$last_iface" ] || [ "$current_wifi" != "$last_wifi" ]; then
                log "检测到变化: 蜂窝($last_iface → $current), Wi-Fi($last_wifi → $current_wifi)"
                do_reapply "$last_iface" "$current"
                last_iface="$current"
                last_wifi="$current_wifi"
            fi
        fi

        # 检查我们的自定义路由规则是否被 Android netd 清理了
        if ! ip rule 2>/dev/null | grep -q "7989:"; then
            log "⚠️ 检测到自定义路由规则被系统清理，正在重新应用..."
            do_reapply "$last_iface" "$current"
        fi

        # 当 Wi-Fi 与蜂窝双网共存时，检测是否有应用正在消耗蜂窝流量并发送通知
        if [ "$current_wifi" = "1" ] && [ -n "$current" ]; then
            check_cellular_traffic_alert "$current"
        fi

        # 定期检查 WG 是否有握手（每 60s 检一次）
        # 如果超过 3 分钟没握手，尝试重连
        if [ -f "$SCRIPTS/wg_start.sh" ]; then
            local wg_status=$(ip link show wg0 2>/dev/null | grep -c "UP")
            if [ "$wg_status" -eq 0 ]; then
                log "⚠️ wg0 不在线，重新启动"
                do_reapply "$last_iface" "$current"
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

case "$1" in
    start)
        # 检查是否已运行
        if [ -f "$PIDFILE" ]; then
            oldpid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
                if grep -q "net_monitor.sh" "/proc/$oldpid/cmdline" 2>/dev/null; then
                    echo "[NetMon] 已在运行 (PID $oldpid)"
                    exit 0
                fi
            fi
        fi
        mkdir -p "$LOGDIR"
        # 清理旧日志(保留最近 200 行)
        if [ -f "$LOGFILE" ]; then
            tail -200 "$LOGFILE" > "${LOGFILE}.tmp" 2>/dev/null
            mv "${LOGFILE}.tmp" "$LOGFILE" 2>/dev/null
        fi
        # 后台启动
        monitor_loop >/dev/null 2>&1 </dev/null &
        echo $! > "$PIDFILE"
        log "守护进程启动 (PID $!)"
        ;;
    stop)
        if [ -f "$PIDFILE" ]; then
            pid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$pid" ]; then
                kill "$pid" 2>/dev/null
                rm -f "$PIDFILE"
                log "守护进程已停止 (PID $pid)"
            fi
        else
            echo "[NetMon] 未在运行"
        fi
        ;;
    status)
        if [ -f "$PIDFILE" ]; then
            pid=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && grep -q "net_monitor.sh" "/proc/$pid/cmdline" 2>/dev/null; then
                echo "[NetMon] 运行中 (PID $pid)"
                echo "最近日志:"
                tail -5 "$LOGFILE" 2>/dev/null
            else
                echo "[NetMon] PID 文件存在但进程已停止"
                rm -f "$PIDFILE"
            fi
        else
            echo "[NetMon] 未运行"
        fi
        ;;
    *)
        echo "用法: $0 {start|stop|status}"
        exit 1
        ;;
esac
