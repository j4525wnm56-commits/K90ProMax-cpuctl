#!/system/bin/sh
# 状态栏 HUD —— 常驻通知显示实时 CPU 频率 / 温度 / GPU / 功耗
#
# ===== 开销设计（本脚本的全部难点都在这）=====
# 一轮采样只需读 ~25 个 sysfs 文件。所以**不用 awk、不用 cat、不用 $(...) 取值**,
# 全部走 shell 内建的 `read < file` + 全局变量 —— 打开/读取/算术/字符串拼接
# 都是内建动作, **不 fork 任何进程**。
#   实测对比: awk 方案 32ms/轮(大头是 awk 进程启动) → 本方案 <1ms/轮。
#
# 派发通知才 fork(一次 cmd 约 40ms), 所以做了"变化阈值 + 心跳":
#   大核频率变化 >= 100MHz / 温度 >= 0.5℃ / GPU >= 50MHz 才重发,
#   否则最多每 15s 发一次心跳。稳频/待机时几乎不产生通知。
#
# 息屏不采样(只读一个 backlight 文件), 间隔拉长到 15s。
# 循环里连 `date` 都不调, 心跳用计数器累计, 又省一个 fork/轮。
#
# 注意: kgsl(clock/temp/busy) 与 backlight 是 root-only, 本脚本必须由 root 拉起。
#
# 子命令: once | post | loop | off | bench

MODDIR=${MODDIR:-/data/adb/modules/k90_cpuctl}
STATE=${STATE:-/data/adb/k90_cpuctl}
CFG=/sys/devices/system/cpu/cpufreq
KGSL=/sys/class/kgsl/kgsl-3d0
BATT=/sys/class/power_supply/battery
TAG=k90hud

TH_FREQ=${TH_FREQ:-100000}   # 频率变化阈值 kHz
TH_TEMP=${TH_TEMP:-500}      # 温度变化阈值 m℃
TH_GPU=${TH_GPU:-50}         # GPU 频率变化阈值 MHz
HEARTBEAT=${HEARTBEAT:-15}   # 心跳秒数

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# 读文件到全局 RV —— 零 fork 的关键
RV=""
rdg() { RV=""; read -r RV < "$1" 2>/dev/null; }

# 整数排版结果放全局
F2=""; fmt2() { F2="$(($1 / 1000000)).$(( ($1 % 1000000) / 10000 ))"; }   # 1234567 -> 1.23
F1=""; fmt1() { F1="$(($1 / 1000)).$(( ($1 % 1000) / 100 ))"; }           # 35900 -> 35.9

# ---------- 拓扑发现(启动一次) ----------
CL_IDS=""
for p in "$CFG"/policy[0-9]*; do
    [ -d "$p" ] || continue
    id=${p##*/policy}
    case "$id" in ''|*[!0-9]*) continue ;; esac
    CL_IDS="$CL_IDS $id"
done
CL_IDS=${CL_IDS# }

# ---------- 温度 zone 列表(启动一次) ----------
TZ_LIST="$STATE/hud_tz.list"
build_tz_list() {
    local tmp="$TZ_LIST.$$" z t
    : > "$tmp"
    for z in /sys/class/thermal/thermal_zone*; do
        rdg "$z/type"; t=$RV
        case "$t" in
            # 必须剔除 *trip*: cpu-hw-trip-0/1 报的是硬件跳闸阈值(固定 95000),
            # 不是实测温度 —— 不过滤的话 HUD 会长年显示 95℃(实测踩过)。
            *trip*) continue ;;
            cpu*|cpullc*) echo "$z" >> "$tmp" ;;
        esac
    done
    if [ -s "$tmp" ]; then mv "$tmp" "$TZ_LIST"; else rm -f "$tmp"; fi
}

# ---------- 采样(零 fork) ----------
BIG=0; LIT=0; CT=0; GT=0; GC=0; GB=0; BI=0; BV=0; BT=0; MW=0; CHG=0
# 频率: 每轮都读(2 个文件, ~0.5ms)。BIG = 最后一个 policy(超大核簇), LIT = 第一个(小核簇)
sample_freq() {
    local id v first="" lastv=""
    for id in $CL_IDS; do
        rdg "$CFG/policy$id/scaling_cur_freq"; v=$RV
        is_num "$v" || v=0
        [ -z "$first" ] && first=$v
        lastv=$v
    done
    BIG=$lastv; LIT=${first:-$lastv}
}

# 温度: 要读 21 个 zone, 是采样里最贵的一块。温度变化慢, 循环里隔轮读一次就够。
sample_temp() {
    local z v
    CT=0
    [ -s "$TZ_LIST" ] || return 0
    while read -r z; do
        rdg "$z/temp"; v=$RV
        is_num "$v" || continue
        [ "$v" -gt "$CT" ] && CT=$v
    done < "$TZ_LIST"
}

