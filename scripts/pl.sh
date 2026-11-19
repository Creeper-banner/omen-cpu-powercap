#!/bin/bash
# 读 / 写 CPU 封装功耗墙 (PL1 / PL2 / PL4 / TAU / clamp&enable 位)
#
# ⚠ 本机实测的坑：内核 powercap 写入路径会丢位！
#   开机原值 0x004284e800df81b8（PL1 enable=1 **clamp(bit16)=1**, PL2 enable(bit47)=1）
#   写 powercap 后变成 0x000204e800de82d0（bit16=0, bit47=0）→ 限制值不再被强制执行，
#   改 55W / 90W 性能一模一样。所以 set 之后必须 --clamp 用 MSR 把位补回来。
#
#   sudo bash pl.sh get                 # 含 enable/clamp 位解码
#   sudo bash pl.sh set 90 157 --clamp  # 设值 + 强制 bit15/bit16/bit47（推荐）
#   sudo bash pl.sh clamp on|off|show   # 只动强制执行位
#   sudo bash pl.sh bios                # 恢复开机原值（救急/对照实验）
#   sudo bash pl.sh raw [0xHEX]         # 直接读写整个 0x610（自己承担风险）
#   sudo bash pl.sh fix|watch|restore|nowallimit
set -eu
export LC_ALL=C
PKG=${PLMSR:-0x610}
Z=${PCZ:-/sys/class/powercap/intel-rapl:0}
STAMP=${PLSTAMP:-/var/lib/omen-cpu-pl}
DEF_RAW=0x004284e800df81b8			# 本会话开机时抓到的 BIOS 原值
DEF_P1=55; DEF_P2=157; DEF_P4=200; DEF_TAU_US=55967744; DEF_TAU2_US=2440

die() { printf '\033[31m错误:\033[0m %s\n' "$*" >&2; exit 1; }
[ "${PL_MOCK:-0}" = 1 ] || [ "$(id -u)" = 0 ] || die "需要 root: sudo bash $0 $*"

HAVE_MSR=0
command -v rdmsr >/dev/null 2>&1 && command -v wrmsr >/dev/null 2>&1 && HAVE_MSR=1
read64() { local v; v=$(rdmsr -p 0 "$1" 2>/dev/null) || return 1; [[ "$v" =~ ^[0-9a-fA-F]+$ ]] || return 1; echo "$v"; }
PU=3; if [ $HAVE_MSR = 1 ]; then t=$(rdmsr -f 3:0 0x606 2>/dev/null || true); [[ "${t:-}" =~ ^[0-9a-f]+$ ]] && PU=$((0x$t)); fi
f2w() { awk -v f="$1" -v u="$PU" 'BEGIN{printf "%.1f", f/(2^u)}'; }
w2f() { awk -v w="$1" -v u="$PU" 'BEGIN{printf "%d", w*(2^u)+0.5}'; }

show() {
	if [ $HAVE_MSR = 1 ] && raw=$(read64 $PKG); then
		raw=$((0x$raw))
		printf 'MSR 0x610 = 0x%016x\n' "$raw"
		printf '  PL1 %6sW en=%d **clamp=%d** | PL2 %6sW en=%d clamp=%d | PL1win=0x%02x PL2win=0x%02x | LOCK=%d\n' \
			"$(f2w $(( raw & 0x7fff )))" "$(( (raw >> 15) & 1 ))" "$(( (raw >> 16) & 1 ))" \
			"$(f2w $(( (raw >> 32) & 0x7fff )))" "$(( (raw >> 47) & 1 ))" "$(( (raw >> 48) & 1 ))" \
			"$(( (raw >> 16) & 0xff ))" "$(( (raw >> 49) & 0x3f ))" "$(( (raw >> 63) & 1 ))"
		[ $(( (raw >> 16) & 1 )) = 1 ] || printf '  \033[33m  ⚠ PL1 clamp=0：PL1 数值不会被强制执行！用 pl.sh clamp on\033[0m\n'
	fi
	[ -d "$Z" ] || return 0
	printf 'powercap: PL1=%-9s PL2=%-9s PL4=%-9s win1=%-9s win2=%-9s enabled=%s\n' \
		"$(cat $Z/constraint_0_power_limit_uw 2>/dev/null)" "$(cat $Z/constraint_1_power_limit_uw 2>/dev/null)" \
		"$(cat $Z/constraint_2_power_limit_uw 2>/dev/null)" "$(cat $Z/constraint_0_time_window_us 2>/dev/null)" \
		"$(cat $Z/constraint_1_time_window_us 2>/dev/null)" "$(cat $Z/enabled 2>/dev/null)"
}

