#!/bin/bash
# 做一个"把 UEFI FV 搬进 0x200000 然后跳进去"的探针镜像。
#
#   tools/stub/build.sh      # 用 out/ 里的 FV（根目录 build.sh 的产物）
#   FV=/path/to/Fv tools/stub/build.sh   # 指定别的 FV
#
# 产物 probe.img 是一个 arm64 Linux Image（带 64 字节 Image 头），可以直接
# 在 U-Boot 里 `booti`，也可以用 `mkbootimg` 包成 boot.img 给 fastboot。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
OUT="${OUT:-$ROOT/out}"
FV="${FV:-$ROOT/out/BL33_AP_UEFI-evb10.Fv}"
CLANG="${CLANG:-${LLVM_BIN:?set LLVM_BIN in .env}/clang}"
OBJCOPY="${OBJCOPY:-$(dirname "$CLANG")/llvm-objcopy}"

[ -f "$FV" ] || { echo "error: 没有 FV: $FV" >&2; exit 1; }
[ -x "$CLANG" ] || { echo "error: 没有 clang: $CLANG" >&2; exit 1; }

mkdir -p "$OUT"
cp "$FV" "$OUT/fv.bin"
echo "== FV: $(stat -c%s "$OUT/fv.bin") 字节"

cd "$OUT"
"$CLANG" --target=aarch64-none-elf \
	-O2 -ffreestanding -nostdlib -fno-pic -fno-stack-protector \
	-mgeneral-regs-only -mstrict-align -Wall -Wextra \
	-DPROBE_WDT="${PROBE_WDT:-1}" \
	-c "$HERE/probe.S" -o probe.o
echo "== PROBE_WDT=${PROBE_WDT:-1}（1 = stub 在跳进固件前武装硬件看门狗，约 89 s；0 = 不武装）"

"$CLANG" --target=aarch64-none-elf -nostdlib -fuse-ld=lld \
	-T "$HERE/probe.ld" -Wl,--build-id=none -Wl,-N \
	-o probe.elf probe.o

"$OBJCOPY" -O binary probe.elf probe.img
echo "== probe.img: $(stat -c%s "$OUT/probe.img") 字节"
xxd -l 64 "$OUT/probe.img"
