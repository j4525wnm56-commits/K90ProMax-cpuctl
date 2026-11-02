#!/system/bin/sh
# 独立启动 httpd。
# 必须在独立脚本里启动: 若在 cpuctl 的函数体内直接写后台启动(&),
# mksh 会把整个调用上下文 fork 成子 shell, 导致守护进程自我复制。
# 用 nohup 而不是 setsid: toybox 的 setsid 不支持 -f, 会留下一个 wait 的父进程。
#
# v1.8.10 修复: 端口漂移会累积进程。
#   soft-reboot 后 service.sh 重新跑, 上一轮的 httpd 还活着并占着 8088,
#   于是"找个空端口"逻辑挑到 8089、下一次 8090 —— 每重启一次多一个常驻 httpd。
#   实测 8088/8089/8090 三份同时在跑, 三份都在响应 CGI。
#   现在起新的之前按 argv 全清, 保证任何时刻只有一份。
MODDIR=/data/adb/modules/k90_cpuctl
STATE=/data/adb/k90_cpuctl
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=busybox

PORT="$1"
[ -n "$PORT" ] || PORT=8088
mkdir -p "$STATE"
LOCK="$STATE/web.lock"

# 单实例还有第二层: 并发调用时两个启动器会同时走到"清场之后、起进程之前",
# 各自清完再各自起一份。这里用 mkdir 原子锁把启动过程串行化,
# 拿不到锁的直接退出 —— 已经有一份在起了, 不需要第二份。
if [ -d "$LOCK" ]; then
    _lp=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCK"
fi
mkdir "$LOCK" 2>/dev/null || exit 0
echo $$ > "$LOCK/pid"

httpd_pids() {
    ps -A -o PID,ARGS 2>/dev/null \
        | grep -F "busybox httpd -f -p 127.0.0.1:" | grep -v grep \
        | awk -v me="$$" '$1 != me { print $1 }'
}

kill_httpd_all() {
    _pids=$(httpd_pids)
    for _p in $_pids; do kill "$_p" 2>/dev/null; done
    [ -n "$_pids" ] && sleep 1
    _pids=$(httpd_pids)
    for _p in $_pids; do kill -9 "$_p" 2>/dev/null; done
}

# 模块目录被整体替换后(升级), 旧 httpd 的 cwd 会变成 ".../k90_cpuctl.old/webroot (deleted)",
# 端口仍被占着但所有 CGI 返回 404, 而且只看端口会误判"还活着"导致永不重启。
OLDPID=$(cat "$STATE/web.pid" 2>/dev/null)
if [ -n "$OLDPID" ] && [ -d "/proc/$OLDPID" ]; then
    OLDCWD=$(readlink "/proc/$OLDPID/cwd" 2>/dev/null)
    [ "$OLDCWD" != "$MODDIR/webroot" ] && kill "$OLDPID" 2>/dev/null
fi

# 单实例: 先清掉所有旧实例, 再在指定端口起唯一一份
kill_httpd_all

nohup "$BB" httpd -f -p "127.0.0.1:$PORT" -h "$MODDIR/webroot" -c "$MODDIR/httpd.conf" >/dev/null 2>&1 &
echo $! > "$STATE/web.pid"
echo "$PORT" > "$STATE/web_port"
rm -rf "$LOCK"
