#!/bin/bash
# 在板子宿主机上跑。把板子送进 U-Boot 的 fastboot，抢到 CLI，设三个地址，再
# `fastboot boot` 镜像。全程不写 flash，也**不碰 UniXNU / UiApp 菜单**。
#
# 用法：  board-launch.sh [IMG]            IMG 默认 /tmp/probe-payload-boot.img
# 环境变量： CAPTURE_SECS（串口抓取秒数，默认 400）
#            SERLOG（串口日志，默认 /tmp/launch-ser.log；同目录有 serial-capture.py 时
#                    另存一份带相对秒数的 $SERLOG.ts——探针靠「多久后复位」传信号）
#            ILOG  （本脚本自己的进度，默认 /tmp/launch.log）
#            DRY_RUN=1  只做「板子现在是什么状态、下一步会做什么」的判断，打印后退出：
#                       不碰串口、不 reboot、不 fastboot（板子不在线仍照常以 3/4 退出）
#            ADB / FB   adb、fastboot 的路径（默认 宿主机上的位置；测试用假的顶替）
# 依赖（和本脚本放同一目录）： uboot-cmd.py、usb-lib.sh；serial-capture.py（有它才会产生带时间戳的 $SERLOG.ts，
#                              tools/xnu-probe/run-kernel.sh、summarize-run.sh 都读那份）。
#                              这几个是各 RK3588 板子共用的，在 UniXNU-rk3588-common/tools/board，run-kernel.sh 部署时一起拷过去。
#
# 铁律（全是踩出来的，（见 UniXNU-evb10 的 docs/handoff.zh-CN.md）、7 节）：
#   1. 板子不在线就直接退出，不往没人听的串口里盲发东西。
#   2. Ctrl+C 只在 USB **稳定**显示 18d1:4d00 之后发：25 次 x 100 ms，单个 fd。
#      绝不在 adb reboot bootloader 的同时开高频 \003 流（400 次 x 50 ms 弄死过板子）。
#   3. 没拿到 `=>` 就退出，**不**继续 fastboot boot。
#   4. 三个地址缺一不可（实测）：
#        kernel_addr_r=0xa000000   探针 stub 在 加载地址+0x502000，低了会被它搬到
#                                  0x200000 的 5 MiB FV 盖掉
#        fdt_addr_r=0x30000000     默认 0x08300000 撞 U-Boot 自己的 FDT_DTBO，
#                                  bootm 报 ret=-12
#        ramdisk_addr_r=0x50000000 默认 0xa200000 落在 stub/FV 里；payload ramdisk
#                                  72 MB 级，必须放到干净的高地址
#   5. USB ID：18d1:4d00 才是 U-Boot fastboot（有 `boot`）。18d1:d001 **本身不说明不能用**：
#      这块板的 Android 用户态是坏的，每次只起到 recovery，recovery 的 USB 就是 d001、
#      同时 adb 在线（状态 recovery）——这是上电后的**常态**，该走 `adb reboot bootloader`
#      （HANDOFF 第 4 节）。所以判断顺序是 4d00 → adb 在线 → 最后才是「d001 且 adb 不在线
#      = 纯 fastbootd，没有 boot 命令」才退出。（旧版把 d001 排在 adb 前面，上电后的
#      常态被它拒绝了——2026-10-27 自动触发器实测撞出来的。）
#   6. `fastboot boot` 偶尔卡在 "Sending 'boot.img'"（见过一次）：单独一次 Ctrl+C
#      能让 U-Boot 回到 CLI，然后重跑本脚本。
#   7. fastboot 不需要 sudo。
#   8. 同一时刻只许一个实例（flock /tmp/board-launch.lock）。撞车的那个什么都不碰、
#      退出码 9——自动触发（wait-and-launch.sh）和手动运行不会互相踩串口。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export USB_VENDORS='18d1|2207' # usb_ids 只列这两家：Google 的 fastboot/recovery 和 Rockchip 的 rockusb/maskrom
. "$HERE/usb-lib.sh" 2>/dev/null || { echo "找不到 $HERE/usb-lib.sh（在 UniXNU-rk3588-common/tools/board，部署时和本脚本放同一目录）" >&2; exit 1; }
IMG="${1:-/tmp/probe-payload-boot.img}"
SER=/dev/ttyUSB0
SERLOG="${SERLOG:-/tmp/launch-ser.log}"
ILOG="${ILOG:-/tmp/launch.log}"
CAPTURE_SECS="${CAPTURE_SECS:-400}"
ADB="${ADB:-adb}"
FB="${FB:-fastboot}"
DRY_RUN="${DRY_RUN:-0}"

