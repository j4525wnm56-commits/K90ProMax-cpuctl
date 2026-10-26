#!/system/bin/sh
# 开机自启: 等系统启动完成 -> 恢复档位 -> 起守护 -> 起 WebUI
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/k90_cpuctl

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 150 ]; do
    sleep 2
    i=$((i + 1))
done

sh "$MODDIR/bin/cpuctl" boot >/dev/null 2>&1 &
