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
PSDIR=${PSDIR:-/sys/class/power_supply}   # 可覆盖, 便于在 PC 上用假节点跑自测
BATT=$PSDIR/battery
TAG=k90hud

# ---------- 节点存在性: 启动探一次, 循环里不再 [ -e ] ----------
# 每个 [ -e ] 都是一次 stat(约 20µs), 一轮 6 个 = 0.12ms, 纯浪费。
KGSL_TEMP=""; KGSL_BUSY=""; KGSL_CLK=""
[ -e "$KGSL/temp" ]                && KGSL_TEMP="$KGSL/temp"
[ -e "$KGSL/gpu_busy_percentage" ] && KGSL_BUSY="$KGSL/gpu_busy_percentage"
[ -e "$KGSL/clock_mhz" ]           && KGSL_CLK="$KGSL/clock_mhz"
USB_ONL="";  [ -e "$PSDIR/usb/online" ]      && USB_ONL="$PSDIR/usb/online"
WL_ONL="";   [ -e "$PSDIR/wireless/online" ] && WL_ONL="$PSDIR/wireless/online"


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
BIG=0; LIT=0; CT=0; GT=0; GC=0; GB=0; BI=0; BV=0; BT=0; MW=0; CHG=0; PSI=0; FPS=0; REF=0
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

# 温度: 要读 21 个 zone。温度变化很慢(实测相邻 5s 差 0.1~1℃), 所以**每 30 秒读一次**,
# 其余轮次沿用上次值(CT_HOLD)。配合 App 侧的中位数平滑, 显示完全不会跳。
# 用累计秒数 tick 判定, 与 hud_interval 设置无关(间隔 1s 或 5s 都是准确的 30 秒)。
# TEMP_INTERVAL 可用环境变量覆盖; TEMP_FULL=1 强制每轮都读(仅测试用)。
TEMP_INTERVAL=${TEMP_INTERVAL:-30}
CT=0
CT_HOLD=0
sample_temp() {
    local z v
    if [ "${TEMP_FULL:-0}" != "1" ] && [ "$CT_HOLD" != "0" ] \
       && [ $(( tick % TEMP_INTERVAL )) -ne 0 ]; then
        CT=$CT_HOLD
        return 0
    fi
    CT=0
    [ -s "$TZ_LIST" ] || return 0
    while read -r z; do
        rdg "$z/temp"; v=$RV
        is_num "$v" || continue
        [ "$v" -gt "$CT" ] && CT=$v
    done < "$TZ_LIST"
    CT_HOLD=$CT
    return 0
}

# ---------- GPU 温度(30 秒一读) ----------
# kgsl/temp 单次读 483µs, 而且是"经 GPU 驱动取值", 有附带唤醒成本; GPU 温度是分钟级
# 缓变量, 每轮读纯浪费 → 与 CPU 温度同样按 30s 采样, 其余轮沿用。
GT=0; GT_HOLD=0
GT_INTERVAL=${GT_INTERVAL:-30}
sample_gputemp() {
    if [ "$GT_HOLD" != "0" ] && [ $(( tick % GT_INTERVAL )) -ne 0 ]; then
        GT=$GT_HOLD
        return 0
    fi
    GT=0
    [ -n "$KGSL_TEMP" ] || { GT_HOLD=0; return 0; }
    rdg "$KGSL_TEMP"; is_num "$RV" && GT=$RV
    GT_HOLD=$GT
    return 0
}

# ---------- GPU 占用 ----------
# gpu_busy_percentage 是高通 KGSL 节点, 返回 "16 %" 这种。
# 【坑1·解析】不能用 ${RV//[^0-9]/}: 设备的 /system/bin/sh(mksh) 不支持 [^0-9] 否定字符类,
#   实测 "13 %" 会被解析成 " %"(数字反被删掉) -> 恒 0。改用 ${raw%% *} 截到第一个空格, 得 "13"。
# 【坑2·节点语义】它是 KGSL 的**异步统计快照**: 内核约 5 秒才更新一次, 非 0 值只存在极短时间。
#   实测(真游戏 Unity 渲染下): 单次读约 40% 为非 0; 但**按守护的 5s 节奏单次读 8/8 全命中**
#   (24/29/18/21/21/27/22/26%)。所以单次读就够, 不必连读。
# 【坑3·别惦记 gpubusy】有人会想用 kgsl-3d0/gpubusy 的 busy/total 差分算占用(更准)。
#   本机实测**不可用**: 空闲和滑动/渲染负载下两个计数**恒为 0**(内核没开对应统计),
#   差分永远 0%。只能用内核算好的百分比 + 保持。
# 【性能】曾用"间隔 0.05s 连读 6 次取最大"提命中率, 那是**性能退化**:
#   设备上 sleep 0.05 真实耗时 69ms/次(不是 50ms), 5 次 = 345ms/轮,
#   采样总耗时从 ~30ms 涨到 347ms/轮(占空比 6.9%), 命中率却没明显提升。
#   现改为单次读 + 保持上次非零值(最多 2 轮), 开销 0.25ms/轮。
#   【已知精度代价】GPU 从忙变闲后, 占用会残留最多 2 轮(10s)才归 0 —— 这是拿准确性换
#   稳定性(否则每轮在 0 和非 0 之间跳)。屏幕静止时读到的 0 会连续命中, 所以能正常归零。
GB=0
GB_HOLD=0      # 上次读到的非零占用
GB_HOLD_N=0    # 还能保持几轮
sample_gpubusy() {
    local v raw
    if [ -n "$KGSL_BUSY" ]; then
        rdg "$KGSL_BUSY"; raw=$RV
        v=${raw%% *}                       # "16 %" -> "16"
        is_num "$v" || v=0
        if [ "$v" -gt 0 ]; then
            GB=$v; GB_HOLD=$v; GB_HOLD_N=2   # 读到真实值, 重新开始保持
        elif [ "$GB_HOLD_N" -gt 0 ]; then
            GB=$GB_HOLD; GB_HOLD_N=$((GB_HOLD_N - 1))
        else
            GB=0
        fi
    else
        GB=0; GB_HOLD=0; GB_HOLD_N=0
    fi
    return 0
}

