#!/system/bin/sh
# 守护进程启动器。
# 用 mkdir 原子锁保证单实例: 拿不到锁说明已有守护在跑, 直接退出。
# 后台启动必须写在独立脚本里(不在函数体内), 否则 mksh 会把调用方
# 的整个上下文 fork 成子 shell, 导致守护进程自我复制。
MODDIR=/data/adb/modules/k90_cpuctl
STATE=/data/adb/k90_cpuctl
LOCK="$STATE/watch.lock"

mkdir -p "$STATE"
mkdir "$LOCK" 2>/dev/null || exit 0

nohup sh "$MODDIR/bin/cpuctl" __watch >/dev/null 2>&1 &
echo $! > "$LOCK/pid"

# 守护若因 watch_enabled=0 立刻退出, 由 cpuctl __watch 自己清理锁目录
