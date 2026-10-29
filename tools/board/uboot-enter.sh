#!/bin/bash
# 在板子宿主机上跑：把板子带到 U-Boot 命令行 `=> `，然后**停在那里**（不 fastboot boot、不碰 UniXNU）。
# 之后用 tools/board/uboot-cmd.py 一条条发 md.l / mw.l。给 GPU 上电序列做「秒级」试验用——
# 比「改内核 → 编 100 s → 上板 2.5 min」快两个数量级。
#
# 铁律同 tools/board/board-launch.sh（Ctrl+C 只在 18d1:4d00 稳定之后发 25×100 ms；没拿到 => 就退出；
# 同一把锁，不会和它撞车）。要先让板子在线（recovery+adb 或已在 4d00）；
# 板子不在线就退出，不往没人听的串口里盲发。
set -u
SER=/dev/ttyUSB0
ADB="${ADB:-adb}"
LOCK="${LAUNCH_LOCK:-/tmp/board-launch.lock}"
exec 9>"$LOCK" || { echo "打不开锁 $LOCK" >&2; exit 1; }
flock -n 9 || { echo "另一个启动器占着串口（$LOCK）" >&2; exit 9; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
usb_ids() { lsusb | grep -Eo '18d1:[0-9a-f]{4}|2207:[0-9a-f]{4}' | tr '\n' ' '; }
stable_4d00() { local need="${1:-5}" n=0 i; for i in $(seq 1 150); do
	if lsusb | grep -q '18d1:4d00'; then n=$((n + 1)); else n=0; fi
	[ "$n" -ge "$need" ] && return 0; sleep 0.2; done; return 1; }
adb_up() { "$ADB" devices 2>/dev/null | awk 'NR>1 && $2 ~ /^(device|recovery)$/ {f=1} END{exit !f}'; }

stty -F "$SER" 1500000 raw -echo || { say "串口打不开"; exit 2; }
# 等板子上线（hw-reset 之后要几秒到几十秒）
for i in $(seq 1 ${WAIT_ONLINE:-120}); do
	if lsusb | grep -q '18d1:4d00' || adb_up; then break; fi
	sleep 1
done
say "0. USB: [$(usb_ids)]"
if ! lsusb | grep -q '18d1:4d00'; then
	adb_up || { say "板子不在线（没有 4d00，adb 也没设备）。不盲发。"; exit 3; }
	say "1. adb reboot bootloader"
	"$ADB" reboot bootloader 2>/dev/null
fi
stable_4d00 5 || { say "4d00 没稳定，USB=[$(usb_ids)]"; exit 5; }
sleep 1
say "2. 25 x 100 ms Ctrl+C（单 fd）"
pkill -f '^(timeout [0-9]+ )?cat /dev/ttyUSB0$' 2>/dev/null
sleep 0.3
LOG=/tmp/uboot-enter.log; : > "$LOG"
timeout 30 cat "$SER" >> "$LOG" 2>/dev/null &
CAP=$!
sleep 0.3
python3 - <<'PY'
import os, time
fd = os.open("/dev/ttyUSB0", os.O_WRONLY | os.O_NOCTTY)
for _ in range(25):
    os.write(fd, b"\x03")
    time.sleep(0.1)
os.close(fd)
PY
sleep 1.5
printf '\r\n' > "$SER"
sleep 1.5
kill "$CAP" 2>/dev/null; wait "$CAP" 2>/dev/null
if tr -d '\000' < "$LOG" | grep -qa '=> '; then
	say "拿到 => 提示符。板子停在 U-Boot；用 uboot-cmd.py 发命令。"
else
	say "没拿到 =>"; tail -c 400 "$LOG" | tr -cd '[:print:]\n' | tail -5; exit 6
fi
