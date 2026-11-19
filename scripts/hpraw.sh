#!/usr/bin/env bash
# hpraw.sh —— 通过 hp_raw 内核模块读写 HP BIOS WMI 原始命令（DSDT HWMC 的 COMD/CMDT）
# 用途：读 EC 眼里的适配器档位 / GPU 功耗模式 / 各种 HP 私有状态；
#       写命令默认禁止（会真打到 EC，有变砖风险）。
set -uo pipefail

RAW=/sys/kernel/hp_raw
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../modules/hp_raw

die() { echo "错误: $*" >&2; exit 1; }
root_or_die() { [ "$(id -u)" = 0 ] || die "这步需要 root：sudo bash scripts/$(basename "$0") $CMD"; }

need_raw() {
	[ -d "$RAW" ] && return 0
	echo "hp_raw 未加载。先跑：sudo bash $(basename "$0") load"
	return 1
}

q() { # q <comd> <cmdt> <outsize> [hexdata...]
	local comd=$1 cmdt=$2 out=$3; shift 3
	echo "$comd $cmdt $out $*" > "$RAW/query" || { cat "$RAW/last_error"; return 1; }
	cat "$RAW/result"
}

build() {
	[ -d "/lib/modules/$(uname -r)/build" ] || die "缺 kernel-devel：sudo dnf install kernel-devel-\$(uname -r)"
	make -C "$DIR" clean >/dev/null 2>&1 || true
	make -C "$DIR" modules
}

load() {
	[ -f "$DIR/hp_raw.ko" ] || build
	modprobe wmi 2>/dev/null || true
	insmod "$DIR/hp_raw.ko" ${1:+allow_write=$1}
	echo "已加载：$RAW"
	ls -l "$RAW"
}

unload() { rmmod hp_raw 2>/dev/null && echo "已卸载" || echo "本来就没加载"; }

design() {
	need_raw || return 1
	local line; line=$(cat "$RAW/design")
	echo "$line"
	# 解 DSDT GM28 里的适配器档位表（ADPH -> 瓦数）
	local aw=${line#adapter=}; aw=${aw%% *}
	case "$aw" in
	  40)  echo "  ADPH=1  → 40W  (USB-C PD 小功率)" ;;
	  65)  echo "  ADPH=2  → 65W" ;;
	  90)  echo "  ADPH=3  → 90W" ;;
	  120) echo "  ADPH=4  → 120W" ;;
	  140) echo "  ADPH=5  → 140W" ;;
	  150) echo "  ADPH=6  → 150W" ;;
	  180) echo "  ADPH=7  → 180W" ;;
	  200) echo "  ADPH=8  → 200W" ;;
	  230) echo "  ADPH=9  → 230W  ← 原装电源应该报这个" ;;
	  24)  echo "  ADPH=10 → 24W/PD 档（byte1=1）" ;;
	  74)  echo "  ADPH=11 → 74W/PD 档（byte1=1）" ;;
	  0)   echo "  ⚠ GM28 没返回适配器瓦数（ECOK=0 或 EC 不应答）" ;;
	  *)   echo "  ADPH 瓦数=$aw（不在表里）" ;;
	esac
}

# EC 里的 CPU 功率限制（真正可能管住 45W 的东西）
#   ECL1@0x37 ECL2@0x38 ECL4@0x39  ← 可写（GM29: data[0]=PL2, data[1]=PL1, data[2]=PL4, data[3]=OPAT×8；0xFF=不改）
#   EL1R@0x3A EL2R@0x3B EL4R@0x3C  ← 可读（GM2A: 回复 buf[3]=EL2R buf[4]=EL1R buf[6]=EL4R buf[7]=ATPP/8）
bpl() { # bpl <回复串> <下标>
	local -a b; read -ra b <<<"${1#*|}"
	echo "$((0x${b[$2]:-$3}))"
}

