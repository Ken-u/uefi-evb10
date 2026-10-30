#!/bin/bash
# 用 upstream 的 edk2-rk3588 构建一个带 UniXNU 的 RK3588 UEFI 固件。
#
#   ./build.sh                 # DEBUG（板上调试必须用 DEBUG，串口日志靠它）
#   ./build.sh -b RELEASE      # RELEASE
#   ./build.sh -n              # 只打包 NOR 镜像，不重编
#   GPU_RAIL_UV=850000 ./build.sh   # GPU 供电 0.85 V（微伏；默认 750000 = 0.75 V）：GPU 跑 1 GHz（mali-npll=1000）要它
#
# 不修改 upstream（edk2-rk3588）里的任何文件：平台 DSC/FDF 片段都在 UniXNUEvb10/ 里，
# UniXNU 的包通过 PACKAGES_PATH 挂进来。路径来自 .env（见 .env.example）：UPSTREAM、UNIXNU、CLANG_BIN。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
. "$ROOT/env.sh"

UPSTREAM="${UPSTREAM:?set UPSTREAM (the edk2-rk3588 checkout) in .env}"
UNIXNU="${UNIXNU:?set UNIXNU (the UniXNU checkout, f85b5a6 or newer) in .env}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build}"
OUT="${OUT:-$ROOT/out}"
# UniXNUPlatformLib compiles two upstream files through this relative link
ln -sfn "$UPSTREAM" "$ROOT/upstream"

TARGET=DEBUG
PACK_ONLY=0
PLATFORM=evb10
JOBS="${JOBS:-$(nproc)}"

while getopts "b:p:nh" opt; do
  case $opt in
    b) TARGET=$OPTARG ;;
    p) PLATFORM=$OPTARG ;;
    n) PACK_ONLY=1 ;;
    h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 1 ;;
  esac
done

case "$PLATFORM" in
  evb10)
    PLAT_DIR=UniXNUEvb10
    IMG_TAG="-evb10"
    ;;
  *)
    echo "error: 未知平台 '$PLATFORM'（只有 evb10）" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------- 前置检查
[ -f "$UPSTREAM/edk2/MdePkg/MdePkg.dec" ] || { echo "error: 没有 upstream 树: $UPSTREAM" >&2; exit 1; }
[ -f "$UNIXNU/package/UniXNUPkg/UniXNUPkg.dec" ] || { echo "error: 没有 UniXNU 树: $UNIXNU" >&2; exit 1; }
[ -f "$UNIXNU/drivers/DarwinBoot/DarwinBootPkg/Driver/DarwinBoot.inf" ] || { echo "error: DarwinBoot 子模块缺失" >&2; exit 1; }
[ -f "$UPSTREAM/edk2/MdePkg/Library/BaseFdtLib/libfdt/libfdt/fdt.c" ] || {
  echo "error: upstream edk2 缺少 libfdt 子模块" >&2
  echo "  git -C $UPSTREAM/edk2 submodule update --init --depth 1 MdePkg/Library/BaseFdtLib/libfdt" >&2
  exit 1
}

# ---------------------------------------------------------------- 工具链
if [ -z "${CLANG_BIN:-}" ]; then
  CLANG=$(command -v clang) || { echo "error: 找不到 clang（CLANGDWARF 需要 clang 11+）" >&2; exit 1; }
  CLANG_BIN="$(dirname "$CLANG")/"
fi
export CLANG_BIN
export CLANGDWARF_BIN="$CLANG_BIN"

# edk2 的 BuildTools 是本地编的；upstream build.sh 也走这条路。
if [ ! -x "$UPSTREAM/edk2/BaseTools/Source/C/bin/GenFw" ]; then
  echo "== 编译 edk2 BaseTools"
  make -C "$UPSTREAM/edk2/BaseTools" -j"$JOBS" >/dev/null
fi

mkdir -p "$BUILD_ROOT/Build/Conf" "$OUT"

# evb10: 把 RamDisk/esp/ 打成 FAT 镜像，FDF 会把它塞进固件卷。
if [ "$PLATFORM" = evb10 ]; then
  python3 "$HERE/tools/mkesp-fv.py" "$HERE/$PLAT_DIR/RamDisk/esp" "$HERE/$PLAT_DIR/RamDisk/esp.img"
