#!/system/bin/sh
# 模块「操作」按钮: 启动 WebUI 并拉起浏览器
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/k90_cpuctl

sh "$MODDIR/bin/cpuctl" web open
