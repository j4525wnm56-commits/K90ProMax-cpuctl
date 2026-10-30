#!/bin/sh
# 安装 + 授权 + 启动，然后截图状态栏区域方便调位置
set -e
ADB=${ADB:-$HOME/.workbuddy/bin/platform-tools/adb}
PKG=com.langrm.k90hud
APK=${1:-build/k90hud.apk}

D=$("$ADB" devices | awk 'NR==2 && $2=="device"{print $1}')
[ -n "$D" ] || { echo "没有已授权的设备"; exit 1; }
echo "设备: $D"

"$ADB" -s "$D" install -r "$APK"
# install 完成后要等一下, 否则紧接着的 appops/启动会撞上包替换过程
sleep 2

# 悬浮窗权限: 用 appops 直接授权, 省得手点
# 注意: install -r 会把 SYSTEM_ALERT_WINDOW 重置成 ignore(窗口在但完全不显示), 必须补
"$ADB" -s "$D" shell "su -c 'appops set $PKG SYSTEM_ALERT_WINDOW allow'" 2>/dev/null || \
  "$ADB" -s "$D" shell "appops set $PKG SYSTEM_ALERT_WINDOW allow"

# 通知权限(前台服务通知)
"$ADB" -s "$D" shell "pm grant $PKG android.permission.POST_NOTIFICATIONS" 2>/dev/null || true

# 关键: 若用户之前在 App 里关过悬浮窗(hud_on=false), 服务会自杀、起不来。
# 这里显式打开, 保证"刚装完一定有悬浮窗"。
"$ADB" -s "$D" shell "su -c \"sed -i 's|name=hud_on value=\\\"false\\\"|name=hud_on value=\\\"true\\\"|' /data/data/$PKG/shared_prefs/hud.xml\"" 2>/dev/null || true

# 拉起服务
"$ADB" -s "$D" shell "am start-foreground-service -n $PKG/.HudService" || \
  "$ADB" -s "$D" shell "su -c 'am start-foreground-service -n $PKG/.HudService'"

sleep 2
echo "--- 服务状态 ---"
"$ADB" -s "$D" shell "dumpsys activity services $PKG | head -20"
echo
echo "--- 悬浮窗是否真的在(权限被重置的话这里会是 0) ---"
"$ADB" -s "$D" shell "dumpsys window windows | grep -c package=$PKG"
echo
echo "提示: 想调位置就打开「K90 HUD」App 拖滑块, 或直接改 prefs:"
echo "  adb shell su -c 'run-as $PKG ...'  (不方便时就用 App 里的滑块)"
