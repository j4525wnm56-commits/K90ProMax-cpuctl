#!/bin/bash
# 把 vmtune 推到手机并立即生效（不需要重启）
# 用法: ./deploy.sh [设备序列号]
#   不传序列号时自动取第一台在线设备；ADB 环境变量可指定 adb 路径
set -e

ADB="${ADB:-adb}"
SERIAL="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# 兼容两种目录布局：仓库里是 vmtune/*.sh，独立部署包里是某目录/k90_vmtune/*.sh
if [ -f "$HERE/module.prop" ]; then
    SRC="$HERE"
else
    SRC="$HERE/k90_vmtune"
fi
[ -f "$SRC/module.prop" ] || { echo "找不到 module.prop（$SRC）"; exit 1; }

if [ -z "$SERIAL" ]; then
    SERIAL=$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')
fi
[ -n "$SERIAL" ] || { echo "没有已授权设备"; "$ADB" devices -l; exit 1; }

DST=/data/adb/modules/k90_vmtune
DATA=/data/adb/k90_vmtune

echo "== 设备 $SERIAL =="
"$ADB" -s "$SERIAL" get-state >/dev/null || { echo "设备未连接"; exit 1; }

echo "== 检查 root =="
"$ADB" -s "$SERIAL" shell "su -c id" | grep -q uid=0 || { echo "root 不可用"; exit 1; }

echo "== 上传模块 =="
"$ADB" -s "$SERIAL" shell "su -c 'rm -rf $DST && mkdir -p $DST'"
for f in module.prop service.sh uninstall.sh; do
    "$ADB" -s "$SERIAL" push "$SRC/$f" "/data/local/tmp/$f" >/dev/null
    "$ADB" -s "$SERIAL" shell "su -c 'cp /data/local/tmp/$f $DST/$f && rm -f /data/local/tmp/$f'"
done
"$ADB" -s "$SERIAL" shell "su -c 'chmod 755 $DST/service.sh $DST/uninstall.sh; chmod 644 $DST/module.prop'"

echo "== 模块内容 =="
"$ADB" -s "$SERIAL" shell "su -c 'ls -l $DST'"

echo "== 立即执行一次 service.sh（免重启生效）=="
"$ADB" -s "$SERIAL" shell "su -c 'sh $DST/service.sh'"

echo "== 结果 =="
"$ADB" -s "$SERIAL" shell "su -c 'echo -n \"min_free_kbytes=\"; cat /proc/sys/vm/min_free_kbytes; echo -n \"page-cluster=\"; cat /proc/sys/vm/page-cluster'"
"$ADB" -s "$SERIAL" shell "su -c 'tail -12 $DATA/vmtune.log'"
