#!/data/data/com.termux/files/usr/bin/sh
##########################################################
# smart_connect.sh — SSH ProxyCommand 智能路由
#
# 每次连接时 mDNS 探测 macmini:
#   找到 → 局域网直连 (动态 IP)
#   没找到 → WireGuard 隧道 (10.10.10.1)
##########################################################

WG_IP=10.10.10.1
PORT=22

# mDNS 解析 macmini (通过 _ssh._tcp 服务发现, 最多等 3 秒)
LAN_IP=$(CLASSPATH=/data/local/tmp/clipboard-helper.jar app_process / com.myphone.ClipboardHelper resolve macmini 2>/dev/null)

if [ -n "$LAN_IP" ] && echo "$LAN_IP" | grep -qE '^[0-9]+\.[0-9]+'; then
    exec nc "$LAN_IP" $PORT
else
    exec nc $WG_IP $PORT
fi
