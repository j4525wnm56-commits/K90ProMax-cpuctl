#!/system/bin/sh
# WebUI 后端接口 (busybox httpd CGI)
# 所有参数走白名单校验, 不拼接命令

MODDIR=/data/adb/modules/k90_cpuctl
CP="$MODDIR/bin/cpuctl"
STATE=/data/adb/k90_cpuctl
CFG=/sys/devices/system/cpu/cpufreq
P0=$CFG/policy0
P6=$CFG/policy6
CPUX=/sys/devices/system/cpu
GPU=/sys/class/kgsl/kgsl-3d0
BATT=/sys/class/power_supply/battery
GCDEV=/sys/class/thermal/cooling_device37
PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
export PATH

. "$MODDIR/bin/profiles.sh" 2>/dev/null

get() { cat "$1" 2>/dev/null; }
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_mask() {
    local m="$1"
    [ ${#m} -eq 8 ] || return 1
    case "$m" in *[!01]*) return 1 ;; esac
    return 0
}

# cooling_device 编号每次启动都可能变(实测 37 一度变成 cdsp_hw), 不能硬编码。
# 优先读 cpuctl 落下的 $STATE/gpu_cdev 缓存(零 fork), 失效才扫一遍目录。
resolve_gpu() {
    local c rest d ms
    if [ -f "$STATE/gpu_cdev" ]; then
        IFS='|' read -r c rest < "$STATE/gpu_cdev"
        if [ -n "$c" ] && [ -d "$c" ]; then GCDEV=$c; return 0; fi
    fi
    for d in /sys/class/thermal/cooling_device*; do
        [ "$(get "$d/type")" = "gpu" ] || continue
        ms=$(get "$d/max_state")
        is_num "$ms" || continue
        if [ "$ms" -gt 1 ]; then GCDEV=$d; return 0; fi
    done
    return 1
}
resolve_gpu

qs="${QUERY_STRING:-}"
getv() {
    local pair
    local IFS='&'
    for pair in $qs; do
        case "$pair" in
            "$1="*) printf '%s' "${pair#*=}"; return 0 ;;
        esac
    done
}

# 空格分隔 -> JSON 数组
jarr() {
    local out="" x
    for x in $1; do
        is_num "$x" || continue
        if [ -z "$out" ]; then out="$x"; else out="$out,$x"; fi
    done
    printf '[%s]' "$out"
}

# 纯 shell 转义: 原来用 sed|tr 每次请求要 fork 两个进程, 而 profiles 循环里要调 30 次
jstr() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# 同上但结果落在 $JSTR / $JARR, 供 printf 直接引用。
# 关键: 写成 $(jstr ...) 时命令替换必然 fork 一个子 shell, 单价 25ms 级;
# 老代码在 profiles 循环里调了 36 次, 单这一项就吃掉近 1 秒。改成赋值形式, 零 fork。
jesc() {
    JSTR=${1//\\/\\\\}
    JSTR=${JSTR//\"/\\\"}
}
jarrv() {
    local out="" x
    for x in $1; do
        is_num "$x" || continue
        if [ -z "$out" ]; then out="$x"; else out="$out,$x"; fi
    done
    JARR="[$out]"
}

header() {
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
}

# 温度: 与 cpuctl 同源, 取 cpu-[01]-* 区域最大值
# 96 个 thermal_zone, 原来每个 zone 读 type+temp 两次, 单请求 192 次 fork,
# 内存紧张时每次 fork 20ms 级 -> 一次 state 要 4 秒。改成缓存 zone 列表 + 一次 awk 读完。
TZC="$STATE/tz_cpu.list"; TZB="$STATE/tz_batt.list"

build_tz() {
    : > "$TZC"; : > "$TZB"
    # 96 个 zone 原来逐个 $(cat type) 是 96 次 fork(首次请求要 2 秒多);
    # 让 awk 一次读完所有 type 再分类, 只剩 1 次 fork
    awk '{print FILENAME "|" $0}' /sys/class/thermal/thermal_zone*/type 2>/dev/null |
    while IFS='|' read -r f t; do
        case "$t" in
            cpu-[01]-*)         echo "${f%/type}" >> "$TZC" ;;
            battery|batt_therm) echo "${f%/type}" >> "$TZB" ;;
        esac
    done
}

