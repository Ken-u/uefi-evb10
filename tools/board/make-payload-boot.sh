#!/bin/bash
# 在构建机上跑。一条龙：(重编 payload) → 去掉 shutdown 项 → 打 boot.img → 传宿主机。
#
#   ./make-payload-boot.sh              # 用现成的 payload.img
#   REBUILD=1 ./make-payload-boot.sh    # 先 `unixnu build payload` 重编
#   PUSH=0 ./make-payload-boot.sh       # 只打包，不传宿主机
#
# 前置：固件 FV 已编（build.sh -b DEBUG，**必须 DEBUG**），
# 并且 tools/stub/build.sh 已经把它做成 out/probe.img。本脚本只检查 probe.img 是不是比
# FV 新，不替你重编。
#
# 为什么必须过 patch-payload-toml.py：`unixnu build payload` 每次都会重新生成
# payload.img（连 --dry-run 也会！），toml 末尾固定带 `shutdown` 动作项；
# 这块板上 shutdown = PSCI SYSTEM_OFF，板子整个断电，没有任何远程手段能拉起来。
# 见 patch-payload-toml.py 的说明。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
UNIXNU="${UNIXNU:?set UNIXNU in .env}"
DEVICE="${DEVICE_DIR:?set DEVICE_DIR (the UniXNU-evb10 checkout) in .env}"
PAYLOAD="${PAYLOAD:-$UNIXNU/out/evb10/payload/payload.img}"
FV="${FV:-$ROOT/out/BL33_AP_UEFI-evb10.Fv}"
ART="${ARTIFACTS:-$ROOT/artifacts}"
BOARD_HOST="${BOARD_HOST:?set BOARD_HOST in .env}"
OUT="$ROOT/out/probe-payload-boot.img"
# 系统 python3.8 就够（只调 mtools）；别用 env.sh 里那个 3.12，它没有 elftools
PY=/usr/bin/python3

# 原版 trust cache（静态 + SystemOS 两个模块打成一个 bundle）。没有它 AMFI 不认任何平台
# 二进制，launchd 也跑不起来。由 tools/xnu-probe/make-trust-bundle.py 从 IPSW 的两个 IM4P 做出来；
# TRUST_CACHE= 留空可以不带（只在 payload 里不要 AMFI 的场合）。
TRUST_CACHE="${TRUST_CACHE-$ART/trust/original-static-system.bundle}"
# 带 evb10-exec=1（board.toml）时用 owner bundle：owner 模块只有 MaliMetal 的 usertest/build.sh 做的那一个 cdhash，后面是原版两个模块（一字节不改）。
# 内核里的测试程序和 bundle 里的 cdhash 是同一次 build.sh 出来的，build.sh 同时把 bundle 的 SHA-256 钉进 board.toml。
if [ "${TRUST_CACHE+set}" = set ] && [ -n "$TRUST_CACHE" ] && grep -q -E '"evb10-(exec|gpu-addon)=1"' "$DEVICE/board.toml" &&
	[ "$TRUST_CACHE" = "$ART/trust/original-static-system.bundle" ]; then
	TRUST_CACHE="$ART/trust/owner-static-system.bundle"
	echo "== board.toml 带 evb10-exec=1 / evb10-gpu-addon=1：用 owner trust bundle（$TRUST_CACHE）"
fi

# GPU addon（Mali 的 Metal 插件，MaliMetal 的 metal-plugin/build-plugin.sh + make-addon.py 的产物）：board.toml 带 evb10-gpu-addon=1 时放进 payload，
# 内核写进 Data 卷并 union 挂到 /System/Library/Extensions。GPU_ADDON= 留空可以不带。
GPU_ADDON="${GPU_ADDON-${MALIMETAL_DIR:?set MALIMETAL_DIR in .env}/metal-plugin/out/NativeMaliMetal.addon}"
if ! grep -q '"evb10-gpu-addon=1"' "$DEVICE/board.toml"; then
	GPU_ADDON=""
