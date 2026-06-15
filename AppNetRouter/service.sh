#!/system/bin/sh
##########################################################
# service.sh — 开机启动入口
#
# KernelSU 在系统启动完成后执行此脚本
##########################################################

MODDIR=${0%/*}
export MODDIR

# 等待系统完全就绪
sleep 15

# 等待网络接口就绪
MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    # 检查 WiFi 和蜂窝是否都 UP
    WIFI_UP=$(ip link show wlan0 2>/dev/null | grep -c 'UP')
    CELL_UP=$(ip link show 2>/dev/null | grep 'rmnet_data.*UP' | grep -cv 'DOWN')

    if [ "$WIFI_UP" -gt 0 ] && [ "$CELL_UP" -gt 0 ]; then
        break
    fi

    sleep 5
    WAITED=$((WAITED + 5))
done

# 应用路由规则
sh "$MODDIR/scripts/apply_rules.sh"

# 启动 WireGuard
sh "$MODDIR/scripts/wg_start.sh" start >/dev/null 2>&1

# 启动蜂窝接口变化监控 (自动更新 WG 路由)
sh "$MODDIR/scripts/net_monitor.sh" start
