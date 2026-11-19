#!/bin/bash
# HP OMEN 16-am0xxx (board 8D3F) —— 走 HP WMI 让 EC 切到 OMEN 高性能功耗表（CPU PL 的真正开关）
#
# 为什么需要它：
#   board 8D3F 不在上游 hp-wmi.c 的 OMEN/Victus 白名单里，所以
#   /sys/firmware/acpi/platform_profile 写 "performance" 走的是 legacy 分支
#   （WMI 命令 0x4C，只改风扇/噪音档），并不会改 CPU 的 PL1/PL2。
#   OMEN Gaming Hub 在 Windows 上用的是 WMI 命令 0x1A + 字节：
#       OMEN v1: 0x30=默认 0x31=性能 0x50=cool   |  Victus-S: 0x01=性能
#   而 omen_wmi_boost 现在默认发的就是 0x01（开机日志: "thermal profile 0x01 set"）。
#
# 用法:
#   sudo ./scripts/unlock.sh              # 用 0x31 应用 OMEN 性能档，打印前后对比
#   sudo ./scripts/unlock.sh --scan       # 逐个试 0x31 0x30 0x01 0x00，看哪个真的动了 PL
#   sudo ./scripts/unlock.sh --byte 0x50  # 指定字节
#   sudo ./scripts/unlock.sh --ec-flags   # 额外写 EC 0x62/0x63：取消性能档超时 + TURBO
set -u
export LC_ALL=C
SB=/sys/kernel/omen_wmi_boost
PL=/mnt/sub/projects/cpu-powercap/scripts/pl.sh
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

pl_now() {
	printf 'PL1=%-7s PL2=%-7s window=%-9s (powercap, uW)\n' \
		"$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null)" \
		"$(cat /sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw 2>/dev/null)" \
		"$(cat /sys/class/powercap/intel-rapl:0/constraint_0_time_window_us 2>/dev/null)"
	rdmsr -p 0 0x610 2>/dev/null | sed 's/^/  MSR 0x610 = 0x/'
}

apply_byte() {
	local b=$1
	echo "--- SET_PERFORMANCE_MODE 字节 $b (模块参数 thermal_profile)"
	if [ ! -w $SB/thermal_profile ]; then
		echo "找不到 $SB —— 模块未加载: sudo modprobe omen_wmi_boost"; return 1
	fi
	echo "$b" > $SB/thermal_profile
	echo "现在 profile 参数 = $(cat $SB/thermal_profile)"
	echo "1" > $SB/performance 2>/dev/null
	# 注意：performance 会连带尝试 GPU boost；本机 ACPI 里 GPSV 路径不存在，
	# 所以这一步可能返回错误码，但 0x1A 的 profile 已经发出去了（看 journal）。
	journalctl -k --no-pager --since "-10 seconds" 2>/dev/null | grep -E 'thermal profile|SET_PERFORMANCE|CTGP' | tail -3
	sleep 1
	pl_now
}

case "${1:-}" in
--scan)
	before=$(pl_now)
	for b in 0x31 0x30 0x01 0x00; do echo; apply_byte "$b"; done
	echo; echo "扫描结束。对比上面 PL1/PL2 有变化的字节，即本机 EC 真正认的性能档。"
	;;
--byte) shift; apply_byte "${1:-0x31}" ;;
--ec-flags)
	echo "== 写 EC 偏移：0x62 flags=NOTIMER|TURBO(0x06), 0x63 timer=0"
	modprobe ec_sys 2>/dev/null || echo "  (ec_sys 加载失败)"
	D=/sys/kernel/debug/ec/ec0
	if [ -e $D/write ]; then
		printf '\x06' | dd of=$D/write bs=1 seek=$((0x62)) count=1 conv=notrunc status=none && echo "  0x62 <- 0x06 OK"
		printf '\x00' | dd of=$D/write bs=1 seek=$((0x63)) count=1 conv=notrunc status=none && echo "  0x63 <- 0x00 OK"
		printf '  读回 0x62=0x%s 0x63=0x%s 0x95=0x%s 0x59=0x%s\n' \
			"$(dd if=$D/read bs=1 skip=$((0x62)) count=1 2>/dev/null | xxd -p)" \
			"$(dd if=$D/read bs=1 skip=$((0x63)) count=1 2>/dev/null | xxd -p)" \
			"$(dd if=$D/read bs=1 skip=$((0x95)) count=1 2>/dev/null | xxd -p)" \
			"$(dd if=$D/read bs=1 skip=$((0x59)) count=1 2>/dev/null | xxd -p)"
	else
		echo "  没有 $D —— 需要 debugfs + ec_sys，且 EC 直写有风险（上游仅在部分 OMEN 机型使用）"
	fi
	;;
*)
	echo "== 应用前"; pl_now; echo
	apply_byte "${PROFILE:-0x31}"
	echo
	echo "== 结论判断"
	echo "  · 若 PL1 从 55000000 变成更大值（如 90000000/105000000）→ EC 性能档生效，收工。"
	echo "  · 若 PL1 仍是 55000000 → EC 不管 CPU PL，再手动覆盖："
	echo "      sudo $PL set 90 157 56 && sudo $PL watch 30"
	echo "    （watch 里若数值自己变回去 = SMM/EC 在覆盖，必须继续走 WMI 路线）"
	;;
esac
