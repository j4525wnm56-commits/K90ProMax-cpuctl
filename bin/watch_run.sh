#!/system/bin/sh
# 守护进程启动器。
# 用 mkdir 原子锁保证单实例: 拿不到锁说明已有守护在跑, 直接退出。
# 后台启动必须写在独立脚本里(不在函数体内), 否则 mksh 会把调用方
# 的整个上下文 fork 成子 shell, 导致守护进程自我复制。
#
# v1.8.10 修复: 光靠锁挡不住软重启后的重叠。
#   `ksud soft-reboot` 只重启 init 托管的用户态, service.sh 会照常再跑一遍;
#   而上一轮 nohup 出去的 __watch 挂在 pid 1 下并不受它管, 仍然活着。
#   锁文件里只记得"最新那个 pid", 旧的不会被判活, 于是每次重启都多一份。
#   实测累积到 6 份并发, 每份 10 秒做一遍全量 sysfs 写 + nc 探测,
#   既费电又和自己的温控/系统热控对着写。
#   所以 spawn 之前必须按 argv 把同类进程物理清干净, 锁只作为快速路径。
MODDIR=/data/adb/modules/k90_cpuctl
STATE=/data/adb/k90_cpuctl
LOCK="$STATE/watch.lock"
PAT="bin/cpuctl __watch"

mkdir -p "$STATE"

# 列出所有 __watch 进程的 pid(不含自己这份启动器)
stray_pids() {
    ps -A -o PID,ARGS 2>/dev/null \
        | grep -F "$PAT" | grep -v grep \
        | awk -v me="$$" '$1 != me { print $1 }'
}

kill_strays() {
    _pids=$(stray_pids)
    for _p in $_pids; do kill "$_p" 2>/dev/null; done
    [ -n "$_pids" ] && sleep 1
    _pids=$(stray_pids)
    for _p in $_pids; do kill -9 "$_p" 2>/dev/null; done
}

# 陈旧/失效锁处理: 锁里的 pid 必须真的活着, 并且确实是 __watch
# (pid 会被复用, 只判 kill -0 会把别人的进程当成自己人)
if [ -d "$LOCK" ]; then
    _p=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null \
       && ps -A -o PID,ARGS 2>/dev/null | grep -F "$PAT" | grep -q "^ *$_p "; then
        exit 0
    fi
    rm -rf "$LOCK"
fi

# 锁失效不代表进程没了 —— 先把残留清干净再起新的
kill_strays

mkdir "$LOCK" 2>/dev/null || exit 0

nohup sh "$MODDIR/bin/cpuctl" __watch >/dev/null 2>&1 &
echo $! > "$LOCK/pid"
# 所有权令牌由 __watch 自己写(它写的是自己的 $$), 启动器不代笔:
# $! 在某些写法下不等于 __watch 的 $$, 代笔会让新起的守护以为自己是多余的而秒退。

# 守护若因 watch_enabled=0 立刻退出, 由 cpuctl __watch 自己清理锁目录
