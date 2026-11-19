#!/bin/bash
# 只读诊断：把 CPU 功耗限制的真实来源全部打印出来
# 用法: sudo ./scripts/probe.sh   (不加 sudo 会跳过 MSR 部分)
set -u
export LC_ALL=C

sec() { printf '\n\033[1m===== %s =====\033[0m\n' "$1"; }
ROOT=0; [ "$(id -u)" = 0 ] && ROOT=1

sec "机器"
for f in sys_vendor product_name board_name bios_version; do
	printf '%-14s %s\n' "$f" "$(cat /sys/class/dmi/id/$f 2>/dev/null)"
done
uname -r
grep -m1 'model name' /proc/cpuinfo

sec "内核模块 / 驱动"
lsmod | awk '$1 ~ /^(omen_wmi_boost|hp_wmi|intel_rapl.*|msr|nvidia|tpmi.*)$/'
echo "lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null)"

sec "platform_profile (EC 性能档位)"
echo "active : $(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"
echo "choices: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)"
if [ -d /sys/kernel/omen_wmi_boost ]; then
	echo "omen_wmi_boost thermal_profile = $(cat /sys/kernel/omen_wmi_boost/thermal_profile 2>&1)"
	echo "  模块参数: $(for f in /sys/module/omen_wmi_boost/parameters/*; do printf '%s=%s ' "${f##*/}" "$(cat $f)"; done)"
fi

sec "powercap (RAPL) 各约束"
for z in /sys/class/powercap/intel-rapl*:[*0-9]*; do
	[ -d "$z" ] || continue
	printf '%-24s name=%-10s enabled=%s\n' "${z##*/}" "$(cat $z/name)" "$(cat $z/enabled)"
	for c in 0 1 2 3; do
		f="$z/constraint_${c}_name"
		[ -f "$f" ] || continue
		printf '    constraint_%s (%-10s) limit=%-11s max=%-11s window=%s\n' \
			"$c" "$(cat "$f")" \
			"$(cat "$z/constraint_${c}_power_limit_uw")" \
			"$(cat "$z/constraint_${c}_max_power_uw" 2>/dev/null)" \
			"$(cat "$z/constraint_${c}_time_window_us")"
	done
done

sec "tuned / cpufreq"
tuned-adm active 2>&1 | head -2
echo "driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null) governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) EPP=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"
for f in status min_perf_pct max_perf_pct no_turbo; do
	[ -f /sys/devices/system/cpu/intel_pstate/$f ] && printf '  intel_pstate/%-13s %s\n' "$f" "$(cat /sys/devices/system/cpu/intel_pstate/$f)"
done

sec "供电"
for p in /sys/class/power_supply/*; do
	printf '%-34s type=%-8s online=%s\n' "${p##*/}" "$(cat $p/type 2>/dev/null)" "$(cat $p/online 2>/dev/null)"
done

if [ $ROOT != 1 ]; then
	printf '\n\033[33m提示: 用 sudo 运行可解码 RAPL MSR (锁定状态 / 真实 PL1/PL2)。当前内核 lockdown=%s，MSR 写可用。\033[0m\n' "$(cat /sys/kernel/security/lockdown)"
	exit 0
fi

PU=$(rdmsr -f 3:0 0x606 2>/dev/null); EU=$(rdmsr -f 12:8 0x606 2>/dev/null); TU=$(rdmsr -f 19:16 0x606 2>/dev/null)
# 注意: awk 没有 << 位运算符，必须用 2^u
watt() { awk -v f="$1" -v u="$PU" 'BEGIN{printf "%.1f", f/(2^u)}'; }

sec "MSR_RAPL_POWER_UNIT(0x606) = 0x$(rdmsr -p 0 0x606)"
printf '  power unit = 2^-%s W/LSB (%s W)   energy unit = 2^-%s J   time unit = 2^-%s s\n' \
	"$PU" "$(awk -v u="$PU" 'BEGIN{printf "%.4f", 1/(2^u)}')" "$EU" "$TU"

sec "MSR_PKG_POWER_LIMIT(0x610)"
raw=$((0x$(rdmsr -p 0 0x610)))
pl1=$(( raw & 0x7fff )); pl1en=$(( (raw >> 15) & 1 )); tau=$(( (raw >> 16) & 0xff ))
pl2=$(( (raw >> 32) & 0x7fff )); pl2en=$(( (raw >> 47) & 1 ))
lock=$(( (raw >> 63) & 1 ))
printf '  raw         = 0x%016x\n' "$raw"
printf '  LOCK(bit63) = %s  %s\n' "$lock" "$([ "$lock" = 1 ] && echo '<- 已锁定：wrmsr 无效，必须走 EC/WMI' || echo '<- 未锁定：wrmsr 可用')"
printf '  PL1         = %s W (field %d) enable=%d\n' "$(watt $pl1)" "$pl1" "$pl1en"
printf '  TAU field   = 0x%02x\n' "$tau"
printf '  PL2         = %s W (field %d) enable=%d\n' "$(watt $pl2)" "$pl2" "$pl2en"

PI=$((0x$(rdmsr -p 0 0x614)))
sec "MSR_PKG_POWER_INFO(0x614) = 0x$(rdmsr -p 0 0x614)"
awk -v v="$PI" -v u="$PU" 'BEGIN{
  m=v%128; M=int(v/128)%128; T=int(v/16384)%128; L=int(v/33554432)%2;
  printf "  字段解码(每段 7bit, LSB=2^-%ds): 最小=%.2fW 最大=%.2fW TDP=%.2fW 锁定=%d\n", u, m/(2^u), M/(2^u), T/(2^u), L
  if (M/(2^u) < 10) print "  → 此寄存器内容无效：powercap 的 55W 天花板来自 TPMI 元数据(processor_thermal_rapl)，不是这里" }'

sec "其它 MSR"
printf '  0x613 PKG_PERF_STATUS   = 0x%s  (非零 = 累计过限幅时间)\n' "$(rdmsr -p 0 0x613 2>/dev/null || echo ERR)"
v=$(rdmsr -p 0 0x64F 2>/dev/null || true)	# POWER_PERF_LIMIT_STATUS：谁在压频率
if [ -n "${v:-}" ]; then
	printf '  0x64F POWER_PERF_LIMIT  = 0x%s → 当前限幅原因:' "$v"
	for b in 0:RAPL 1:VDDt 2:VDD 3:Turbo 4:MaxRatio 5:Other 15:Active; do
		i=${b%%:*}; n=${b#*:}
		if [ $(( (0x$v >> i) & 1 )) = 1 ]; then printf ' %s' "$n"; fi
	done
	printf '   (无输出 = 此刻没限幅，负载中再看)\n'
fi
printf '  0x610..0x61c 备用       :'
for m in 0x615 0x616 0x619 0x61c 0x620; do printf ' %s=0x%s' "$m" "$(rdmsr -p 0 $m 2>/dev/null || echo ERR)"; done; echo

sec "GPU (共享供电/散热预算)"
nvidia-smi --query-gpu=name,power.limit,power.default_limit,power.max_limit,temperature.gpu --format=csv,noheader 2>/dev/null

sec "温度/风扇"
sensors 2>/dev/null | grep -Ei 'Package|fan[0-9]|Tctl|acpitz' | head