ecl_read() {
	need_raw || return 1
	local out p2 p1 p4 at
	out=$(q 0x20008 0x2a 16) || return 1
	echo "$out"
	p2=$(bpl "$out" 3 0); p1=$(bpl "$out" 4 0); p4=$(bpl "$out" 6 0); at=$(bpl "$out" 7 0)
	echo "  EC EL2R(PL2)=$p2  EL1R(PL1)=$p1  EL4R(PL4)=$p4  ATPP/8=$at"
	local m="?" raw=""
	if command -v rdmsr >/dev/null 2>&1; then
		raw=$(rdmsr -p 0 0x610 2>/dev/null) || raw=""
		[ -n "$raw" ] && m=$(( (0x$raw & 0x7fff) / 8 ))
	fi
	echo "  对照：MSR 0x610 PL1=${m}W（1/8W 单位）；powercap PL1=$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null) uW"
	echo "  → 如果 EL1R 是个和 PL1 不同、且 ≈45×N 的数，那 EC 就是那堵墙"
}

ecl_write() { # ecl_write <PL1> <PL2> <PL4>   传 keep 表示 0xFF 不改
	local p1=${1:-keep} p2=${2:-keep} p4=${3:-keep}
	local b1=ff b2=ff b4=ff
	[ "$p1" = keep ] || b1=$(printf '%02x' "$p1")
	[ "$p2" = keep ] || b2=$(printf '%02x' "$p2")
	[ "$p4" = keep ] || b4=$(printf '%02x' "$p4")
	echo "将写 EC：PL2=0x$b2 PL1=0x$b1 PL4=0x$b4（OPAT 保持 0xff=不改）"
	[ "${YES:-0}" = 1 ] || { read -r -p "确认？输入 yes 继续: " a; [ "$a" = yes ] || { echo "取消"; return 1; }; }
	q 0x20008 0x29 4 "$b2" "$b1" "$b4" ff || return 1
	echo "已下发，读回校验："
	ecl_read
}

# 只读命令表（已逐条审过 AML：GM 空间只有 0x21/0x23/0x26/0x28/0x2A 是真只读）
RD_CMDS=(0x04 0x05 0x06 0x07 0x08 0x09 0x0A 0x0D 0x12 0x13 0x16 0x17 0x19
	 0x1A 0x1B 0x1C 0x28 0x2A 0x2C 0x31 0x35 0x36 0x3A 0x3B 0x3E 0x44 0x4B 0x52)
GM_CMDS=(0x21 0x23 0x26 0x28 0x2A)
# 这些 GM 命令在 AML 里会写 EC/NPCF —— 绝不放进 sweep（踩过坑：0x1A 会把 OMEN
# 性能档清零并触发 DTPC，0x22 会把 GPU 的 CTGP/DBAC/DBDC 写成输入缓冲里的 0）
GM_DIRTY=(0x10 0x12 0x1A 0x22 0x27 0x29 0x2E)

sweep() {
	need_raw || return 1
	local mode=${1:-safe} c i
	echo "== COMD=1（BIOS Read）扫描 =="
	local -a list
	if [ "$mode" = all ]; then
		list=()
		for i in $(seq 1 96); do list+=("$(printf '0x%02x' "$i")"); done
		echo "⚠ 全量扫描：个别读命令可能有副作用，出错请记录 last_error"
	else
		list=("${RD_CMDS[@]}")
	fi
	for c in "${list[@]}"; do
		printf "  cmd=%-5s " "$c"
		if echo "1 $c 16" > "$RAW/query" 2>/dev/null; then
			cat "$RAW/result"
		else
			cat "$RAW/last_error"
		fi
	done
	echo "== COMD=0x20008（GM 系列）扫描（只跑 AML 审计过的只读命令）=="
	for c in "${GM_CMDS[@]}"; do
		printf "  gm=%-5s " "$c"
		if echo "0x20008 $c 16" > "$RAW/query" 2>/dev/null; then
			cat "$RAW/result"
		else
			cat "$RAW/last_error"
		fi
	done
}

# ---- EC RAM 直读（比对 NPL1/NPL2 是否真被写进去） ----
# EC0.ERAM: NPL1@0x29 NPL2@0x2A SRP1@0x34 SRP2@0x35 ECL1@0x37 ECL2@0x38 ECL4@0x39
#            EL1R@0x3A EL2R@0x3B EL4R@0x3C TNT3@0x48 ECLS@0x52(盖子) HPCM@0x95
#            ADPH@0xA3(4bit) DTMT@0xE9 PL12@0xEA ETMT@0xEB FFFS@0xEC
# ⚠ 本机没编 ec_sys，这个属性走的是 ACPI EC 驱动导出的 ec_read()（只读，安全）
ecram() { # ecram [偏移] [字节数]
	need_raw || return 1
	printf '%s %s\n' "${1:-0x29}" "${2:-16}" > "$RAW/ecram" || { cat "$RAW/last_error"; return 1; }
	cat "$RAW/ecram_result"
}