cpu_temp() {
    [ -s "$TZC" ] || build_tz
    [ -s "$TZC" ] || { echo 0; return; }
    awk 'BEGIN{m=0} {v=$1+0; if(v>m)m=v} END{printf "%d", m}' \
        $(sed 's|$|/temp|' "$TZC") 2>/dev/null
}

batt_temp() {
    [ -s "$TZB" ] || build_tz
    [ -s "$TZB" ] || { echo 0; return; }
    awk 'FNR==1 && !done && ($1+0)>0 {printf "%d", $1+0; done=1}' \
        $(sed 's|$|/temp|' "$TZB") 2>/dev/null
}

do_state() {
    local prof watch hud hudiv lim thr maxleft until now=0 msec
    # 状态文件都是 /data 下的普通文件, 用 shell 内建 read 直读:
    # 原来 6 次 $(cat) 就是 6 次 fork, 按 25ms 单价约 150ms
    prof="";   [ -f "$STATE/profile" ] && read -r prof < "$STATE/profile"; [ -z "$prof" ] && prof=stock
    watch=0;   [ -f "$STATE/watch_enabled" ] && read -r watch < "$STATE/watch_enabled"
    hud=0;     [ -f "$STATE/hud_enabled" ] && read -r hud < "$STATE/hud_enabled"
    hudiv=3;   [ -f "$STATE/hud_interval" ] && read -r hudiv < "$STATE/hud_interval"
    is_num "$hudiv" || hudiv=3
    lim=48000; [ -f "$STATE/temp_limit" ] && read -r lim < "$STATE/temp_limit"
    thr=0;     [ -f "$STATE/throttled" ] && read -r thr < "$STATE/throttled"
    msec=300;  [ -f "$STATE/max_seconds" ] && read -r msec < "$STATE/max_seconds"
    until="";  [ -f "$STATE/max_until" ] && read -r until < "$STATE/max_until"
    is_num "$lim"  || lim=48000
    is_num "$thr"  || thr=0
    is_num "$msec" || msec=300
    maxleft=0
    # maxLeft 留到拿到 awk 的 systime() 之后再算, 省掉一次 date fork(实测 29ms)
    # 一次 awk 读完所有 sysfs: 24 个标量 + 18 个温度 + 3 个电源, 顺带算好功耗和时间戳。
    # 原来这里是 1 次 awk + 2×(sed+awk) + 3 次 cat + 1 次 date ≈ 9 次 fork;
    # fork 单价实测 25-30ms, 合并后只剩 1 次。
    local raw k f1 f2 f3 f4 f5 f6 f7
    local p0min=0 p0max=0 p0cur=0 p0gov="" p0av="" p6min=0 p6max=0 p6cur=0 p6gov="" p6av=""
    local glev=0 gmax=0 gcur=0 gth=0 gfr=""
    local c0=1 c1=1 c2=1 c3=1 c4=1 c5=1 c6=1 c7=1
    local t=0 gt=0 bt=0 pmw=0 pma=0 pmv=0 pst=""
    local cpup="" batp=""
    [ -s "$TZC" ] || build_tz
    # 缓存列表存的是 zone 目录, 这里补上 /temp —— 漏了这一步 awk 拿到的是目录,
    # 不会报错也不会命中任何规则, 温度会静默变成 0
    while read -r p; do [ -n "$p" ] && cpup="$cpup $p/temp"; done < "$TZC" 2>/dev/null
    while read -r p; do [ -n "$p" ] && batp="$batp $p/temp"; done < "$TZB" 2>/dev/null
    raw=$(awk -v zc="$TZC" -v zb="$TZB" '
        FILENAME==zc { if (NF) cput[$0 "/temp"]=1; next }
        FILENAME==zb { if (NF) btt[$0 "/temp"]=1; next }
        # 注意: busybox awk 的正则字面量 /.../ 遇到 / 会提前终止(连 [/] 都不行),
        # 所以路径一律用字符串正则匹配, 别写成 /xxx\/temp$/
        FILENAME ~ "kgsl-3d0/temp$" { gt=$1+0; next }
        FILENAME ~ "thermal_zone[0-9]+/temp$" {
            v=$1+0
            if (FILENAME in cput) { if (v>mc) mc=v }
            else if ((FILENAME in btt) && !bs && v>0) { mb=v; bs=1 }
            next
        }
        FILENAME ~ "power_supply/battery/current_now$" { I=$1+0; next }
        FILENAME ~ "power_supply/battery/voltage_now$" { V=$1+0; next }
        FILENAME ~ "power_supply/battery/status$"      { ST=$1; next }
        { print FILENAME "|" $0 }
        END {
            # 放电为正, 充电为负(内核惯例), 功率取绝对值, 方向交给 status 判断
            mw=(V*I)/1000000000; if (mw<0) mw=-mw
            printf "@sum|%d|%d|%d|%d|%d|%d|%s\n", mc, gt, mb, mw, I, V, ST
            printf "@time|%d\n", systime()
        }
    ' "$TZC" "$TZB" $cpup $batp \
        "$P0/scaling_min_freq" "$P0/scaling_max_freq" "$P0/scaling_cur_freq" \
        "$P0/scaling_governor" "$P0/scaling_available_frequencies" \
        "$P6/scaling_min_freq" "$P6/scaling_max_freq" "$P6/scaling_cur_freq" \
        "$P6/scaling_governor" "$P6/scaling_available_frequencies" \
        "$GCDEV/cur_state" "$GPU/max_clock_mhz" "$GPU/clock_mhz" \
        "$GPU/thermal_pwrlevel" "$GPU/freq_table_mhz" "$GPU/temp" \
        "$CPUX/cpu0/online" "$CPUX/cpu1/online" "$CPUX/cpu2/online" "$CPUX/cpu3/online" \
        "$CPUX/cpu4/online" "$CPUX/cpu5/online" "$CPUX/cpu6/online" "$CPUX/cpu7/online" \
        "$BATT/current_now" "$BATT/voltage_now" "$BATT/status" 2>/dev/null)
    while IFS='|' read -r k f1 f2 f3 f4 f5 f6 f7; do
        case "$k" in
            "@sum")  t=$f1; gt=$f2; bt=$f3; pmw=$f4; pma=$f5; pmv=$f6; pst=$f7 ;;
            "@time") now=$f1 ;;
            "$P0/scaling_min_freq") p0min=$f1 ;; "$P0/scaling_max_freq") p0max=$f1 ;;
            "$P0/scaling_cur_freq") p0cur=$f1 ;; "$P0/scaling_governor") p0gov=$f1 ;;
            "$P0/scaling_available_frequencies") p0av=$f1 ;;
            "$P6/scaling_min_freq") p6min=$f1 ;; "$P6/scaling_max_freq") p6max=$f1 ;;
            "$P6/scaling_cur_freq") p6cur=$f1 ;; "$P6/scaling_governor") p6gov=$f1 ;;
            "$P6/scaling_available_frequencies") p6av=$f1 ;;
            "$GCDEV/cur_state") glev=$f1 ;; "$GPU/max_clock_mhz") gmax=$f1 ;;
            "$GPU/clock_mhz") gcur=$f1 ;; "$GPU/thermal_pwrlevel") gth=$f1 ;;
            "$GPU/freq_table_mhz") gfr=$f1 ;;
            "$CPUX/cpu0/online") c0=$f1 ;; "$CPUX/cpu1/online") c1=$f1 ;;
            "$CPUX/cpu2/online") c2=$f1 ;; "$CPUX/cpu3/online") c3=$f1 ;;
            "$CPUX/cpu4/online") c4=$f1 ;; "$CPUX/cpu5/online") c5=$f1 ;;
            "$CPUX/cpu6/online") c6=$f1 ;; "$CPUX/cpu7/online") c7=$f1 ;;
        esac
    done <<SYSEOF
