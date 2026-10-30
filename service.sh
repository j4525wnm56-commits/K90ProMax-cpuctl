#!/system/bin/sh
# 开机自启: 等系统启动完成 -> 恢复档位 -> 起 HUD 守护 -> 起悬浮窗并补权限
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/k90_cpuctl
STATE=/data/adb/k90_cpuctl
PKG=com.langrm.k90hud

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 150 ]; do
    sleep 2
    i=$((i + 1))
done

sh "$MODDIR/bin/cpuctl" boot >/dev/null 2>&1 &

# 状态栏 HUD 采样守护(上次开了就继续开)
if [ "$(cat "$STATE/hud_enabled" 2>/dev/null)" = "1" ]; then
    sleep 3
    # 走 cpuctl 而不是直接 hud_run.sh: 它会先清陈旧锁再拉起
    sh "$MODDIR/bin/cpuctl" hud on >/dev/null 2>&1
fi

# 悬浮窗 App: 模块自带了一份 APK, 没装就装上
if [ -f "$MODDIR/K90HUD.apk" ] && ! pm list packages 2>/dev/null | grep -q "$PKG"; then
    pm install -r -g "$MODDIR/K90HUD.apk" >/dev/null 2>&1
    sleep 2
fi

if pm list packages 2>/dev/null | grep -q "$PKG"; then
    # appops 必须每次补: 重装 APK 会把它重置成 ignore, 窗口在但不显示(实测 mAppOpVisibility=false)
    appops set "$PKG" SYSTEM_ALERT_WINDOW allow 2>/dev/null
    am start-foreground-service -n "$PKG/.HudService" >/dev/null 2>&1
    # 那条 ONGOING 的"正在其他应用的上层显示内容"通知划不掉, 只能 snooze(hud.sh 里会每 50 分钟续)
    cmd notification snooze --for 3600000 \
        "0|android|0|com.android.server.wm.AlertWindowNotification - $PKG|1000" >/dev/null 2>&1
fi
