#!/bin/bash
# 把 probe.img（arm64 Linux Image）包成 Android boot.img（header v2），
# second 段放 Rockchip 的 resource.img —— U-Boot 的 Android 流程要从那里读 dtb，
# 少了它就是 `bootm can't read dtb, ret=-22`（sweet 那边 pitfalls 第 34 条）。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
MKBOOTIMG="${MKBOOTIMG:?set MKBOOTIMG in .env}"
SECOND="${SECOND:?set SECOND (the Rockchip resource.img of the board, see README) in .env}"
# RAMDISK=payload.img：把 unixnu build payload 的 FAT 卷当 ramdisk 带上（固件里的
# UniXNURamDiskDxe 会通过 FDT 的 linux,initrd-* 找到它）。不设就是空 ramdisk。
RAMDISK="${RAMDISK:-/dev/null}"
OUT="${OUT:-$ROOT/out/probe-boot.img}"
# boot.img 的 cmdline：U-Boot 会把它写进交给固件的 FDT 的 /chosen/bootargs，
# 固件里的 UniXNUBootWdtDxe 读它。`unixnu.wdt=0` = 驱动不要自己武装看门狗
# （stub 已经武装的关不掉，要完全无看门狗得配合 PROBE_WDT=0 ./build.sh）。
CMDLINE="${CMDLINE:-console=null}"
"$MKBOOTIMG" \
	--header_version 2 \
	--kernel "$ROOT/out/probe.img" \
	--second "$SECOND" --second_offset 0xf00000 \
	--dtb "${BOARD_DTB:?set BOARD_DTB in .env}" --dtb_offset 0x1f00000 \
	--ramdisk "$RAMDISK" \
	--base 0 --kernel_offset 0xa00000 --ramdisk_offset 0x1000000 --tags_offset 0x100 \
	--pagesize 4096 \
	--cmdline "$CMDLINE" \
	-o "$OUT"
ls -l "$OUT"
