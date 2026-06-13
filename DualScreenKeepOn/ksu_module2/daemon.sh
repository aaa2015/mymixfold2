#!/system/bin/sh

# ============================================================
# 双屏同时显示守护进程 v4.0
# 小米 Mix Fold 2 (22061218C)
#
# 原理：
#   1. 展开时设置 device_state = 5 (OPENED_PRESENTATION)
#      让内屏和外屏同时点亮
#   2. 在内屏 (display 1, presentation) 上自动启动 Launcher
#      让内屏也有渲染内容（否则只是背光亮但黑屏）
#
# 物理屏幕映射（小米 Mix Fold 2 特殊）：
#   HWC 0, port=130 → 外屏 (1914x2160) → display 0 (主屏)
#   HWC 1, port=131 → 内屏 (1080x2520) → display 1 (在state5下为presentation)
#
# Device States:
#   0 = CLOSED        (折叠，仅外屏)
#   3 = OPENED        (展开，仅外屏作为主屏)
#   5 = OPENED_PRESENTATION (展开，双屏亮)
# ============================================================

TAG="DualScreenKeepOn"
LOGFILE="/data/local/tmp/dualscreen_v3.log"
ENABLED_FILE="/data/local/tmp/dualscreen_enabled"

# 目标 device_state
TARGET_STATE=5

# Presentation display ID (内屏, 在 state 5 下)
PRESENT_DISPLAY=1

# 轮询间隔（秒）
POLL_ACTIVE=1
POLL_IDLE=2

write_log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') [$TAG] $1"
    echo "$msg" >> "$LOGFILE"
}

get_base_state() {
    dumpsys device_state 2>/dev/null | grep 'mLastReportedState' | awk -F'= ' '{print $2}' | tr -d ' \n\r'
}

is_override_active() {
    local override
    override=$(dumpsys device_state 2>/dev/null | grep 'mOverrideState' | grep -o "identifier=[0-9]*" | cut -d= -f2)
    [ "$override" = "$TARGET_STATE" ]
}

# 检查 display 1 上是否有窗口获得焦点
# 注意: mCurrentFocus 可能在 mDisplayId 后面很多行，不能用 grep -A3
has_content_on_display1() {
    local result
    result=$(dumpsys window displays 2>/dev/null | awk "/mDisplayId=$PRESENT_DISPLAY/{found=1} found && /mCurrentFocus=Window/{print \"YES\"; exit}")
    [ "$result" = "YES" ]
}

set_dual_screen() {
    cmd device_state state $TARGET_STATE 2>/dev/null
    write_log "已设置 device_state = $TARGET_STATE (OPENED_PRESENTATION)"

    # 等待 state 生效
    sleep 2

    # 重启 MIUI Home 修复手势导航
    # state 5 会导致 GestureStub 绑定到错误的 display
    # 重启后重新注册到 display 0
    am force-stop com.miui.home 2>/dev/null
    sleep 2
    if is_enabled; then
        am start --display 0 -n com.dualscreen.keepon/.MainActivity 2>/dev/null
    else
        am start -n com.miui.home/.launcher.Launcher 2>/dev/null
    fi
    sleep 3
    write_log "已重启 MIUI Home 修复手势导航并拉起主屏控制台"

    # 重启 Home 会清理 display 1 上的旧窗口，必须重置标记
    CONTENT_LAUNCHED=0

    # 在 display 1 (小屏) 上启动内容
    launch_on_presentation_display
}

# 在 presentation display 上启动 Launcher/Activity
# CONTENT_LAUNCHED 标记: 避免重复启动（只在状态变化时重置）
CONTENT_LAUNCHED=0

