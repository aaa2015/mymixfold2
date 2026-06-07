#!/system/bin/sh
##########################################################
# traffic_stats.sh — 每应用 WiFi/蜂窝 流量统计
#
# 数据来源: dumpsys netstats detail (系统级 per-UID 统计)
# 用法:
#   traffic_stats.sh          → 显示当前统计 (按总流量排序)
#   traffic_stats.sh --log    → 追加到日志
#   traffic_stats.sh --cell   → 只看蜂窝流量
##########################################################

MODDIR=${MODDIR:-/data/adb/modules/app_net_router}
LOGDIR="$MODDIR/logs"
PACKAGES_LIST="/data/system/packages.list"
TMP="/data/local/tmp/traffic_$$"

human_bytes() {
    local b=$1
    if [ "$b" -ge 1073741824 ] 2>/dev/null; then
        awk "BEGIN{printf \"%.1fG\", $b/1073741824}"
    elif [ "$b" -ge 1048576 ] 2>/dev/null; then
        awk "BEGIN{printf \"%.1fM\", $b/1048576}"
    elif [ "$b" -ge 1024 ] 2>/dev/null; then
        awk "BEGIN{printf \"%.1fK\", $b/1024}"
    else
        echo "${b}B"
    fi
}

uid_to_pkg() {
    local uid=$1
    [ "$uid" = "0" ] && echo "root" && return
    [ "$uid" -lt 0 ] 2>/dev/null && echo "kernel($uid)" && return
    [ "$uid" -lt 10000 ] 2>/dev/null && echo "system($uid)" && return
    if [ -f "$PACKAGES_LIST" ]; then
        local pkg=$(awk -v u="$uid" '$2==u {print $1; exit}' "$PACKAGES_LIST")
        [ -n "$pkg" ] && echo "$pkg" && return
    fi
    echo "uid:$uid"
}

collect_stats() {
    # 解析 dumpsys netstats detail
    # 格式:
    #   ident=[{type=0, ...}] uid=10300 set=FOREGROUND tag=0x0
    #     NetworkStatsHistory: bucketDuration=7200
    #       st=1780740000 rb=1058885 rp=819 tb=34529 tp=392 op=0
    # type=0 → 蜂窝, type=1 → WiFi, type=17 → VPN

    dumpsys netstats detail 2>/dev/null | awk '
    /ident=.*type=/ {
        type = ""
        uid = ""
        if (match($0, /type=[0-9]+/)) {
            type = substr($0, RSTART+5, RLENGTH-5)
        }
        if (match($0, /uid=[0-9-]+/)) {
            uid = substr($0, RSTART+4, RLENGTH-4)
        }
        next
    }
    /st=[0-9]+ rb=/ {
        if (uid == "" || type == "") next
        rb = 0; tb = 0
        if (match($0, /rb=[0-9]+/)) rb = substr($0, RSTART+3, RLENGTH-3)
        if (match($0, /tb=[0-9]+/)) tb = substr($0, RSTART+3, RLENGTH-3)
        total = rb + tb
        if (total > 0) {
            # type 0=cell, 1=wifi, 17=vpn
            if (type == "0") {
                cell_rx[uid] += rb
                cell_tx[uid] += tb
            } else if (type == "1") {
                wifi_rx[uid] += rb
                wifi_tx[uid] += tb
            }
        }
        next
    }
    END {
        for (uid in cell_rx) uids[uid] = 1
        for (uid in cell_tx) uids[uid] = 1
        for (uid in wifi_rx) uids[uid] = 1
        for (uid in wifi_tx) uids[uid] = 1

        for (uid in uids) {
            wr = wifi_rx[uid] + 0
            wt = wifi_tx[uid] + 0
            cr = cell_rx[uid] + 0
            ct = cell_tx[uid] + 0
            w = wr + wt
            c = cr + ct
            t = w + c
            if (t > 0) {
                printf "%s %d %d %d %d %d %d %d\n", uid, wr, wt, w, cr, ct, c, t
            }
        }
    }' | sort -t' ' -k8 -rn > "$TMP"
}

show_stats() {
    local only_cell=$1
    collect_stats

    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo ""
    echo "📊 流量统计 ($ts)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-28s  %8s %8s │ %8s %8s │ %8s\n" "应用" "WiFi↓" "WiFi↑" "蜂窝↓" "蜂窝↑" "总计"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local total_wifi=0 total_cell=0

    while read uid wr wt w cr ct c t; do
        [ -z "$uid" ] && continue
        if [ "$only_cell" = "1" ] && [ "$c" -eq 0 ]; then
            continue
        fi
        pkg=$(uid_to_pkg "$uid")
        pkg_disp=$(echo "$pkg" | cut -c1-28)
        total_wifi=$((total_wifi + w))
        total_cell=$((total_cell + c))

        # 蜂窝有流量标红
        cell_mark=""
        [ "$c" -gt 0 ] && cell_mark="⚠"

        printf "%-28s  %8s %8s │ %8s %8s │ %8s %s\n" \
            "$pkg_disp" \
            "$(human_bytes $wr)" "$(human_bytes $wt)" \
            "$(human_bytes $cr)" "$(human_bytes $ct)" \
            "$(human_bytes $t)" "$cell_mark"
    done < "$TMP"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-28s  %8s          │ %8s          │ %8s\n" \
        "合计" "$(human_bytes $total_wifi)" "$(human_bytes $total_cell)" "$(human_bytes $((total_wifi + total_cell)))"
    echo ""

    rm -f "$TMP"
}

case "$1" in
    --cell)
        show_stats 1
        ;;
    --log)
        show_stats 0 >> "$LOGDIR/traffic_$(date '+%Y-%m-%d').log"
        echo "✓ 已写入 $LOGDIR/traffic_$(date '+%Y-%m-%d').log"
        ;;
    *)
        show_stats 0
        ;;
esac