pc_write() {	# $1=约束序号 $2=值 $3=us 表示写时间窗
	local idx=$1 val=$2 kind=${3:-} f
	case "$kind" in us) f=$Z/constraint_${idx}_time_window_us ;; *) f=$Z/constraint_${idx}_power_limit_uw ;; esac
	[ -w "$f" ] || { echo "    powercap: $(basename "$f") 不可写"; return 1; }
	echo "$val" > "$f" 2>/dev/null && { echo "    powercap: $(basename "$f") <- $val"; return 0; }
	echo "    powercap: $(basename "$f") <- $val  被拒绝"; return 1
}

# 读改写：只动 PL1/PL2 数值位与 enable/clamp 位，其余位（TAU、PL2 window、LOCK）原样保留
# $1=PL1_W $2=PL2_W(可空) $3=clamp(1=强制 bit15|bit16|bit47)
msr_write() {
	[ $HAVE_MSR = 1 ] || { echo "    无 msr-tools，跳过 MSR"; return 1; }
	local raw new v
	raw=$(read64 $PKG) || { echo "    读 MSR 失败（/dev/cpu/0/msr 未加载？）"; return 1; }
	raw=$((0x$raw))
	[ $(( (raw >> 63) & 1 )) = 0 ] || { echo "    MSR LOCK=1，wrmsr 无效"; return 1; }
	new=$(( raw & ~0x7fff ))
	new=$(( new | $(w2f "$1") ))
	new=$(( new | (1 << 15) ))					# PL1 enable
	if [ "${3:-0}" = 1 ]; then
		new=$(( new | (1 << 16) ))				# PL1 clamp ← 强制执行的关键位
		echo "    clamp: 置起 bit16 (PL1 强制执行)"
	fi
	if [ -n "${2:-}" ]; then
		v=$(w2f "$2")
		new=$(( (new & ~(0x7fff << 32)) | (v << 32) | (1 << 47) ))	# PL2 value + enable
		[ "${3:-0}" = 1 ] && new=$(( new | (1 << 48) ))
	fi
	# ⚠ 必须带 0x：wrmsr 用 strtoull(base 0)，前导 0 会被当八进制（上次 004284e8… → 34 → 4.25W）
	printf '    wrmsr 0x610 = 0x%016x\n' "$new"
	wrmsr -p 0 $PKG "$(printf '0x%016x' "$new")"
}

verify() {	# $1=期望 PL1_W；$2=1 时还要求 bit16(clamp) 已置起
	local g; g=$(read64 $PKG) || return 1
	[ $(( 0x$g & 0x7fff )) = "$(w2f "$1")" ] || return 1
	if [ "${2:-0}" = 1 ]; then [ $(( (0x$g >> 16) & 1 )) = 1 ] || return 1; fi
	return 0
}

CMD=${1:-get}; shift || true
CLAMP=0; POS=()
for a in "$@"; do case "$a" in --clamp) CLAMP=1 ;; *) POS+=("$a") ;; esac; done
# 把位置参数重建为“去掉 flag 之后”的形式，否则 set 90 157 --clamp 会把 --clamp 当成 TAU
if [ ${#POS[@]} -gt 0 ]; then set -- "${POS[@]}"; else set --; fi

case "$CMD" in
get) show ;;

raw)
	[ $HAVE_MSR = 1 ] || die "需要 msr-tools"
	if [ -z "${1:-}" ]; then echo "0x$(read64 $PKG)"
	else
		[[ "$1" =~ ^0?[xX]?[0-9a-fA-F]{1,16}$ ]] || die "不合法的 64bit 值: $1"
		printf '旧: 0x%s\n' "$(read64 $PKG)"
		wrmsr -p 0 $PKG "$(printf '0x%016x' $((0x${1#0x})))"
		sleep 0.3; printf '新: '; show
	fi ;;

bios)
	[ $HAVE_MSR = 1 ] || die "需要 msr-tools"
	echo "恢复开机原值 $DEF_RAW（PL1 55W 且 clamp/enable 位齐全）"
	wrmsr -p 0 $PKG "$(printf '0x%016x' $((DEF_RAW)))"
	sleep 0.3; show ;;