# ---------- CPU 占用率 ----------
# 【v1.8.5 修正语义】旧版把 PSI(/proc/pressure/cpu 的 avg10)当"CPU 占用%"显示, **这是错的**:
#   PSI 统计的是"有任务因为等 CPU 而卡住的时间占比", 8 核手机在 2~3 线程的游戏里几乎为 0,
#   于是界面显示"占用 5%"而实际大核已经跑满 —— 数值方向性错误, 不是精度问题。
#   现在按标准做法用 /proc/stat 的 cpu 汇总行做差分: (Δ非空闲) / Δ总时间 = 8 核平均利用率。
# 【代价】/proc/stat 一次 open 约 0.75ms(比 PSI 的 0.33ms 贵), 且利用率天然需要窗口,
#   所以 10 秒才读一次(与 5s 采样循环对齐时 2 轮一读), 其余轮沿用上次值。
USE=0                  # 0~100, 8 核平均利用率
CPU_BUSY_PREV=0
CPU_TOTAL_PREV=0
USE_INTERVAL=${USE_INTERVAL:-10}
_BUSY=0; _TOTAL=0
cpu_stat_read() {
    local u n s i w irq sirq st
    read -r _ u n s i w irq sirq st _ < /proc/stat 2>/dev/null
    is_num "$u" || { _BUSY=0; _TOTAL=0; return 0; }
    _BUSY=$(( u + n + s + irq + sirq + st ))
    _TOTAL=$(( _BUSY + i + w ))
    return 0
}
sample_cpuuse() {
    local db dt
    [ $(( tick % USE_INTERVAL )) -eq 0 ] || return 0
    cpu_stat_read
    [ "$_TOTAL" = "0" ] && return 0
    # 首次(或刚重启)没有基线: 补一次 1 秒的窗口。整个生命周期只付一次。
    #   窗口别取太短: 实测 0.2s 窗口下 dev/编译之类的瞬时负载能把读数顶到 24%,
    #   而同一时刻 5s 窗口只有 6% —— 1s 是"够稳定又不拖慢启动"的下限。
    if [ "$CPU_TOTAL_PREV" -eq 0 ]; then
        CPU_BUSY_PREV=$_BUSY; CPU_TOTAL_PREV=$_TOTAL
        sleep 1
        cpu_stat_read
    fi
    db=$(( _BUSY - CPU_BUSY_PREV ))
    dt=$(( _TOTAL - CPU_TOTAL_PREV ))
    CPU_BUSY_PREV=$_BUSY; CPU_TOTAL_PREV=$_TOTAL
    if [ "$dt" -gt 0 ] && [ "$db" -ge 0 ]; then
        USE=$(( db * 100 / dt ))
    else
        sample_psi                  # 极端情况(/proc/stat 读不到或计数回绕)退回 PSI
        USE=$PSI
    fi
    [ "$USE" -gt 100 ] && USE=100
    return 0
}

# CPU 压力 (PSI): /proc/pressure/cpu 的 avg10, 表示最近 10 秒里有百分之几的时间
# 在等 CPU —— 比"频率高"更能说明"真在满载/卡顿"。1 次读, 纯参数展开解析, 零 fork。
PSI=0
sample_psi() {
    local a
    read -r _ a _ < /proc/pressure/cpu 2>/dev/null
    a=${a#avg10=}
    a=${a%.*}
    case "$a" in ''|*[!0-9]*) a=0 ;; esac
    PSI=$a
    return 0
}

