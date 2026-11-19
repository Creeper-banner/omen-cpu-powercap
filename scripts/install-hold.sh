#!/bin/bash
# 安装「性能档保持」常驻服务（第 7/8 轮验证过的方案：hold 定期重申 GM1A）
#   sudo bash scripts/install-hold.sh                 # profile=1，10s 一查，PL1=90 PL2=100（推荐）
#   sudo bash scripts/install-hold.sh 1 10 90 157     # 放开 130W 尖峰（更热、跑分略高）
#   sudo bash scripts/install-hold.sh 1 5             # 5s 一查（空档更短）
#   sudo bash scripts/install-hold.sh --uninstall
#
# 关于 PL1/PL2（第 10 轮实测）：
#   稳态 = min(EC 的 EL1R=90, PL1)   → PL1>90 无收益；PL1<90 就是降档
#   boost = min(EC 的 EL2R=130, PL2) → PL2=100 可掐掉 130W 尖峰（93-97°C → ~89°C）
#   注意 MSR 易失：重启回出厂 PL1=55W ⇒ 不设的话 EC 的 90W 会被削成 55W
set -eu
export LC_ALL=C
SRC=$(cd "$(dirname "$0")/.." && pwd)
U=/etc/systemd/system/omen-cpu-hold.service

[ "$(id -u)" = 0 ] || { echo "需要 root：sudo bash scripts/install-hold.sh"; exit 1; }

case "${1:-}" in
--uninstall|--disable)
	systemctl disable --now omen-cpu-hold.service 2>/dev/null || true
	[ "${1}" = "--uninstall" ] && rm -f "$U" && systemctl daemon-reload
	echo "已停用。当前档位仍在（EC 约 95s 后自己撤销回 45/56/90）。"
	exit 0 ;;
esac

PROFILE=${1:-1}
INTERVAL=${2:-10}
PL1=${3:-90}
PL2=${4:-100}
num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
num "$PROFILE" && [ "$PROFILE" -le 15 ] || { echo "profile 取 0..15（DTPC 用 HPCM & 0x0F）"; exit 1; }
num "$INTERVAL" && [ "$INTERVAL" -ge 5 ] || { echo "间隔至少 5s（EC 倒计时约 95s，太小只是多读 EC）"; exit 1; }
num "$PL1" && [ "$PL1" -ge 15 ] || { echo "PL1 取 15..157（>90 无收益，<90 就是降档）"; exit 1; }
num "$PL2" && [ "$PL2" -ge "$PL1" ] && [ "$PL2" -le 157 ] || { echo "PL2 取 PL1..157（EC 上限 130）"; exit 1; }

[ -f "$SRC/modules/hp_raw/hp_raw.ko" ] || { echo "先生成模块：sudo bash $SRC/scripts/hpraw.sh build"; exit 1; }

sed -e "s|@SRC@|$SRC|g" -e "s|@PROFILE@|$PROFILE|g" -e "s|@INTERVAL@|$INTERVAL|g" \
	-e "s|@PL1@|$PL1|g" -e "s|@PL2@|$PL2|g" \
	"$SRC/systemd/omen-cpu-hold.service" > "$U"
systemctl daemon-reload
systemctl enable --now omen-cpu-hold.service

echo
echo "已启动：profile=$PROFILE，每 ${INTERVAL}s 检查一次 HPCM，RAPL PL1=${PL1}W PL2=${PL2}W"
echo "  看状态: systemctl status omen-cpu-hold --no-pager"
echo "  看日志: journalctl -u omen-cpu-hold -b -f     （应只在漂移时打印「重申」，正常时静默）"
echo "  立即验证: sudo bash $SRC/scripts/hpraw.sh ecl | tail -3   （应为 EL1R(PL1)=90）"
echo "           sudo bash $SRC/scripts/pl.sh get                  （应为 PL1=${PL1}W clamp=1）"
echo "  回滚: sudo bash $SRC/scripts/install-hold.sh --uninstall"
echo
echo "注意：/mnt/sub 是 noexec，服务里用 /bin/bash 显式解释脚本，不需要可执行位。"