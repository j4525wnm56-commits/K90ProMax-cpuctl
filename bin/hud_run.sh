#!/system/bin/sh
# HUD 守护启动器。
# 和 watch_run.sh 同样的道理: 后台启动必须写在独立脚本里, 否则 mksh 会把调用方
# 整个上下文 fork 成子 shell, 守护会自我复制。mkdir 原子锁保证单实例。
MODDIR=/data/adb/modules/k90_cpuctl
STATE=/data/adb/k90_cpuctl
LOCK="$STATE/hud.lock"

mkdir -p "$STATE"

# 陈旧锁处理: 上次被 kill -9 / pkill 强杀时锁目录会留在磁盘上,
# 直接 mkdir 会失败并永久拒绝重启(实测踩过)。这里先判断 pid 是否真的活着。
if [ -d "$LOCK" ]; then
    _p=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
        exit 0          # 真的在跑, 不重复启动
    fi
    rm -rf "$LOCK"      # 残留锁, 清掉继续
fi

mkdir "$LOCK" 2>/dev/null || exit 0

nohup sh "$MODDIR/bin/hud.sh" loop >/dev/null 2>&1 &
echo $! > "$LOCK/pid"