fi
export WORKSPACE="$BUILD_ROOT"
export PACKAGES_PATH="$HERE:$UPSTREAM:$UPSTREAM/edk2:$UPSTREAM/edk2-non-osi:$UPSTREAM/edk2-platforms:$UPSTREAM/edk2-rockchip:$UPSTREAM/edk2-rockchip-non-osi:$UPSTREAM/devicetree:$UNIXNU/package:$UNIXNU/drivers/DarwinBoot"
export EDK_TOOLS_PATH="$UPSTREAM/edk2/BaseTools"
export CONF_PATH="$BUILD_ROOT/Build/Conf"
export PYTHON_COMMAND="${PYTHON_COMMAND:-python3}"

for f in target tools_def build_rule; do
  if [ ! -f "$CONF_PATH/$f.txt" ] || [ "$EDK_TOOLS_PATH/Conf/$f.template" -nt "$CONF_PATH/$f.txt" ]; then
    cp "$EDK_TOOLS_PATH/Conf/$f.template" "$CONF_PATH/$f.txt"
  fi
done

BUILD="$EDK_TOOLS_PATH/BinWrappers/PosixLike/build"
[ -x "$BUILD" ] || BUILD="$EDK_TOOLS_PATH/Source/Python/build/build.py"
export PYTHONPATH="$EDK_TOOLS_PATH/Source/Python${PYTHONPATH:+:$PYTHONPATH}"
# GenSec/GenFfs/GenFw 等宿主工具由 GenFds 直接调用，必须在 PATH 上。
export PATH="$EDK_TOOLS_PATH/BinWrappers/PosixLike:$EDK_TOOLS_PATH/Source/C/bin:$PATH"

# ---------------------------------------------------------------- 编固件
DSC="$HERE/$PLAT_DIR/$PLAT_DIR.dsc"

if [ "$PACK_ONLY" -eq 0 ]; then
  echo "== 构建 $(basename "$DSC" .dsc) [$TARGET]"
  "$BUILD" \
    -a AARCH64 \
    -t CLANGDWARF \
    -b "$TARGET" \
    -p "$DSC" \
    -n "$JOBS" \
    -D NETWORK_ALLOW_HTTP_CONNECTIONS=TRUE \
    -D GPU_RAIL_UV="${GPU_RAIL_UV:-750000}" \
    --pcd gRockchipTokenSpaceGuid.PcdFitImageFlashAddress=0x100000
fi

FV_DIR="$BUILD_ROOT/Build/$PLAT_DIR/${TARGET}_CLANGDWARF/FV"
[ -f "$FV_DIR/NOR_FLASH_IMAGE.fd" ] || { echo "error: 没有生成 $FV_DIR/NOR_FLASH_IMAGE.fd" >&2; exit 1; }

# ---------------------------------------------------------------- 打包
# 与 upstream build.sh 的 _pack_image 一致：GPT + idblock + FIT(FV/DTB) 拼成
# 8MB NOR 镜像。这里只是把 edk2-rockchip 已经产出的东西拼起来，不重编 TF-A。
echo "== 打包 NOR 镜像 ($PLAT_DIR, $TARGET)"
MACHINE_TYPE=$(uname -m)
[ "$MACHINE_TYPE" = "arm64" ] && MACHINE_TYPE=aarch64
[ "$MACHINE_TYPE" = "amd64" ] && MACHINE_TYPE=x86_64
MKIMAGE="$UPSTREAM/misc/tools/$MACHINE_TYPE/mkimage"

WORK="$BUILD_ROOT/pack"
rm -rf "$WORK"
mkdir -p "$WORK"

cp "$FV_DIR/NOR_FLASH_IMAGE.fd" "$WORK/RK3588_NOR_FLASH.img"

# idblock：DDR 初始化 + SPL v1.12（v1.13 的 SD 卡支持是坏的，upstream 也退回 v1.12）
DDRBIN_RKBIN=$(grep '^FlashData' "$UPSTREAM/misc/rkbin/RKBOOT/RK3588MINIALL.ini" | cut -d = -f 2-)
"$MKIMAGE" -n rk3588 -T rksd \
  -d "$UPSTREAM/misc/rkbin/${DDRBIN_RKBIN}:$UPSTREAM/misc/rk3588_spl_v1.12.bin" \
  "$WORK/idblock.bin"