ecwr() { # ecwr <偏移> <值>（需 allow_write=1，危险）
	need_raw || return 1
	[ $# -ge 2 ] || die "用法: ecwr <偏移> <值>（需 allow_write=1）"
	printf '%s %s\n' "$1" "$2" > "$RAW/ecwrite" || { cat "$RAW/last_error"; return 1; }
	cat "$RAW/last_error"
	echo "回读:"
	ecram "$1" 4
}

# ---- NPCF._DSM：HP 自己的 CPU 功率预算入口 -------------------------------
# ssdt11.dsl:1455 Device (NPCF) @ \_SB.NPCF
#   1521 _DSM: UUID 36b49710-2483-11e7-9598-0800200c9a66，要求 rev=0x0200
#   1543 func#0  支持位图 07 03 00 00 → 0,1,2,8,9
#   1940 func#8  读 EC BVLB/BVHB → TGP 表（只读）
#   1968 func#9  ★ CreateDWordField(Arg3,3,CPTD)
#                EC0.NPL1 = CPTD/1000；EC0.NPL2 = NPL1*125/100；
#                然后 SSMP = 0x77（SystemIO 0xB2 → SMI）→ EC 立即生效
#   1858 func#5  INC5=3/4 时写 NPCF.CUSL/CUCT（有副作用）
dsm() { # dsm <func> [hex...]   （不给 hex 时模块补 32 字节零缓冲）
	need_raw || return 1
	[ $# -ge 1 ] || die "用法: dsm <func> [hex...]"
	local f=$1; shift
	echo "$f $*" > "$RAW/dsm" || { cat "$RAW/last_error"; return 1; }
	cat "$RAW/dsm_result"
}

dsmscan() { # 只扫只读 func（0,1,2,3,4,7,8,10；不含 5/9）
	need_raw || return 1
	local f
	for f in 0 1 2 3 4 7 8 10; do
		echo "-- func=$f"
		dsm "$f" | sed 's/^/   /'
	done
}

# ★ 主入口：把一个 PL1 瓦数写进 EC（NPL1/NPL2）并让 EC 立即应用
npl() { # npl <PL1瓦数>[.5]
	local w=${1:-}
	[ -n "$w" ] || die "用法: npl <PL1瓦数>（例: npl 100；也接受 99.5）"
	local cw=${w/\./}
	case "$cw" in ''|*[!0-9]*) die "瓦数必须是数字: $w" ;; esac
	local mw
	if [ "$w" != "$cw" ]; then mw=$(( cw * 100 )); else mw=$(( cw * 1000 )); fi
	[ "$mw" -ge 5000 ] && [ "$mw" -le 250000 ] || die "PL1 应在 5..250W 之间（EC 字段 8 位，单位 W）"
	local hex
	hex=$(printf '00 00 00 %02x %02x %02x %02x' \
		$(( mw & 0xff )) $(( mw >> 8 & 0xff )) $(( mw >> 16 & 0xff )) $(( mw >> 24 & 0xff )))
	local i; for i in $(seq 1 25); do hex="$hex 00"; done
	echo "CPTD=${mw}mW → AML 将写 EC0.NPL1=$(( mw / 1000 ))W  NPL2=$(( mw / 1000 * 125 / 100 ))W，再 SSMP=0x77(SMI)"
	[ $(( mw / 1000 * 125 / 100 )) -le 255 ] || \
		echo "⚠ NPL2=$(( mw / 1000 * 125 / 100 )) 超过 EC 的 8 位字段（255W）→ 会被截断，建议 PL1 ≤ 204W"
	if [ "$(cat /sys/module/hp_raw/parameters/allow_write 2>/dev/null)" != Y ]; then
		echo "需要先解锁：echo 1 | sudo tee /sys/module/hp_raw/parameters/allow_write"
		return 1
	fi
	if [ "${YES:-0}" != 1 ]; then
		read -r -p "这会写 EC 并触发 SMI，确认？输入 yes 继续: " a
		[ "$a" = yes ] || { echo "取消"; return 1; }
	fi
	echo "== 下发前 EC =="; ecl_read
	dsm 9 $hex
	sleep 1
	echo "== 下发后 EC =="; ecl_read; ecram 0x29 4
}

gmw() { # gmw <cmdt> <hexdata...>  COMD=0x20008 带数据（这才是真正的 GM 写）
	need_raw || return 1
	[ $# -ge 2 ] || die "用法: gmw <cmdt> <hexdata...>（需 allow_write=1）"
	q 0x20008 "$1" 16 "${@:2}"
}

# 轮询监控 EC 里的功率相关字节（不写任何东西）
emon() { # emon [次数] [间隔秒]
	need_raw || return 1
	local n=${1:-10} iv=${2:-2} i v line msr p1
	v() { awk -v k="$1" '$1==k {print $4}' <<<"$line"; }
	printf '%-8s %4s %4s %4s %4s %4s %4s %4s %4s %6s %s\n' \
		时间 EL1R EL2R EL4R NPL1 NPL2 ECL1 HPCM TNT3 PL12 "MSR0x610-PL1"
	for ((i = 0; i < n; i++)); do
		echo "0x29 0" > "$RAW/ecram"
		line=$(cat "$RAW/ecram_result")
		p1="-"
		if command -v rdmsr >/dev/null 2>&1; then
			msr=$(rdmsr -p 0 0x610 2>/dev/null) && p1="$(( (0x$msr & 0x7fff) / 8 ))W"
		fi
		printf '%-8s %4s %4s %4s %4s %4s %4s %4s %4s %6s %s\n' \
			"$(date +%H:%M:%S)" "$(v 0x3a)" "$(v 0x3b)" "$(v 0x3c)" \
			"$(v 0x29)" "$(v 0x2a)" "$(v 0x37)" "$(v 0x95)" \
			"$(v 0x48)" "$(v 0xea)" "$p1"
		[ $((i + 1)) -lt "$n" ] && sleep "$iv"
	done
}

# ★ 长期按住性能档：EC 里有个 ~95 秒的倒计时（EC 私有字节 0x63），到点就把 HPCM 清 0，
# 同时把 EL*R 重算回 45/56/90（= 那堵 45W 墙）。所以想长期吃高功耗就得定期重申 profile。
#   hold [profile=1] [总秒数=0 表示一直跑] [检查间隔=15] [EL1R瓦数（可选）]
# 传了第 4 个参数时，每次重申后会再直写 EC 0x3a（EL1R），因为 EC 重算会把 EL1R 打回表里的 90。
hold() {
	need_raw || return 1
	local prof=${1:-1} dur=${2:-0} iv=${3:-15} e1=${4:-} cur n=0 end
	case "$prof" in ''|*[!0-9]*) die "profile 必须是数字（0..15，实测 1/4 = 性能档）" ;; esac
	[ "$prof" -le 15 ] || die "profile 取 0..15（DTPC 用 HPCM & 0x0F）"
	[ "$iv" -ge 3 ] || die "检查间隔至少 3s（太小会刷屏，EC 倒计时约 95s）"
	if [ -n "$e1" ]; then
		case "$e1" in *[!0-9]*) die "EL1R 必须是整数瓦数: $e1" ;; esac
		{ [ "$e1" -ge 20 ] && [ "$e1" -le 250 ]; } || die "EL1R 取 20..250W"
	fi
	if [ "$(cat /sys/module/hp_raw/parameters/allow_write 2>/dev/null)" != Y ]; then
		echo "需要先解锁：echo 1 | sudo tee /sys/module/hp_raw/parameters/allow_write"
		return 1
	fi
	end=$(( SECONDS + dur ))
	echo "hold: profile=$prof${e1:+，EL1R=${e1}W}，每 ${iv}s 看一次 HPCM，漂了就重申（$([ "$dur" -gt 0 ] && echo "${dur}s" || echo '一直跑，Ctrl-C 停')）"
	while :; do
		echo "0x29 0" > "$RAW/ecram"
		cur=$(awk '$1=="0x95" {print $4}' "$RAW/ecram_result")
		if [ "$n" -eq 0 ] || [ "${cur:-x}" != "$prof" ]; then
			n=$(( n + 1 ))
			if [ "$n" -eq 1 ] && [ "${cur:-x}" = "$prof" ]; then
				printf '%s  HPCM=%s → 首轮应用 profile=%s' \
					"$(date +%H:%M:%S)" "$cur" "$prof"
			else
				printf '%s  HPCM=%s → 重申 profile=%s（第 %d 次）' \
					"$(date +%H:%M:%S)" "${cur:-?}" "$prof" "$n"
			fi
			q 0x20008 0x1a 16 00 "$(printf '%02x' "$prof")" >/dev/null
			if [ -n "$e1" ]; then
				sleep 1
				printf '0x3a %s\n' "$(printf '0x%02x' "$e1")" > "$RAW/ecwrite"
				printf '，EL1R→%sW（%s）' "$e1" "$(cat "$RAW/last_error")"
			fi
			echo
		else
			printf '%s  HPCM=%s 正常\n' "$(date +%H:%M:%S)" "$cur"
		fi
		if [ "$dur" -gt 0 ] && [ "$SECONDS" -ge "$end" ]; then
			echo "hold: 到时间退出（共重申 $n 次）"
			break
		fi
		sleep "$iv"
	done
}

