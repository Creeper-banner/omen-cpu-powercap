#!/usr/bin/env bash
# ecwatch.sh —— 在 CPU 负载下定时快照「整片 EC RAM」，最后只打印**变过的字节**
#
# 为什么要它：实测已经证明墙不是 RAPL，而是 EC 里的预算（EL1R=45/90、EL2R=130）。
# 但同一个 profile 下功耗会走 130W → 90W → 45W 的台阶，说明 EC 里还有一个
# “随时间衰减”的预算变量。它的名字在 AML 里只是声明、从不引用（SHPM/DPPC/CMAX/
# TDP0/TDP1/P1DP/P2DP…），没法静态推导 —— 只能边跑负载边逐字节对比。
#
# 输出两部分：
#   1) 每次快照的时刻 + 封装瓦数（RAPL energy 差分，真实时间折算）
#   2) 只列出值发生变化的 EC 偏移，按快照顺序排成一行
# 用法：
#   sudo bash scripts/ecwatch.sh              # 240 秒，每 15 秒一次
#   sudo bash scripts/ecwatch.sh 120 10       # 120 秒，每 10 秒
#   CPU=24 sudo bash scripts/ecwatch.sh 60 5  # 指定 stress 线程数
set -uo pipefail

RAW=${RAW:-/sys/kernel/hp_raw}
DUR=${1:-240}
IV=${2:-15}
CPU=${CPU:-24}
RAPL=${RAPL:-/sys/class/powercap/intel-rapl:0/energy_uj}

die() { echo "错误: $*" >&2; exit 1; }

[ -d "$RAW" ] || die "hp_raw 未加载：sudo bash scripts/hpraw.sh load"
[ "$(id -u)" = 0 ] || die "需要 root：sudo bash scripts/ecwatch.sh $DUR $IV"
command -v stress-ng >/dev/null 2>&1 || die "缺 stress-ng：sudo dnf install stress-ng"
[ "$IV" -ge 2 ] 2>/dev/null || die "间隔至少 2 秒（一次快照要读 256 次 EC）"
[ -r "$RAPL" ] || die "读不到 $RAPL（瓦数会缺，不影响字节对比）"

# EC 字段名（dsdt ERAM Field，只列有意义的；空名就只印偏移）
declare -A NAMES=(
	[0x29]=NPL1 [0x2a]=NPL2 [0x30]=BTPL [0x31]=BTPH [0x32]=BCLC
	[0x34]=SRP1 [0x35]=SRP2 [0x37]=ECL1 [0x38]=ECL2 [0x39]=ECL4
	[0x3a]=EL1R [0x3b]=EL2R [0x3c]=EL4R
	[0x40]=APS0 [0x41]=APS1 [0x42]=APS2 [0x43]=APS3 [0x44]=APS4
	[0x47]=TNT2 [0x48]=TNT3 [0x49]=TNT4 [0x4a]=IRSN [0x4b]=TNT5 [0x4c]=STRM
	[0x52]=ECLS [0x53]=CPHK [0x55]=EC45 [0x57]=CPUT [0x58]=RTMP [0x59]=TNT1
	[0x5b]=HPTC [0x61]=SHPM [0x62]=OMCC [0x68]=PLGS [0x69]=BCTF
	[0x89]=GPUT [0x90]=NVDO [0x91]=ECDO [0x94]=GSSU [0x95]=HPCM [0x96]=BSOC
	[0xa0]=QBHK [0xa2]=QBBB [0xa3]=ADPH [0xb0]=RPM1 [0xb7]=GPTM [0xb8]=EPWM
	[0xba]=CLOW [0xbb]=CMAX [0xbe]=TDP01 [0xbf]=P1DP [0xc1]=DPPC
	[0xe9]=DTMT [0xea]=PL12 [0xeb]=ETMT [0xec]=FFFS
)

# 一次全 256 字节快照（4 次 ecram 调用，每次 64 字节；只读）
# 每段都校验拿到的字节数，不足就重试（sysfs 写入是同步的，重试只是保险）
snap() {
	local off out="" chunk n try
	for off in 0x00 0x40 0x80 0xC0; do
		chunk=""
		for try in 1 2 3; do
			printf '%s 0x40\n' "$off" > "$RAW/ecram" || return 1
			chunk=$(sed -n '/起 64 字节/,$p' "$RAW/ecram_result" | tail -n +2 |
				tr -d '\t' | tr '\n' ' ')
			set -- $chunk
			n=$#
			[ "$n" -eq 64 ] && break
			sleep 0.1
		done
		[ "$n" -eq 64 ] || echo "  ⚠ EC 偏移 $off 只读到 $n/64 字节" >&2
		out+=" $chunk"
	done
	printf '%s' "$out"
}

