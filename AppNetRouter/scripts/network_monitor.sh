#!/system/bin/sh
##########################################################
# network_monitor.sh — 网络状态监控守护进程
#
# 功能: 监控蜂窝/WiFi 状态变化，自动重新应用路由规则
# 用法: sh network_monitor.sh &
##########################################################

MODDIR=${MODDIR:-/data/adb/modules/app_net_router}
LOGFILE="$MODDIR/logs/monitor.log"
CHECK_INTERVAL=30  # 秒

log() {
    local ts=$(date '+%m-%d %H:%M:%S')
    echo "[$ts] [monitor] $1" >> "$LOGFILE" 2>/dev/null
}

# 获取当前蜂窝路由表号
get_current_cell_table() {
    local ifaces=$(ip -6 addr show 2>/dev/null | grep -B2 'scope global' | grep 'rmnet_data' | awk -F'[ @]' '{print $2}')
    local cell_if=$(echo "$ifaces" | head -1)
    [ -z "$cell_if" ] && echo "" && return

    ip -6 route show table all 2>/dev/null | grep "default.*dev $cell_if" | head -1 | sed -n 's/.*table \([0-9]*\).*/\1/p'
}

# 获取 WiFi 状态
get_wifi_state() {
    ip link show wlan0 2>/dev/null | grep -c 'UP'
}

log "监控守护进程启动 (间隔 ${CHECK_INTERVAL}s)"

# 上次状态
LAST_CELL_TABLE=$(cat "$MODDIR/logs/.cell_table_v6" 2>/dev/null)
LAST_WIFI_STATE=$(get_wifi_state)

while true; do
    sleep $CHECK_INTERVAL

    # 检查模块是否被禁用
    [ -f "$MODDIR/disable" ] && {
        log "模块已禁用，清理规则"
        sh "$MODDIR/scripts/apply_rules.sh" --clean
        LAST_CELL_TABLE=""
        # 等待模块重新启用
        while [ -f "$MODDIR/disable" ]; do sleep 60; done
        log "模块已重新启用"
    }

    # 获取当前状态
    CUR_CELL_TABLE=$(get_current_cell_table)
    CUR_WIFI_STATE=$(get_wifi_state)

    # 检测变化
    CHANGED=0

    # 蜂窝路由表变化
    if [ "$CUR_CELL_TABLE" != "$LAST_CELL_TABLE" ]; then
        log "蜂窝路由表变化: $LAST_CELL_TABLE → $CUR_CELL_TABLE"
        CHANGED=1
    fi

    # WiFi 状态变化
    if [ "$CUR_WIFI_STATE" != "$LAST_WIFI_STATE" ]; then
        log "WiFi 状态变化: $LAST_WIFI_STATE → $CUR_WIFI_STATE"
        CHANGED=1
    fi

    # 重新应用规则
    if [ $CHANGED -eq 1 ]; then
        if [ -n "$CUR_CELL_TABLE" ] && [ "$CUR_WIFI_STATE" -gt 0 ]; then
            log "WiFi + 蜂窝均在线，重新应用分流规则"
            sh "$MODDIR/scripts/apply_rules.sh"
        elif [ "$CUR_WIFI_STATE" -eq 0 ]; then
            log "WiFi 已断开，清理分流规则（全走蜂窝）"
            sh "$MODDIR/scripts/apply_rules.sh" --clean
        elif [ -z "$CUR_CELL_TABLE" ]; then
            log "蜂窝已断开，清理分流规则（全走 WiFi）"
            sh "$MODDIR/scripts/apply_rules.sh" --clean
        fi

        LAST_CELL_TABLE="$CUR_CELL_TABLE"
        LAST_WIFI_STATE="$CUR_WIFI_STATE"
    fi

    # 日志轮转（保留最近 500 行）
    local line_count=$(wc -l < "$LOGFILE" 2>/dev/null)
    if [ "${line_count:-0}" -gt 1000 ]; then
        tail -500 "$LOGFILE" > "$LOGFILE.tmp"
        mv "$LOGFILE.tmp" "$LOGFILE"
    fi
done