$raw
SYSEOF
    # 一个都没读到(awk 失败)时给安全默认值, 别把空串塞进 JSON
    is_num "$t" || t=0
    is_num "$gt" || gt=0
    is_num "$bt" || bt=0
    is_num "$pmw" || pmw=0
    is_num "$pma" || pma=0
    is_num "$pmv" || pmv=0
    is_num "$now" || now=0
    if is_num "$until" && [ "$now" -gt 0 ]; then
        maxleft=$((until - now))
        [ "$maxleft" -lt 0 ] && maxleft=0
    fi

    # 转义与数组拼接全在当前 shell 完成: $(jstr ...) 每次都要 fork 子 shell
    jesc "$prof";  local profj=$JSTR
    jesc "$p0gov"; local p0gj=$JSTR
    jesc "$p6gov"; local p6gj=$JSTR
    jarrv "$p0av"; local p0aj=$JARR
    jarrv "$p6av"; local p6aj=$JARR
    jarrv "$gfr";  local gfj=$JARR
    # 档位表是静态的, 缓存成单行 JSON: 老实现每次 state 都要 9 条 × 4 次 $(jstr),
    # 等于 36 个子 shell。现在命中缓存时用 shell 内建 read, 零 fork。
    local pj=""
    PJ="$STATE/profiles.json"
    if [ ! -s "$PJ" ] || [ "$MODDIR/bin/profiles.sh" -nt "$PJ" ]; then
        profiles_dump | awk -F'|' '
            BEGIN { printf "[" }
            {
                if (NR>1) printf ","
                printf "{\"k\":\"%s\",\"n\":\"%s\",\"d\":\"%s\",\"p0\":[%s,%s],\"p6\":[%s,%s],\"gpu\":\"%s\"}", $1, $2, $3, $4, $5, $6, $7, $9
            }
            END { printf "]" }' > "$PJ" 2>/dev/null
    fi
    [ -s "$PJ" ] && read -r pj < "$PJ"
    [ -z "$pj" ] && pj='[]'

    header
    printf '{'
    printf '"ok":1,'
    printf '"profile":"%s",' "$profj"
    printf '"watch":%s,"hud":%s,"hudInterval":%s,' "$watch" "$hud" "$hudiv"
    printf '"throttled":%s,' "$thr"
    printf '"limit":%s,' "$lim"
    printf '"maxSeconds":%s,' "$msec"
    printf '"maxLeft":%s,' "$maxleft"
    printf '"temp":%s,"gpuTemp":%s,"battTemp":%s,' "$t" "$gt" "$bt"
    # power: mw 为绝对值, ma/mv 保号(负电流=充电中), st 交给前端翻译
    printf '"power":{"mw":%s,"ma":%s,"mv":%s,"st":"%s"},' \
        "$pmw" "$((pma / 1000))" "$((pmv / 1000))" "$pst"
    printf '"p0":{"id":"p0","name":"性能核 0-5","cpus":"0-5","min":%s,"max":%s,"cur":%s,"gov":"%s","avail":%s},' \
        "$p0min" "$p0max" "$p0cur" "$p0gj" "$p0aj"
    printf '"p6":{"id":"p6","name":"超大核 6-7","cpus":"6-7","min":%s,"max":%s,"cur":%s,"gov":"%s","avail":%s},' \
        "$p6min" "$p6max" "$p6cur" "$p6gj" "$p6aj"
    printf '"gpu":{"level":%s,"maxMhz":%s,"curMhz":%s,"thermal":%s,"freqs":%s},' \
        "$glev" "$gmax" "$gcur" "$gth" "$gfj"
    printf '"cores":[%s,%s,%s,%s,%s,%s,%s,%s],' "$c0" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7"
    printf '"profiles":%s' "$pj"
    printf '}'
}