# GPU 温度/占用: 只有发通知时才需要
sample_gputherm() {
    local v
    if [ -e "$KGSL/temp" ]; then
        rdg "$KGSL/temp";      v=$RV; is_num "$v" && GT=$v
        rdg "$KGSL/gpu_busy_percentage"
        # "16 %" -> 16, 用参数展开剥掉非数字, 不 fork tr
        GB=${RV//[^0-9]/}
        is_num "$GB" || GB=0
    fi
    return 0
}

# GPU 频率: 一个文件, 每轮都读: 一个文件, 每轮都读
sample_gpuclk() {
    GC=0
    [ -e "$KGSL/clock_mhz" ] || return 0
    rdg "$KGSL/clock_mhz"
    is_num "$RV" && GC=$RV
}

# 电池功耗: current_now × voltage_now, 变化慢, 隔轮读
sample_batt() {
    local v
    BI=0; BV=0; BT=0; MW=0; CHG=0
    rdg "$BATT/current_now"; v=$RV
    # 正电流 = 电流流向电池(充电), 负电流 = 放电。CHG 只用来给 App 加 "+" 后缀。
    case "$v" in
        -*) v=${v#-} ;;
        *)  if is_num "$v" && [ "$v" -gt 0 ]; then CHG=1; fi ;;
    esac
    is_num "$v" && BI=$v
    # 满电时 current_now 会一直是 0，光看电流判断不出"插着充电器"，所以再看一眼 status
    rdg "$BATT/status"
    case "$RV" in Charg*|Full) CHG=1 ;; esac
    rdg "$BATT/voltage_now"; v=$RV; is_num "$v" && BV=$v
    rdg "$BATT/temp"; v=$RV
    case "$v" in -*) v=${v#-} ;; esac
    if is_num "$v"; then [ "$v" -lt 1000 ] && v=$((v * 100)); BT=$v; fi
    # 单位: µV × µA = pW, /1e9 才是 mW。
    # 旧代码写的 /1e6 得到的是 µW, 却被当 mW 显示 —— 结果大了 1000 倍。
    MW=$(( (BV * BI) / 1000000000 ))
    [ "$MW" -lt 0 ] && MW=$((0 - MW))
    return 0
}

# 全量采样(once / post / bench 用)
sample() {
    BIG=0; LIT=0; CT=0; GT=0; GC=0; GB=0; BI=0; BV=0; BT=0; MW=0; CHG=0
    sample_freq
    sample_gpuclk
    sample_temp
    sample_batt
    sample_gputherm
    return 0
}

# ---------- 排版 + 派发 ----------
render_post() {
    local title body prof mw g f notify
    rdg "$STATE/hud_notify"; notify=${RV:-1}
    rdg "$STATE/profile"; prof=$RV
    mw=$(( (BV * BI) / 1000000 ))
    fmt2 "$BIG"; g=$F2
    fmt1 "$CT";  f=$F1
    title="CPU ${g}G · ${f}℃"
    body="超大核 ${g}G"
    fmt2 "$LIT"; body="$body · 性能核 ${F2}G"
    [ "$GC" -gt 0 ] && body="$body · GPU ${GC}M"
    [ "$GB" -gt 0 ] && body="$body(${GB}%)"
    fmt1 "$CT"; body="$body
CPU ${F1}℃"
    if [ "$GT" -gt 0 ]; then fmt1 "$GT"; body="$body · GPU ${F1}℃"; fi
    if [ "$BT" -gt 0 ]; then fmt1 "$BT"; body="$body · 电池 ${F1}℃"; fi
    if [ "$mw" -gt 0 ]; then fmt1 "$mw"; body="$body · ${F1}W"; fi
    [ -n "$prof" ] && body="$body · $prof"
    # 只留悬浮窗时把通知关掉(hud_notify=0), 但采样和写文件不能停
    [ "$notify" != "0" ] && cmd notification post -S bigtext -t "$title" "$TAG" "$body" >/dev/null 2>&1
    printf '%s\n%s\n' "$title" "$body" > "$STATE/hud_last.txt" 2>/dev/null
}

# 写给状态栏悬浮窗 App 的紧凑串(它没有 root, 读不了 sysfs, 只能读这个文件)。
# 用 printf 内建重定向, 不 fork。文件在 /data/local/tmp, 对普通 app 可读(0644)。
HUD_FILE=/data/local/tmp/k90_hud.txt
# 格式: "<性能核kHz> <超大核kHz> <温度m℃> <GPUMHz> <功耗mW> <是否充电1/0>"，排版交给 App。
# 只写 3 个整数: 不用取模拼小数, 也方便 App 用 split 解析。
write_state() {
    printf '%d %d %d %d %d %d\n' "$BIG" "$LIT" "$CT" "$GC" "$MW" "$CHG" > "$HUD_FILE" 2>/dev/null
}

