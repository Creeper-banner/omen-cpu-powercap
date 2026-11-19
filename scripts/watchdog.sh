#!/bin/bash
# 看门狗：AC 供电时保持目标 PL，被 EC/SMM 改回去就立刻重放；拔电回落到安全值
# 用法: omen-pl-watchdog <AC下PL1> <AC下PL2> [电池PL1] [电池PL2]
# ⚠ 重放一律带 --clamp：内核 powercap 写路径会清掉 bit16(强制执行位)，
#    只写瓦数不写 clamp 的话，限制值是"摆设"（本机实测 55W vs 90W 性能完全一致）。
set -u
PL=${PL:-/usr/local/bin/omen-pl.sh}
AC1=${1:-90}; AC2=${2:-157}; B1=${3:-55}; B2=${4:-85}
on_ac() { [ "$(cat /sys/class/power_supply/ADP1/online 2>/dev/null)" = 1 ]; }
raw()   { local v; v=$(rdmsr -p 0 0x610 2>/dev/null) || return 1; [[ "$v" =~ ^[0-9a-fA-F]+$ ]] || return 1; echo "$v"; }
cur()   { local r=${1:-0}; awk -v f=$(( r & 0x7fff )) -v u="${PU:-3}" 'BEGIN{printf "%.0f", f/(2^u)}'; }

PU=$(rdmsr -f 3:0 0x606 2>/dev/null || echo 3); [[ "$PU" =~ ^[0-9a-f]+$ ]] && PU=$((0x$PU)) || PU=3

while :; do
	if on_ac; then want1=$AC1; want2=$AC2; else want1=$B1; want2=$B2; fi
	r=$(raw) || { sleep 30; continue; }			# MSR 暂时不可读（休眠中），下一轮再看
	r=$((0x$r)); have=$(cur "$r"); clamp=$(( (r >> 16) & 1 ))
	if [ "$have" != "$want1" ] || [ "$clamp" != 1 ]; then
		echo "$(date -Is) PL1 ${have}W clamp=${clamp} -> ${want1}W --clamp，重放"
		"$PL" set "$want1" "$want2" --clamp >/dev/null 2>&1 || echo "$(date -Is) 写入失败"
	fi
	sleep 15
done