fi

# Data 种子（原始 APFS 容器，由 RAM 盘交给内核，内核把它当 /dev/md0）。没有它 /private/var 就是 OS 卷里那个
# 空壳，launchd 起不来多少东西。由 tools/xnu-probe/make-data-seed.sh 做出来（空的容器；目录树由内核在挂载后拷进去）。
# DATA_SEED= 留空可以不带。
# 默认是 256 MiB 容器截掉后面的零（2 MiB；board.toml 的 emmc-data-size=256 让驱动补回去）。DATA_MIB 换大小（要和
# board.toml 的 emmc-data-size 一致，也要先 SIZE_MIB=… TRIM=1 tools/xnu-probe/make-data-seed.sh）；
# 没有截断版就退回 32 MiB 的整盘种子（那种要把 board.toml 里的 emmc-data-size 去掉）。
DATA_MIB="${DATA_MIB:-2048}"
if [ -f "$ART/data/owner-data-$DATA_MIB.trim.img" ]; then
	DATA_SEED="${DATA_SEED-$ART/data/owner-data-$DATA_MIB.trim.img}"
else
	DATA_SEED="${DATA_SEED-$ART/data/owner-data-32.img}"
fi

if [ "${REBUILD:-0}" = 1 ]; then
	echo "== 重编 payload（在 user namespace 里）"
	TRUST_ARG=""
	if [ -n "$TRUST_CACHE" ]; then
		[ -f "$TRUST_CACHE" ] || { echo "error: 没有 trust cache bundle: $TRUST_CACHE（先跑 tools/xnu-probe/make-trust-bundle.py）" >&2; exit 1; }
		TRUST_ARG=" --trust-cache $TRUST_CACHE"
		echo "   trust cache: $TRUST_CACHE ($(sha256sum "$TRUST_CACHE" | cut -c1-16)…)"
	fi
	# 这一次实验才要的内核参数（NAME=VALUE，空格分隔；同名的会替换 board.toml 里那一项），
	# 比如 EXTRA_KERNEL_ARGS="wdt-kick=330 emmc-probe=2"。不改 board.toml，下一轮自动恢复。
	EXTRA_ARG=""
	for kernel_arg in ${EXTRA_KERNEL_ARGS:-}; do
		EXTRA_ARG="$EXTRA_ARG --kernel-arg $kernel_arg"
		echo "   本轮额外内核参数: $kernel_arg"
	done
	DATA_ARG=""
	if [ -n "$DATA_SEED" ] && [ -f "$DATA_SEED" ]; then
		DATA_ARG=" --data-ramdisk $DATA_SEED"
		echo "   Data 种子: $DATA_SEED ($(stat -c %s "$DATA_SEED") B, sha256 $(sha256sum "$DATA_SEED" | cut -c1-16)…)"
	elif [ -n "$DATA_SEED" ]; then
		echo "   （没有 Data 种子 $DATA_SEED：不带 RAM 盘）"
	fi
	ADDON_ARG=""
	if [ -n "$GPU_ADDON" ]; then
		[ -f "$GPU_ADDON" ] || { echo "error: 没有 GPU addon: $GPU_ADDON（先跑 MaliMetal 的 metal-plugin/build-plugin.sh）" >&2; exit 1; }
		ADDON_ARG=" --gpu-addon $GPU_ADDON"
		echo "   GPU addon: $GPU_ADDON ($(stat -c %s "$GPU_ADDON") B, sha256 $(sha256sum "$GPU_ADDON" | cut -c1-16)…)"
	fi
	# UNIXNU_WRAP: optional command prefix (e.g. a user-namespace wrapper) the payload build has to run under
	(cd "$UNIXNU" && ${UNIXNU_WRAP:-} bash -c \
		'./unixnu build payload -D "'"$DEVICE"'" --unique-chip-id "'"${UNIQUE_CHIP_ID:?set UNIQUE_CHIP_ID in .env}"'"'"$TRUST_ARG$DATA_ARG$ADDON_ARG$EXTRA_ARG"' -j "'"${JOBS:-8}"'"')
