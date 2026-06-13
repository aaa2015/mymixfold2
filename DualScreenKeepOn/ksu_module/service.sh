#!/system/bin/sh

# 双屏常亮 - KernelSU 模块
# 开机自启动

MODDIR=${0%/*}

# 等待系统启动完成
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 5
done

# 启动守护进程
nohup $MODDIR/daemon.sh > /data/local/tmp/dualscreen_keepon.log 2>&1 &
