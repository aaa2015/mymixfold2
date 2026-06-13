#!/system/bin/sh
# WireGuard 隧道启动脚本
# 电信蜂窝 IPv6 直连到 Mac macmini

WG="/data/data/com.termux/files/usr/bin/wg"
WG_CONF="/data/data/com.termux/files/usr/etc/wireguard/wg0.conf"
PRIV_KEY_FILE="/data/local/tmp/wg_priv.key"

# WireGuard 配置
CLIENT_PRIV=$(grep 'PrivateKey' "$WG_CONF" | awk -F' = ' '{print $2}')
SERVER_PUB=$(grep 'PublicKey' "$WG_CONF" | awk -F' = ' '{print $2}')
ENDPOINT=$(grep 'Endpoint' "$WG_CONF" | awk -F' = ' '{print $2}')

log() { echo "[WG] $(date '+%H:%M:%S') $1"; }

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

    # 设置 peer
    $WG set wg0 peer "$SERVER_PUB" \
        endpoint "$ENDPOINT" \
        allowed-ips 10.10.10.1/32 \
        persistent-keepalive 25

    # 配置地址并启动
    ip addr add 10.10.10.2/24 dev wg0
    ip link set wg0 up

    log "WireGuard 已启动"
    $WG show

    # 启动后台健康检测 daemon
    nohup sh "$0" daemon >/dev/null 2>&1 &
}

stop() {
    ip link del wg0 2>/dev/null
    log "WireGuard 已停止"
}

status() {
    ip link show wg0 >/dev/null 2>&1 && {
        $WG show
    } || {
        log "WireGuard 未运行"
    }
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
    restart) stop; sleep 1; start ;;
    daemon)  daemon ;;
    *)  echo "用法: $0 {start|stop|status|restart|daemon}" ;;
esac