now_ns() { date +%s%N; }

# 顺手把几个“可能被别人悄悄改掉”的 MSR 也记下来（没有 rdmsr 就跳过）
HAVE_MSR=0; command -v rdmsr >/dev/null 2>&1 && HAVE_MSR=1
msrs() {
	[ "$HAVE_MSR" = 1 ] || return 0
	local r out=""
	for r in 0x610 0x618 0x61a 0x771 0x774; do
		out+=" $r=$(rdmsr -p 0 "$r" 2>/dev/null || echo '??')"
	done
	printf '%s' "$out"
}

SNAP=(); TS=(); WT=(); MSR=()
e_prev=$(cat "$RAPL"); t_prev=$(now_ns); t0=$t_prev

echo "ecwatch: 总 ${DUR}s，每 ${IV}s 一次，stress-ng --cpu $CPU"
stress-ng --cpu "$CPU" --timeout "${DUR}s" >/dev/null 2>&1 &
LOAD=$!
trap 'kill $LOAD 2>/dev/null' EXIT
sleep 2   # 让负载先起来

SNAP+=("$(snap)"); TS+=(0); WT+=(0); MSR+=("$(msrs)")
echo "  采样 #0（负载刚起步）"

while :; do
	sleep "$IV"
	e=$(cat "$RAPL"); t=$(now_ns)
	de=$((e - e_prev)); [ "$de" -lt 0 ] && de=$((de + 0x100000000))
	dt=$((t - t_prev))
	w=$(awk -v d="$de" -v t="$dt" 'BEGIN { printf "%.0f", (t > 0) ? d / (t / 1e9) / 1e6 : 0 }')
	el=$(( (t - t0) / 1000000000 ))
	e_prev=$e; t_prev=$t
	SNAP+=("$(snap)"); TS+=("$el"); WT+=("$w"); MSR+=("$(msrs)")
	echo "  采样 #${#SNAP[@]}  第 ${el}s  上段瓦数 ${w}W"
	[ "$el" -ge "$DUR" ] && break
done
wait $LOAD 2>/dev/null || true
trap - EXIT

n=${#SNAP[@]}
echo
echo "== 时间轴（瓦数 = 上一个采样间隔内的平均封装功耗）"
for i in "${!SNAP[@]}"; do
	printf '  #%d %4ss %4sW\n' "$i" "${TS[$i]}" "${WT[$i]}"
done

if [ "$HAVE_MSR" = 1 ]; then
	echo
	echo "== MSR（同样的采样序号）"
	for i in "${!MSR[@]}"; do
		printf '  #%d%s\n' "$i" "${MSR[$i]}"
	done
fi

# 校验快照完整性
declare -a B
read -ra B <<< "${SNAP[0]}"
if [ "${#B[@]}" -ne 256 ]; then
	echo
	echo "⚠ 快照只有 ${#B[@]}/256 字节，字节对比跳过（EC 读太慢？把间隔调大）"
	exit 1
fi

echo
echo "== 变过的字节（列 = 上面的采样序号；只列变化过的）"
printf '  %-4s %-5s' 偏移 名字
for i in "${!SNAP[@]}"; do printf ' %4s' "#$i"; done
echo
changed=0
declare -a C
for ((off = 0; off < 256; off++)); do
	line=""; hit=0; first="${B[$off]}"
	for s in "${!SNAP[@]}"; do
		read -ra C <<< "${SNAP[$s]}"
		v=${C[$off]:-??}
		if [ "$v" != "??" ]; then
			printf -v cell '%6s' "$((16#$v))/$v"   # 十进制/十六进制
		else
			printf -v cell '%6s' "??"
		fi
		line+=" $cell"
		[ "$v" != "$first" ] && hit=1
	done
	if [ "$hit" = 1 ]; then
		printf '  0x%02x %-5s%s\n' "$off" "${NAMES[$off]:-}" "$line"
		changed=$((changed + 1))
	fi
done
echo "  （共 $changed 个字节变化）"
echo
echo "判读：跟着瓦数台阶同步跳变的字节就是 EC 的“预算”；"
echo "      0x3a/0x3b/0x3c（EL1R/EL2R/EL4R）是我们的老朋友，"
echo "      新出现的（0x61 SHPM / 0xbb CMAX / 0xbe TDP0,1 / 0xbf P1DP,P2DP / 0xc1 DPPC）才是候选。"