launch_on_presentation_display() {
    # 如果已经启动过且没有状态变化，跳过
    if [ "$CONTENT_LAUNCHED" = "1" ]; then
        return
    fi

    # 先检查 display 1 上是否已有内容
    if has_content_on_display1; then
        write_log "display $PRESENT_DISPLAY 上已有内容，跳过启动"
        CONTENT_LAUNCHED=1
        return
    fi

    write_log "在 display $PRESENT_DISPLAY 上启动 Launcher..."

    # 尝试启动 MIUI Launcher
    am start --display $PRESENT_DISPLAY \
        -n com.miui.home/.launcher.Launcher \
        -f 0x10000000 2>/dev/null

    # 等待窗口 focus 注册（需要较长时间）
    sleep 3
    if has_content_on_display1; then
        write_log "display $PRESENT_DISPLAY 上 Launcher 启动成功"
        CONTENT_LAUNCHED=1
        return
    fi

    # Launcher 不行，尝试启动设置
    write_log "Launcher 未获得焦点，尝试启动设置..."
    am start --display $PRESENT_DISPLAY \
        -n com.android.settings/.Settings \
        -f 0x10000000 2>/dev/null

    sleep 3
    if has_content_on_display1; then
        write_log "display $PRESENT_DISPLAY 上设置启动成功"
        CONTENT_LAUNCHED=1
    else
        write_log "display $PRESENT_DISPLAY 上启动内容失败，下次状态变化时重试"
        CONTENT_LAUNCHED=1  # 标记已尝试，避免轮询刷屏
    fi
}

reset_state() {
    cmd device_state state reset 2>/dev/null
    write_log "已重置 device_state override"
    # 重启 MIUI Home 以修复手势导航
    # state 5 会破坏 GestureStub 的 display 绑定
    sleep 1
    am force-stop com.miui.home 2>/dev/null
    sleep 1
    am start -n com.miui.home/.launcher.Launcher 2>/dev/null
    write_log "已重启 MIUI Home 修复手势导航"
}

is_enabled() {
    if [ -f "$ENABLED_FILE" ]; then
        [ "$(cat "$ENABLED_FILE" 2>/dev/null)" = "1" ]
    else
        echo "1" > "$ENABLED_FILE"
        return 0
    fi
}

# ============================================================
# 主逻辑
# ============================================================

sleep 15

write_log "=========================================="
write_log "双屏同时显示守护进程 v4.0 启动"
write_log "设备: $(getprop ro.product.model)"
write_log "Android: $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
write_log "=========================================="

LAST_BASE_STATE=""
DUAL_MODE_ACTIVE=0

# 启动时检查: 如果 override 已经是 active 的，同步状态
if is_override_active; then
    DUAL_MODE_ACTIVE=1
    write_log "启动时检测到 override 已激活，同步状态"
    # 确保 display 1 有内容
    if ! has_content_on_display1; then
        launch_on_presentation_display
    fi
fi

while true; do
    if ! is_enabled; then
        if [ "$DUAL_MODE_ACTIVE" = "1" ]; then
            reset_state
            DUAL_MODE_ACTIVE=0
            write_log "模块已禁用，退出双屏模式"
        fi
        sleep $POLL_IDLE
        continue
    fi

    BASE_STATE=$(get_base_state)

    if [ "$BASE_STATE" != "$LAST_BASE_STATE" ]; then
        write_log "物理状态变化: $LAST_BASE_STATE -> $BASE_STATE"
        LAST_BASE_STATE="$BASE_STATE"
    fi

    case "$BASE_STATE" in
        3|4|5|6)
            # OPENED 系列 — 开启双屏
            if ! is_override_active; then
                set_dual_screen
                DUAL_MODE_ACTIVE=1
            elif ! has_content_on_display1; then
                # override 已激活但 display 1 无内容
                launch_on_presentation_display
            fi
            sleep $POLL_ACTIVE
            ;;
        2)
            # HALF_OPENED — 也开启双屏
            if ! is_override_active; then
                set_dual_screen
                DUAL_MODE_ACTIVE=1
            fi
            sleep $POLL_ACTIVE
            ;;
        0)
            # CLOSED — 折叠
            if [ "$DUAL_MODE_ACTIVE" = "1" ]; then
                reset_state
                DUAL_MODE_ACTIVE=0
                CONTENT_LAUNCHED=0  # 重置，下次展开重新启动
                write_log "已折叠，退出双屏模式"
            fi
            sleep $POLL_IDLE
            ;;
        *)
            sleep $POLL_IDLE
            ;;
    esac
done