# 实时帧率 + 面板刷新率 (高通 SM8850 实测)
# 帧率: /sys/class/drm/card0-sde-crtc-0/measured_fps -> "fps: 60.5 duration:... frame_count:..."
#   这是 DRM CRTC 的**画面合成帧率**: 屏幕静止无新帧时=0, 有动画/游戏时才跳到几十。
# 【坑·统计窗口】fps_periodicity_ms 是内核统计窗口(ms), 可写。实测(真游戏 Unity 渲染):
#     1000 → 读数稳定 39~41  (帧间隔直方图显示真实提交间隔 24ms → 41.7fps ✓)
#     200  → 读数在 26~116 间剧烈跳动(窗口太小, 采样不稳)
#     50/100 → 读数 0~119 剧烈跳动
#   所以用 1000(内核默认): 稳定。虽然它统计的是"有新内容提交的帧", 游戏锁 40fps 时就显示 40。
#   想要"应用真实渲染帧率"用 sample_app_fps() 走 SurfaceFlinger, 更准但更贵(低频采样)。
# 刷新率: /sys/class/mi_display/disp-DSI-0/hw_vsync_info -> "fps: 120.109 vsync_period_ns:..."
#   这是面板实测刷新率(硬件 vsync), 比 dynamic_fps(配置目标值)更准。
# 各 1 次 read, 纯参数展开解析, 零 fork。节点不存在时自动探测备选路径。
FPS=0; REF=0
FPS_NODE=""; REF_NODE=""
FPS_PERIOD=1000
probe_fps_nodes() {
    local c
    for c in /sys/class/drm/card0-sde-crtc-0/measured_fps \
             /sys/class/drm/card0-sde-crtc-1/measured_fps \
             /sys/class/graphics/fb0/measured_fps; do
        [ -e "$c" ] && { FPS_NODE=$c; break; }
    done
    for c in /sys/class/mi_display/disp-DSI-0/hw_vsync_info \
             /sys/class/mi_display/disp-DSI-1/hw_vsync_info; do
        [ -e "$c" ] && { REF_NODE=$c; break; }
    done
    return 0
}
sample_fps() {
    local ln n int
    FPS=0
    if [ -n "$FPS_NODE" ]; then
        rdg "$FPS_NODE"; ln=$RV
        # "fps: 60.5 ..." -> 取 "fps:" 后到空格之间的数, 去掉小数点部分取整
        ln=${ln#*fps:}          # 去掉前缀到 fps:
        ln=${ln# }              # 去掉 fps: 后的空格
        n=${ln%% *}             # 截到第一个空格 -> "60.5"
        int=${n%%.*}            # 整数部分 -> "60"
        is_num "$int" && FPS=$int
    fi
    return 0
}

# ---------- 应用真实渲染帧率(SurfaceFlinger, 低频) ----------
# 为什么需要: 内核 measured_fps 统计的是"CRTC 提交的帧", 遇到 SurfaceView 直通的游戏会漏计,
#   实测同一个游戏: 内核节点读 36~56 跳动, 而 SF 的 per-layer averageFPS 稳定 125.000。
# 【方案: 全局 totalFrames 差分】不判断前台包名, 直接用 SF 的全局帧计数:
#   totalFrames 是**从上次 dump 起新提交的帧数**, statsEnd 是当前时间戳。
#   两次 dump 的差值 ÷ 时间差 = 全局实际帧率(实测 373帧/3秒 = 124fps, 与 per-layer 125 一致)。
#   dumpsys SurfaceFlinger --timestats -dump 约 30ms, 每 10 秒一次(占空比 0.3%)。
# 输出: APP_FPS = 差分算出的帧率; 取不到时为 0(回退到内核 measured_fps)。
APP_FPS=0
APP_FPS_HOLD=0
# 前一次 dump 的 totalFrames / statsEnd, 用于差分
APP_FPS_PREV_TF=0
APP_FPS_PREV_TS=0
# 采样间隔(秒)。设 APP_FPS_ENABLED=0 可完全关闭(退回内核合成帧率)。
APP_FPS_ENABLED=${APP_FPS_ENABLED:-1}
APP_FPS_INTERVAL=${APP_FPS_INTERVAL:-10}                  # 有帧时: 10s 一次
APP_FPS_IDLE_INTERVAL=${APP_FPS_IDLE_INTERVAL:-60}        # 屏幕静止时: 60s 一次
APP_FPS_ENABLED_STATE=0
TS_DUMP=/data/local/tmp/k90_ts.txt

sample_app_fps() {
    local tf ts dt df v period
    # 【性能·整条链路最贵的一步】一次 `dumpsys SurfaceFlinger --timestats -dump` 实测 **235ms**
    #   (原注释写的"约 30ms"差了 8 倍), 占 10 秒周期的 2.35%, 比其余所有采样加起来贵 25 倍。
    #   所以按内核 measured_fps 门控:
    #     有帧(FPS>0) → 10s 一次, 拿到准确值
    #     静止(FPS=0) → 60s 才来一次兜底。兜底是为了少数 SurfaceView 直通的游戏:
    #                   极端情况下内核节点会读到 0 而 SF 其实在出帧, 60s 内也能发现。
    #   静止时直接把 APP_FPS 归 0(屏幕确实没在出新帧, 显示 "-" 才是准的),
    #   不会把上一场游戏的高帧率一直挂在那儿。
    [ "${APP_FPS_ENABLED:-0}" = "1" ] || { APP_FPS=$APP_FPS_HOLD; return 0; }
    if [ "$FPS" -gt 0 ]; then period=$APP_FPS_INTERVAL; else period=$APP_FPS_IDLE_INTERVAL; fi
    if [ $(( tick % period )) -ne 0 ]; then
        if [ "$FPS" -gt 0 ]; then APP_FPS=$APP_FPS_HOLD; else APP_FPS=0; fi
        return 0
    fi
    # totalFrames 只在 --timestats -enable 时才累积(实测: 不 enable 时恒定不变,
    # enable 后每 3 秒涨 367 帧 = 122fps)。所以首次调用要先 enable。
    if [ "$APP_FPS_ENABLED_STATE" != "1" ]; then
        dumpsys SurfaceFlinger --timestats -enable >/dev/null 2>&1
        APP_FPS_ENABLED_STATE=1
        sleep 1
    fi
    dumpsys SurfaceFlinger --timestats -dump > "$TS_DUMP" 2>/dev/null
    if [ ! -s "$TS_DUMP" ]; then
        if [ "$FPS" -gt 0 ]; then APP_FPS=$APP_FPS_HOLD; else APP_FPS=0; fi
        return 0
    fi
    # 头部就是 statsStart/statsEnd/totalFrames(第 3~5 行), 读到就 break —— 整份 dump 有 8600 行。
    # 旧版用两次 awk(各 fork 一次, ~5ms × 2), 这里纯 shell 内建, 0 次 fork。
    tf=""; ts=""
    while read -r k _ v; do
        case "$k" in
            totalFrames) [ -z "$tf" ] && tf=$v ;;
            statsEnd)    [ -z "$ts" ] && ts=$v ;;
        esac
        [ -n "$tf" ] && [ -n "$ts" ] && break
    done < "$TS_DUMP"
    if [ -n "$tf" ] && [ -n "$ts" ] && [ "$APP_FPS_PREV_TF" != "0" ] && [ -n "$APP_FPS_PREV_TS" ]; then
        dt=$(( ts - APP_FPS_PREV_TS ))
        df=$(( tf - APP_FPS_PREV_TF ))
        if [ "$dt" -gt 0 ] && [ "$df" -ge 0 ]; then
            # statsEnd 是 Unix 秒级时间戳, dt 就是秒数; df 是帧数 -> 帧率 = df/dt
            v=$(( df / dt ))
            [ "$v" -gt 0 ] && APP_FPS_HOLD=$v
        fi
    fi
    if [ -n "$tf" ]; then APP_FPS_PREV_TF=$tf; fi
    if [ -n "$ts" ]; then APP_FPS_PREV_TS=$ts; fi
    # 差分失败(两次间隔不足 1 秒 / 计数器重置)时沿用上次算出的值, 而不是掉回内核的
    # 不准确读数 —— 否则界面会在 124 和 41 之间来回跳(旧版就是这个毛病)。
    if [ "$FPS" -gt 0 ]; then APP_FPS=$APP_FPS_HOLD; else APP_FPS=0; fi
    return 0
}

