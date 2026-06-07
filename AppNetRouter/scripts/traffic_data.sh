#!/system/bin/sh
# traffic_data.sh — 输出简单格式的 per-UID 流量数据
# 格式: uid wifi_rx wifi_tx cell_rx cell_tx (每行一个 UID)
dumpsys netstats detail 2>/dev/null | awk '
/ident=.*type=/ {
    t=""; u=""
    if (match($0, /type=[0-9]+/)) t=substr($0, RSTART+5, RLENGTH-5)
    if (match($0, /uid=[0-9-]+/)) u=substr($0, RSTART+4, RLENGTH-4)
    next
}
/st=[0-9]+ rb=/ {
    if (u=="" || t=="") next
    rb=0; tb=0
    if (match($0, /rb=[0-9]+/)) rb=substr($0, RSTART+3, RLENGTH-3)
    if (match($0, /tb=[0-9]+/)) tb=substr($0, RSTART+3, RLENGTH-3)
    if (t=="0") { cr[u]+=rb; ct[u]+=tb }
    else if (t=="1") { wr[u]+=rb; wt[u]+=tb }
    next
}
END {
    for (u in cr) U[u]=1
    for (u in ct) U[u]=1
    for (u in wr) U[u]=1
    for (u in wt) U[u]=1
    for (u in U) {
        printf "%s %d %d %d %d\n", u, wr[u]+0, wt[u]+0, cr[u]+0, ct[u]+0
    }
}'
