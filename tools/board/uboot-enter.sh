#!/bin/bash
# 在板子宿主机上跑：把板子带到 U-Boot 命令行 `=> `，然后**停在那里**（不 fastboot boot、不碰 UniXNU）。
# 之后用 uboot-cmd.py（UniXNU-rk3588-common/tools/board）一条条发 md.l / mw.l。给 GPU 上电序列做「秒级」试验用——
# 比「改内核 → 编 100 s → 上板 2.5 min」快两个数量级。
#
# 铁律同 tools/board/board-launch.sh（Ctrl+C 只在 18d1:4d00 稳定之后发 25×100 ms；没拿到 => 就退出；
# 同一把锁，不会和它撞车）。要先让板子在线（recovery+adb 或已在 4d00）；
# 板子不在线就退出，不往没人听的串口里盲发。
# 和 board-launch.sh 一样依赖同目录的 usb-lib.sh。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export USB_VENDORS='18d1|2207'
. "$HERE/usb-lib.sh" 2>/dev/null || { echo "找不到 $HERE/usb-lib.sh（在 UniXNU-rk3588-common/tools/board，和本脚本放同一目录）" >&2; exit 1; }
SER=/dev/ttyUSB0
ADB="${ADB:-adb}"
LOCK="${LAUNCH_LOCK:-/tmp/board-launch.lock}"
exec 9>"$LOCK" || { echo "打不开锁 $LOCK" >&2; exit 1; }
flock -n 9 || { echo "另一个启动器占着串口（$LOCK）" >&2; exit 9; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
stable_4d00() { usb_stable 18d1:4d00 "${1:-5}"; }
adb_up() { "$ADB" devices 2>/dev/null | awk 'NR>1 && $2 ~ /^(device|recovery)$/ {f=1} END{exit !f}'; }

stty -F "$SER" 1500000 raw -echo || { say "串口打不开"; exit 2; }
# 等板子上线（hw-reset 之后要几秒到几十秒）
for i in $(seq 1 ${WAIT_ONLINE:-120}); do
	if has_usb 18d1:4d00 || adb_up; then break; fi
	sleep 1
done
say "0. USB: [$(usb_ids)]"
if ! has_usb 18d1:4d00; then
	adb_up || { say "板子不在线（没有 4d00，adb 也没设备）。不盲发。"; exit 3; }
	say "1. adb reboot bootloader"
	"$ADB" reboot bootloader 2>/dev/null
fi
stable_4d00 5 || { say "4d00 没稳定，USB=[$(usb_ids)]"; exit 5; }
sleep 1
say "2. 25 x 100 ms Ctrl+C（单 fd）"
LOG=/tmp/uboot-enter.log
if uboot_grab_cli "$SER" "$LOG"; then
	say "拿到 => 提示符。板子停在 U-Boot；用 uboot-cmd.py 发命令。"
else
	say "没拿到 =>"; tail -c 400 "$LOG" | tr -cd '[:print:]\n' | tail -5; exit 6
fi