# 守护退出时关掉 timestats 统计(否则 SurfaceFlinger 会一直记直方图, 占内存)
app_fps_disable() {
    [ "$APP_FPS_ENABLED_STATE" = "1" ] || return 0
    dumpsys SurfaceFlinger --timestats -disable >/dev/null 2>&1
    APP_FPS_ENABLED_STATE=0
    rm -f "$TS_DUMP"
    return 0
}

sample_refresh() {
    local ln n int
    REF=0
    if [ -n "$REF_NODE" ]; then
        rdg "$REF_NODE"; ln=$RV
        ln=${ln#*fps:}
        ln=${ln# }
        n=${ln%% *}
        int=${n%%.*}
        is_num "$int" && REF=$int
    fi
    # 回退: 若没有 hw_vsync_info, 用 dynamic_fps(配置目标值)
    if [ "$REF" = "0" ] && [ -e /sys/class/mi_display/disp-DSI-0/dynamic_fps ]; then
        rdg /sys/class/mi_display/disp-DSI-0/dynamic_fps
        is_num "$RV" && REF=$RV
    fi
    return 0
}
probe_fps_nodes

# GPU 频率: 单文件, 每轮都读(0.23ms)。KGSL 只暴露 clock_mhz 一个可信来源。
sample_gpuclk() {
    GC=0
    [ -n "$KGSL_CLK" ] || return 0
    rdg "$KGSL_CLK"
    is_num "$RV" && GC=$RV
}

# 电池功耗: current_now × voltage_now
#
# ===== 单文件实测读取开销(本机, 300 次均值; mksh 一次 read 的底噪约 230µs)=====
#   battery/current_now    1166µs   ← 走电量计 I2C, 是底噪的 5 倍
#   battery/voltage_now    1156µs   ← 同上
#   battery/temp            243µs
#   battery/status          256µs
#   usb/current_now        5766µs   ← 走 PD 控制器, **5.8ms**!
#   usb/voltage_now        6126µs   ← **6.1ms**!
# 所以采样频率必须按"单项开销"分档, 不能每轮全读:
#   status/current   每轮(充电判定和功耗主信号, 必须新鲜)
#   voltage          2 轮一次(锂电池端电压变化 <0.5%/5s, 对 mW 的影响 <1%)
#   battery temp     60 秒一次(分钟级缓变量)
#   usb/wireless V,I 30 秒一次并缓存 —— 每轮读就是 +12ms/轮(2.5 倍开销)
#
# 【坑2·电池满电后 current_now≈0】插着充电器且电池已充满(status=Full)时,
#   电池不再充放电, current_now 会掉到 0~9mA 的涓流噪声 → 电池侧功率 ≈0,
#   看着像"坏掉了"。此时整机功耗全从充电器来, 真实值在 USB 输入侧, 所以用输入功率兜底。
BV_HOLD=0      # 上次的端电压(µV), 跨轮沿用
BT_HOLD=0      # 上次的电池温度(m℃), 跨轮沿用
BT_INTERVAL=${BT_INTERVAL:-60}
PIN=0          # 充电器输入功率(mW) 缓存
PIN_TICK=-999  # 上次刷新 PIN 时的 tick
PIN_INTERVAL=${PIN_INTERVAL:-30}
ONLPS=""       # 本次探到的在线充电器(usb/wireless), 空=没插

probe_online() {
    local ps f
    ONLPS=""
    for ps in usb wireless; do
        case "$ps" in
            usb) f=$USB_ONL ;;
            *)   f=$WL_ONL ;;
        esac
        [ -n "$f" ] || continue
        rdg "$f"
        [ "$RV" = "1" ] || continue
        ONLPS=$ps
        break
    done
    return 0
}

