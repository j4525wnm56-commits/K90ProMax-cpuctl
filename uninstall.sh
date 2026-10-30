#!/system/bin/sh
# 卸载: 停服务 + 还原出厂配置
# 注意: 这里直接读备份文件还原, 不依赖 cpuctl, 因为卸载时模块文件可能已被移除。

STATE=/data/adb/k90_cpuctl
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/k90_cpuctl

P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6
GPU=/sys/class/kgsl/kgsl-3d0
GCDEV=/sys/class/thermal/cooling_device37
GCDEV2=/sys/class/thermal/cooling_device35
MSM=/sys/kernel/msm_performance/parameters

# 1) 停守护
echo 0 > "$STATE/watch_enabled" 2>/dev/null
p=$(cat "$STATE/watch.lock/pid" 2>/dev/null)
case "$p" in ''|*[!0-9]*) ;; *) kill "$p" 2>/dev/null ;; esac
sleep 1
rm -rf "$STATE/watch.lock"

# 2) 停 WebUI
p=$(cat "$STATE/web.pid" 2>/dev/null)
case "$p" in ''|*[!0-9]*) ;; *) kill "$p" 2>/dev/null ;; esac
for pid in $(ps -A -o PID,ARGS 2>/dev/null | grep -F "httpd -f -p 127.0.0.1:" | grep -v grep | awk '{print $1}'); do
    kill "$pid" 2>/dev/null
done

# 3) 还原出厂配置
F="$STATE/backup/stock.conf"
if [ -f "$F" ]; then
    while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        case "$k" in
            p0_gov)  [ -n "$v" ] && echo "$v" > "$P0/scaling_governor" 2>/dev/null ;;
            p0_min)  [ -n "$v" ] && echo "$v" > "$P0/scaling_min_freq" 2>/dev/null ;;
            p0_max)  [ -n "$v" ] && echo "$v" > "$P0/scaling_max_freq" 2>/dev/null ;;
            p6_gov)  [ -n "$v" ] && echo "$v" > "$P6/scaling_governor" 2>/dev/null ;;
            p6_min)  [ -n "$v" ] && echo "$v" > "$P6/scaling_min_freq" 2>/dev/null ;;
            p6_max)  [ -n "$v" ] && echo "$v" > "$P6/scaling_max_freq" 2>/dev/null ;;
            gpu_min_pwrlevel) [ -n "$v" ] && echo "$v" > "$GPU/min_pwrlevel" 2>/dev/null ;;
            gpu_max_pwrlevel) [ -n "$v" ] && echo "$v" > "$GPU/max_pwrlevel" 2>/dev/null ;;
            gpu_pwrscale)     [ -n "$v" ] && echo "$v" > "$GPU/pwrscale" 2>/dev/null ;;
            gpu_force_clk_on) [ -n "$v" ] && echo "$v" > "$GPU/force_clk_on" 2>/dev/null ;;
            cdev35)  [ -n "$v" ] && echo "$v" > "$GCDEV2/cur_state" 2>/dev/null ;;
            cdev37)  [ -n "$v" ] && echo "$v" > "$GCDEV/cur_state" 2>/dev/null ;;
            msm_cpu_max) [ -n "$v" ] && echo "$v" > "$MSM/cpu_max_freq" 2>/dev/null ;;
        esac
    done < "$F"
else
    echo walt > "$P0/scaling_governor" 2>/dev/null
    echo walt > "$P6/scaling_governor" 2>/dev/null
    echo 384000  > "$P0/scaling_min_freq" 2>/dev/null
    echo 3628800 > "$P0/scaling_max_freq" 2>/dev/null
    echo 768000  > "$P6/scaling_min_freq" 2>/dev/null
    echo 4608000 > "$P6/scaling_max_freq" 2>/dev/null
    echo 17 > "$GPU/min_pwrlevel" 2>/dev/null
    echo 0  > "$GPU/max_pwrlevel" 2>/dev/null
fi

# 4) 核心全部恢复上线(限核状态不能留给系统)
for n in 1 2 3 4 5 6 7; do
    p=/sys/devices/system/cpu/cpu$n/online
    [ -e "$p" ] && echo 1 > "$p" 2>/dev/null
done

# 5) 保留备份, 只清运行状态
rm -f "$STATE/profile" "$STATE/watch_enabled" "$STATE/web.pid" "$STATE/web_port" \
      "$STATE/custom_p0_min" "$STATE/custom_p0_max" "$STATE/custom_p6_min" "$STATE/custom_p6_max" \
      "$STATE/gpu_level" "$STATE/web_disabled" "$STATE/throttled" "$STATE/max_until" \
      "$STATE/cores"
