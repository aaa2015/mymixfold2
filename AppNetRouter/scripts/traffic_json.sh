#!/system/bin/sh
# traffic_json.sh — 输出 JSON 格式的流量数据
MODDIR=${MODDIR:-/data/adb/modules/app_net_router}
PACKAGES_LIST="/data/system/packages.list"

uid_to_pkg() {
    local uid=$1
    [ "$uid" = "0" ] && echo "root" && return
    [ "$uid" -lt 0 ] 2>/dev/null && echo "kernel" && return
    [ "$uid" -lt 10000 ] 2>/dev/null && echo "system($uid)" && return
    if [ -f "$PACKAGES_LIST" ]; then
        local pkg=$(awk -v u="$uid" '$2==u {print $1; exit}' "$PACKAGES_LIST")
        [ -n "$pkg" ] && echo "$pkg" && return
    fi
    echo "uid:$uid"
}

# 获取接口级流量
wifi_rx=$(cat /proc/net/dev | awk '/wlan0/ {gsub(/.*:/, ""); print $1}')
wifi_tx=$(cat /proc/net/dev | awk '/wlan0/ {gsub(/.*:/, ""); print $9}')
cell_if=$(cat "$MODDIR/logs/.cell_if" 2>/dev/null)
cell_rx=0; cell_tx=0
if [ -n "$cell_if" ]; then
    cell_rx=$(cat /proc/net/dev | awk -v iface="$cell_if" '$0 ~ iface {gsub(/.*:/, ""); print $1}')
    cell_tx=$(cat /proc/net/dev | awk -v iface="$cell_if" '$0 ~ iface {gsub(/.*:/, ""); print $9}')
fi

echo "{"
echo "\"timestamp\":\"$(date '+%Y-%m-%d %H:%M:%S')\","
echo "\"cell_if\":\"${cell_if:-none}\","
echo "\"interface\":{\"wifi_rx\":${wifi_rx:-0},\"wifi_tx\":${wifi_tx:-0},\"cell_rx\":${cell_rx:-0},\"cell_tx\":${cell_tx:-0}},"

# WireGuard 状态
wg_status="down"
wg_handshake=0
if ip link show wg0 >/dev/null 2>&1; then
    wg_status="up"
    WG_BIN="/data/data/com.termux/files/usr/bin/wg"
    if [ -x "$WG_BIN" ]; then
        hs=$(LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib $WG_BIN show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
        [ -n "$hs" ] && wg_handshake=$hs
    fi
fi
echo "\"wireguard\":{\"status\":\"$wg_status\",\"handshake\":$wg_handshake},"

# WiFi 信息
ssid=$(dumpsys wifi 2>/dev/null | grep "mWifiInfo SSID" | head -1 | sed -n 's/.*SSID: "\([^"]*\)".*/\1/p')
echo "\"wifi_ssid\":\"${ssid:-disconnected}\","

# Per-UID 流量
echo "\"apps\":["
dumpsys netstats detail 2>/dev/null | awk '
/ident=.*type=/ {
    type=""; uid=""
    if (match($0, /type=[0-9]+/)) type=substr($0, RSTART+5, RLENGTH-5)
    if (match($0, /uid=[0-9-]+/)) uid=substr($0, RSTART+4, RLENGTH-4)
    next
}
/st=[0-9]+ rb=/ {
    if (uid=="" || type=="") next
    rb=0; tb=0
    if (match($0, /rb=[0-9]+/)) rb=substr($0, RSTART+3, RLENGTH-3)
    if (match($0, /tb=[0-9]+/)) tb=substr($0, RSTART+3, RLENGTH-3)
    if (type=="0") { cell_rx[uid]+=rb; cell_tx[uid]+=tb }
    else if (type=="1") { wifi_rx[uid]+=rb; wifi_tx[uid]+=tb }
    next
}
END {
    for (uid in cell_rx) uids[uid]=1
    for (uid in cell_tx) uids[uid]=1
    for (uid in wifi_rx) uids[uid]=1
    for (uid in wifi_tx) uids[uid]=1
    first=1
    for (uid in uids) {
        wr=wifi_rx[uid]+0; wt=wifi_tx[uid]+0
        cr=cell_rx[uid]+0; ct=cell_tx[uid]+0
        t=wr+wt+cr+ct
        if (t>0) {
            if (!first) printf ","
            printf "{\"uid\":\"%s\",\"wr\":%d,\"wt\":%d,\"cr\":%d,\"ct\":%d}", uid, wr, wt, cr, ct
            first=0
        }
    }
}' 

# UID → 包名映射
echo "],"
echo "\"uid_map\":{"
first=1
if [ -f "$PACKAGES_LIST" ]; then
    awk '{
        if (NR>1) printf ","
        gsub(/"/, "\\\"", $1)
        printf "\"%s\":\"%s\"", $2, $1
    }' "$PACKAGES_LIST"
fi
echo ",\"0\":\"root\""
echo "}"
echo "}"