sample_batt() {
    local v uv ui st need_onl=0
    BI=0; MW=0; CHG=0

    # ---------- 1) 是否在充电: 只认 status(+充电器 online), 绝不看电流符号 ----------
    # 【坑3 · current_now 符号约定】(v1.8.4 修复: PWR 一直带 "+")
    #   本机(mca,business_battery)是 **充电为负、放电为正**:
    #     实测插着充电器时 STATUS=Charging 而 CURRENT_NOW=-1169000(µA)。
    #     与 webroot/api.cgi、index.html 里的注释"放电为正, 充电为负"一致。
    #   旧代码按"正电流 = 充电"推断 CHG, 于是**拔掉充电器(放电, current_now 为正)也被判成充电**,
    #   表现就是 PWR 永远带 "+"。电流符号只用来算功率(取绝对值), 方向一律交给 status。
    rdg "$BATT/status"; st=$RV
    case "$st" in
        Charg*|Full) CHG=1 ;;    # 充电中 / 已充满(满电仍插着充电器, 由充电器供电)
        Discharging) CHG=0 ;;    # 明确放电 -> 一定不显示 "+"
        *)           need_onl=1 ;;   # Unknown / Not charging / 读不到 -> 用充电器 online 兜底
    esac

    rdg "$BATT/current_now"; v=$RV
    case "$v" in -*) v=${v#-} ;; esac      # 只取幅值: 功耗显示不看方向
    is_num "$v" && BI=$v

    if [ "$BV_HOLD" = "0" ] || [ $(( tick % 2 )) -eq 0 ]; then
        rdg "$BATT/voltage_now"; v=$RV
        is_num "$v" && BV_HOLD=$v
    fi
    BV=$BV_HOLD

    if [ "$BT_HOLD" = "0" ] || [ $(( tick % BT_INTERVAL )) -eq 0 ]; then
        rdg "$BATT/temp"; v=$RV
        case "$v" in -*) v=${v#-} ;; esac
        # 单位守卫: 本机是 0.1℃(320=32.0℃), 部分机型是 m℃(32000)。值 <1000 判为 0.1℃。
        if is_num "$v"; then
            [ "$v" -lt 1000 ] && v=$((v * 100))
            BT_HOLD=$v
        fi
    fi
    BT=$BT_HOLD

    # status 判不出来(Not charging / 未知)时才去读 online —— 平时不花这 0.24ms
    if [ "$need_onl" = "1" ]; then
        probe_online
        # Not charging = 接着电源但电池不吃电(电池保护/高温限流): 仍算"有外接电源", 显示 "+"。
        #   真拔掉线时 status 会转 Discharging, 走不到这个分支。
        if [ -n "$ONLPS" ]; then CHG=1; else CHG=0; fi
    fi

    # 单位: µV × µA = pW, /1e9 才是 mW。
    # 【坑1·32位整数溢出】设备的 /system/bin/sh(mksh) 的 $(( )) 是 **32 位**运算!
    #   BV(约 4.4e6) × BI(约 6e5) ≈ 2.7e12, 远超 32 位上限 2.1e9 → 回绕,
    #   再 /1e9 就变成 0~1, 表现为 PWR 恒显示 0.0W 且永不变化。
    #   实测: 4469000 × 602000 回绕成 1688472704, /1e9 = 1 (真值应是 2690mW)。
    # 解法: **先除后乘**, 把两个数都缩到 1e3 量级再相乘, 结果落在 32 位内。
    #   (BV/1000) × (BI/1000) / 1000 → 4469 × 602 / 1000 = 2690 ✓ (精度损失 <1%)
    if [ "$BV" -gt 0 ] && [ "$BI" -gt 0 ]; then
        MW=$(( (BV / 1000) * (BI / 1000) / 1000 ))
    else
        MW=0
    fi

    # 【兜底·只在充电且电池侧几乎不吃电时】用充电器输入功率顶上, 30 秒刷新一次。
    #   注意外接电压单位: usb 是 µV(4983000), wireless 是 mV(4454), 量级差 1000 倍。
    if [ "$MW" -lt 100 ] && [ "$CHG" = "1" ]; then
        if [ "$PIN_TICK" -lt 0 ] || [ $(( tick - PIN_TICK )) -ge "$PIN_INTERVAL" ]; then
            [ -n "$ONLPS" ] || probe_online
            PIN=0
            if [ -n "$ONLPS" ]; then
                rdg "$PSDIR/$ONLPS/current_now"; ui=$RV
                rdg "$PSDIR/$ONLPS/voltage_now"; uv=$RV
                case "$ui" in -*) ui=${ui#-} ;; esac
                if is_num "$ui" && is_num "$uv" && [ "$ui" -gt 0 ] && [ "$uv" -gt 0 ]; then
                    if [ "$uv" -lt 100000 ]; then uv=$(( uv * 1000 )); fi
                    PIN=$(( (uv / 1000) * (ui / 1000) / 1000 ))
                fi
            fi
            PIN_TICK=$tick
        fi
        [ "$PIN" -gt 0 ] && MW=$PIN
    fi
    return 0
}