clamp)
	[ $HAVE_MSR = 1 ] || die "需要 msr-tools"
	case "${1:-show}" in
	show) show; exit 0 ;;
	on)  mode=1 ;; off) mode=0 ;; *) die "clamp on|off|show" ;;
	esac
	raw=$((0x$(read64 $PKG)))
	if [ $mode = 1 ]; then new=$(( raw | (1 << 16) | (1 << 15) ))
	else new=$(( raw & ~((1 << 16) | (1 << 15)) )); fi
	printf 'clamp %s: 0x%016x -> 0x%016x\n' "${1:-}" "$raw" "$new"
	wrmsr -p 0 $PKG "$(printf '0x%016x' "$new")"
	sleep 0.3; show ;;

fix)	echo "恢复出厂值（powercap 路径）: PL1=${DEF_P1} PL2=${DEF_P2} PL4=${DEF_P4} win=${DEF_TAU_US}/${DEF_TAU2_US}us"
	pc_write 0 $(( DEF_P1 * 1000000 )) || true
	pc_write 1 $(( DEF_P2 * 1000000 )) || true
	pc_write 2 $(( DEF_P4 * 1000000 )) || true
	pc_write 0 "$DEF_TAU_US" us || true
	pc_write 1 "$DEF_TAU2_US" us || true
	sleep 0.3
	if [ $HAVE_MSR = 1 ]; then		# powercap 写路径会丢 enable/clamp 位 → 最后用开机原值整体覆盖回去
		echo "  用开机原值覆盖 MSR（恢复 enable/clamp/TAU 全套位）"
		wrmsr -p 0 $PKG "$(printf '0x%016x' $((DEF_RAW)))"
	fi
	sleep 0.3; echo; show ;;

set)
	P1=${1:-}; P2=${2:-}; TAU=${3:-}
	[ -n "$P1" ] || die "用法: $0 set <PL1_W> [PL2_W] [TAU_秒] [--clamp]"
	m="== 写入 PL1=${P1}W"
	[ -n "$P2" ] && m="$m PL2=${P2}W"
	[ -n "$TAU" ] && m="$m TAU=${TAU}s"
	[ "$CLAMP" = 1 ] && m="$m clamp=on"
	echo "$m"
	pc_write 0 $(( ${P1%.*} * 1000000 )) || true
	[ -n "$P2" ] && { pc_write 1 $(( ${P2%.*} * 1000000 )) || true; }
	[ -n "$TAU" ] && { pc_write 0 $(( ${TAU%.*} * 1000000 )) us || true; }
	sleep 0.3
	if [ $HAVE_MSR = 1 ] && ! verify "$P1" "$CLAMP"; then
		echo "  powercap 未把值/位落到 MSR，改用 MSR 读改写"
		msr_write "$P1" "$P2" "$CLAMP"
		sleep 0.3
		verify "$P1" "$CLAMP" || { printf '\033[41m回读仍不符，已停止（不记录）\033[0m\n'; show; exit 1; }
	fi
	show
	if [ -z "${PL_NO_SAVE:-}" ]; then
		s=$(printf '%s %s %s' "$P1" "${P2:-}" "${TAU:-}")
		[ $CLAMP = 1 ] && s="$s --clamp"
		echo "$s" > "$STAMP" 2>/dev/null && echo "已记录: $s"
	fi
	;;

restore)
	[ -s "$STAMP" ] || die "$STAMP 里没有记录，先跑一次 set"
	exec bash "$0" set $(cat "$STAMP") ;;

watch)
	S=${1:-30}; prev=""; [ $HAVE_MSR = 1 ] || die "watch 需要 msr-tools"
	echo "每 2s 采样，共 ${S}s（raw 变了 = 有人改写；重点看 PL1 与 clamp 位）"
	for ((i=0;i<S/2;i++)); do
		cur=$(read64 $PKG) || die "读 MSR 失败"
		printf '%s  0x%-16s PL1=%sW clamp=%d PL2=%sW\n' "$(date +%T)" "$cur" \
			"$(f2w $(( 0x$cur & 0x7fff )))" "$(( (0x$cur >> 16) & 1 ))" "$(f2w $(( (0x$cur >> 32) & 0x7fff )))"
		[ -n "$prev" ] && [ "$prev" != "$cur" ] && printf '\033[33m   ^^^ 变了\033[0m\n'
		prev=$cur; sleep 2
	done ;;

nowallimit)
	case "${1:-off}" in
	on)  echo 0 > $Z/enabled; echo "已关闭整个 zone 的 RAPL 约束，务必盯温度！";;
	off) echo 1 > $Z/enabled; echo "已恢复 RAPL 约束。";;
	esac
	show ;;

*) die "未知子命令: $CMD (get|set|raw|bios|clamp|fix|watch|restore|nowallimit)" ;;
esac
