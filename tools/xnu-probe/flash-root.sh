#!/bin/bash
# 在板子宿主机上跑。把根卷镜像写进板子 `userdata` 分区的一个窗口：U-Boot `ums 0 mmc 0` 把 eMMC 变成 USB 盘 →
# flash-root.py 写 + 读回校验 → 退出 ums → U-Boot `reset`（回 recovery）。全程不需要人碰板子。
#
#   BOARD_SUDO_PASS=… ./flash-root.sh IMG OFFSET_BYTES            # 演练：走到 ums、认出设备、让写入器 dry-run，不写
#   BOARD_SUDO_PASS=… WRITE=1 ./flash-root.sh IMG OFFSET_BYTES    # 真写（先过同样的检查）
#   DRY_RUN=1 ./flash-root.sh IMG OFFSET_BYTES                    # 只看板子在线状态，不碰板子，不需要 sudo
#
# OFFSET_BYTES：窗口在 userdata 里的字节偏移（4096 的倍数）。24 GiB = 25769803776（HFS+ 旧安装只占开头 20 GiB，
# 不碰它；内核要加 boot-arg emmc-root-lba=N，N = userdata 首 LBA + OFFSET/512）。0 = 官方布局（覆盖旧安装）。
#
# 环境变量：BOARD_SUDO_PASS  写块设备要 root，写入器用 sudo -S 起（必须给；不落盘、不进仓库）
#           WRITE=1          真写；否则演练
#           EXPECT_SHA256    镜像文件的 SHA-256（强烈建议给：拷到 宿主机的过程中损坏就拒绝写）
#           DISK_BYTES       整盘字节数，默认 62537072640（GPT 实测：122142720 块 x 512）
#           USERDATA_BYTES   userdata 分区字节数，默认 58205896704（GPT 实测：LBA 8459264–122142655）
#           ADB / DRY_RUN    同 board-launch.sh
#
# 安全（都是刻意的，别放宽）：
#   - 和 board-launch.sh 共用 /tmp/board-launch.lock：同一时刻只许一个人动串口；wait-and-launch.sh 撞车时它 rc 9 退出。
#   - 板子不在线就中止，不盲发任何东西；没拿到 `=>` 提示符不发 `ums`。
#   - 只认「`ums` 之后新出现的、TRAN=usb、大小恰好等于整盘字节数」的盘，再在其中认 PARTLABEL=userdata 且大小恰好等于
#     USERDATA_BYTES 的分区；认不出就退出 ums。宿主机 自己的盘是 /dev/sda*，绝不会满足这些条件。
#   - 写入器自己再查一遍（没挂载、USB、大小、标签、窗口放得下、源文件 SHA-256），并且读回比对（O_DIRECT）。
#   - 不论写成败，最后都尽力退出 ums 并 `reset`，让板子回到 recovery（用户明确要求永远不要让他帮忙复位）。
#   - 只有 `reset`（U-Boot CLI 允许的自动复位手段之一），没有任何会让板子断电的命令。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="${1:?用法: flash-root.sh IMG OFFSET_BYTES}"
OFFSET="${2:?用法: flash-root.sh IMG OFFSET_BYTES}"
SER=/dev/ttyUSB0
FLOG="${FLOG:-/tmp/flash-root.log}"
SERLOG="${SERLOG:-/tmp/flash-root-ser.log}"
ADB="${ADB:-adb}"
DRY_RUN="${DRY_RUN:-0}"
WRITE="${WRITE:-0}"
DISK_BYTES="${DISK_BYTES:-62537072640}"
USERDATA_BYTES="${USERDATA_BYTES:-58205896704}"
EXPECT_SHA256="${EXPECT_SHA256:-}"

LOCK="${LAUNCH_LOCK:-/tmp/board-launch.lock}"
exec 9>"$LOCK" || { echo "打不开锁文件 $LOCK" >&2; exit 1; }
flock -n 9 || { echo "另一个启动器/刷写正在跑（锁 $LOCK），本次不动串口，退出" >&2; exit 9; }