# 全量采样(once / post / bench / loop 用)
sample() {
    BIG=0; LIT=0; GC=0; GB=0; BI=0; MW=0; CHG=0; PSI=0; FPS=0; REF=0
    # CT/GT/BV/BT 由各自的采样函数按间隔跨轮保持, 这里**不能**清零, 否则分级采样失效
    sample_freq
    sample_gpuclk
    sample_temp        # CPU 温度: 30s 一读
    sample_batt        # 电流每轮, 电压 2 轮, 电池温度 60s, 充电器功率 30s
    sample_gputemp     # GPU 温度: 30s 一读
    sample_gpubusy     # GPU 占用: 每轮(内核算好的百分比)
    sample_cpuuse      # CPU 占用: /proc/stat 差分, 10s 一读
    sample_fps         # 内核合成帧率
    sample_refresh     # 面板刷新率
    sample_app_fps     # SF 真实帧率: 内部按内核帧率决定是否真去 dump(235ms/次)
    # SF 值优先(它才是"应用真实渲染帧率"); 静止时 APP_FPS=0, 自然落回内核读数
    if [ "$APP_FPS" -gt 0 ]; then FPS=$APP_FPS; fi
    return 0
}

# ---------- 排版 + 派发 ----------
# 拆成"拼串"(每轮都做, 零 fork)和"发通知"(只在文本真的变了才做, 86ms/次)两步。
# 旧版把两件事绑在一起: 只要频率/温度过了阈值就 fork 一次 cmd notification,
# 实测 cmd notification post 86ms/次 —— 5 秒一次就是 1.7% 单核, 而且大多数重发的文本
# 和上一条完全一样(心跳), 纯属白花。
TITLE=""; BODY=""; LAST_BODY=""
PROF_HOLD=""; PROF_TICK=-999
render_text() {
    local prof mw g f
    # 档位名 30 秒刷新一次(用户切档不频繁), 省掉 0.23ms/轮
    if [ "$PROF_TICK" -lt 0 ] || [ $(( tick - PROF_TICK )) -ge 6 ]; then
        if [ -e "$STATE/profile" ]; then rdg "$STATE/profile"; PROF_HOLD=$RV; fi
        PROF_TICK=$tick
    fi
    prof=$PROF_HOLD
    # MW 由 sample_batt 算好(单位 mW), 别再自己除一遍
    mw=$MW
    fmt2 "$BIG"; g=$F2
    fmt1 "$CT";  f=$F1
    TITLE="CPU ${g}G · ${f}℃"
    BODY="超大核 ${g}G"
    fmt2 "$LIT"; BODY="$BODY · 性能核 ${F2}G"
    [ "$GC" -gt 0 ] && BODY="$BODY · GPU ${GC}M"
    [ "$GB" -gt 0 ] && BODY="$BODY(${GB}%)"
    fmt1 "$CT"; BODY="$BODY
CPU ${F1}℃"
    if [ "$GT" -gt 0 ]; then fmt1 "$GT"; BODY="$BODY · GPU ${F1}℃"; fi
    if [ "$BT" -gt 0 ]; then fmt1 "$BT"; BODY="$BODY · 电池 ${F1}℃"; fi
    # 功耗段恒显示(与状态栏一致); 充电时 "+" 只贴在数值后面, 不能挂在温度后面
    if [ "$mw" -ge 1000 ]; then
        fmt1 "$mw"; pw="${F1}W"
    else
        pw="${mw}mW"
    fi
    [ "$CHG" = "1" ] && pw="${pw}+"
    BODY="$BODY · $pw"
    BODY="$BODY · 占用 ${USE}%"
    # 帧率/刷新率(节点存在才显示, 与状态栏一致)
    if [ -n "$FPS_NODE" ]; then
        BODY="$BODY · FPS ${FPS}"
        [ "$REF" -gt 0 ] && BODY="$BODY/${REF}Hz" || BODY="$BODY/-Hz"
    fi
    [ -n "$prof" ] && BODY="$BODY · $prof"
    printf '%s\n%s\n' "$TITLE" "$BODY" > "$STATE/hud_last.txt" 2>/dev/null
    return 0
}

