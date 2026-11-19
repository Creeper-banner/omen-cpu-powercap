#!/bin/bash
# 负载测试：真实功耗 + 性能(bogo-ops/s)，并显示强制执行位是否还在
# 用法: sudo bash scripts/loadtest.sh [秒=30] [--label "90W+clamp"] [--no-load] [--turbostat]
set -u
export LC_ALL=C
N=30; LOAD=1; LABEL=""; USE_TS=0; THREADS=""
while [ $# -gt 0 ]; do
	case "$1" in
	--no-load) LOAD=0 ;;
	--label) LABEL=${2:-}; shift ;;
	--turbostat) USE_TS=1 ;;
	--cpu) THREADS=${2:-}; shift ;;
	*[!0-9]*) : ;;
	*) N=$1 ;;
	esac
	shift
done
Z=${PCZ:-/sys/class/powercap/intel-rapl:0}
OUT=$(mktemp /tmp/loadtest.XXXXXX)
[ "${PL_MOCK:-0}" = 1 ] || [ "$(id -u)" = 0 ] || { echo "请用 sudo 运行（energy_uj/MSR 需要 root）"; exit 1; }

read64() { local v; v=$(rdmsr -p 0 "$1" 2>/dev/null) || return 1; [[ "$v" =~ ^[0-9a-fA-F]+$ ]] || return 1; echo "$v"; }
PU=3; t=$(rdmsr -f 3:0 0x606 2>/dev/null || true); [[ "${t:-}" =~ ^[0-9a-f]+$ ]] && PU=$((0x$t))
w()   { awk -v f="$1" -v u="$PU" 'BEGIN{printf "%.0f", f/(2^u)}'; }
tmp() { sensors 2>/dev/null | awk '/Package id 0/{for(i=1;i<=NF;i++) if($i ~ /^\+[0-9]+(\.[0-9]+)?C?$/){gsub(/[+:]/,"",$i); print $i+0; exit}}'; }
mhz() { cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | sort -n | tail -1 | awk '{printf "%.2f", $1/1000000}'; }
enr() { cat $Z/energy_uj 2>/dev/null || echo 0; }
# MSR 0x64F = POWER_PERF_LIMIT_STATUS：bit0 RAPL | bit1 VDDt | bit2 VDD | bit3 Turbo | bit4 Max Ratio | bit5 Other
reasons() {
	local v=${1:-0} out=""
	[ "$v" = "?" ] && { echo "?"; return; }
	[ $(( v & 1 )) = 1 ] && out="$out RAPL"
	[ $(( (v >> 1) & 1 )) = 1 ] && out="$out VDDt"
	[ $(( (v >> 2) & 1 )) = 1 ] && out="$out VDD"
	[ $(( (v >> 3) & 1 )) = 1 ] && out="$out Turbo"
	[ $(( (v >> 4) & 1 )) = 1 ] && out="$out MaxRatio"
	[ $(( (v >> 5) & 1 )) = 1 ] && out="$out Other"
	[ -z "$out" ] && out="none"
	echo "${out# }"
}
REASON_MSR=1
# 一次 rdmsr 解出 PL1/PL2/clamp，省掉重复调用（每秒只做 1 次 MSR 读）
decode() {
	local r=${1:-0}
	PL1W=$(w $(( r & 0x7fff ))); PL2W=$(w $(( (r >> 32) & 0x7fff )))
	CLAMP=$(( (r >> 16) & 1 )); EN1=$(( (r >> 15) & 1 ))
}

decode $((0x$(read64 0x610 2>/dev/null || echo 0)))
echo "采样 ${N}s | 起始 PL1=${PL1W}W en=${EN1} clamp=${CLAMP} PL2=${PL2W}W | 温度 $(tmp)C${LABEL:+ | label=$LABEL}"
[ "$USE_TS" = 1 ] && command -v turbostat >/dev/null && \
	( turbostat --interval 5 --show PkgTmp,PkgWatt,Bzy_MHz -q > "$OUT.turbostat" 2>&1 & echo "turbostat 记录到 $OUT.turbostat" )

if [ $LOAD = 1 ]; then
	stress-ng --cpu "${THREADS:-$(nproc)}" --cpu-method matrixprod --timeout "${N}s" --metrics-brief > "$OUT" 2>&1 &
	SPID=$!
fi

now_ns() { date +%s%N; }
# ⚠ 每轮循环实际耗时 ≈1.35s（sleep 1 + sensors/cat 24 个文件 + 3 次 rdmsr），
#    按“整 1 秒”算瓦数会系统性高估 35%。必须用两次采样的真实时间差做分母。
t0=$(now_ns); prev=$(enr); declare -a W=(); max=0; tmax=0; cmin=99; cmax=0; pmin=99999; pmax=0; SEEN=""
n=0; dtsum=0
end=$(( $(date +%s) + N + 2 ))
while [ "$(date +%s)" -lt $end ]; do
	sleep 1
	e=$(enr); t1=$(now_ns); dt=$(( t1 - t0 )); t0=$t1	# dt 单位 ns
	[ "$e" -lt "$prev" ] && { prev=$e; continue; }
	[ $dt -le 0 ] && { prev=$e; continue; }
	# W = Δe[uJ]×1e-6 / (Δt[ns]×1e-9) = Δe×1000/Δt
	pw=$(awk -v d=$(( e - prev )) -v t=$dt 'BEGIN{printf "%.0f", d*1000/t}')
	prev=$e; n=$((n+1)); dtsum=$((dtsum + dt))
	W+=($pw)
	[ $pw -gt $max ] && max=$pw
	decode $((0x$(read64 0x610 2>/dev/null || echo 0)))
	if [ $REASON_MSR = 1 ]; then
		v=$(read64 0x64f 2>/dev/null) || { REASON_MSR=0; v=""; rs="n/a"; }
		[ $REASON_MSR = 1 ] && { rs=$(reasons $((0x$v))); SEEN="$SEEN $rs"; }
		pkg=$(read64 0x613 2>/dev/null || echo "?")
	fi
	[ "$CLAMP" -lt "$cmin" ] && cmin=$CLAMP; [ "$CLAMP" -gt "$cmax" ] && cmax=$CLAMP
	[ "$PL1W" -lt "$pmin" ] && pmin=$PL1W; [ "$PL1W" -gt "$pmax" ] && pmax=$PL1W
	t=$(tmp); [ "${t:-0}" -gt "$tmax" ] 2>/dev/null && tmax=$t
	printf '  %s  Pkg=%3dW  T=%sC  最高频=%sGHz  PL1=%sW clamp=%d  限幅: %s  0x613=%s\n' \
		"$(date +%T)" "$pw" "${t:-?}" "$(mhz)" "$PL1W" "$CLAMP" "${rs:-?}" "${pkg:-?}"