# 通用物理内存 dump（只读）+ 解码 ssdt9 的 \_SB.PNVS
PNVS_BASE=${PNVS_BASE:-0x6C481000}

phys() { # phys <物理地址> [偏移] [字节数]
	need_raw || return 1
	[ $# -ge 1 ] || die "用法: phys <物理地址> [偏移] [字节数]"
	printf '%s %s %s\n' "$1" "${2:-0}" "${3:-64}" > "$RAW/phys" || {
		cat "$RAW/last_error" 2>/dev/null; return 1; }
	cat "$RAW/phys_result"
}

PB=()
pb8() { echo $(( 0x${PB[$1]:-0} )); }
pb16() { echo $(( 0x${PB[$(($1 + 1))]:-0}${PB[$1]:-0} )); }

# ssdt9: OperationRegion (PNVS, SystemMemory, 0x6C481000, 0xAA)
#   Field 布局（ssdt9.dsl:191）：
#     0x00 PGRV  0x01 CFGD(32)  0x06 ACRT  0x07 APSV  0x08 AAC0
#     0x09 CPID(32)  0x0D CPPC  0x0E CLVL  0x0F CBMI
#     0x10 PL10 / 0x12 PL11 / 0x14 PL12 = PL1（按电源/模式三档）
#     0x16 PL20 / 0x18 PL21 / 0x1A PL22 = PL2
#     0x1C PLW0/1/2（秒）0x1F CTC0/1/2  0x22 TAR0/1/2  0x25 PPC0/1/2
#     0x29 C6MW 0x2A C7MW 0x2B CDMW  0x2E C6LT 0x30 C7LT 0x32 CDLT
#     0x34 CDLV 0x36 CDPW（PL4）…
# AML 里只声明、从不引用 → 这是 BIOS/SMM 用的「Intel 功耗表」，不是 DPTF 驱动在用。
#
# ★ 单位是 1/8 W（RAPL 的 PL 编码），不是 mW —— 实机对上了：
#     PL10=440 → 55W   == 出厂 MSR 0x610 的 PL1=55W
#     PL20=1256 → 157W == 出厂 MSR 0x610 的 PL2=157W
#     PLW0=56s         == powercap 的 window1=55.97s
#     CDPW=200         == 性能档 EC.E L4R=200
pnvs() {
	need_raw || return 1
	local base=${1:-$PNVS_BASE} d
	d=$(phys "$base" 0 0xAA) || return 1
	echo "$d"
	PB=( $(sed 1d <<<"$d") )	# 去掉表头行，其余就是十六进制字节
	if [ ${#PB[@]} -lt 42 ]; then
		echo "  ⚠ 只解析到 ${#PB[@]} 字节，可能 PNVS 基址变了"
		return 1
	fi
	local -a n=(PL10 PL11 PL12 PL20 PL21 PL22)
	local -a o=(0x10 0x12 0x14 0x16 0x18 0x1a)
	local i v
	printf '  PGRV=%s CFGD=0x%02x%02x%02x%02x ACRT=%s APSV=%s AAC0=%s\n' \
		"$(pb8 0)" "$(pb8 4)" "$(pb8 3)" "$(pb8 2)" "$(pb8 1)" \
		"$(pb8 6)" "$(pb8 7)" "$(pb8 8)"
	printf '  CPID=0x%02x%02x%02x%02x（0x0B0671=14 代 HX ✔）\n' \
		"$(pb8 0x0c)" "$(pb8 0x0b)" "$(pb8 0x0a)" "$(pb8 0x09)"
	for i in 0 1 2 3 4 5; do
		v=$(pb16 "${o[$i]}")
		printf '  %-4s = %5d  (raw 0x%04x)  → %s W\n' \
			"${n[$i]}" "$v" "$v" "$(awk -v v="$v" 'BEGIN{printf "%.2f", v/8}')"
	done
	echo "  0x1C: PLW0=$(pb8 0x1c)s PLW1=$(pb8 0x1d)s PLW2=$(pb8 0x1e)s   （= PL1 的时间窗）"
	echo "  0x1F: CTC0=$(pb8 0x1f) CTC1=$(pb8 0x20) CTC2=$(pb8 0x21)"
	echo "  0x22: TAR0=$(pb8 0x22) TAR1=$(pb8 0x23) TAR2=$(pb8 0x24)"
	echo "  0x25: PPC0=$(pb8 0x25) PPC1=$(pb8 0x26) PPC2=$(pb8 0x27)"
	printf '  0x29: C6MW=%s C7MW=%s CDMW=%s  / 0x2E: C6LT=%s C7LT=%s CDLT=%s  / 0x34: CDLV=%s CDPW=%s\n' \
		"$(pb8 0x29)" "$(pb8 0x2a)" "$(pb8 0x2b)" \
		"$(pb16 0x2e)" "$(pb16 0x30)" "$(pb16 0x32)" \
		"$(pb16 0x34)" "$(pb16 0x36)"
	echo "        （CDPW 按 W 看 = $(pb16 0x36) W，正好等于性能档 EC.EL4R=200，即 PL4）"
	echo "  → 单位 1/8 W：PL10=55W（=出厂 PL1）、PL20=157W（=出厂 PL2）；"
	echo "     45W 的"那堵墙"正好等于 PL11 —— 三个 PL1 档位 55/45/65W。"
}

CMD=${1:-}
# 除 build/help 之外都要 root（写 sysfs 是 0200）
case "$CMD" in
  ""|-h|--help|help|build) ;;
  *) root_or_die ;;
esac
case "$CMD" in
  build)  build ;;
  load)   shift; load "${1:-}" ;;
  unload) unload ;;
  gm)     shift; [ $# -ge 1 ] || die "用法: gm <cmd> [outsize]"; q 0x20008 "$1" "${2:-16}" ;;
  rd)     shift; [ $# -ge 1 ] || die "用法: rd <cmd> [outsize]"; q 1 "$1" "${2:-16}" ;;
  design) design ;;
  ecl)    ecl_read ;;
  setecl) shift; ecl_write "$@" ;;
  dsm)    shift; dsm "$@" ;;
  dsmscan) dsmscan ;;
  npl)    shift; npl "$@" ;;
  ecram)  shift; ecram "$@" ;;
  phys)   shift; phys "$@" ;;
  pnvs)   shift; pnvs "$@" ;;
  gmw)    shift; gmw "$@" ;;
  emon)   shift; emon "$@" ;;
  hold)   shift; hold "$@" ;;
  ecwr)   shift; ecwr "$@" ;;
  gnvs)   need_raw || return 1; cat "$RAW/gnvs" ;;
  peek)   need_raw || return 1; shift; [ $# -ge 1 ] || die "用法: peek <GNVS偏移> [字节数]"
          echo "$1 ${2:-16}" > "$RAW/peek" && cat "$RAW/peek_result" ;;
  sweep)  sweep "${2:-safe}" ;;
  wr)     shift; [ $# -ge 2 ] || die "用法: wr <cmd> <hexdata...>（需 allow_write=1）"
          q 2 "$1" 16 "${@:2}" ;;
  status) need_raw || return 1; cat "$RAW/last_error" ;;
  ""|-h|--help|help)
	cat <<EOF
