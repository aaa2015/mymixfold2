#!/system/bin/sh
##########################################################
# net_monitor.sh — 蜂窝接口变化监控 + WireGuard 自动修复
#
# 每 10 秒检测:
#   1. 蜂窝接口变化 → 重新应用路由规则
#   2. WireGuard 握手超时 → 自动修复
#
# SSH 路由由 smart_connect.sh 在连接时实时 mDNS 探测决定
##########################################################

MODDIR=${MODDIR:-/data/adb/modules/app_net_router}
LOGDIR="$MODDIR/logs"
STATE_FILE="$LOGDIR/.last_cell_if"
CHECK_INTERVAL=10

log() {
    local today=$(date '+%Y-%m-%d')
    local ts=$(date '+%H:%M:%S')
    echo "[$ts] [monitor] $1" >> "$LOGDIR/anr_${today}.log" 2>/dev/null
}

get_cell_if() {
    dumpsys connectivity 2>/dev/null \
        | grep "NetworkAgentInfo.*MOBILE.*CONNECTED.*INTERNET" \
        | sed -n 's/.*InterfaceName: \([^ ]*\).*/\1/p' \
        | grep 'rmnet_data' \
        | head -1
}

mkdir -p "$LOGDIR"
log "监控启动 (间隔 ${CHECK_INTERVAL}s)"

# 初始化
LAST_IF=$(cat "$STATE_FILE" 2>/dev/null)
TRAFFIC_COUNTER=0
TRAFFIC_INTERVAL=30   # 每 30 个周期 (5分钟) 记录一次流量

while true; do
    # === 蜂窝接口变化检测 ===
    CURRENT_IF=$(get_cell_if)

    if [ -n "$CURRENT_IF" ] && [ "$CURRENT_IF" != "$LAST_IF" ]; then
        log "⚡ 蜂窝接口变化: ${LAST_IF:-无} → $CURRENT_IF, 重新应用规则"
        sh "$MODDIR/scripts/apply_rules.sh" >> "$LOGDIR/anr_$(date '+%Y-%m-%d').log" 2>&1
        LAST_IF="$CURRENT_IF"
        echo "$CURRENT_IF" > "$STATE_FILE"
    elif [ -z "$CURRENT_IF" ] && [ -n "$LAST_IF" ]; then
        log "📴 蜂窝断开"
        : > "$STATE_FILE"
        LAST_IF=""
    fi

    # === WireGuard 握手超时检测 ===
    if ip link show wg0 >/dev/null 2>&1; then
        WG_BIN="/data/data/com.termux/files/usr/bin/wg"
        if [ -x "$WG_BIN" ]; then
            HANDSHAKE=$(LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib $WG_BIN show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
            NOW=$(date +%s)
            if [ -n "$HANDSHAKE" ] && [ "$HANDSHAKE" -gt 0 ] 2>/dev/null; then
                AGE=$((NOW - HANDSHAKE))
                if [ "$AGE" -gt 180 ]; then
                    log "⚠ WireGuard 握手超时 (${AGE}s), 重新应用路由"
                    sh "$MODDIR/scripts/apply_rules.sh" >> "$LOGDIR/anr_$(date '+%Y-%m-%d').log" 2>&1
                fi
            fi
        fi
    fi

    # === 定时流量统计 ===
    TRAFFIC_COUNTER=$((TRAFFIC_COUNTER + 1))
    if [ "$TRAFFIC_COUNTER" -ge "$TRAFFIC_INTERVAL" ]; then
        TRAFFIC_COUNTER=0
        if [ -x "$MODDIR/scripts/traffic_stats.sh" ]; then
            MODDIR="$MODDIR" sh "$MODDIR/scripts/traffic_stats.sh" --log 2>/dev/null
            log "📈 流量统计已记录"
        fi
    fi

    sleep $CHECK_INTERVAL
done