done
[ $LOAD = 1 ] && wait $SPID
[ "$USE_TS" = 1 ] && pkill -f 'turbostat --interval' 2>/dev/null

# 平均 / 稳态（最后 10 个采样）/ 性能
read -r AVG STEADY <<< "$(printf '%s\n' "${W[@]}" | awk '
{ a[NR]=$1 } END {
	n=NR; s=0; for(i=1;i<=n;i++) s+=a[i]
	t0 = (n>10 ? n-9 : 1); ts=0; tc=0
	for(i=t0;i<=n;i++){ ts+=a[i]; tc++ }
	printf "%.0f %.0f", (n?s/n:0), (tc?ts/tc:0)
}')"
printf '\n\033[1m结果%s\033[0m: 平均 %sW | 峰值 %sW | 稳态(末10采样) %sW | 最高温 %sC\n' \
	"$([ -n "$LABEL" ] && printf ' [%s]' "$LABEL")" "$AVG" "$max" "$STEADY" "$tmax"
if [ $n -gt 0 ]; then
	printf '  \033[2m(%d 个采样，平均间隔 %.2fs —— 瓦数已按真实间隔折算；温度 %.0f°C 时 %sW 若 ≈PL1 即为撞墙)\033[0m\n' \
		"$n" "$(awk -v d=$dtsum -v n=$n 'BEGIN{printf "%.2f", d/n/1e9}')" "${tmax:-0}" "$STEADY"
fi
BOGO=$(awk '/\] cpu /{print $(NF-1)}' "$OUT" | tail -1)
echo "  性能: ${BOGO:-N/A} bogo-ops/s   （A/B 就比这个数和上面的稳态瓦数）"

RAPL=0
if [ -n "$SEEN" ]; then
	RAPL=$(printf '%s\n' $SEEN | grep -c '^RAPL$' || true)
	printf '  \033[1m限幅原因统计\033[0m（MSR 0x64F，出现次数）: %s\n' \
		"$(printf '%s\n' $SEEN | sed '/^$/d' | sort | uniq -c | sort -rn | awk '{printf "%s×%s ", $2, $1}')"
fi

printf '  \033[1m判读\033[0m\n'
if [ "$cmin" != "$cmax" ]; then
	echo "    ⚠ clamp 位在测试中变过 ($cmin→$cmax)：有人（内核 powercap 写路径 / EC）在改写 0x610"
elif [ "$cmax" = 0 ]; then
	printf '    \033[33mPL1 clamp=0 全程 → 限制值不生效，瓦数和 PL1 无关。先 pl.sh set <W> --clamp 或 pl.sh bios\033[0m\n'
elif awk -v a="$STEADY" -v p="$pmax" 'BEGIN{exit !(a > p*1.15)}'; then
	if [ "${RAPL:-0}" -gt 0 ]; then
		echo "    稳态 ${STEADY}W > PL1 ${pmax}W，但 0x64F 报过 RAPL → 墙是真的，只是执行窗口远长于本次采样：跑 180s 再看"
	else
		printf '    \033[33m稳态 %sW ≈ PL1(%sW) 的 %s 倍，且 0x64F 全程不报 RAPL → PL1 没有在压功率，天花板在别处（电流/VRM/EC 供电或频率上限）\033[0m\n' \
			"$STEADY" "$pmax" "$(awk -v a="$STEADY" -v p="$pmax" 'BEGIN{printf "%.2f", a/p}')"
		echo "    下一步：pl.sh set 25 157 --clamp（限制值若是活的，功率必须塌）；loadtest --cpu 8（看频率能不能上去）"
	fi
elif awk -v a="$STEADY" -v p="$pmax" 'BEGIN{exit !(a >= p*0.85)}'; then
	echo "    稳态 ${STEADY}W ≈ PL1 ${pmax}W → 正在撞功耗墙，抬 PL1(+TAU) 有收益"
elif [ "${tmax:-0}" -ge 95 ]; then
	echo "    稳态 ${STEADY}W 远低于 PL1，但温度 ${tmax}C → 撞温度墙，先动风扇曲线"
else
	echo "    稳态 ${STEADY}W 远低于 PL1 ${pmax}W 且只有 ${tmax}C → 限流在 EC/供电侧，不在 RAPL"
fi
echo "  原始输出: $OUT${USE_TS:+ $OUT.turbostat}"
