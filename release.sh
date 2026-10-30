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
# 【坑】这步必须用 curl, 不能用 python urllib ——
#   urllib 不读 http_proxy/https_proxy 环境变量(要显式 ProxyHandler),
#   直连 api.github.com 会被墙, 表现为 404/None, 最后报
#   "TypeError: 'NoneType' object is not subscriptable"。
#   curl 会自动读这些环境变量, 走代理就正常了。
# 实现放在独立脚本里, 避开 bash -c '...' 的多层引号地狱。
REPO="$REPO" VER="$VER" MSG="$MSG" ZIP="$ZIP" bash ./release_assets.sh
