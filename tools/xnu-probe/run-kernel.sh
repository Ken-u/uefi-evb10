#!/bin/bash
# 在构建机上跑。内核已经编好（UniXNU-evb10 的内核构建）之后：
# 重打 payload → 传宿主机 → 上板跑一次 → 取回带时间戳的串口日志 → 打印摘要。全程不碰板子的 flash、不需要人。
#
#   ./run-kernel.sh TAG                  # 完整一条龙（含 REBUILD=1 重打 payload，约 10 s）
#   NO_PAYLOAD=1 ./run-kernel.sh TAG     # 沿用 宿主机:/tmp/probe-payload-boot.img（payload 没变时）
#   CAPTURE_SECS=120 ./run-kernel.sh TAG
#   RETRY_FLAKE=0 ./run-kernel.sh TAG    # 关掉"UEFI 的 eMMC 初始化失败就自动重跑"（默认最多重跑 2 次）
#
# 一轮约 2.5 分钟（EBS 在第 ~19 s；内核 panic 走 PSCI 复位 ≈80 s；没有复位也最长到看门狗 ≈109 s）。
# 结果：runs/TAG.ts（带时间戳）、runs/TAG.raw、runs/TAG.kernel.log（只含内核那一段，见 summarize-run.sh）。
#
# 为什么要自动重跑：UEFI 自己的 eMMC 初始化（HS200 → HS → HS400）大约每 4–5 轮失败一次
# （`EmmcSetBusMode: Switch to HS400 CRC Error`，是 DwcSdhciDxe 的采样点没收敛，跟内核无关）。
# 失败那一轮 eMMC 控制器停在半截状态，内核驱动认不到卡（`no card answers CMD13`），
# 整轮结果作废。失败的那轮会改名保存为 runs/TAG.flakeN.*，成功的那轮才用 TAG.* 这个名字。
#
# 要在后台跑（Shell 工具会超时）：
#   (setsid nohup ./run-kernel.sh TAG > runs/TAG.driver.log 2>&1 </dev/null &)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
RUNS="${RUNS_DIR:-$ROOT/runs}"
TAG="${1:?用法: run-kernel.sh TAG}"
BOARD_HOST="${BOARD_HOST:?set BOARD_HOST in .env}"
# 内核最长活到看门狗（EBS 后 ≈89 s，约在抓取的第 109 s），再留 U-Boot/recovery 起来的时间；panic 走 PSCI 的话 ≈85 s 就结束
CAP="${CAPTURE_SECS:-130}"
RETRIES="${RETRY_FLAKE:-2}"
mkdir -p "$RUNS"

if [ "${NO_PAYLOAD:-0}" != 1 ]; then
	echo "== 重打 payload + boot.img + 传宿主机（日志 runs/$TAG.payload.log）"
	if ! REBUILD=1 "$ROOT/tools/board/make-payload-boot.sh" > "$RUNS/$TAG.payload.log" 2>&1; then
		tail -n 20 "$RUNS/$TAG.payload.log" >&2
		echo "error: payload 失败" >&2
		exit 1
	fi
	grep -E "kernel args|ok:|警告" "$RUNS/$TAG.payload.log" || true
fi

echo "== 部署脚本到宿主机（CAPTURE_SECS=$CAP）"
scp -q "$HERE/kernel-run.sh" "$ROOT/tools/board/board-launch.sh" "$ROOT/tools/board/serial-capture.py" \
	"$ROOT/tools/board/uboot-cmd.py" "$BOARD_HOST:unixnu-probe/"
ssh "$BOARD_HOST" "chmod +x ~/unixnu-probe/kernel-run.sh ~/unixnu-probe/board-launch.sh"

# 上板跑一次，取回 TAG.ts / TAG.raw。宿主机的登录 shell 是 zsh：显式 bash -c
run_board() {
	echo "== 上板"
	ssh "$BOARD_HOST" "bash -c 'cd ~/unixnu-probe && ADB=${ADB:-adb} FB=${FB:-fastboot} RESET_DIR=${RESET_DIR:-} CAPTURE_SECS=$CAP HW_RESET_AFTER=${HW_RESET_AFTER:-1} ./kernel-run.sh /tmp/probe-payload-boot.img $TAG'" \
		| tee "$RUNS/$TAG.run.txt"
	scp -q "$BOARD_HOST:unixnu-probe/runs/$TAG.ts" "$RUNS/$TAG.ts"
	scp -q "$BOARD_HOST:unixnu-probe/runs/$TAG.raw" "$RUNS/$TAG.raw" 2>/dev/null || true
}

# UEFI 把 eMMC 带到了 HS400 吗？只在"UEFI 确实去试了"但没成功时判失败，
# 其它情况（串口全空、UEFI 根本没起来）不当成这类抖动，别把别的问题吞掉。
uefi_emmc_flaked() {
	local ts="$RUNS/$TAG.ts"
	grep -q "EmmcSetBusMode: Target bus mode" "$ts" || return 1
	grep -q "EmmcSetBusMode: Switch to .* Success" "$ts" && return 1
	return 0
}

attempt=0
while :; do
	run_board
	uefi_emmc_flaked || break
	attempt=$((attempt + 1))
	if [ "$attempt" -gt "$RETRIES" ]; then
		echo "warning: UEFI 的 eMMC 初始化连续失败 $attempt 次，不再重试（结果里的 eMMC 部分不可信）" >&2
		break
	fi
	echo "== UEFI 的 eMMC 初始化失败（EmmcSetBusMode 没成功），自动重跑 $attempt/$RETRIES；这一轮另存为 runs/$TAG.flake$attempt.*"
	for ext in ts raw run.txt; do
		[ -e "$RUNS/$TAG.$ext" ] && mv "$RUNS/$TAG.$ext" "$RUNS/$TAG.flake$attempt.$ext"
	done
done

"$HERE/summarize-run.sh" "$TAG"