# 同一时刻只许一个启动器：串口只有一个读者，两个实例同时发 Ctrl+C / 抓串口会互相弄乱
# （wait-and-launch.sh 自动触发和人手动跑可能撞车）。**必须在 `: > "$ILOG"` 之前**拿锁，
# 否则后来者会先把先来者的日志清空。锁随本脚本退出释放；抓串口的 cat 子进程会继承它，
# 它还在读串口时锁不放——这正是想要的语义。
LOCK="${LAUNCH_LOCK:-/tmp/board-launch.lock}"
exec 9>"$LOCK" || { echo "打不开锁文件 $LOCK" >&2; exit 1; }
flock -n 9 || { echo "另一个 board-launch.sh 正在跑（锁 $LOCK），本次不动串口，退出" >&2; exit 9; }

: > "$ILOG"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$ILOG"; }
die() { local msg="$1"; say "中止：$msg"; exit "${2:-1}"; }
# USB ID 直接读 sysfs，不用 lsusb（usb-lib.sh 里写了原因：路上的 hub 一抖动 lsusb 每次要 6–8 s，"稳定"就凑不齐）。
stable_4d00() { usb_stable 18d1:4d00 "${1:-5}"; } # 连续 N 次(每次 0.2 s)都看到 4d00 才算稳定

[ -f "$IMG" ] || die "找不到镜像 $IMG"
[ -f "$HERE/uboot-cmd.py" ] || die "找不到 $HERE/uboot-cmd.py"
[ "$DRY_RUN" = 1 ] || stty -F "$SER" 1500000 raw -echo || die "串口 $SER 打不开"

# ---- 0. 板子得在线 ----
adb_up() { "$ADB" devices 2>/dev/null | awk 'NR>1 && $2 ~ /^(device|recovery)$/ {f=1} END{exit !f}'; }
say "0. 当前 USB: [$(usb_ids)]"
# 链路抖动（dwc3 复位）时 USB 设备和 adb 每隔几秒到几十秒掉一次，一次判断可能正好落在断开的那一瞬（2026-10-30 实测：第一行还看到 d001，
# 紧接着的判断里 USB 和 adb 都没了，于是误报"不在线"）。所以最多等 120 s，等到 4d00 或 adb 任一出现，再往下判断；
# d001 在而 adb 一直不来才是 fastbootd。
#（2026-10-30 实测的第二种误报：等待循环里 adb 在线、break 了，紧接着的 `elif adb_up` 再问一次，链路正好掉了，落到 d001 分支报"fastbootd"。
# 所以循环里看到什么就记下来，下面按记下的状态走，不再重新问。）
state=""
for _ in $(seq 1 60); do
	if has_usb 18d1:4d00; then state=uboot; break; fi
	if adb_up; then state=adb; break; fi
	sleep 2
done
if [ "$state" = uboot ]; then
	say "   已在 U-Boot fastboot"
elif [ "$state" = adb ]; then
	# 顺序不能换：必须排在 d001 判断**前面**（见铁律 5）。recovery 的 USB 是 d001，adb 同时在线。
	say "   adb 在线: $("$ADB" devices 2>/dev/null | awk 'NR>1 && NF {print $1" "$2}' | tr '\n' ';')"
elif has_usb 18d1:d001; then
	die "板子在 fastbootd(18d1:d001) 而且 adb 不在线；它没有 boot 命令，先 fastboot reboot 回 Android/recovery" 4
else
	die "板子不在线（USB 里没有 18d1:*，adb 也没设备，等了 120 s）。不盲发任何东西。" 3
fi
if [ "$DRY_RUN" = 1 ]; then
	if has_usb 18d1:4d00; then
		say "DRY_RUN: 已在 4d00，下一步直接抢 U-Boot CLI（不会 reboot）。什么都没做。"
	else
		say "DRY_RUN: 下一步会 adb reboot bootloader，然后等 4d00 稳定。什么都没做。"
	fi
	exit 0
fi

# ---- 1. 进 U-Boot fastboot，等 4d00 稳定 ----
if ! has_usb 18d1:4d00; then
	say "1. adb reboot bootloader"
	# 链路抖动时 adb 可能正好看不到设备（"no devices"）：最多试 6 次，4d00 一出现就停（reboot 本身只发一次生效）
	for try in 1 2 3 4 5 6; do
		"$ADB" reboot bootloader 2>/dev/null && break
		say "   adb reboot bootloader 失败（第 $try 次），3 s 后重试"
		sleep 3
		has_usb 18d1:4d00 && break
	done
fi
# U-Boot 会进两次 fastboot（late-init 一次、bootcmd 一次），所以要「稳定」而不是「出现」
stable_4d00 5 || die "18d1:4d00 没有稳定出现，USB=[$(usb_ids)]" 5
sleep 1
say "   4d00 稳定，USB=[$(usb_ids)]"

# ---- 2. 抢 U-Boot CLI ----
say "2. 25 x 100 ms Ctrl+C（单 fd）"
if uboot_grab_cli "$SER" "$SERLOG"; then # usb-lib.sh：只杀我们自己抓串口的 cat（整行锚定），25 次 Ctrl+C，一个 fd，再回车，看有没有 `=> `
	say "   拿到 => 提示符"
