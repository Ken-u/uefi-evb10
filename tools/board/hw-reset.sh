#!/bin/bash
# 硬件复位：宿主机上的 ESP32-S3 控制器（用户 2026-10-27 装的）替我们按板子的 RESET / RECOVERY / MASKROM 键。
#
#   ./hw-reset.sh status             控制器在不在（只读，不按键）
#   ./hw-reset.sh reset              按 RESET 键（通道 1，GPIO4）——整板硬复位，等于拔插电源以外最彻底的一种
#   ./hw-reset.sh loader             RECOVERY 键 + RESET：板子起来后停在 Rockchip Loader（rockusb）模式
#   ./hw-reset.sh maskrom            MASKROM 组合：停在 BootROM（maskrom）模式
#   ./hw-reset.sh loader --hold-ms 3000    复位松开后再按住模式键多久（100..10000 ms，默认 1500）
#   ./hw-reset.sh usb-status|result  控制器自己的状态/最近一次操作回执
#
# 在构建机上跑会 ssh 到宿主机；在板子宿主机上跑直接本机调用。
#
# 为什么不用 `./espreset`：它靠 uv 临时装 Python 3.12 + pyserial，宿主机上没有 uv（也没有出网代理），
# 而 tools/device.py 本体只要 python3 + pyserial，宿主机的系统 python3 已经都有（pyserial 3.5，2026-10-27 实测）。
#
# 语义（读 README.txt/device.py 得来的，不是猜的）：
#   * 每次调用只是一次「按键」请求，没有自动重试，超时也不重发——所以这里同样**不重试**。
#     重复按 RESET 在启动序列里是有害的（会打断 BootROM→SPL→U-Boot→UEFI），失败了先看串口再决定。
#   * 控制器自己有 3 s 冷却，紧接着连按会被它拒掉。
#   * 它只会按键，**不证明**能把「断电」的板子重新上电；SYSTEM_OFF 之后是否回得来没验证过，
#     所以 payload 里仍然不放 shutdown 项（patch-payload-toml.py 会去掉）。
#   * 串口 /dev/ttyACM0（303a:1001）被它独占，别同时开 minicom 之类。
#   * 不要在 serial-capture.py 采集中途无意按——复位本身会把采集打断（想测复位后的启动日志除外）。
#
# 退出码：0 = 控制器接受了；其余 = 失败（看输出）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/../../.env" ] && { set -a; . "$HERE/../../.env"; set +a; }
BOARD_HOST="${BOARD_HOST:-}"
TOOL_DIR="${RESET_TOOL_DIR:?set RESET_TOOL_DIR in .env (the reset controller tool directory on the board host)}"

usage() {
	sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
status | reset | loader | maskrom | usb-status | result) ;;
-h | --help | help) usage ;;
*)
	echo "error: 未知子命令 $cmd" >&2
	usage
	;;
esac

if [ -f "$TOOL_DIR/tools/device.py" ]; then
	# 在板子宿主机上：直接本机调用
	cd "$TOOL_DIR"
	exec python3 tools/device.py "$cmd" "$@"
fi

# 在构建机上：经 ssh 到宿主机（BatchMode：免密钥已配；要密码就直接失败，不卡住）
quoted=""
for a in "$cmd" "$@"; do quoted+=" $(printf '%q' "$a")"; done
[ -n "$BOARD_HOST" ] || { echo "error: set BOARD_HOST in .env" >&2; exit 2; }
exec ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOARD_HOST" \
	"bash -c 'cd $(printf '%q' "$TOOL_DIR") && exec python3 tools/device.py$quoted'"
