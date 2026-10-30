#!/bin/sh
# 一条命令装好悬浮窗: 检查设备 -> 装 APK -> 授权悬浮窗 -> 拉起服务 -> 截图
#
#   ./setup.sh          # 装并启动
#   ./setup.sh --shot    # 只截图
set -e
ADB=${ADB:-$HOME/.workbuddy/bin/platform-tools/adb}
PY=${PY:-/Users/li/.workbuddy/binaries/python/envs/default/bin/python}
PKG=com.langrm.k90hud
APK=build/k90hud.apk
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

D=$("$ADB" devices | awk 'NR==2 && $2=="device"{print $1}')
if [ -z "$D" ]; then
    echo "没有已授权的设备。先把手机插上并在弹窗里点「允许 USB 调试」。"
    "$ADB" devices -l
    exit 1
fi
echo "设备: $D"

if [ "$1" = "--shot" ]; then
    "$ADB" -s "$D" exec-out screencap -p > /tmp/k90_shot.png
    "$PY" - <<'EOF'
from PIL import Image
im = Image.open('/tmp/k90_shot.png'); w,h = im.size
im.crop((0,0,w,120)).resize((w*2,240), Image.LANCZOS).save('/tmp/k90_sbar_view.png')
print('已保存 /tmp/k90_sbar_view.png')
EOF
    exit 0
fi

[ -f "$APK" ] || ./build.sh

echo "[1/4] 安装 APK"
"$ADB" -s "$D" install -r "$APK"
# install 完成后要等一下, 否则紧接着的 appops/启动会撞上包替换过程
sleep 2

echo "[2/4] 授予悬浮窗权限"
# install -r 会把 SYSTEM_ALERT_WINDOW 重置成 ignore(窗口在但完全不显示), 必须补
"$ADB" -s "$D" shell "su -c 'appops set $PKG SYSTEM_ALERT_WINDOW allow'" 2>/dev/null \
    || "$ADB" -s "$D" shell "appops set $PKG SYSTEM_ALERT_WINDOW allow" 2>/dev/null || true

echo "[3/4] 授予通知权限"
"$ADB" -s "$D" shell "pm grant $PKG android.permission.POST_NOTIFICATIONS" 2>/dev/null || true

# 若用户之前在 App 里关过悬浮窗(hud_on=false), 服务会自杀、起不来 -> 显式打开
"$ADB" -s "$D" shell "su -c \"sed -i 's|name=hud_on value=\\\"false\\\"|name=hud_on value=\\\"true\\\"|' /data/data/$PKG/shared_prefs/hud.xml\"" 2>/dev/null || true

echo "[4/4] 拉起悬浮窗服务"
if ! "$ADB" -s "$D" shell "am start-foreground-service -n $PKG/.HudService" 2>&1 | grep -qi "error\|exception"; then
    echo "  已启动"
else
    echo "  直接启动被拒(后台限制), 改为打开 App 让用户点一下"
    "$ADB" -s "$D" shell "am start -n $PKG/.MainActivity" >/dev/null 2>&1 || true
fi

sleep 2
# 验证悬浮窗真的在(权限没补上时窗口数会是 0)
NWIN=$("$ADB" -s "$D" shell "dumpsys window windows | grep -c package=$PKG" 2>/dev/null | tr -d '\r\n ')
if [ "${NWIN:-0}" -gt 0 ]; then
    echo "  悬浮窗已就位"
else
    echo "  ⚠️ 悬浮窗没起来: 多半是 SYSTEM_ALERT_WINDOW 权限被重置, 手动开一次「K90 HUD」App 授权即可"
fi

sleep 2
# 回到桌面看效果
"$ADB" -s "$D" shell 'input keyevent KEYCODE_WAKEUP; am start -a android.intent.action.MAIN -c android.intent.category.HOME' >/dev/null 2>&1
sleep 1
"$ADB" -s "$D" exec-out screencap -p > /tmp/k90_shot.png
"$PY" - <<'EOF'
from PIL import Image
im = Image.open('/tmp/k90_shot.png'); w,h = im.size
im.crop((0,0,w,120)).resize((w*2,240), Image.LANCZOS).save('/tmp/k90_sbar_view.png')
print('状态栏截图: /tmp/k90_sbar_view.png')
EOF
echo
echo "调位置: 打开「K90 HUD」App 拖两个滑块; 或 ./setup.sh --shot 重新截图看效果"
