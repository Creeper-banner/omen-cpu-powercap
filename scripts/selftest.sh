#!/bin/bash
# 不碰真机的回归自测：假 MSR + 假 powercap 跑遍 pl.sh 的所有写路径
#   bash scripts/selftest.sh
set -u
SRC=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export MOCK_STATE=$D/msr; mkdir -p $MOCK_STATE $D/bin $D/zone
export PATH=$D/bin:$PATH PCZ=$D/zone PLMSR=0x610 PLSTAMP=$D/stamp PL_MOCK=1

: > "$MOCK_STATE/log"
# --- 假 rdmsr/wrmsr：忠实复刻 msr-tools 的 strtoull(base 0) 八进制坑 ---
for t in rdmsr wrmsr; do
	printf '#!/bin/bash\nexec python3 "%s/mock/msrtool.py" "%s" "$@"\n' "$SRC" "$t" > "$D/bin/$t"
	chmod +x "$D/bin/$t"
done

# --- 初始状态 = 本机开机实测值 ---
echo 004284e800df81b8 > "$MOCK_STATE/610"	# PL1 55W(en) / TAU 0xdf / PL2 157W(en) / LOCK 0
echo a0e03            > "$MOCK_STATE/606"	# power unit = 2^-3 W
echo 1b8              > "$MOCK_STATE/614"
echo 0                > "$MOCK_STATE/613"
echo 200000000        > "$MOCK_STATE/689"

# --- 假 powercap zone ---
cd "$D/zone"
echo 1 > enabled; echo package-0 > name
echo 55000000  > constraint_0_power_limit_uw;  echo 55000000 > constraint_0_max_power_uw
echo 55967744  > constraint_0_time_window_us
echo 157000000 > constraint_1_power_limit_uw;  echo 2440     > constraint_1_time_window_us
echo 200000000 > constraint_2_power_limit_uw
cd - > /dev/null

FAILED=0
chk() { if [ "$2" = "$3" ]; then printf '  \033[32mPASS\033[0m %s = %s\n' "$1" "$3"
	else printf '  \033[41mFAIL\033[0m %s 期望 %s 实际 %s\n' "$1" "$2" "$3"; FAILED=1; fi; }
raw()  { RAWV=$(rdmsr -p 0 0x610); }
bits() { python3 -c "print((0x$RAWV >> $1) & $2)" 2>/dev/null; }   # 位段抽取交给 python，避免 bash 移位歧义

