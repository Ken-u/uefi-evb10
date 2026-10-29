#!/bin/bash
# 验证 UniXNUHelper.S 的 EL2 -> EL1 降级：构建机上编，宿主机上用 QEMU 跑两遍。
#
#   ./run.sh            编 + 传宿主机 + 跑（EL2 启动、EL1 启动各一遍）
#   BOARD_HOST=... ./run.sh
#
# 跑什么：
#   * EL2 启动（-M virt,virtualization=on）：先布置最坏情况，再调真正的降级函数，
#     在 EL1 里验证。
#   * EL1 启动（-M virt）：降级函数应当原样返回（CurrentEL != 2 的分支）。
# 退出码 0 = 两遍都过。
#
# 这只证明「降级序列本身对」。真板上 TF-A 留下的状态、GIC 的安全配置、EDK2 其余部分在
# EL1 下是否都 OK，QEMU 看不出来——那些只能上板。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
CLANG="${CLANG:-${LLVM_BIN:+$LLVM_BIN/}clang}"
EDK2_INC="${UPSTREAM:?set UPSTREAM in .env}/edk2/MdePkg/Include/AArch64"
LIBDIR="$ROOT/UniXNUEvb10/Library/UniXNUPlatformLib"
BOARD_HOST="${BOARD_HOST:?set BOARD_HOST in .env}"
OUT="$HERE/out"
mkdir -p "$OUT"

echo "== 编译（汇编的是 $LIBDIR/UniXNUHelper.S 本体）"
"$CLANG" --target=aarch64-none-elf -c -x assembler-with-cpp \
	-I"$EDK2_INC" -I"$LIBDIR" "$HERE/test.S" -o "$OUT/test.o"
"$CLANG" --target=aarch64-none-elf -nostdlib -fuse-ld=lld -T "$HERE/test.ld" \
	-Wl,--build-id=none -o "$OUT/test.elf" "$OUT/test.o"
ls -l "$OUT/test.elf"

echo "== 传 $BOARD_HOST:/tmp/el2drop.elf"
scp -q "$OUT/test.elf" "$BOARD_HOST:/tmp/el2drop.elf"

# 宿主机的登录 shell 是 zsh（没有 PIPESTATUS），所以远端一律显式 bash -c，
# 并用 QEMU_RC= 标记带回 qemu 真正的退出码。
qemu_remote() { # $1 = -M 参数，$2 = elf
	ssh "$BOARD_HOST" "bash -c 'timeout 60 qemu-system-aarch64 -M $1 -cpu max -m 128 -nographic -monitor none \
		-semihosting-config enable=on,target=native -kernel $2 2>&1; echo QEMU_RC=\$?'" | tr -d '\r'
}

run() { # $1 = 说明, $2 = -M 参数, $3 = 日志名
	echo "== QEMU: $1"
	qemu_remote "$2" /tmp/el2drop.elf >"$OUT/$3.log" || true
	cat "$OUT/$3.log"
	local rc
	rc="$(sed -n 's/^QEMU_RC=//p' "$OUT/$3.log" | tail -1)"
	echo "   qemu 退出码 ${rc:-?}"
	# 判定：退出码 0 且日志里有 TEST PASS（两个都要，免得退出码被吞掉）
	[ "${rc:-1}" = 0 ] && grep -q '^TEST PASS' "$OUT/$3.log"
}

FAIL=0
run "EL2 启动（virtualization=on）：真正做降级" "virt,virtualization=on,gic-version=3" el2 || FAIL=1
run "EL1 启动：降级函数原样返回" "virt,gic-version=3" el1 || FAIL=1
if [ "$FAIL" = 0 ]; then echo "== 全部通过"; else echo "== 有失败"; fi
exit "$FAIL"
