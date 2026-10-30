#!/bin/sh
# 截一张状态栏，裁出来放大，方便看悬浮窗位置/清晰度
# 用法: ./sbar.sh [输出路径]
set -e
ADB=${ADB:-$HOME/.workbuddy/bin/platform-tools/adb}
PY=${PY:-/Users/li/.workbuddy/binaries/python/envs/default/bin/python}
OUT=${1:-/tmp/k90_sbar_view.png}

D=$("$ADB" devices | awk 'NR==2 && $2=="device"{print $1}')
"$ADB" -s "$D" exec-out screencap -p > /tmp/k90_shot.png

"$PY" - "$OUT" <<'EOF'
import sys
from PIL import Image
out = sys.argv[1]
im = Image.open('/tmp/k90_shot.png')
w, h = im.size
bar = im.crop((0, 0, w, 120))
bar = bar.resize((w * 2, 240), Image.LANCZOS)
bar.save(out)
print(f"原始 {w}x{h} -> {out}")
EOF