: > "$FLOG"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$FLOG"; }
die() { local msg="$1"; say "中止：$msg"; exit "${2:-1}"; }
usb_ids() { lsusb | grep -Eo '18d1:[0-9a-f]{4}|2207:[0-9a-f]{4}' | tr '\n' ' '; }
adb_up() { "$ADB" devices 2>/dev/null | awk 'NR>1 && $2 ~ /^(device|recovery)$/ {f=1} END{exit !f}'; }
stable_4d00() {
	local need="${1:-5}" n=0 i
	for i in $(seq 1 150); do
		if lsusb | grep -q '18d1:4d00'; then n=$((n + 1)); else n=0; fi
		[ "$n" -ge "$need" ] && return 0
		sleep 0.2
	done
	return 1
}
usb_disks() { lsblk -bdno NAME,SIZE,TRAN 2>/dev/null | awk '$3=="usb" {print $1" "$2}'; }

[ -f "$IMG" ] || die "找不到镜像 $IMG"
[ -f "$HERE/flash-root.py" ] || die "找不到 $HERE/flash-root.py"
[ -f "$HERE/uboot-cmd.py" ] || die "找不到 $HERE/uboot-cmd.py"
case "$OFFSET" in *[!0-9]*|'') die "OFFSET_BYTES 要是十进制整数，拿到 '$OFFSET'" ;; esac
[ $((OFFSET % 4096)) -eq 0 ] || die "OFFSET_BYTES 要是 4096 的倍数"
IMG_BYTES="$(stat -c %s "$IMG")"
say "镜像 $IMG ($IMG_BYTES B)，窗口偏移 $OFFSET B，$([ "$WRITE" = 1 ] && echo 真写 || echo 演练)"

# ---- 0. 板子得在线（顺序同 board-launch.sh：4d00 → adb 在线 → 最后才是 d001）----
say "0. 当前 USB: [$(usb_ids)]"
if lsusb | grep -q '18d1:4d00'; then
	say "   已在 U-Boot fastboot"
elif adb_up; then
	say "   adb 在线: $("$ADB" devices | awk 'NR>1 && NF {print $1" "$2}' | tr '\n' ';')"
elif lsusb | grep -q '18d1:d001'; then
	die "板子在 fastbootd(18d1:d001) 而且 adb 不在线；先 fastboot reboot 回 Android/recovery" 4
else
	die "板子不在线（USB 里没有 18d1:*，adb 也没设备）。不盲发任何东西。" 3
fi
if [ "$DRY_RUN" = 1 ]; then
	say "DRY_RUN: 到这里为止什么都没做。下一步会（adb reboot bootloader →）抢 U-Boot CLI → ums 0 mmc 0。"
	exit 0
fi
[ -n "${BOARD_SUDO_PASS:-}" ] || die "没有 BOARD_SUDO_PASS：写块设备要 root（写入器用 sudo -S）。先给它，板子还没碰。" 2
stty -F "$SER" 1500000 raw -echo || die "串口 $SER 打不开"

# ---- 1. 进 U-Boot fastboot，等 4d00 稳定 ----
if ! lsusb | grep -q '18d1:4d00'; then
	say "1. adb reboot bootloader"
	"$ADB" reboot bootloader 2>/dev/null
fi
stable_4d00 5 || die "18d1:4d00 没有稳定出现，USB=[$(usb_ids)]" 5
sleep 1
say "   4d00 稳定，USB=[$(usb_ids)]"

# ---- 2. 抢 U-Boot CLI（25 x 100 ms Ctrl+C，单 fd；绝不狂按）----
say "2. 25 x 100 ms Ctrl+C（单 fd）"
pkill -f '^(timeout [0-9]+ )?cat /dev/ttyUSB0$' 2>/dev/null
sleep 0.3
: > "$SERLOG"
timeout 30 cat "$SER" >> "$SERLOG" 2>/dev/null &
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
if tr -d '\000' < "$SERLOG" | grep -qa '=> '; then
	say "   拿到 => 提示符"
else
	say "   串口尾部："; tail -c 400 "$SERLOG" | tr -cd '[:print:]\n' | tail -5 | tee -a "$FLOG"
	die "没拿到 =>，不发 ums" 6
fi

