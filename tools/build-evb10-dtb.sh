#!/bin/bash
# 从 Rockchip 内核树里的 EVB10 设备树编出 UEFI 用的 vendor dtb。
#
#   ./build-evb10-dtb.sh              # rk3588-evb10-v10-linux.dts -> 平台目录
#   KERNEL_TREE=... ./build-evb10-dtb.sh   # 换内核树
#
# 只读内核树，不写回任何文件；产物落在
# UniXNUEvb10/DeviceTree/rk3588-evb10-v10.dtb。
#
# 唯一一处刻意的改动：删掉 /chosen/bootargs。Android/Linux 的启动参数
# （androidboot.*、root=PARTUUID=...、ttyFIQ0）对 UEFI 和 XNU 都没有意义，
# upstream 自己的 vendor dtb 里也没有 /chosen。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/env.sh"

KERNEL="${KERNEL_TREE:?set KERNEL_TREE (a Rockchip kernel 6.12 tree with rk3588-evb10-v10-linux.dts) in .env}"
DTS_DIR="$KERNEL/arch/arm64/boot/dts/rockchip"
DTS="$DTS_DIR/rk3588-evb10-v10-linux.dts"
OUT_DIR="$ROOT/UniXNUEvb10/DeviceTree"
OUT="$OUT_DIR/rk3588-evb10-v10.dtb"
WORK="${WORK:-$ROOT/build/dtb}"

for t in cpp dtc fdtget; do
  command -v "$t" >/dev/null || { echo "error: 缺 $t（dtc 包）" >&2; exit 1; }
done
[ -f "$DTS" ] || { echo "error: 没有 $DTS" >&2; exit 1; }

mkdir -p "$WORK" "$OUT_DIR"

echo "== 预处理 $(basename "$DTS")"
cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ \
    -I "$KERNEL/include" \
    -I "$DTS_DIR" \
    -I "$KERNEL/scripts/dtc/include-prefixes" \
    "$DTS" -o "$WORK/evb10.dts.i"

echo "== 编译 dtb"
dtc -I dts -O dtb -o "$WORK/evb10.dtb" "$WORK/evb10.dts.i"

if fdtget "$WORK/evb10.dtb" /chosen bootargs >/dev/null 2>&1; then
  echo "== 去掉 /chosen/bootargs"
  # -d 删属性，-r 删节点；这里要的是删属性。
  fdtput -d "$WORK/evb10.dtb" /chosen bootargs
fi

# 冒烟检查：这几项是 UEFI 侧真正依赖的板级信息，读出来给人看。
# 没有 status 属性的节点按 DT 规则视为 enabled，这里显示成 "(no status)"。
echo "== 校验关键节点"
for path in /spi@feb20000/rk806single@0 /i2c@fd880000 /i2c@fea90000 \
            /i2c@fec80000 /i2c@fec90000 /pwm@fd8b0030; do
  if ! fdtget -l "$WORK/evb10.dtb" "$path" >/dev/null 2>&1; then
    printf '   %-34s %s\n' "$path" "NOT PRESENT"
    continue
  fi
  st=$(fdtget "$WORK/evb10.dtb" "$path" status 2>/dev/null || echo "(no status)")
  printf '   %-34s %s\n' "$path" "$st"
done

cp "$WORK/evb10.dtb" "$OUT"
echo "== 完成: $OUT ($(stat -c%s "$OUT") 字节)"
