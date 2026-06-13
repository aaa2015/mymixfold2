#!/system/bin/sh
# WireGuard 状态查询 — 结果写入文件供 WebUI 读取
WG="/data/data/com.termux/files/usr/bin/wg"
export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib
MODDIR="/data/adb/modules/app_net_router"
OUT="$MODDIR/logs/wg_status.txt"
START_FILE="$MODDIR/logs/.wg_start_time"

mkdir -p "$(dirname "$OUT")"

ip link show wg0 2>/dev/null | grep -q UP || { echo "DOWN" > "$OUT"; exit 0; }

wg_out=$($WG show wg0 2>/dev/null)

# ---- 握手时间 ----
hs_line=$(echo "$wg_out" | grep "latest handshake")
hs_time="无"
hs_ago=""
if [ -n "$hs_line" ]; then
    secs=0
    num=0
    for token in $(echo "$hs_line" | sed 's/.*: //;s/,//g;s/ ago//'); do
        case "$token" in
            second*) secs=$((secs + num)) ;;
            minute*) secs=$((secs + num * 60)) ;;
            hour*)   secs=$((secs + num * 3600)) ;;
            day*)    secs=$((secs + num * 86400)) ;;
            [0-9]*)  num=$token ;;
        esac
    done
    hs_ago=$secs
    hs_epoch=$(($(date +%s) - secs))
    hs_time=$(date -d @"$hs_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$hs_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "无")
fi

# ---- 启动时间 ----
start_time="无"
if [ -f "$START_FILE" ]; then
    start_time=$(cat "$START_FILE" | tr -d '\n\r')
fi

# ---- IP 地址 ----
local_ip=$(ip -4 addr show wg0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
# remote_ip: 取 allowed-ips 的网关地址（将 x.x.x.0 → x.x.x.1）
raw_allowed=$($WG show wg0 allowed-ips 2>/dev/null | awk '{print $2}')
if echo "$raw_allowed" | grep -q '/'; then
    net_addr=$(echo "$raw_allowed" | cut -d/ -f1)
    # 如果是 .0 结尾的网段,改成 .1 (网关)
    if echo "$net_addr" | grep -qE '\.0$'; then
        remote_ip=$(echo "$net_addr" | sed 's/\.0$/.1/')
    else
        remote_ip="$net_addr"
    fi
else
    remote_ip="$raw_allowed"
fi
# remote_endpoint: 正确解析 IPv4 和 IPv6 endpoint
raw_endpoint=$($WG show wg0 endpoints 2>/dev/null | awk '{print $2}')
if echo "$raw_endpoint" | grep -q '\['; then
    # IPv6: [addr]:port → 提取 addr
    remote_ipv6=$(echo "$raw_endpoint" | sed 's/\[//;s/\]:[0-9]*//')
else
    # IPv4: addr:port → 原样保留
    remote_ipv6="$raw_endpoint"
fi

# ---- 本机 IPv6（在重定向外执行 dumpsys）----
local_ipv6=""
cell_if=$(LD_LIBRARY_PATH="" dumpsys connectivity 2>/dev/null \
    | grep "MOBILE.*CONNECTED.*INTERNET" \
    | grep -o "InterfaceName: [^ ]*" \
    | head -1 | cut -d' ' -f2)
if [ -n "$cell_if" ]; then
    local_ipv6=$(ip -6 addr show "$cell_if" 2>/dev/null | grep "scope global" | head -1 | awk '{print $2}' | cut -d/ -f1)
fi
if [ -z "$local_ipv6" ]; then
    local_ipv6=$(ip -6 addr show wlan0 2>/dev/null | grep "scope global" | head -1 | awk '{print $2}' | cut -d/ -f1)
fi

# ---- 流量（分开发送/接收）----
transfer_line=$(echo "$wg_out" | grep "transfer:" | sed 's/.*transfer: //')
transfer_recv=$(echo "$transfer_line" | cut -d',' -f1 | sed 's/ received//')
transfer_sent=$(echo "$transfer_line" | cut -d',' -f2 | sed 's/^ *//;s/ sent//')

# ---- 远程连接状态（直接 ping 判断，不依赖 IPv6）----
ping_time=""
ping_rtt=""
ping_out=$(ping -c1 -W2 10.10.10.1 2>/dev/null)
if [ $? -eq 0 ]; then
    remote_status="connected"
    ping_time=$(date '+%Y-%m-%d %H:%M:%S')
    ping_rtt=$(echo "$ping_out" | grep 'time=' | sed 's/.*time=\([0-9.]*\).*/\1/')
else
    # 区分: 有握手但 ping 不通 = 重连中; 完全没握手 = 未连接
    if [ -n "$hs_ago" ] && [ "$hs_ago" -lt 180 ] 2>/dev/null; then
        remote_status="reconnecting"
    else
        remote_status="disconnected"
    fi
fi

# ---- 写入结果 ----
cat > "$OUT" <<EOF
UP
interface: wg0
start_time: ${start_time:-无}
handshake_time: ${hs_time}
handshake_ago: ${hs_ago:-}
local_ip: ${local_ip:-无}
remote_ip: ${remote_ip:-无}
local_ipv6: ${local_ipv6:-无}
remote_ipv6: ${remote_ipv6:-无}
transfer_sent: ${transfer_sent:-0 B}
transfer_recv: ${transfer_recv:-0 B}
remote_status: ${remote_status}
ping_time: ${ping_time:-无}
ping_rtt: ${ping_rtt:-}
EOF
