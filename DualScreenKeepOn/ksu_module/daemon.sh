#!/system/bin/sh

# 双屏常亮守护进程 v2
# 原理：阻止系统在展开内屏时关闭外屏
# 通过持续监控并重置 device_state 来实现

sleep 20

# 先确保内屏亮起
cd /data/local/tmp
if [ -f DualScreenDaemon.dex ]; then
    CLASSPATH=/data/local/tmp/DualScreenDaemon.dex app_process /data/local/tmp DualScreenDaemon once 2>/dev/null
fi

# 主循环
while true; do
    # 检查外屏背光是否被关闭
    BL_POWER=$(cat /sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel1-backlight/bl_power 2>/dev/null)
    
    if [ "$BL_POWER" != "0" ] 2>/dev/null; then
        # 外屏被关闭了，重新点亮
        # 先重置 device_state
        cmd device_state state reset 2>/dev/null
        sleep 1
        
        # 重新点亮内屏
        if [ -f /data/local/tmp/DualScreenDaemon.dex ]; then
            CLASSPATH=/data/local/tmp/DualScreenDaemon.dex app_process /data/local/tmp DualScreenDaemon once 2>/dev/null
        fi
        
        # 设置背光
        echo 0 > /sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel1-backlight/bl_power 2>/dev/null
        echo 2047 > /sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel1-backlight/brightness 2>/dev/null
    fi
    
    sleep 3
done