# FIT：BL31 各 PT_LOAD 段 + OP-TEE + UEFI FV
cp "$FV_DIR/BL33_AP_UEFI.Fv" "$WORK/"
BL31=$(grep '^PATH=.*_bl31_' "$UPSTREAM/misc/rkbin/RKTRUST/RK3588TRUST.ini" | cut -d = -f 2-)
BL32=$(grep '^PATH=.*_bl32_' "$UPSTREAM/misc/rkbin/RKTRUST/RK3588TRUST.ini" | cut -d = -f 2-)
cp "$UPSTREAM/misc/rkbin/$BL32" "$WORK/bl32.bin"
cp "$UPSTREAM/misc/rk3588_spl.dtb" "$WORK/unixnu.dtb"

(cd "$WORK" && python3 "$UPSTREAM/misc/extractbl31.py" "$UPSTREAM/misc/rkbin/$BL31")

ATF_NODES="$WORK/atf_nodes.its"
ATF_LOADABLES=""
ATF_INDEX=0
ATF_ENTRY=""
for seg in $(cd "$WORK" && ls bl31_0x*.bin 2>/dev/null | sort); do
  addr="${seg#bl31_}"; addr="${addr%.bin}"
  ATF_INDEX=$((ATF_INDEX + 1))
  [ -z "$ATF_ENTRY" ] && ATF_ENTRY=$addr
  cat >> "$ATF_NODES" <<EOF
		atf-${ATF_INDEX} {
			description = "ARM Trusted Firmware";
			data = /incbin/("./${seg}");
			type = "firmware";
			arch = "arm64";
			os = "arm-trusted-firmware";
			compression = "none";
			load = <${addr}>;
			hash { algo = "sha256"; };
		};
EOF
  [ "$ATF_INDEX" -gt 1 ] && ATF_LOADABLES="${ATF_LOADABLES}\"atf-${ATF_INDEX}\", "
done
[ "$ATF_INDEX" -gt 0 ] || { echo "error: 从 $BL31 里没提出 BL31 段" >&2; exit 1; }

sed -e "s,@DEVICE@,unixnu,g" \
    -e "s|@ATF_LOADABLES@|${ATF_LOADABLES}|" \
    -e "/@ATF_IMAGES@/r ${ATF_NODES}" \
    -e "/@ATF_IMAGES@/d" \
    "$UPSTREAM/misc/uefi_rk3588.its" > "$WORK/rk3588_unixnu_EFI.its"
rm -f "$ATF_NODES"

(cd "$WORK" && "$MKIMAGE" -f rk3588_unixnu_EFI.its -E unixnu_EFI.itb)

# 8MB NOR 布局：GPT@0x0、idblock@0x8000、FIT@0x100000
IMG="$WORK/RK3588_NOR_FLASH.img"
dd if="$UPSTREAM/misc/rk3588_spi_nor_gpt.img" of="$IMG" conv=notrunc status=none
dd if="$WORK/idblock.bin" of="$IMG" bs=1K seek=32 conv=notrunc status=none
dd if="$WORK/unixnu_EFI.itb" of="$IMG" bs=1K seek=1024 conv=notrunc status=none

cp "$IMG" "$OUT/RK3588_NOR_FLASH-unixnu${IMG_TAG}.img"
cp "$FV_DIR/BL33_AP_UEFI.Fv" "$OUT/BL33_AP_UEFI${IMG_TAG}.Fv"
cp "$WORK/unixnu_EFI.itb" "$OUT/unixnu${IMG_TAG}_EFI.itb"

# 单独把 UniXNU 的 EFI 拿出去，方便在已有固件里手工加载
for m in UniXNU UniXNUDxe DarwinBoot; do
  found=$(find "$BUILD_ROOT/Build/$PLAT_DIR/${TARGET}_CLANGDWARF" -name "$m.efi" | head -1)
  [ -n "$found" ] && cp "$found" "$OUT/$m.efi"
done

echo
echo "== 完成"
ls -la "$OUT"