用法: sudo bash $(basename "$0") <命令>
  build                 编译 hp_raw.ko（需要 kernel-devel）
  load [1]              加载模块；传 1 = 解锁非只读命令（模块内有 AML 审计白名单）
  unload                卸载模块
  design                ★ 读 EC 眼里的适配器瓦数/PL4V（GM28），带档位解码
  ecl                   ★ 读 EC 存的 CPU 功率限制 EL1R/EL2R/EL4R（GM2A，只读）
  setecl <P1> <P2> <P4> 写 EC 的 ECL1/ECL2/ECL4（GM29；传 keep 跳过；需 allow_write=1）
  dsm <func> [hex..]    ★ 调 \\_SB.NPCF._DSM（HP 的 CPU 功率预算入口；func 0..10）
  dsmscan               只扫只读 func（0,1,2,3,4,7,8,10），输出全部 hexdump
  npl <瓦数>            ★ _DSM func#9：EC0.NPL1/<PL1>W + NPL2=<PL1×1.25>W + SMI 0x77
  phys <addr> [off] [n] ★ 直读任意物理内存（只读，默认 64 字节）
  pnvs [addr]           ★ 解码 \_SB.PNVS（0x6C481000）的 Intel 功耗表 PL10…CDPW（单位 1/8W）
  esnap                 （见 scripts/ecwatch.sh）负载中逐字节对比整片 EC RAM
  ecram [off] [n]       ★ 直读 EC RAM（已知功耗字段表 + 指定范围；只读）
  emon [n] [秒]         ★ 轮询上表（默认 10 次 ×2s）：看 EL1R/HPCM 自己会不会变
  hold [档=1] [秒=0] [间隔=15] [EL1R瓦数]
                        ★ 长期按住性能档：EC 的 0x63 倒计时（~95s）会把 HPCM 打回 0，
                        这里每 <间隔>s 查一次，漂了就用 GM1A 重申；给了第 4 参就顺带
                        直写 EC 0x3a(EL1R)（EC 重算会把它打回 90，所以要每次补）需 allow_write=1
  gmw <cmdt> <hex..>    COMD=0x20008 带数据（真正的 GM 写，需 allow_write=1）
  ecwr <off> <val>      直写 EC RAM 单字节（需 allow_write=1，危险）
  gnvs                  ★ 读固件影子变量：PLCS/PLVL（AML 从不赋值 → SMM 写的 CPU PL 目标）
  peek <off> [n]        读 GNVS 任意偏移（默认 16 字节）
  gm <cmd> [size]       COMD=0x20008 原始查询（GM 系列：0x1A/0x21/0x22/0x28…）
  rd <cmd> [size]       COMD=1 原始查询（GDST/GBIF/GPSS/GABD…）
  sweep [all]           扫描只读命令（all = 连没列出的也试）
  wr <cmd> <bytes...>   COMD=2 写（需 load 1）
  status                看上次调用的返回码
例：
  sudo bash scripts/hpraw.sh build
  sudo bash scripts/hpraw.sh load
  sudo bash scripts/hpraw.sh design
  sudo bash scripts/hpraw.sh ecl            # ★ 看 EC 存的 CPU 限制到底是多少
  sudo bash scripts/hpraw.sh gnvs
  sudo bash scripts/hpraw.sh dsm 0          # 支持位图
  sudo bash scripts/hpraw.sh npl 100        # ★ _DSM func#9 → EC NPL1/NPL2 + SMI
  sudo bash scripts/hpraw.sh hold 1 300 10     # ★ 5 分钟内按住性能档（EL1R=90，10s 一查）
  sudo bash scripts/hpraw.sh hold 1 300 10 110 # ★ 同上，但每次重申后把 EL1R 补到 110W
  sudo bash scripts/hpraw.sh ecram 0x29 4   # 直读 EC：NPL1/NPL2
  sudo bash scripts/hpraw.sh peek 0x2F4 8
  sudo bash scripts/hpraw.sh sweep
EOF
	;;
  *) die "未知命令：$1" ;;
esac
