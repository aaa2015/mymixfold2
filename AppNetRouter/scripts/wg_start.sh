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

case "$1" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    restart) stop; sleep 1; start ;;
    *)  echo "用法: $0 {start|stop|status|restart}" ;;
esac
