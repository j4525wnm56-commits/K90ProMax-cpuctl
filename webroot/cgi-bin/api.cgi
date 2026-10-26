#!/system/bin/sh
# WebUI 后端接口 (busybox httpd CGI)
# 所有参数走白名单校验, 不拼接命令

MODDIR=/data/adb/modules/k90_cpuctl
CP="$MODDIR/bin/cpuctl"
STATE=/data/adb/k90_cpuctl
CFG=/sys/devices/system/cpu/cpufreq
P0=$CFG/policy0
P6=$CFG/policy6
GPU=/sys/class/kgsl/kgsl-3d0
GCDEV=/sys/class/thermal/cooling_device37
PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
export PATH

. "$MODDIR/bin/profiles.sh" 2>/dev/null

get() { cat "$1" 2>/dev/null; }
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

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

jstr() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'
}

header() {
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
}

# 温度: 与 cpuctl 同源, 取 cpu-[01]-* 区域最大值
cpu_temp() {
    local z t v max=0
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(get "$z/type")
        case "$t" in
            cpu-[01]-*)
                v=$(get "$z/temp")
                is_num "$v" && [ "$v" -gt "$max" ] && max=$v ;;
        esac
    done
    echo "$max"
}

batt_temp() {
    local z t v
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(get "$z/type")
        case "$t" in
            battery|batt_therm)
                v=$(get "$z/temp")
                is_num "$v" && { echo "$v"; return 0; } ;;
        esac
    done
    echo 0
}

do_state() {
    local prof watch lim thr t gt bt maxleft until now msec
    prof=$(get "$STATE/profile"); [ -z "$prof" ] && prof=stock
    watch=$(get "$STATE/watch_enabled"); [ -z "$watch" ] && watch=0
    lim=$(get "$STATE/temp_limit"); is_num "$lim" || lim=48000
    thr=$(get "$STATE/throttled"); is_num "$thr" || thr=0
    msec=$(get "$STATE/max_seconds"); is_num "$msec" || msec=300
    maxleft=0
    until=$(get "$STATE/max_until")
    if is_num "$until"; then
        now=$(date +%s)
        maxleft=$((until - now))
        [ "$maxleft" -lt 0 ] && maxleft=0
    fi
    t=$(cpu_temp); gt=$(get "$GPU/temp"); bt=$(batt_temp)
    is_num "$t" || t=0
    is_num "$gt" || gt=0
    is_num "$bt" || bt=0

    header
    printf '{'
    printf '"ok":1,'
    printf '"profile":"%s",' "$(jstr "$prof")"
    printf '"watch":%s,' "$watch"
    printf '"throttled":%s,' "$thr"
    printf '"limit":%s,' "$lim"
    printf '"maxSeconds":%s,' "$msec"
    printf '"maxLeft":%s,' "$maxleft"
    printf '"temp":%s,"gpuTemp":%s,"battTemp":%s,' "$t" "$gt" "$bt"
    printf '"p0":{"id":"p0","name":"性能核 0-5","cpus":"0-5","min":%s,"max":%s,"cur":%s,"gov":"%s","avail":%s},' \
        "$(get "$P0/scaling_min_freq")" "$(get "$P0/scaling_max_freq")" "$(get "$P0/scaling_cur_freq")" \
        "$(jstr "$(get "$P0/scaling_governor")")" "$(jarr "$(get "$P0/scaling_available_frequencies")")"
    printf '"p6":{"id":"p6","name":"超大核 6-7","cpus":"6-7","min":%s,"max":%s,"cur":%s,"gov":"%s","avail":%s},' \
        "$(get "$P6/scaling_min_freq")" "$(get "$P6/scaling_max_freq")" "$(get "$P6/scaling_cur_freq")" \
        "$(jstr "$(get "$P6/scaling_governor")")" "$(jarr "$(get "$P6/scaling_available_frequencies")")"
    printf '"gpu":{"level":%s,"maxMhz":%s,"curMhz":%s,"thermal":%s,"freqs":%s},' \
        "$(get "$GCDEV/cur_state")" "$(get "$GPU/max_clock_mhz")" "$(get "$GPU/clock_mhz")" \
        "$(get "$GPU/thermal_pwrlevel")" "$(jarr "$(get "$GPU/freq_table_mhz")")"

    printf '"profiles":['
    local first=1 k n d a b c e g l
    profiles_dump | while IFS='|' read -r k n d a b c e g l; do
        [ "$first" = "1" ] || printf ','
        first=0
        printf '{"k":"%s","n":"%s","d":"%s","p0":[%s,%s],"p6":[%s,%s],"gpu":"%s"}' \
            "$(jstr "$k")" "$(jstr "$n")" "$(jstr "$d")" "$a" "$b" "$c" "$e" "$(jstr "$l")"
    done
    printf ']'
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
