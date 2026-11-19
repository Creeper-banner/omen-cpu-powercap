#!/bin/bash
# 安装/卸载 CPU 功耗墙持久化（确认 pl.sh 有效之后再跑！）
#   sudo bash scripts/install.sh              # AC: PL1=90 PL2=157 / 电池: 55/85
#   sudo bash scripts/install.sh 100 157      # 自定义 AC 目标
#   sudo bash scripts/install.sh --disable    # 停用但保留文件
#   sudo bash scripts/install.sh --uninstall
set -eu
export LC_ALL=C
SRC=$(cd "$(dirname "$0")/.." && pwd)
BIN=/usr/local/bin
U1=/etc/systemd/system/omen-cpu-pl.service
U2=/etc/systemd/system/omen-cpu-pl-watchdog.service

[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 1; }

case "${1:-}" in
--uninstall)
	systemctl disable --now omen-cpu-pl.service omen-cpu-pl-watchdog.service 2>/dev/null || true
	rm -f "$U1" "$U2" $BIN/omen-pl.sh $BIN/omen-pl-watchdog /var/lib/omen-cpu-pl
	systemctl daemon-reload
	echo "已卸载；当前 PL 仍是上次写入的值，重启后回到 BIOS 默认(55/157)。"
	exit 0 ;;
--disable)
	systemctl disable --now omen-cpu-pl.service omen-cpu-pl-watchdog.service
	exit 0 ;;
esac

AC1=${1:-90}; AC2=${2:-157}; B1=${3:-55}; B2=${4:-85}

install -Dm0755 "$SRC/scripts/pl.sh"       $BIN/omen-pl.sh
install -Dm0755 "$SRC/scripts/watchdog.sh" $BIN/omen-pl-watchdog

sed -e "s/@PL1@/$AC1/" -e "s/@PL2@/$AC2/" "$SRC/systemd/omen-cpu-pl.service" > "$U1"
cat > "$U2" <<EOF
[Unit]
Description=HP OMEN CPU power limit watchdog (保持 PL 不被 EC 改回)
After=omen-cpu-pl.service

[Service]
ExecStart=$BIN/omen-pl-watchdog $AC1 $AC2 $B1 $B2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now omen-cpu-pl.service omen-cpu-pl-watchdog.service

echo
echo "已安装并启动。AC=$AC1/$AC2 W，电池=$B1/$B2 W"
echo "  检查:  systemctl status omen-cpu-pl-watchdog --no-pager; journalctl -u omen-cpu-pl-watchdog -b | tail"
echo "  验证:  sudo bash $BIN/omen-pl.sh get"
echo "  回滚:  sudo bash $SRC/scripts/install.sh --uninstall"
