#!/system/bin/sh
# 独立启动 httpd。
# 必须在独立脚本里启动: 若在 cpuctl 的函数体内直接写后台启动(&),
# mksh 会把整个调用上下文 fork 成子 shell, 导致守护进程自我复制。
# 用 nohup 而不是 setsid: toybox 的 setsid 不支持 -f, 会留下一个 wait 的父进程。
MODDIR=/data/adb/modules/k90_cpuctl
STATE=/data/adb/k90_cpuctl
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=busybox

PORT="$1"
[ -n "$PORT" ] || PORT=8088
mkdir -p "$STATE"

nohup "$BB" httpd -f -p "127.0.0.1:$PORT" -h "$MODDIR/webroot" -c "$MODDIR/httpd.conf" >/dev/null 2>&1 &
echo $! > "$STATE/web.pid"
echo "$PORT" > "$STATE/web_port"