# 从这里开始板子在 U-Boot CLI：无论后面成败，都要走到 leave_ums（退出 ums + reset）。
leave_ums() {
	say "退出 ums：Ctrl+C（一次）→ 等 => → reset"
	python3 - <<'PY'
import os
fd = os.open("/dev/ttyUSB0", os.O_WRONLY | os.O_NOCTTY)
os.write(fd, b"\x03")
os.close(fd)
PY
	sleep 2
	printf '\r\n' > "$SER"
	sleep 1
	local out
	out="$(TO=3 python3 "$HERE/uboot-cmd.py" 'echo ums-left' 2>&1 | tr -d '\000')"
	echo "$out" | tail -n 3 | tee -a "$FLOG" >/dev/null
	if echo "$out" | grep -q 'ums-left'; then
		say "   回到 U-Boot 提示符，发 reset"
	else
		say "   ⚠ 没确认回到提示符，仍然发 reset（它在非提示符状态下大概率被忽略；看门狗约 89 s 后兜底不适用于 U-Boot——需要关注）"
	fi
	TO=2 python3 "$HERE/uboot-cmd.py" 'reset' >/dev/null 2>&1
}

# ---- 3. ums，认设备 ----
BEFORE="$(usb_disks)"
BEFORE_NAMES="$(echo "$BEFORE" | awk 'NF {print $1}' | paste -sd, -)"
say "3. ums 0 mmc 0（已有的 USB 盘：[${BEFORE_NAMES}]）"
TO=3 python3 "$HERE/uboot-cmd.py" 'ums 0 mmc 0' >/dev/null 2>&1

# 认法在 flash-root.py find-target（有离线测试）：ums 之后新出现的、TRAN=usb、大小恰好等于整盘字节数的盘，
# 上面恰好一个 PARTLABEL=userdata 且大小恰好等于 USERDATA_BYTES 的分区。0 个就重试（分区节点晚几秒才出来），
# 多于一个（rc 3）就放弃。
NODE=""
for _ in $(seq 1 60); do
	NODE="$(python3 "$HERE/flash-root.py" find-target --before "$BEFORE_NAMES" --disk-bytes "$DISK_BYTES" \
		--userdata-bytes "$USERDATA_BYTES" 2>>"$FLOG")"
	frc=$?
	[ "$frc" -eq 0 ] && break
	NODE=""
	if [ "$frc" -eq 3 ]; then break; fi
	sleep 1
done
if [ -z "$NODE" ]; then
	say "   没有认出板子的 userdata 分区；现在的块设备："
	lsblk -bno NAME,SIZE,TRAN,PARTLABEL 2>&1 | tee -a "$FLOG"
	leave_ums
	die "认不出 userdata 分区，什么都没写" 7
fi
say "   userdata = $NODE"

# ---- 4. 写（或演练）----
ARGS=("$IMG" "$NODE" --offset "$OFFSET" --expect-bytes "$USERDATA_BYTES" --expect-label userdata)
[ -n "$EXPECT_SHA256" ] && ARGS+=(--expect-sha256 "$EXPECT_SHA256")
[ "$WRITE" = 1 ] && ARGS+=(--write)
say "4. flash-root.py ${ARGS[*]}"
printf '%s\n' "$BOARD_SUDO_PASS" | sudo -S -p '' python3 "$HERE/flash-root.py" "${ARGS[@]}" 2>&1 | tee -a "$FLOG"
RC="${PIPESTATUS[1]}"
say "   flash-root.py rc=$RC"

# ---- 5. 退出 ums、reset、等板子回来 ----
sync
leave_ums
say "5. 等板子回到 recovery（最多 150 s）"
for _ in $(seq 1 150); do
	if adb_up; then
		say "   板子回来了: USB [$(usb_ids)] adb: $("$ADB" devices | awk 'NR>1 && NF {print $2}' | tr '\n' ' ')"
		[ "$RC" -eq 0 ] && say "完成" || say "写入器失败（rc=$RC），见上面的日志"
		exit "$RC"
	fi
	sleep 1
done
say "   150 s 内 adb 没回来，USB=[$(usb_ids)]；串口日志 $SERLOG"
[ "$RC" -eq 0 ] && exit 10 || exit "$RC"
