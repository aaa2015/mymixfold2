#!/system/bin/sh

# 双屏同时显示 - KernelSU 模块
# 开机自启动守护进程

MODDIR=${0%/*}
LOG=/data/local/tmp/dualscreen_v3.log

# 等待系统启动完成
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 5
done

# 额外等待 5 秒确保 display service 就绪
sleep 5

# 日志轮转：保留最近 500KB
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 512000 ]; then
    tail -c 256000 "$LOG" > "${LOG}.tmp"
    mv "${LOG}.tmp" "$LOG"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') [DualScreenKeepOn] service.sh 启动守护进程" >> "$LOG"

# 杀掉之前可能残留的守护进程
pkill -f "daemon.sh" 2>/dev/null

# 启动守护进程
nohup $MODDIR/daemon.sh >> "$LOG" 2>&1 &