fi

[ -f "$PAYLOAD" ] || { echo "error: 没有 payload: $PAYLOAD（REBUILD=1 重编）" >&2; exit 1; }
[ -f "$ROOT/out/probe.img" ] || { echo "error: 没有 out/probe.img，先 tools/stub/build.sh" >&2; exit 1; }
if [ "$FV" -nt "$ROOT/out/probe.img" ]; then
	echo "error: FV 比 out/probe.img 新（$FV），先 tools/stub/build.sh 重做 probe.img" >&2
	exit 1
fi

# stub 武装不武装硬件看门狗是 probe.img 的编译期属性（PROBE_WDT），cmdline 里的
# unixnu.wdt=0 只管 DXE 驱动自己要不要武装。两者要对得上，否则会出现
# "以为没有看门狗、其实 stub 已经武装、约 89 s 后板子自己复位" 的误会。
if strings -a "$ROOT/out/probe.img" | grep -q 'DW WDT NOT armed'; then
	STUB_WDT=0
	echo "== probe.img: stub 不武装看门狗（PROBE_WDT=0）"
else
	STUB_WDT=1
	echo "== probe.img: stub 在跳进固件前武装硬件看门狗（约 89 s 没人喂就复位）"
fi
case " ${CMDLINE:-console=null} " in
	*" unixnu.wdt=0 "*)
		if [ "$STUB_WDT" = 1 ]; then
			echo "警告: CMDLINE 带 unixnu.wdt=0，但 stub 已经武装了看门狗且关不掉：" >&2
			echo "      板子仍会在最后一次喂狗约 89 s 后复位。要完全无看门狗，先 PROBE_WDT=0 ./build.sh" >&2
		fi ;;
	*)
		if [ "$STUB_WDT" = 0 ]; then
			echo "警告: probe.img 不武装看门狗，但 CMDLINE 没有 unixnu.wdt=0：DXE 驱动会自己武装它。" >&2
		fi ;;
esac

echo "== 去掉 payload 里的 shutdown 项"
"$PY" "$HERE/patch-payload-toml.py" "$PAYLOAD"
"$PY" "$HERE/patch-payload-toml.py" "$PAYLOAD" --check

echo "== 打 boot.img"
RAMDISK="$PAYLOAD" OUT="$OUT" "$HERE/mk-bootimg.sh"

# 板子的 U-Boot 的 fastboot 下载缓冲只有 112 MiB（CONFIG_FASTBOOT_BUF_SIZE=0x07000000），
# 超了不是慢，是 `FAILED (remote: 'data too large')`（2026-10-27：payload 128 MiB 的那一轮白等了 4 分钟）。
FASTBOOT_MAX=117440512
OUT_SIZE="$(stat -c %s "$OUT")"
if [ "$OUT_SIZE" -gt "$FASTBOOT_MAX" ]; then
	echo "error: boot.img 有 $OUT_SIZE 字节，超过 U-Boot fastboot 的缓冲 $FASTBOOT_MAX（112 MiB）；板子会拒收。" >&2
	echo "       调小 board.toml 的 [payload] size_mib（现在 payload.img = $(stat -c %s "$PAYLOAD") 字节），或者 Data 种子再小一点。" >&2
	exit 1
fi
echo "   boot.img $OUT_SIZE 字节（fastboot 上限 $FASTBOOT_MAX，余 $((FASTBOOT_MAX - OUT_SIZE))）"

if [ "${PUSH:-1}" = 1 ]; then
	echo "== 传宿主机:/tmp/probe-payload-boot.img"
	scp -q "$OUT" "$BOARD_HOST:/tmp/probe-payload-boot.img"
	ssh "$BOARD_HOST" 'ls -l /tmp/probe-payload-boot.img'
fi
echo "== 完成。上板：宿主机上 ~/unixnu-probe/board-launch.sh /tmp/probe-payload-boot.img"