else
	say "   串口尾部："; tail -c 400 "$SERLOG" | tr -cd '[:print:]\n' | tail -5 | tee -a "$ILOG"
	die "没拿到 =>，不继续 fastboot boot" 6
fi

# ---- 3. 设地址并校验 ----
say "3. setenv x3 并校验"
OUT="$(python3 "$HERE/uboot-cmd.py" \
	'setenv kernel_addr_r 0xa000000' \
	'setenv fdt_addr_r 0x30000000' \
	'setenv ramdisk_addr_r 0x50000000' \
	'printenv kernel_addr_r fdt_addr_r ramdisk_addr_r')"
echo "$OUT" | tee -a "$ILOG"
for kv in kernel_addr_r=0xa000000 fdt_addr_r=0x30000000 ramdisk_addr_r=0x50000000; do
	echo "$OUT" | grep -q "^$kv" || die "printenv 里没看到 $kv" 7
done

# ---- 4. 回 fastboot ----
say "4. fastboot usb 0"
TO=3 python3 "$HERE/uboot-cmd.py" 'fastboot usb 0' >/dev/null
stable_4d00 4 || die "fastboot usb 0 之后 4d00 没回来，USB=[$(usb_ids)]" 8
sleep 1

# ---- 5. boot ----
say "5. 起串口抓取（${CAPTURE_SECS}s）并 fastboot boot $IMG ($(stat -c %s "$IMG") B)"
pkill -f '^(timeout [0-9]+ )?cat /dev/ttyUSB0$' 2>/dev/null; sleep 0.3
: > "$SERLOG"
if [ -f "$HERE/serial-capture.py" ]; then
	# 同一个读者同时写两份：$SERLOG（原样）和 $SERLOG.ts（每行带相对秒数）。
	# 板子上看不到屏幕时，「ExitBootServices 之后过多久复位」就是信号，必须有时间。
	# 这一轮作废的两种情况，不必把整个 CAPTURE_SECS 抓完（EARLY_STOP=0 关掉）：
	#  - UEFI 自己的 eMMC 初始化抖动（HS400 CRC Error）：板子此时已经回 Android，白等几分钟；run-kernel.sh 会自动重跑；
	#  - 内核的从核没起来（`evb10: smp running 0 conduit 1|2`，八个核只剩 CPU 0 在跑整个 iPadOS）：性能、时序全不可信，同样自动重跑。
	STOPS=()
	if [ "${EARLY_STOP:-1}" != 0 ]; then
		STOPS+=(--stop 'EmmcSetBusMode: Switch to HS400 CRC Error' 8 "UEFI's eMMC init flaked")
		STOPS+=(--stop 'evb10: smp running 0 conduit [12]' 3 "the kernel's secondary CPUs did not start (smp running 0)")
	fi
	python3 "$HERE/serial-capture.py" ${STOPS[@]+"${STOPS[@]}"} "$SER" "$CAPTURE_SECS" "$SERLOG" "$SERLOG.ts" 2>/dev/null &
	say "   带时间戳的串口日志: $SERLOG.ts"
else
	timeout "$CAPTURE_SECS" cat "$SER" > "$SERLOG" 2>/dev/null &
fi
CAP=$!
# USB 链路上有 hub 抖动时（每隔 10–80 s 掉线重连一次），传输 100 MB 的 3–4 s 里可能正好被打断：
# "Sending ... FAILED" 说明镜像没送完、U-Boot 没启动内核，U-Boot 的 fastboot 还在等，等链路回来再发一次是安全的。
# 只对这一种失败重试；传完之后的失败（Booting FAILED、超时）不重试，因为那时内核可能已经起来了。
RC=1
for try in 1 2 3 4 5 6; do
	: > "$ILOG.fb"
	timeout 150 "$FB" boot "$IMG" >> "$ILOG.fb" 2>&1
	RC=$?
	cat "$ILOG.fb" >> "$ILOG"
	[ "$RC" -eq 0 ] && break
	grep -q "Sending 'boot.img'.*FAILED" "$ILOG.fb" || break
	say "   fastboot boot 没送完（第 $try 次：$(grep -o 'FAILED.*' "$ILOG.fb" | head -1 | cut -c1-90)），4 s 后重试"
	sleep 4
done
rm -f "$ILOG.fb"
say "   fastboot rc=$RC"
if [ "$RC" -ne 0 ]; then
	say "   fastboot boot 失败/超时。若卡在 Sending：串口发 **一次** Ctrl+C 再重跑"
fi
say "   串口日志持续写入 $SERLOG（本脚本等抓取结束）"
wait "$CAP" 2>/dev/null
say "完成，串口共 $(stat -c %s "$SERLOG") 字节"
