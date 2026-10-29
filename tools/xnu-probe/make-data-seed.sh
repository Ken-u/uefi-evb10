#!/bin/bash
# 在构建机上跑。做一个「空的」APFS Data 种子（原始容器镜像，dense 形式），给 payload 的 --data-ramdisk。
#
#   ./make-data-seed.sh                 # → tools/xnu-probe/data/owner-data-32.img（32 MiB，卷名 OwnerData）
#   SIZE_MIB=64 LABEL=Data ./make-data-seed.sh
#
# 卷的 UUID 是定值（mkapfs -u）：内核按这个 UUID 在「Data RAM 盘」下面找卷（native_emmc_data_device），
# 它必须和 UniXNU-evb10 的 patches/xnu/userland-mounts/ 里的 EVB10_DATA_VOLUME_UUID 一致，
# scripts/check-evb10.py 会核对。
#
# 官方怎么做（UniXNU/scripts/prepare-owner-data-fixture.py，只能在 macOS 上跑）：
#   hdiutil create -size 32m -layout NONE -fs APFS -volname OwnerData -type UDTO owner-data-32.cdr
#   挂载它，把原版 OS 卷的 /private/var 整棵树（去掉 staged_system_apps）拷进去，再建 keybags、mobile/tmp、
#   tmp(1777)、run。拿到的是 32 MiB 的原始 APFS 容器，偏移 32 处是 "NXSB"。
# 这里没有 macOS（也没有 hdiutil），所以：
#   1. 容器和卷由 linux-apfs 的 mkapfs 做（"experimental"，Apple 的 APFS kext 认不认要上板试：
#      emmc-data-mount=1 把它挂到 /private/var，日志里有 "evb10: Data: ..." 几行）。容器层面 Apple 的 kext
#      已经认了（emmc5f：nx_mount、checkpoint、spaceman 都过）；挂载不能走 /dev/md0（APFS 从设备「名字」
#      算卷序号，md0 → -1 → ENOENT），要走 NativeEmmc 发布的可写 RAM 块设备下的 /dev/diskNsM；
#   2. 里面的目录树不在这里填（Linux 上没有 APFS 写入手段），由内核在挂载后从被盖住的 OS 卷
#      /private/var 里拷（见 UniXNU-evb10 的 patches/xnu/evb10-userland-mounts.patch）。
#
# mkapfs 是第三方源码（linux-apfs/apfsprogs，GPL-2.0），放在 $APFSPROGS，编出来的二进制不进本仓库。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
ART="${ARTIFACTS:-$ROOT/artifacts}"
SIZE_MIB="${SIZE_MIB:-32}"
LABEL="${LABEL:-OwnerData}"
VOLUME_UUID="${VOLUME_UUID:-3E8C2B1A-5D47-4F90-A6C3-9B1D7E0F2A48}"   # = EVB10_DATA_VOLUME_UUID of the kernel hook
CASE_SENSITIVE="${CASE_SENSITIVE:-0}"   # 官方的 hdiutil -fs APFS 是大小写不敏感，默认跟它一致
OUT="${OUT:-$ART/data/owner-data-${SIZE_MIB}.img}"
PROGS="${APFSPROGS:?set APFSPROGS (checkout path for linux-apfs/apfsprogs) in .env}"

if [ ! -x "$PROGS/mkapfs/mkapfs" ]; then
	[ -d "$PROGS" ] || git clone --depth 1 https://github.com/linux-apfs/apfsprogs "$PROGS"
	make -C "$PROGS/mkapfs" >/dev/null
	make -C "$PROGS/apfsck" >/dev/null
fi
[ -e "$OUT" ] && { echo "error: $OUT 已存在（不覆盖；删掉再来）" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
truncate -s "${SIZE_MIB}M" "$OUT"
flags=()
[ "$CASE_SENSITIVE" = 1 ] && flags+=(-s)
"$PROGS/mkapfs/mkapfs" "${flags[@]}" -L "$LABEL" -u "$VOLUME_UUID" "$OUT" >/dev/null
# 官方脚本的同一条自检：大小对、偏移 32 处是 NXSB
size=$(stat -c %s "$OUT")
[ "$size" = $((SIZE_MIB * 1024 * 1024)) ] || { echo "error: 大小 $size 不对" >&2; exit 1; }
[ "$(dd if="$OUT" bs=1 skip=32 count=4 2>/dev/null)" = NXSB ] || { echo "error: 偏移 32 不是 NXSB" >&2; exit 1; }
"$PROGS/apfsck/apfsck" "$OUT"
echo "ok: $OUT ($size B) volume $VOLUME_UUID sha256 $(sha256sum "$OUT" | cut -c1-64)"

# TRIM=1: 一个空容器只有前面几个块不是 0（512 MiB 的容器：18 个 4 KiB 块，最后一个在 1.68 MiB 处）。payload 只放
# 这前面一截（向上取整到 MiB），内核驱动在 boot-arg emmc-data-size=<SIZE_MIB> 下把后面补零
# （NativeEmmc.cpp growDataDisk）。这样 Data 卷可以是几百 MiB，而 payload / fastboot 缓冲区不用多装这些零。
if [ "${TRIM:-0}" = 1 ]; then
	TRIMMED="${OUT%.img}.trim.img"
	python3 - "$OUT" "$TRIMMED" <<'PY'
import sys
src, dst = sys.argv[1:3]
last = 0
with open(src, "rb") as f:
    offset = 0
    while True:
        block = f.read(4096)
        if not block:
            break
        offset += len(block)
        if block.strip(b"\0"):
            last = offset
size = (last + (1 << 20) - 1) >> 20 << 20
with open(src, "rb") as f, open(dst, "wb") as g:
    g.write(f.read(size))
print("trimmed: %s (%d MiB of %d MiB; the rest is zeros)" % (dst, size >> 20, __import__("os").path.getsize(src) >> 20))
PY
	echo "   boot-arg: emmc-data-size=$SIZE_MIB   payload seed: $TRIMMED"
fi
