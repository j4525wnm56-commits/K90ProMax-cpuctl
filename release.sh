#!/usr/bin/env bash
# 一键发版：改完 module.prop 的 version / versionCode 与 update.json 后跑这个
#
#   GH_TOKEN=github_pat_xxx ./release.sh "这一版做了什么"
#   走代理时再带上:  HTTPS_PROXY=http://127.0.0.1:7897
#
# 做的事：打包 zip -> 提交（有改动才提交）-> 推 main -> 打 tag -> 建/复用 Release -> 上传资产
# token 只从环境变量读，不写进任何文件；推送用一次性的 credential.helper=
set -euo pipefail
cd "$(dirname "$0")"

MSG=${1:-"release"}
: "${GH_TOKEN:?需要 GH_TOKEN 环境变量（fine-grained PAT，权限 Contents: Read and write）}"

REPO=$(git remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')
VER=$(sed -n 's/^version=//p' module.prop)
CODE=$(sed -n 's/^versionCode=//p' module.prop)
NAME=$(basename "$PWD")
ZIP="dist/${NAME}-${VER}.zip"

UJ_VER=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' update.json)
[ "$UJ_VER" = "$VER" ] || {
    echo "update.json 里是 $UJ_VER，module.prop 里是 $VER —— 先改成一致（模块管理器读 update.json）"
    exit 1
}

echo "[1/4] 打包"
./package.sh >/dev/null
ls -l "$ZIP"

echo "[2/4] 提交并推送"
if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -q -m "$MSG

版本: $VER ($CODE)"
else
    echo "  工作区干净，跳过提交"
fi
git -c credential.helper= push "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" main

echo "[3/4] 打 tag $VER"
git tag -f -a "$VER" -m "$MSG" >/dev/null 2>&1
git -c credential.helper= push -f "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "refs/tags/$VER" 2>&1 | tail -1

echo "[4/4] 建 Release 并上传资产"
# 【坑】这里必须用 curl, 不能用 python urllib ——
#   urllib 不读 http_proxy/https_proxy 环境变量(要显式 ProxyHandler),
#   直连 api.github.com 会被墙, 表现为 404/None, 最后报
#   "TypeError: 'NoneType' object is not subscriptable"。
#   curl 会自动读这些环境变量, 走代理就正常了。
REPO="$REPO" VER="$VER" MSG="$MSG" ZIP="$ZIP" bash -c '
set -euo pipefail
REPO="$REPO"; VER="$VER"; MSG="$MSG"; ZIP="$ZIP"
NAME=$(basename "$ZIP")
H=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json")

# 建 Release; 已存在就复用
RESP=$(curl -s -w "\n%{http_code}" -X POST "${H[@]}" -H "Content-Type: application/json" \
  --data-binary "$(python3 -c "
import json,sys
print(json.dumps({\"tag_name\": sys.argv[1], \"name\": sys.argv[2], \"body\": sys.argv[3]}))
" "$VER" "$VER $MSG" "$MSG")" \
  "https://api.github.com/repos/$REPO/releases")
CODE=$(printf "%s" "$RESP" | tail -1)
BODY=$(printf "%s" "$RESP" | sed "\$d")
if [ "$CODE" != "201" ]; then
  echo "  创建返回 HTTP=$CODE, 尝试复用已存在的 Release"
  BODY=$(curl -s "${H[@]}" "https://api.github.com/repos/$REPO/releases/tags/$VER")
fi
RID=$(printf "%s" "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get(\"id\",\"\"))")
[ -n "$RID" ] || { echo "  拿不到 Release id, 放弃"; exit 1; }
echo "  Release id = $RID"

# 上传资产(同名先删, GitHub 会短暂占用名字, 重试)
upload() {
  local nm="$1" path="$2" ctype="$3"
  local aid
  aid=$(curl -s "${H[@]}" "https://api.github.com/repos/$REPO/releases/$RID/assets" | \
    python3 -c "
import json,sys
try:
    for a in json.load(sys.stdin):
        if a[\"name\"]==sys.argv[1]: print(a[\"id\"]); break
except Exception: pass
" "$nm")
  if [ -n "$aid" ]; then
    echo "  删除旧同名资产 id=$aid"
    curl -s -X DELETE "${H[@]}" "https://api.github.com/repos/$REPO/releases/assets/$aid" -o /dev/null
    sleep 3
  fi
  for i in 1 2 3 4 5; do
    local c
    c=$(curl -s -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: $ctype" \
      --data-binary "@$path" -w "%{http_code}" -o /tmp/_rel_asset.json \
      "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$nm")
    if [ "$c" = "201" ]; then
      python3 -c "
import json
d=json.load(open(\"/tmp/_rel_asset.json\"))
print(\"  资产:\", d[\"name\"], d[\"size\"], \"bytes\")
print(\"    \", d[\"browser_download_url\"])
"
      rm -f /tmp/_rel_asset.json
      return 0
    fi
    echo "  第 $i 次 HTTP=$c, 重试..."
    head -c 200 /tmp/_rel_asset.json 2>/dev/null; echo
    sleep 3
  done
  echo "  上传失败: $nm"; return 1
}

upload "$NAME" "$ZIP" "application/zip"
[ -f K90HUD.apk ] && upload "K90HUD-${VER}.apk" "K90HUD.apk" "application/vnd.android.package-archive"

echo ""
echo "=== Release 状态 ==="
curl -s "${H[@]}" "https://api.github.com/repos/$REPO/releases/tags/$VER" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(\"  链接:\", d[\"html_url\"])
for a in d[\"assets\"]:
    print(f\"    {a[\"name\"]:<32} {a[\"size\"]:>8} bytes\")
"
rm -f /tmp/_rel_asset.json
'