post_notify() {
    [ "$TITLE" != "" ] || return 0
    cmd notification post -S bigtext -t "$TITLE" "$TAG" "$BODY" >/dev/null 2>&1
    LAST_BODY=$BODY
    return 0
}

# once / post / bench 用: 采样 -> 拼串 -> 无条件发一次
render_post() {
    local notify
    rdg "$STATE/hud_notify"; notify=${RV:-1}
    render_text
    # 只留悬浮窗时把通知关掉(hud_notify=0), 但采样和写文件不能停
    [ "$notify" != "0" ] && post_notify
    return 0
}

# 写给状态栏悬浮窗 App 的紧凑串(它没有 root, 读不了 sysfs, 只能读这个文件)。
# 用 printf 内建重定向, 不 fork。文件在 /data/local/tmp, 对普通 app 可读(0644)。
HUD_FILE=/data/local/tmp/k90_hud.txt
# 格式: "<性能核kHz> <超大核kHz> <温度m℃> <GPUMHz> <功耗mW> <是否充电1/0> <占用%> <帧率> <刷新率Hz> <GPU占用%>"，排版交给 App。
# 全整数: 不用取模拼小数, 也方便 App 用 split 解析。帧率/刷新率节点不存在时为 0(不显示)。
# 【坑4·前两个字段的顺序】(v1.8.5 修) App 侧 HudService.readRaw() 是
#   `rLit = p[0]; rBig = p[1];` —— 第 1 个字段必须是**性能核**(policy0), 第 2 个才是超大核。
#   旧版这里 printf 写的是 "$BIG" "$LIT"(超大核在前), 于是悬浮窗把"超大核的频率"标成了"性能核",
#   和状态栏通知(自己拼串, 顺序是对的)对不上。BIG/LIT 两个变量本身没错, 错的是落盘顺序。
# 第 7 字段 v1.8.5 起是**真实 CPU 利用率**(/proc/stat 差分), 旧版塞的是 PSI avg10 ——
#   语义不同(PSI 是"等 CPU 卡住的时间占比"), App 里却标着"占用%", 数值也是错的。字段位置不变。
# 第 10 字段 GB (GPU 占用%) 是 v1.8.0 新增。文件是覆盖写(printf > ), 恒定几十字节, 不会无限增长。
write_state() {
    printf '%d %d %d %d %d %d %d %d %d %d\n' "$LIT" "$BIG" "$CT" "$GC" "$MW" "$CHG" "$USE" "$FPS" "$REF" "$GB" > "$HUD_FILE" 2>/dev/null
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
    # 单速率循环: tick 单位是秒, HEARTBEAT 单位也是秒
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

# 每次启动都重建温度 zone 列表: 旧版用 [ -s ] || 只在"文件不存在"时才建, 于是
#   a) 历史版本留下的列表会一直沿用 —— 实测现网那份 21 条里混进了 thermal_zone76(type=battery),
#      旧过滤器把它当 CPU 温度参与了取最大值;
#   b) 内核/系统升级后 zone 编号会变, 缓存会指向错误传感器。
# 代价: 96 个 type 文件 ≈ 24ms, **只在守护启动时一次**。
build_tz_list

case "$1" in
    once)
        tick=0; sample; write_state; render_text
        printf '标题: %s\n正文: %s\n' "$TITLE" "$BODY"
        printf -- '---\n温度源 %s 个 zone · 状态文件: %s\n' "$(wc -l < "$TZ_LIST")" "$(cat "$HUD_FILE" 2>/dev/null)"
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
        # 逐项计时。旧版的 bench 是坏的: 它从 tick=0 开始连跑 50 次 sample(),
        #   而 sample_app_fps 的触发条件是 tick%10==0 → 50 轮全命中 → 50 次 dumpsys,
        #   报出 245ms/轮, 把"采样开销"和"一次 235ms 的 SF dump"混在一起, 数字毫无意义。
        # 现在: 单项分测(tick 固定, 避开分级采样) + 一轮按生产节奏走的总量。
        N=${BENCH_N:-50}
        bt() {
            bn=$1; bname=$2; shift 2
            bs=$(date +%s%3N); bi=0
            while [ "$bi" -lt "$bn" ]; do "$@"; bi=$((bi + 1)); done
            be=$(date +%s%3N)
            printf '  %-28s %6d µs/轮\n' "$bname" $(( (be - bs) * 1000 / bn ))
        }
        echo "== 逐项开销(各 $N 轮) =="
        tick=31                                  # 奇数: 避开 2 轮一次的分级采样
        bt "$N" "sample_freq"            sample_freq
        bt "$N" "sample_gpuclk"          sample_gpuclk
        bt "$N" "sample_temp(沿用上次)"   sample_temp
        TEMP_FULL=1; bt "$N" "sample_temp(全读)" sample_temp; TEMP_FULL=0
        bt "$N" "sample_batt"            sample_batt
        bt "$N" "sample_gputemp(沿用)"    sample_gputemp
        bt "$N" "sample_gpubusy"         sample_gpubusy
        bt "$N" "sample_fps"             sample_fps
        bt "$N" "sample_refresh"         sample_refresh
        bt "$N" "read_backlight"         read_backlight
        tick=30
        bt "$N" "sample_cpuuse"          sample_cpuuse
        echo "== 整轮(sample, tick 按 +5 前进 = 生产节奏) =="
        tick=0; s=$(date +%s%3N); i=0
        while [ "$i" -lt "$N" ]; do sample; i=$((i + 1)); tick=$((tick + 5)); done
        e=$(date +%s%3N)
        echo "  平均 $(( (e - s) / N )) ms/轮 (共 $N 轮 / $((e - s))ms)"
        echo "温度源 $(wc -l < "$TZ_LIST") 个 zone · 分级: CPU温度 ${TEMP_INTERVAL}s / GPU温度 ${GT_INTERVAL}s / 电池温度 ${BT_INTERVAL}s / 电压 2轮 / 占用 ${USE_INTERVAL}s / 充电器功率 ${PIN_INTERVAL}s"
        echo "SF dump: 有帧 ${APP_FPS_INTERVAL}s 一次, 静止 ${APP_FPS_IDLE_INTERVAL}s 一次(单次约 235ms)"
        sample; render_post
        echo "样例:"; cat "$STATE/hud_last.txt" 2>/dev/null
        ;;
    loop)
        last_key=""; last_tick=0; tick=0; LAST_BODY=""
        # ===== 单速率循环 =====
        # 所有数据(含帧率/刷新率)统一每 hud_interval(默认 5s)采样一次。
        # 之前试过 0.1s 高频刷 FPS, 守护 CPU 冲到 3.45% 单核(5s 档仅 0.30%, 差 11.5 倍),
        # 且高频唤醒阻碍 CPU 深睡, 实测开销太大 —— 退回统一 5s。
        # 高通 DRM 统计窗口 fps_periodicity_ms 用 1000ms(内核默认)。
        # 注意: 这个内核节点统计的是"CRTC 提交的帧", 遇 SurfaceView 直通的游戏会漏计,
        # 真正准确的帧率由 sample_app_fps() 从 SurfaceFlinger 取(见该函数注释)。
        FPERIOD=/sys/class/drm/card0-sde-crtc-0/fps_periodicity_ms
        [ -e "$FPERIOD" ] && echo "$FPS_PERIOD" > "$FPERIOD" 2>/dev/null
        while :; do
            rdg "$STATE/hud_enabled"; [ "$RV" = "1" ] || break
            rdg "$STATE/hud_interval"; iv=$RV; is_num "$iv" || iv=5
            [ "$iv" -lt 1 ] && iv=1
            read_backlight
            if [ "$BL" = "0" ]; then
                # 息屏: 不采样不推送, 用长睡眠省电
                sleep 15; tick=$((tick + 15)); continue
            fi
            # ---- 全量采样: 频率/温度/GPU/电池/占用/帧率/刷新率, 每 iv 秒一次 ----
            sample
            write_state
            render_text                     # 每轮都拼串 + 写 hud_last.txt(零 fork, 让 CLI 不再看到 15s 前的旧值)
            rdg "$STATE/hud_notify"; notify=${RV:-1}
            # 只在"该发 且 文本真的变了"时才 fork 一次 cmd notification(86ms/次)
            if [ "$notify" != "0" ] && should_post; then
                [ "$BODY" = "$LAST_BODY" ] || post_notify
                mark_posted
            fi
            # ONGOING 悬浮窗通知每 50 分钟续一次 snooze(tick 单位秒)
            [ $((tick % 3000)) -eq 0 ] && snooze_alert
            sleep "$iv"; tick=$((tick + iv))
        done
        # 退出时关掉 SurfaceFlinger 的 timestats 统计(它会一直累积直方图, 占内存)
        app_fps_disable
        rm -rf "$STATE/hud.lock"
        ;;
    *)
        echo "用法: hud.sh <once|post|loop|off|bench>"
        ;;
esac
