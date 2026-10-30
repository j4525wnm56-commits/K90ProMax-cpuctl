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
REPO="$REPO" GH_TOKEN="$GH_TOKEN" VER="$VER" MSG="$MSG" ZIP="$ZIP" APK="K90HUD.apk" python3 - <<'PY'
import json, os, time, urllib.error, urllib.request

repo  = os.environ["REPO"]
token = os.environ["GH_TOKEN"]
ver   = os.environ["VER"]
msg   = os.environ["MSG"]
zip_path = os.environ["ZIP"]
name  = os.path.basename(zip_path)
H = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}


def call(url, data=None, method="GET", ctype="application/json"):
    h = dict(H)
    if data is not None:
        h["Content-Type"] = ctype
    req = urllib.request.Request("https://api.github.com" + url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r) if r.length != 0 else {}
    except urllib.error.HTTPError as e:
        # 404: 不存在；422: 已存在（重复发同一版时 GitHub 会给这个）
        if e.code in (404, 422):
            return None
        raise


# 建 release；已存在就复用（重复发同一版时不会 422 中断）
rel = call(f"/repos/{repo}/releases", json.dumps(
    {"tag_name": ver, "name": f"{ver} {msg}".strip(), "body": msg}).encode(), "POST")
if rel is None or "id" not in rel:
    rel = call(f"/repos/{repo}/releases/tags/{ver}")
    print("  Release 已存在，复用 id", rel["id"])
    # 让标题/说明与本次一致
    call(f"/repos/{repo}/releases/{rel['id']}", json.dumps(
        {"name": f"{ver} {msg}".strip(), "body": msg}).encode(), "PATCH")

rid = rel["id"]
ZIP, APK = os.environ["ZIP"], os.environ.get("APK", "")
assets = [(os.path.basename(ZIP), ZIP, "application/zip")]
# 模块包里自带 K90HUD.apk，同时作为独立资产发出，方便只想要状态栏 HUD 的人直接装
if APK and os.path.exists(APK):
    assets.append((f"K90HUD-{ver}.apk", APK, "application/vnd.android.package-archive"))

for nm, path, ctype in assets:
    # 同名资产先删掉，否则上传会 422 already_exists
    # 注意删除用的是 /releases/assets/<id>，不是 /releases/<rid>/assets/<id>（后者 404）
    for a in call(f"/repos/{repo}/releases/{rid}/assets") or []:
        if a["name"] == nm:
            call(f"/repos/{repo}/releases/assets/{a['id']}", method="DELETE")
            print("  已删除旧同名资产:", nm)
            time.sleep(2)

    data = open(path, "rb").read()
    url = f"https://uploads.github.com/repos/{repo}/releases/{rid}/assets?name={nm}"
    # 刚删完同名资产时 GitHub 会短暂占用这个名字（422 already_exists），重试几次即可
    for attempt in range(1, 7):
        req = urllib.request.Request(
            url, data=data,
            headers={"Authorization": f"Bearer {token}", "Content-Type": ctype},
            method="POST")
        try:
            with urllib.request.urlopen(req) as r:
                a = json.load(r)
            break
        except urllib.error.HTTPError as e:
            if e.code == 422 and attempt < 6:
                time.sleep(3)
                continue
            raise
    else:
        raise SystemExit("资产上传失败: " + nm)

    print("  资产:", a["name"], a["size"], "bytes")
    print("    ", a["browser_download_url"])
PY