# AOSP 的 AlertWindowNotification: 只要 App 在别的应用上层画窗口, WMS 就发一条
# ONGOING 通知("……正在其他应用的上层显示内容"), 用户划不掉, 也没有系统开关能关。
# 唯一可用的办法是把它 snooze 掉(实测有效, 会进 "Snoozed notifications" 分区),
# 但 snooze 有有效期, 所以在守护循环里每 50 分钟续一次。
ALERT_KEY="0|android|0|com.android.server.wm.AlertWindowNotification - com.langrm.k90hud|1000"
snooze_alert() {
    pm list packages 2>/dev/null | grep -q 'com.langrm.k90hud' || return 0
    cmd notification snooze --for 3600000 "$ALERT_KEY" >/dev/null 2>&1
}

last_key=""
last_tick=0
tick=0

should_post() {
    [ -z "$last_key" ] && return 0
    local pb=${last_key%%|*} rest=${last_key#*|}
    local pt=${rest%%|*}    pg=${rest#*|}
    local df=$((BIG - pb)); [ "$df" -lt 0 ] && df=$((0 - df))
    local dt=$((CT - pt));  [ "$dt" -lt 0 ] && dt=$((0 - dt))
    local dg=$((GC - pg));  [ "$dg" -lt 0 ] && dg=$((0 - dg))
    [ "$df" -ge "$TH_FREQ" ] && return 0
    [ "$dt" -ge "$TH_TEMP" ] && return 0
    [ "$dg" -ge "$TH_GPU" ]  && return 0
    [ $((tick - last_tick)) -ge "$HEARTBEAT" ] && return 0
    return 1
}

mark_posted() { last_key="$BIG|$CT|$GC"; last_tick=$tick; }

BL=1
read_backlight() {
    local b
    BL=1
    for b in /sys/class/backlight/*/brightness; do
        [ -e "$b" ] || continue
        rdg "$b"; is_num "$RV" && { BL=$RV; return 0; }
    done
    return 0
}

[ -s "$TZ_LIST" ] || build_tz_list

case "$1" in
    once)
        sample; write_state
        fmt2 "$BIG"; a=$F2
        fmt1 "$CT";  b=$F1
        fmt2 "$LIT"; c=$F2
        printf '标题: CPU %sG · %s℃\n' "$a" "$b"
        printf '正文: 超大核 %sG · 性能核 %sG' "$a" "$c"
        [ "$GC" -gt 0 ] && printf ' · GPU %sM(%s%%)' "$GC" "$GB"
        printf '\n      CPU %s℃' "$b"
        [ "$GT" -gt 0 ] && { fmt1 "$GT"; printf ' · GPU %s℃' "$F1"; }
        [ "$BT" -gt 0 ] && { fmt1 "$BT"; printf ' · 电池 %s℃' "$F1"; }
        printf '\n---\n温度源 %s 个 zone · 功耗 %smW · 状态文件: %s\n' "$(wc -l < "$TZ_LIST")" "$MW" "$(cat "$HUD_FILE" 2>/dev/null)"
        ;;
    post)
        sample; write_state; render_post; echo "已发送"; cat "$STATE/hud_last.txt" 2>/dev/null
        ;;
    off)
        cmd notification cancel "$TAG" >/dev/null 2>&1
        echo "--" > /data/local/tmp/k90_hud.txt 2>/dev/null
        echo "已取消通知"
        ;;
    bench)
        s=$(date +%s%3N); i=0
        while [ "$i" -lt 50 ]; do sample; i=$((i + 1)); done
        e=$(date +%s%3N)
        echo "纯采样 50 轮: 总 $(($e - $s))ms, 平均 $(( (e - s) / 50 )) ms/轮"
        echo "温度源 $(wc -l < "$TZ_LIST") 个 zone"
        sample; render_post
        echo "样例:"; cat "$STATE/hud_last.txt" 2>/dev/null
        ;;
    loop)
        last_key=""; last_tick=0; tick=0
        while :; do
            rdg "$STATE/hud_enabled"; [ "$RV" = "1" ] || break
            rdg "$STATE/hud_interval"; iv=$RV; is_num "$iv" || iv=5
            [ "$iv" -lt 1 ] && iv=1
            if [ $((tick % 3600)) -eq 0 ]; then snooze_alert; fi
            read_backlight
            if [ "$BL" = "0" ]; then
                # 息屏: 不采样不推送
                sleep 15; tick=$((tick + 15)); continue
            fi
            # ---- 分级采样: 频率每轮, 温度隔轮, GPU/电池仅通知模式 ----
            sample_freq
            sample_gpuclk
            if [ $((tick % 4)) -eq 0 ] || [ "$CT" = "0" ]; then sample_temp; sample_batt; fi
            rdg "$STATE/hud_notify"; notify=${RV:-1}
            [ "$notify" != "0" ] && sample_gputherm
            write_state
            if [ "$notify" != "0" ] && should_post; then render_post; mark_posted; fi
            sleep "$iv"; tick=$((tick + iv))
        done
        rm -rf "$STATE/hud.lock"
        ;;
    *)
        echo "用法: hud.sh <once|post|loop|off|bench>"
        ;;
esac
