for v in 0 1 2 3 4 5; do
     echo "===== HPCM=$v ====="
     sudo bash scripts/hpraw.sh gmw 0x1a 00 $(printf '%02x' "$v")
     sleep 2
     sudo bash scripts/hpraw.sh emon 1 1
     sudo bash scripts/hpraw.sh ecl | tail -2
   done
