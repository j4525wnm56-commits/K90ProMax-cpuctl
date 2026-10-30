#!/bin/sh
# 从 Mac 直接调悬浮窗位置并截图看效果（不用打开 App 拖滑块）
#
#   ./tune.sh 96 0        # X=96dp  Y=0dp
#   ./tune.sh shot        # 只截图
#
# 原理: HudService 每 2s 读一次 /data/local/tmp/k90_hud_pos.txt（两列 dp），
# 有文件就覆盖 App 里存的偏好。
set -e
ADB=${ADB:-$HOME/.workbuddy/bin/platform-tools/adb}
PY=${PY:-/Users/li/.workbuddy/binaries/python/envs/default/bin/python}

D=$("$ADB" devices | awk 'NR==2 && $2=="device"{print $1}')
[ -n "$D" ] || { echo "没有已授权设备"; "$ADB" devices -l; exit 1; }

if [ "$1" != "shot" ] && [ -n "$1" ] && [ -n "$2" ]; then
    echo "$1 $2" > /tmp/pos.txt
    "$ADB" -s "$D" push /tmp/pos.txt /data/local/tmp/k90_hud_pos.txt >/dev/null
    "$ADB" -s "$D" shell 'su -c "chmod 644 /data/local/tmp/k90_hud_pos.txt"' 2>/dev/null || true
    echo "位置已设为 X=$1dp Y=$2dp，等 3 秒生效"
    sleep 3
fi

"$ADB" -s "$D" shell 'am start -a android.intent.action.MAIN -c android.intent.category.HOME' >/dev/null 2>&1
sleep 1
"$ADB" -s "$D" exec-out screencap -p > /tmp/k90_shot.png
"$PY" - <<'EOF'
from PIL import Image
im = Image.open('/tmp/k90_shot.png'); w, h = im.size
im.crop((0, 0, w, 120)).resize((w * 2, 240), Image.LANCZOS).save('/tmp/k90_sbar_view.png')
print('状态栏: /tmp/k90_sbar_view.png')
EOF