echo "== 0) 逐文件语法 + lint"
SYN=$(for f in "$SRC"/*.sh; do bash -n "$f" 2>/dev/null || basename "$f"; done | tr '\n' ' ')
chk "bash -n 全通过（注意 bash -n a b 只检查 a）" "" "$SYN"
if python3 "$SRC/mock/lint.py" "$SRC"; then chk "lint 未闭合 \${VAR:+}" 0 0; else chk "lint 未闭合 \${VAR:+}" 0 1; fi

echo "== 1) get 解码"
out=$(bash "$SRC/pl.sh" get 2>&1); echo "$out" | sed 's/^/  /'
chk "MSR 里的 PL1 显示"  55.0 "$(echo "$out" | awk '/PL1/{gsub("W","",$2); print $2; exit}')"
chk "LOCK 显示"            0 "$(echo "$out" | sed -n 's/.*LOCK=\([0-9]\).*/\1/p')"
chk "powercap PL1(uW)" 55000000 "$(echo "$out" | awk '/powercap/{split($2,a,"="); print a[2]}')"

echo "== 2) set 90 157：powercap 假写不改 MSR → 必须自动回退 wrmsr，且不破坏 TAU/LOCK"
bash "$SRC/pl.sh" set 90 157 2>&1 | sed 's/^/  /'
raw
chk "PL1 字段 = 90*8"       720 "$(bits 0 0x7fff)"
chk "PL1 enable"              1 "$(bits 15 1)"
chk "PL2 字段 = 157*8"     1256 "$(bits 32 0x7fff)"
chk "PL2 enable"              1 "$(bits 47 1)"
chk "TAU 未被破坏 (0xdf)"   223 "$(bits 16 0xff)"
chk "LOCK 仍为 0"             0 "$(bits 63 1)"
BAD=$(python3 -c "
import re
print(sum(1 for l in open('$MOCK_STATE/log') if re.search(r' (?!0x)[0-9a-fA-F]{16}\$', l.rstrip())))" 2>/dev/null || echo err)
chk "wrmsr 参数全带 0x（无八进制坑）" 0 "$BAD"
sed 's/^/    /' "$MOCK_STATE/log" 2>/dev/null

echo "== 3) 模拟内核 powercap 写路径会丢 clamp 位（真机实测：bit16/bit47 被清）"
echo 004284e800df81b8 > "$MOCK_STATE/610"
bash "$SRC/pl.sh" set 90 157 > /dev/null 2>&1
python3 -c "
p='$MOCK_STATE/610'; v=int(open(p).read().strip(),16)
v &= ~((1<<16)|(1<<47))|0x0000000000000000	# 假装 driver 把 clamp/enable 位抹了
open(p,'w').write('%x' % v)"
raw; chk "模拟后 bit16=0" 0 "$(bits 16 1)"
bash "$SRC/pl.sh" set 90 157 --clamp 2>&1 | sed 's/^/  /'
raw
chk "--clamp 把 bit16 找回"   1 "$(bits 16 1)"
chk "--clamp 后 PL1 仍 90W" 720 "$(bits 0 0x7fff)"
chk "--clamp 后 PL2 enable"  1 "$(bits 47 1)"
raw; TAUB=$(bits 16 0xff)

echo "== 4) set 90 157 --clamp：flag 不能被当成 TAU 参数（位置参数重建）"
bash "$SRC/pl.sh" set 90 157 --clamp > /dev/null 2>&1
rc=$?
raw; chk "TAU 字节没被动过" "$TAUB" "$(bits 16 0xff)"
chk "退出码" 0 "$rc"
chk "时间窗没被 --clamp 污染" 55967744 "$(cat "$D/zone/constraint_0_time_window_us")"
chk "stamp 记录了 --clamp" 1 "$(grep -c -- '--clamp' "$D/stamp" 2>/dev/null || echo 0)"

echo "== 5) fix：从真机事故值 0x8022 恢复"
echo 8022 > "$MOCK_STATE/610"
bash "$SRC/pl.sh" fix > /dev/null 2>&1
raw
chk "PL1 字段(55W)"   440 "$(bits 0 0x7fff)"
chk "PL2 字段(157W)" 1256 "$(bits 32 0x7fff)"
bash "$SRC/pl.sh" bios > /dev/null 2>&1
raw
chk "bios 一字不差恢复原值" 004284e800df81b8 "$(printf '%016x' $((0x$RAWV)))"

echo "== 6) raw / clamp 子命令"
bash "$SRC/pl.sh" raw > /dev/null 2>&1 && chk "raw 读" 0 0 || chk "raw 读" 0 1
bash "$SRC/pl.sh" raw 0x004284e800df81b8 > /dev/null 2>&1; chk "raw 写带 0x" 0 "$?"
bash "$SRC/pl.sh" raw "0xzz" > /dev/null 2>&1; chk "raw 拒绝非法值" 1 "$?"
bash "$SRC/pl.sh" clamp off > /dev/null 2>&1; raw; chk "clamp off 清 bit16" 0 "$(bits 16 1)"
bash "$SRC/pl.sh" clamp on  > /dev/null 2>&1; raw; chk "clamp on 置 bit16" 1 "$(bits 16 1)"

echo "== 7) 各子命令在 set -u 下不炸"
for c in restore watch "nowallimit off" "clamp show"; do
	out=$(bash "$SRC/pl.sh" $c 2>&1); rc=$?
	[ $rc = 0 ] || chk "$c 退出码" 0 $rc
	echo "$out" | grep -qiE "unbound|未绑定|syntax error|unexpected EOF" && chk "$c 无 shell 错误" clean dirty
done
chk "缺参数时报用法而非崩" 1 "$([ "$(bash "$SRC/pl.sh" set >/dev/null 2>&1; echo $?)" = 1 ] && echo 1 || echo 0)"
chk "未知子命令返回 1"     1 "$([ "$(bash "$SRC/pl.sh" bogus >/dev/null 2>&1; echo $?)" = 1 ] && echo 1 || echo 0)"

echo "== 8) loadtest 解码函数在假环境下不炸"
echo 3000000000 > "$D/zone/energy_uj"
out=$(bash "$SRC/loadtest.sh" 2 --no-load 2>&1); rc=$?
echo "$out" | sed 's/^/  /'
[ $rc = 0 ] || chk "loadtest 退出码" 0 $rc
echo "$out" | grep -qiE "unbound|syntax error|unexpected EOF" && chk "loadtest 无 shell 错误" clean dirty

echo "== 9) hpraw.sh（WMI 原始探针）在 set -u 下不炸"
out=$(bash "$SRC/hpraw.sh" 2>&1); rc=$?
chk "usage 退出码" 0 $rc
chk "usage 里有 gnvs 子命令" 1 "$(echo "$out" | grep -c '^  gnvs')"
chk "usage 里有 design 子命令" 1 "$(echo "$out" | grep -c '^  design')"
chk "usage 里有 dsm 子命令" 1 "$(echo "$out" | grep -c '^  dsm ')"
chk "usage 里有 npl 子命令" 1 "$(echo "$out" | grep -c '^  npl ')"
chk "usage 里有 ecram 子命令" 1 "$(echo "$out" | grep -c '^  ecram ')"
for c in "gnvs" "design" "sweep" "peek 0x2F4" "gm 0x28" "dsm 0" "dsmscan" "npl 100" "ecram 0x29 4"; do
	out=$(bash "$SRC/hpraw.sh" $c 2>&1); rc=$?
	echo "$out" | grep -qiE "unbound|未绑定|syntax error|unexpected EOF" && chk "hpraw $c 无 shell 错误" clean dirty
done
chk "hpraw 未知子命令返回 1" 1 "$([ "$(bash "$SRC/hpraw.sh" bogus >/dev/null 2>&1; echo $?)" = 1 ] && echo 1 || echo 0)"
chk "非 root 时 design 会拒绝而不是崩" 0 "$(bash "$SRC/hpraw.sh" design 2>&1 | grep -qiE 'unbound|syntax' && echo 1 || echo 0)"
chk "非 root 时 npl 会拒绝（不是 syntax 错）" 1 "$(bash "$SRC/hpraw.sh" npl 100 2>&1 | grep -qiE 'unbound|syntax' && echo 0 || echo 1)"
chk "非 root 时 dsm 会拒绝（不是 syntax 错）" 1 "$(bash "$SRC/hpraw.sh" dsm 0 2>&1 | grep -qiE 'unbound|syntax' && echo 0 || echo 1)"

echo "== 9b) ecwatch.sh（负载中逐字节对比 EC RAM）"
chk "usage 表里有 pnvs" 1 "$(bash "$SRC/hpraw.sh" 2>&1 | grep -c '^  pnvs ')"
chk "ecwatch 语法" 0 "$(bash -n "$SRC/ecwatch.sh" 2>/dev/null; echo $?)"
out=$(bash "$SRC/ecwatch.sh" 2>&1); rc=$?
chk "ecwatch 非 root 退出码" 1 $rc
chk "ecwatch 非 root 提示要 sudo" 1 "$(echo "$out" | grep -c 'sudo')"
chk "ecwatch 无 shell 错误" 1 "$(echo "$out" | grep -qiE 'unbound|syntax error|unexpected' && echo 0 || echo 1)"
chk "ecwatch 有字节 diff 输出段" 1 "$([ "$(grep -c '变过的字节' "$SRC/ecwatch.sh")" -ge 1 ] && echo 1 || echo 0)"
chk "ecwatch 里 EC 字段名含 EL1R" 1 "$([ "$(grep -c 'EL1R' "$SRC/ecwatch.sh")" -ge 1 ] && echo 1 || echo 0)"

echo "== 9c) hold（长期按住性能档）"
chk "usage 表里有 hold" 1 "$(bash "$SRC/hpraw.sh" 2>&1 | grep -c '^  hold ')"
chk "hold 无 shell 错误" 1 "$(bash "$SRC/hpraw.sh" hold 2>&1 | grep -qiE 'unbound|syntax error|unexpected' && echo 0 || echo 1)"
chk "非 root 时 hold 会拒绝" 1 "$(bash "$SRC/hpraw.sh" hold 1 0 30 2>&1 | grep -qiE 'root|sudo' && echo 1 || echo 0)"
chk "hold 参数校验写了 0..15" 1 "$([ "$(grep -c 'DTPC 用 HPCM & 0x0F' "$SRC/hpraw.sh")" -ge 1 ] && echo 1 || echo 0)"
# 回归：${e1:+…$e1W} 会被当成变量 e1W（set -u 下直接崩），必须写 ${e1}W
chk "无 \${x:+…\$x后缀} 变量粘连" 0 "$(grep -cE '\$\{[a-zA-Z_][a-zA-Z0-9_]*:\+[^}]*\$[a-zA-Z_][a-zA-Z0-9_]*[A-Za-z]' "$SRC/hpraw.sh")"
chk "hold 头行写的是 \${e1}W" 1 "$([ "$(grep -c 'EL1R=\${e1}W' "$SRC/hpraw.sh")" -ge 1 ] && echo 1 || echo 0)"

echo "== 9d) systemd 持久化（hold 常驻服务）"
chk "unit 模板存在" 1 "$([ -f "$SRC/../systemd/omen-cpu-hold.service" ] && echo 1 || echo 0)"
chk "unit 里 ExecStart 是 hold @PROFILE@ 0 @INTERVAL@" 1 "$([ "$(grep -c 'hold @PROFILE@ 0 @INTERVAL@' "$SRC/../systemd/omen-cpu-hold.service")" -ge 1 ] && echo 1 || echo 0)"
chk "unit 带 Restart（EC 撤销后能自愈）" 1 "$([ "$(grep -c '^Restart=always' "$SRC/../systemd/omen-cpu-hold.service")" -ge 1 ] && echo 1 || echo 0)"
chk "unit 等 /mnt/sub 挂载（RequiresMountsFor）" 1 "$([ "$(grep -c '^RequiresMountsFor=@SRC@' "$SRC/../systemd/omen-cpu-hold.service")" -ge 1 ] && echo 1 || echo 0)"
# 模板里所有 @XXX@ 都必须被 install-hold.sh 的 sed 覆盖，否则服务跑不起来
chk "模板占位符只有 SRC/PROFILE/INTERVAL/PL1/PL2" 0 "$(grep -o '@[A-Z_0-9]*@' "$SRC/../systemd/omen-cpu-hold.service" | grep -vcE '^@(SRC|PROFILE|INTERVAL|PL1|PL2)@$')"
chk "install-hold.sh 替换了全部 5 个占位符" 5 "$(grep -o 's|@[A-Z_0-9]*@' "$SRC/install-hold.sh" | wc -l)"
chk "unit 里补 RAPL（pl.sh set，易失值）" 1 "$([ "$(grep -c 'pl.sh set @PL1@ @PL2@ --clamp' "$SRC/../systemd/omen-cpu-hold.service")" -ge 1 ] && echo 1 || echo 0)"
chk "install-hold.sh 有 --uninstall" 1 "$([ "$(grep -c -- '--uninstall' "$SRC/install-hold.sh")" -ge 1 ] && echo 1 || echo 0)"

echo "== 10) hp_raw.ko 能编译（可选：SELFTEST_BUILD=1）"
if [ "${SELFTEST_BUILD:-0}" = 1 ] && [ -d "/lib/modules/$(uname -r)/build" ]; then
	if make -C "$SRC/../modules/hp_raw" >/tmp/hp_raw.build 2>&1; then
		chk "模块编译" 0 0
	else
		sed 's/^/  /' /tmp/hp_raw.build | tail -15
		chk "模块编译" 0 1
	fi
else
	echo "  [2m(跳过：加 SELFTEST_BUILD=1 且需 kernel-devel)[0m"
fi

echo; if [ $FAILED = 0 ]; then printf '\033[32m全部通过\033[0m\n'; else printf '\033[41m有失败项\033[0m\n'; fi
exit $FAILED
