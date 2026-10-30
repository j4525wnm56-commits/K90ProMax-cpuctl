#!/usr/bin/env bash
# 上传 Release 资产(curl 版, 绕开 urllib 走代理的问题)
set -euo pipefail
cd "$(dirname "$0")"

REPO=j4525wnm56-commits/K90ProMax-cpuctl
VER=v1.8.3
ZIP=dist/K90ProMax-cpuctl-v1.8.3.zip
APK=K90HUD.apk
export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897

RID=$(curl -s -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/releases/tags/$VER" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
echo "Release id = $RID"

upload() {
  local name="$1" path="$2" ctype="$3"
  echo ""
  echo "--- 上传 $name ($(stat -f%z "$path") bytes) ---"
  # 先删同名资产
  AID=$(curl -s -H "Authorization: Bearer $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/releases/$RID/assets" | \
    python3 -c "
import json,sys
try:
    for a in json.load(sys.stdin):
        if a['name']=='$name': print(a['id']); break
except Exception: pass
")
  if [ -n "$AID" ]; then
    echo "  删除旧同名资产 id=$AID"
    curl -s -X DELETE -H "Authorization: Bearer $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/releases/assets/$AID" -o /dev/null -w "  delete HTTP=%{http_code}\n"
    sleep 3
  fi
  for attempt in 1 2 3 4 5; do
    CODE=$(curl -s -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Content-Type: $ctype" \
      --data-binary "@$path" \
      -w "%{http_code}" -o /tmp/up_out.json \
      "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$name")
    if [ "$CODE" = "201" ]; then
      echo "  上传成功 HTTP=201"
      python3 -c "
import json
d=json.load(open('/tmp/up_out.json'))
print('  资产:', d['name'], d['size'], 'bytes')
print('  下载:', d['browser_download_url'])
"
      return 0
    fi
    echo "  第 $attempt 次 HTTP=$CODE, 重试..."
    head -c 300 /tmp/up_out.json; echo
    sleep 3
  done
  echo "  上传失败: $name"
  return 1
}

upload "K90ProMax-cpuctl-v1.8.3.zip" "$ZIP" "application/zip"
upload "K90HUD-v1.8.3.apk" "$APK" "application/vnd.android.package-archive"

echo ""
echo "=== 最终 Release 状态 ==="
curl -s -H "Authorization: Bearer $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/releases/tags/$VER" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  tag:', d['tag_name'])
print('  名称:', d['name'])
print('  发布于:', d['published_at'])
print('  链接:', d['html_url'])
print('  资产:')
for a in d['assets']:
    print(f\"    {a['name']:<32} {a['size']:>8} bytes  {a['download_count']} 次下载\")
"
rm -f /tmp/up_out.json
