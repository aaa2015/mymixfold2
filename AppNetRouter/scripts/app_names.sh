#!/system/bin/sh
# app_names.sh — 批量获取 app 显示名称
# 输出: 包名:显示名 (每行一个)
# 来源: MIUI launcher 数据库 + packages.list

# 从 launcher 数据库获取有 label 的 app
content query --uri content://com.miui.home.launcher.settings/favorites \
    --projection title:intent --where "itemType=0" 2>/dev/null \
    | sed -n 's/.*title=\([^,]*\), intent=.*component=\([^\/;]*\).*/\2:\1/p'
