#!/system/bin/sh
# K90 Pro Max VM 参数持久化（开机应用 + 运行期守护）
#
# 历史与结论（2026-11-09 排查）：
#   /data/adb/service.d/99-k90-powertune.sh 是正常执行的，powertune.log 里有 7 条
#   boot apply（10-31 00:54、02:47，11-02 09:56、10:00、10:05、14:47、17:06）。
#   但最后一次 11-02 17:06 写入 262144 之后，到 11-09 读到的值又变回 22528。
#   期间没有重启，说明 vm.min_free_kbytes 在运行期被重算/覆盖了
#   （首次记录显示当时的默认值是 11584，与现在的 22528 不同，符合内核重算水位的特征）。
#   => 单靠开机写一次不够，必须有运行期守护。
#
# 本模块做两件事：
#   1. 开机（boot_completed 后）写入 vm.min_free_kbytes=262144、vm.page-cluster=2
#   2. 启动常驻看门狗，每 300 秒检查一次，发现漂移立即重写并记录
#
# 看门狗去重：用 mkdir 原子性加锁 + /proc 校验持有者 cmdline，
#             避免 soft reboot 后累积多份（k90_cpuctl 的 __watch 曾累积 6 份）。

MODDIR=${0%/*}
DATA=/data/adb/k90_vmtune
LOG=$DATA/vmtune.log
LOCK=$DATA/watchdog.lock
WATCH=$DATA/vmtune_watch.sh
TARGET_MFK=262144
TARGET_PC=2

mkdir -p "$DATA" 2>/dev/null

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

apply_one() {
  key="$1"
  val="$2"
  p="/proc/sys/vm/$key"

  if [ ! -w "$p" ]; then
    log "SKIP  vm.$key 不可写"
    return 1
  fi

  old=$(cat "$p" 2>/dev/null)
  echo "$val" > "$p" 2>/dev/null
  now=$(cat "$p" 2>/dev/null)

  if [ "$now" = "$val" ]; then
    if [ "$old" = "$val" ]; then
      log "OK    vm.$key 已是 $val"
    else
      log "OK    vm.$key $old -> $now"
    fi
    return 0
  fi

  log "FAIL  vm.$key 写入无效（期望 $val，实际 $now）"
  return 1
}

# 判断某个 pid 是否是本模块的看门狗
is_our_watch() {
  p="$1"
  [ -n "$p" ] || return 1
  [ -d "/proc/$p" ] || return 1
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "vmtune_watch" || return 1
  return 0
}

# 等开机完成，最多 180 秒
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 180 ]; do
  sleep 1
  i=$((i + 1))
done

log "=== 开机应用 start (等待 boot_completed ${i}s) ==="
apply_one min_free_kbytes "$TARGET_MFK"
apply_one page-cluster "$TARGET_PC"

# 再等 15 秒让厂商服务跑完，复查一次
sleep 15
if [ "$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)" != "$TARGET_MFK" ]; then
  log "WARN  15s 后被覆盖，重新写入"
  apply_one min_free_kbytes "$TARGET_MFK"
fi
log "=== 开机应用 done: mfk=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null) pc=$(cat /proc/sys/vm/page-cluster 2>/dev/null) ==="

# ---------- 生成看门狗 ----------
cat > "$WATCH" <<'WATCHBODY'
#!/system/bin/sh
DATA=/data/adb/k90_vmtune
LOG=$DATA/vmtune.log
TARGET_MFK=262144
TARGET_PC=2
INTERVAL=300

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

while true; do
  cur=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)
  if [ "$cur" != "$TARGET_MFK" ]; then
    echo "$TARGET_MFK" > /proc/sys/vm/min_free_kbytes 2>/dev/null
    log "drift mfk: $cur -> $(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)"
  fi

  cur=$(cat /proc/sys/vm/page-cluster 2>/dev/null)
  if [ "$cur" != "$TARGET_PC" ]; then
    echo "$TARGET_PC" > /proc/sys/vm/page-cluster 2>/dev/null
    log "drift pc: $cur -> $(cat /proc/sys/vm/page-cluster 2>/dev/null)"
  fi

  # 存活标记，便于随时确认看门狗还在跑
  date '+%F %T' > "$DATA/watchdog.last" 2>/dev/null
  sleep $INTERVAL
done
WATCHBODY

chmod 755 "$WATCH" 2>/dev/null

# ---------- 去重启动 ----------
if [ -d "$LOCK" ]; then
  oldpid=$(cat "$LOCK/pid" 2>/dev/null)
  if is_our_watch "$oldpid"; then
    log "watchdog 已在运行 (pid $oldpid)，跳过启动"
    exit 0
  fi
  log "watchdog 锁残留 (pid=$oldpid 已失效)，接管"
  rm -rf "$LOCK"
fi

if ! mkdir "$LOCK" 2>/dev/null; then
  log "watchdog 加锁失败（并发启动），跳过"
  exit 0
fi

nohup sh "$WATCH" >/dev/null 2>&1 &
newpid=$!
echo "$newpid" > "$LOCK/pid"
log "watchdog 已启动 (pid $newpid, 间隔 300s)"
