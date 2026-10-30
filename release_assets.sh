#!/usr/bin/env bash
# release.sh 的第 4 步：建/复用 Release + 上传资产。
# 独立成文件是为了避开 bash -c '...' 里的多层引号地狱。
#
# 必须用 curl 而不是 python urllib：
#   urllib 不读 http_proxy/https_proxy 环境变量（要显式 ProxyHandler），
#   直连 api.github.com 会被墙，表现为 404/None。
#   curl 会自动读这些环境变量。
#
# 入参（环境变量）：REPO / VER / MSG / ZIP / GH_TOKEN
set -euo pipefail

: "${REPO:?}"; : "${VER:?}"; : "${MSG:?}"; : "${ZIP:?}"; : "${GH_TOKEN:?}"

NAME=$(basename "$ZIP")
AUTH=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json")

# ---------- 建 Release ----------
# 用临时文件拼 JSON，避免任何嵌套引号
JSON_TMP=$(mktemp)
MSG_FILE=$(mktemp)
printf '%s' "$MSG" > "$MSG_FILE"
python3 - "$JSON_TMP" "$VER" "$MSG_FILE" <<'PY'
import json, sys
out, ver, msgfile = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(msgfile, encoding="utf-8").read()
json.dump({"tag_name": ver, "name": f"{ver} {body.splitlines()[0][:90]}".strip(),
           "body": body}, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY

CODE=$(curl -s -o "$JSON_TMP.resp" -w "%{http_code}" -X POST "${AUTH[@]}" \
  -H "Content-Type: application/json" --data-binary "@$JSON_TMP" \
  "https://api.github.com/repos/$REPO/releases")
if [ "$CODE" = "201" ]; then
  echo "  Release 已创建"
else
  echo "  创建返回 HTTP=$CODE，复用已存在的 Release"
fi

RID=$(curl -s "${AUTH[@]}" "https://api.github.com/repos/$REPO/releases/tags/$VER" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")
[ -n "$RID" ] || { echo "  拿不到 Release id，放弃"; rm -f "$JSON_TMP" "$JSON_TMP.resp" "$MSG_FILE"; exit 1; }
echo "  Release id = $RID"

# ---------- 上传资产 ----------
upload() {
  local nm="$1" path="$2" ctype="$3" aid c
  if [ ! -f "$path" ]; then echo "  跳过(文件不存在): $nm"; return 0; fi
  aid=$(curl -s "${AUTH[@]}" "https://api.github.com/repos/$REPO/releases/$RID/assets" \
    | python3 -c "
import json,sys
try:
    for a in json.load(sys.stdin):
        if a['name']==sys.argv[1]: print(a['id']); break
except Exception: pass
" "$nm")
  if [ -n "$aid" ]; then
    echo "  删除旧同名资产 id=$aid"
    curl -s -X DELETE "${AUTH[@]}" "https://api.github.com/repos/$REPO/releases/assets/$aid" -o /dev/null
    sleep 3
  fi
  for i in 1 2 3 4 5; do
    c=$(curl -s -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: $ctype" \
      --data-binary "@$path" -w "%{http_code}" -o "$JSON_TMP.asset" \
      "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$nm")
    if [ "$c" = "201" ]; then
      python3 -c "
import json
d=json.load(open('$JSON_TMP.asset'))
print('  资产:', d['name'], d['size'], 'bytes')
print('    ', d['browser_download_url'])
"
      return 0
    fi
    echo "  第 $i 次 HTTP=$c，重试..."
    head -c 200 "$JSON_TMP.asset" 2>/dev/null; echo
    sleep 3
  done
  echo "  上传失败: $nm"
  return 1
}

upload "$NAME" "$ZIP" "application/zip"
upload "K90HUD-${VER}.apk" "K90HUD.apk" "application/vnd.android.package-archive"

echo ""
echo "=== Release 状态 ==="
curl -s "${AUTH[@]}" "https://api.github.com/repos/$REPO/releases/tags/$VER" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  链接:', d['html_url'])
for a in d['assets']:
    print(f\"    {a['name']:<34} {a['size']:>8} bytes\")
"

rm -f "$JSON_TMP" "$JSON_TMP.resp" "$JSON_TMP.asset" "$MSG_FILE"