do_action() {
    local act msg
    act=$(getv action)

    case "$act" in
        apply)
            local prof
            prof=$(getv profile)
            if ! profiles_dump | grep -q "^$prof|"; then
                header
                printf '{"ok":0,"msg":"未知档位"}'
                return 0
            fi
            msg=$(sh "$CP" apply "$prof" 2>&1)
            header
            printf '{"ok":1,"msg":"%s"}' "$(jstr "$msg")"
            ;;
        set)
            local cl mn mx
            cl=$(getv cluster); mn=$(getv min); mx=$(getv max)
            if ! is_num "$mn" || ! is_num "$mx"; then
                header; printf '{"ok":0,"msg":"频率必须是数字"}'; return 0
            fi
            case "$cl" in p0|p6) ;; *) header; printf '{"ok":0,"msg":"集群非法"}'; return 0 ;; esac
            if [ "${#mn}" -gt 8 ] || [ "${#mx}" -gt 8 ]; then
                header; printf '{"ok":0,"msg":"数值越界"}'; return 0
            fi
            msg=$(sh "$CP" set "$cl" "$mn" "$mx" 2>&1)
            header
            printf '{"ok":1,"msg":"%s"}' "$(jstr "$msg")"
            ;;
        setall)
            local a b c e gl
            a=$(getv p0min); b=$(getv p0max); c=$(getv p6min); e=$(getv p6max); gl=$(getv gpu)
            if ! is_num "$a" || ! is_num "$b" || ! is_num "$c" || ! is_num "$e"; then
                header; printf '{"ok":0,"msg":"频率必须是数字"}'; return 0
            fi
            if [ "${#a}" -gt 8 ] || [ "${#b}" -gt 8 ] || [ "${#c}" -gt 8 ] || [ "${#e}" -gt 8 ]; then
                header; printf '{"ok":0,"msg":"数值越界"}'; return 0
            fi
            # gpu 可选: 传了才改, 不传则保持原等级
            case "$gl" in ''|*[!0-9]*) gl="" ;; esac
            if [ -n "$gl" ] && [ "$gl" -gt 17 ]; then
                header; printf '{"ok":0,"msg":"GPU 等级 0-17"}'; return 0
            fi
            msg=$(sh "$CP" setall "$a" "$b" "$c" "$e" "$gl" 2>&1)
            header
            printf '{"ok":1,"msg":"%s"}' "$(jstr "$msg")"
            ;;
        gpu)
            local lv
            lv=$(getv level)
            if ! is_num "$lv" || [ "$lv" -gt 17 ]; then
                header; printf '{"ok":0,"msg":"GPU 等级 0-17"}'; return 0
            fi
            msg=$(sh "$CP" gpu "$lv" 2>&1)
            header
            printf '{"ok":1,"msg":"%s"}' "$(jstr "$msg")"
            ;;
        core)
            local n v
            n=$(getv cpu); v=$(getv value)
            if ! is_num "$n" || [ "$n" -gt 7 ]; then
                header; printf '{"ok":0,"msg":"核心编号 0-7"}'; return 0
            fi
            case "$v" in
                0|1) ;;
                *) header; printf '{"ok":0,"msg":"参数非法"}'; return 0 ;;
            esac
            if [ "$n" = "0" ] && [ "$v" = "0" ]; then
                header; printf '{"ok":0,"msg":"cpu0 是引导核, 不允许关闭"}'; return 0
            fi
            msg=$(sh "$CP" core "$n" "$v" 2>&1)
            header
            printf '{"ok":1,"msg":"%s"}' "$(jstr "$msg")"
            ;;
        cores)
            local m
            m=$(getv mask)
            if ! is_mask "$m"; then
                header; printf '{"ok":0,"msg":"掩码必须是 8 位 0/1"}'; return 0
            fi
            msg=$(sh "$CP" cores "$m" 2>&1)
            header
            printf '{"ok":1,"msg":"%s"}' "$(jstr "$msg")"
            ;;
        watch)
            local v
            v=$(getv value)
            case "$v" in
                0) msg=$(sh "$CP" watch off 2>&1) ;;
                1) msg=$(sh "$CP" watch on 2>&1) ;;
                *) header; printf '{"ok":0,"msg":"参数非法"}'; return 0 ;;
            esac
            header
            printf '{"ok":1,"msg":"%s"}' "$(jstr "$msg")"
            ;;
        temp_limit)
            local v
            v=$(getv value)
            if ! is_num "$v" || [ "$v" -lt 35000 ] || [ "$v" -gt 65000 ]; then
                header; printf '{"ok":0,"msg":"温度上限 35-65 度"}'; return 0
            fi
            echo "$v" > "$STATE/temp_limit"
            header
            printf '{"ok":1,"msg":"温度上限已设为 %s"}' "$((v / 1000))"
            ;;
        backup)
            msg=$(sh "$CP" backup 2>&1)
            header
            printf '{"ok":1,"msg":"已重新备份当前配置"}'
            ;;
        hud)
            local v
            v=$(getv value)
            case "$v" in
                0) msg=$(sh "$CP" hud off 2>&1) ;;
                1) msg=$(sh "$CP" hud on 2>&1) ;;
                *) header; printf '{"ok":0,"msg":"参数非法"}'; return 0 ;;
            esac
            header; printf '{"ok":1,"msg":"%s"}' "$(jstr "$msg")"
            ;;
        hud_interval)
            local v
            v=$(getv value)
            if ! is_num "$v" || [ "$v" -lt 1 ] || [ "$v" -gt 60 ]; then
                header; printf '{"ok":0,"msg":"间隔 1-60 秒"}'; return 0
            fi
            echo "$v" > "$STATE/hud_interval"
            header; printf '{"ok":1,"msg":"采样间隔已设为 %ss"}' "$v"
            ;;
        restore)
            msg=$(sh "$CP" restore 2>&1)
            header
            printf '{"ok":1,"msg":"%s"}' "$(jstr "$msg")"
            ;;
        *)
            header
            printf '{"ok":0,"msg":"未知动作"}'
            ;;
    esac
}

act=$(getv action)
case "$act" in
    ""|state) do_state ;;
    *)        do_action ;;
esac
