#!/bin/bash
# 硬件复位：宿主机上的 ESP32-S3 控制器替我们按板子的 RESET / RECOVERY / MASKROM 键。
#
#   ./hw-reset.sh status|reset|loader|maskrom|usb-status|result [--hold-ms N]
#
# 实现是各 RK3588 板子共用的：UniXNU-rk3588-common/tools/board/hw-reset.sh（子命令、单次不重试、3 s 冷却等语义写在它的头部）。
# 这里只做两件事：读本仓库的 .env（RESET_TOOL_DIR、BOARD_HOST，以及共用工具的位置 RK3588_COMMON），再把参数原样交给它。
#
# 为什么不用控制器自带的 `./espreset`：它靠 uv 临时装 Python 3.12 + pyserial，宿主机上没有 uv（也没有出网代理），
# 而 tools/device.py 本体只要 python3 + pyserial，宿主机的系统 python3 已经都有（pyserial 3.5，2026-10-27 实测）。
#
# 这块板子上的补充：
#   * 控制器只会按键，**不证明**能把「断电」的板子重新上电；SYSTEM_OFF 之后是否回得来没验证过，
#     所以 payload 里仍然不放 shutdown 项（patch-payload-toml.py 会去掉）。
#   * 不要在 serial-capture.py 采集中途无意按——复位本身会把采集打断（想测复位后的启动日志除外）。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../env.sh"
[ -x "$RK3588_BOARD_TOOLS/hw-reset.sh" ] || {
	echo "error: $RK3588_BOARD_TOOLS/hw-reset.sh not found: clone UniXNU-rk3588-common next to this repository or set RK3588_COMMON in .env" >&2
	exit 2
}
exec "$RK3588_BOARD_TOOLS/hw-reset.sh" "$@"
