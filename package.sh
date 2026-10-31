#!/usr/bin/env bash
# 打包成可直接刷入的 Magisk 模块 zip
# 用法: ./package.sh   ->  产出 dist/<name>-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

MODID=$(sed -n 's/^id=//p' module.prop)
NAME=$(basename "$PWD")
VERSION=$(sed -n 's/^version=//p' module.prop)
OUT="dist/${NAME}-${VERSION}.zip"

mkdir -p dist
rm -f "$OUT"

# 不进 zip 的东西：仓库元数据、文档、构建脚本本身、开发用工具
# （tools/ 是仓库侧的辅助脚本，比如 docs/hud-preview.png 的打码工具，不该装到手机上）
EXCLUDES=(
  '.git/*' '*.zip' 'dist/*' '*.md' '*.png'
  '.gitignore' '.gitattributes' 'package.sh' 'release.sh' 'release_assets.sh' 'update.json' 'LICENSE'
  'overlay/*' 'docs/*' 'tools/*' '*.jks' '*.keystore'
)

if command -v zip >/dev/null 2>&1; then
  xargs_args=()
  for e in "${EXCLUDES[@]}"; do xargs_args+=(-x "$e"); done
  zip -r9 "$OUT" . "${xargs_args[@]}" >/dev/null
else
  python3 - "$OUT" "${EXCLUDES[@]}" <<'PY'
import os, sys, zipfile
out, pats = sys.argv[1], sys.argv[2:]
def skip(rel):
    for p in pats:
        if p.startswith('*.') and rel.endswith(p[1:]): return True
        if p.endswith('/*') and rel.startswith(p[:-1]): return True
        if rel == p: return True
    return False
n = 0
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dp, dn, fn in os.walk('.'):
        dn[:] = [d for d in dn if d != '.git']
        for f in sorted(fn):
            full = os.path.join(dp, f)
            rel = os.path.relpath(full, '.').replace(os.sep, '/')
            if rel in ('.', '') or skip(rel): continue
            executable = (rel.endswith(('.sh', '.cgi'))
                          or rel.startswith(('bin/', 'system/bin/')))
            zi = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (0o755 if executable else 0o644) << 16
            with open(full, 'rb') as fh:
                z.writestr(zi, fh.read())
            n += 1
print(f"{out}: {n} files")
PY
fi

echo "OK -> $OUT"
