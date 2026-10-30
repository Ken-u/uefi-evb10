#!/bin/bash
# 在板子宿主机上跑。等板子稳定在线 → board-launch.sh 起一次 → 把带时间戳的串口日志存成 runs/TAG.ts。
# 和 probe-once.sh 的区别：不判读（没有探针要判），只留日志，给「内核现在有串口了，看它打什么」用。
#
#   kernel-run.sh IMG TAG
# 环境变量：CAPTURE_SECS（串口抓取秒数，默认 200：EBS 约在第 20 s，看门狗 TOP15 约 89 s 后复位，
#                         再留够 U-Boot 重新起来的时间）
#           WAIT_SECS（等板子回来的最长秒数，默认 300）
#           ADB（adb 路径）
#
# 只依赖同目录的 board-launch.sh / serial-capture.py / uboot-cmd.py。
# 不碰 UniXNU 菜单，不写 flash。抓取期间 宿主机上不要再开第二个串口读者（serial-cli.py、cat）。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="${1:?用法: kernel-run.sh IMG TAG}"
TAG="${2:?用法: kernel-run.sh IMG TAG}"
CAP="${CAPTURE_SECS:-200}"
WAIT="${WAIT_SECS:-300}"
ADB="${ADB:-adb}"

# USB ID 读 sysfs，不用 lsusb：路上的 hub 一抖动 lsusb 就要 6–8 s（2026-10-29 实测），"连续在线"的判断凑不齐。
usb_list() { local d; for d in /sys/bus/usb/devices/*; do [ -r "$d/idVendor" ] && echo "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)"; done; }
usb_has() { usb_list | grep -q "^$1\$"; }
usb_ids() { usb_list | grep -E '^(18d1|2207):[0-9a-f]{4}$' | tr '\n' ' '; }
online() {
	usb_has 18d1:4d00 && return 0
	usb_has 18d1:d001 || return 1   # U-Boot fastboot 和 recovery 都不在总线上：不必去问要好几秒的 adb
	"$ADB" devices 2>/dev/null | awk 'NR>1 && $2 ~ /^(device|recovery)$/ {f=1} END{exit !f}'
}

# 硬件复位（用户 2026-10-27 装的 ESP32-S3 控制器按板子的 RESET 键；tools/device.py 只要 python3 + pyserial）。
# 一次一发，不重试：重复按 RESET 会打断启动序列。HW_RESET=0 关掉（下面两处都关）。
RESET_DIR="${RESET_DIR:-}"
hw_reset() {
	[ "${HW_RESET:-1}" = 1 ] && [ -f "$RESET_DIR/tools/device.py" ] || return 1
	(cd "$RESET_DIR" && python3 tools/device.py reset) 2>&1 | tail -n 3
	return "${PIPESTATUS[0]}"
}

wait_online() { # 秒数：连续在线 ONLINE_STABLE_SECS（默认 4）秒算稳定。按时钟算，不按次数：每次判断本身可能要几秒
	local deadline=$((SECONDS + $1)) since=-1
	while [ "$SECONDS" -lt "$deadline" ]; do
		if online; then
			[ "$since" -lt 0 ] && since=$SECONDS
			[ $((SECONDS - since)) -ge "${ONLINE_STABLE_SECS:-4}" ] && return 0
		else
			since=-1
		fi
		sleep 1
	done
	return 1
}

if ! wait_online "$WAIT"; then
	echo "板子 ${WAIT}s 内没有稳定回到可用状态（USB: $(usb_ids)）"
	# 兜底：按一次硬件 RESET，再等一轮（看门狗/PSCI 都没把它带回来 = 它卡在固件或别的什么里）
	if hw_reset; then
		echo "已按硬件 RESET 键，再等 ${WAIT}s"
		if ! wait_online "$WAIT"; then
			echo "硬件复位后 ${WAIT}s 仍没回来（USB: $(usb_ids)）"
			exit 3
		fi
	else
		exit 3
	fi
fi

mkdir -p "$HERE/runs"
rm -f /tmp/launch-ser.log.ts
CAPTURE_SECS="$CAP" "$HERE/board-launch.sh" "$IMG" > /tmp/kernel-run-launch.out 2>&1
rc=$?
cp -f /tmp/launch-ser.log.ts "$HERE/runs/$TAG.ts" 2>/dev/null
cp -f /tmp/launch-ser.log "$HERE/runs/$TAG.raw" 2>/dev/null
# 日志已经落盘：这一轮的内核不用再活着了。按一次硬件 RESET 让板子立刻回到 recovery，
# 不必等看门狗（≈89 s，wdt-kick 之后更久）。HW_RESET_AFTER=0 可以留着它跑（比如要接着看板子在干什么）。
if [ "${HW_RESET_AFTER:-1}" = 1 ]; then
	if hw_reset; then echo "采集结束：已按硬件 RESET 键"; else echo "采集结束：没有按硬件 RESET（工具不在或 HW_RESET=0），等看门狗/PSCI"; fi
fi
if [ "$rc" -ne 0 ]; then
	echo "启动器失败 rc=$rc（见 宿主机:/tmp/launch.log）："
	tail -n 8 /tmp/launch.log
	exit 4
fi
echo "ok: $HERE/runs/$TAG.ts ($(wc -l < "$HERE/runs/$TAG.ts") 行)"
