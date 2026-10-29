#!/bin/bash
# 变异测试：给 UniXNUHelper.S 的副本逐个注入真实 bug，确认 test.S 每次都会失败。
# 一个「一次就过」的测试不证明它能发现问题；这个脚本证明它能。
#
#   ./mutate.sh          # 只跑 EL2 启动那一遍（EL1 启动不走降级路径）
#
# 每个变异都应当得到 FAIL（退出码非 0 或超时）。有任何一个变异「存活」(PASS)，
# 说明 test.S 少了一项检查，要补。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$ROOT/env.sh"
CLANG="${CLANG:-${LLVM_BIN:+$LLVM_BIN/}clang}"
EDK2_INC="${UPSTREAM:?set UPSTREAM in .env}/edk2/MdePkg/Include/AArch64"
SRC="$ROOT/UniXNUEvb10/Library/UniXNUPlatformLib/UniXNUHelper.S"
BOARD_HOST="${BOARD_HOST:?set BOARD_HOST in .env}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 名字|s|模式|替换|已知限制（可空；非空表示「QEMU 测不出来」，存活不算失败）
# 模式/替换里的 \n 表示换行。
MUTANTS=(
"HCR_EL2.RW 没置位（sweet 线踩过的 bug）|s|mov   x0, #(1 << 31)|mov   x0, xzr|"
"CNTHCTL_EL2 没放开|s|msr   cnthctl_el2, x0|nop|"
"CNTVOFF_EL2 没清零|s|msr   cntvoff_el2, xzr|nop|"
"ICC_SRE_EL2 没设|s|msr   ICC_SRE_EL2, x0|nop|QEMU 的 GICv3 模型在没有 EL3 时把 ICC_SRE_EL2 的 SRE/Enable 当 RAO/WI，投毒清不掉（读回恒为 0xf），这一项只能上板"
"CPTR_EL2 没放开（FP 会陷入）|s|msr   cptr_el2, x0|nop|"
"VPIDR_EL2 没设|s|msr   vpidr_el2, x0|nop|"
"VMPIDR_EL2 没设|s|msr   vmpidr_el2, x1|nop|"
"MDCR_EL2 没设（PMU 会陷入）|s|msr   mdcr_el2, x0|nop|"
"HCR_EL2.IMO 残留（IRQ 被路由到 EL2）|s|msr   hcr_el2, x0|orr   x0, x0, #(1 << 4)\n  msr   hcr_el2, x0|"
"SCTLR_EL1 写错|s|movk  x0, #0x30d0, lsl #16|movk  x0, #0x0000, lsl #16|"
"根本不降级（EL2 直接 ret）|s|b.ne  .Lnodrop|b     .Lnodrop|"
)

echo "== 基线（未变异）应当 PASS"
run_one() { # $1 = helper 所在目录, $2 = 标签
	"$CLANG" --target=aarch64-none-elf -c -x assembler-with-cpp \
		-I"$EDK2_INC" -I"$1" "$HERE/test.S" -o "$TMP/t.o" 2>"$TMP/as.err" || { echo "   汇编失败:"; head -5 "$TMP/as.err"; return 99; }
	"$CLANG" --target=aarch64-none-elf -nostdlib -fuse-ld=lld -T "$HERE/test.ld" \
		-Wl,--build-id=none -o "$TMP/t.elf" "$TMP/t.o" || return 99
	scp -q "$TMP/t.elf" "$BOARD_HOST:/tmp/el2drop-mut.elf" || return 99
	ssh "$BOARD_HOST" "bash -c 'timeout 40 qemu-system-aarch64 -M virt,virtualization=on,gic-version=3 -cpu max -m 128 \
		-nographic -monitor none -semihosting-config enable=on,target=native -kernel /tmp/el2drop-mut.elf 2>&1; echo QEMU_RC=\$?'" \
		| tr -d '\r' >"$TMP/$2.log"
	# 判定：退出码 0 且有 TEST PASS（宿主机的登录 shell 是 zsh，不能靠管道退出码）
	local rc
	rc="$(sed -n 's/^QEMU_RC=//p' "$TMP/$2.log" | tail -1)"
	[ "${rc:-1}" = 0 ] && grep -q '^TEST PASS' "$TMP/$2.log" && return 0
	return "${rc:-1}"
}

mkdir -p "$TMP/base"
cp "$SRC" "$TMP/base/UniXNUHelper.S"
run_one "$TMP/base" base; rc=$?
echo "   基线退出码 $rc（0 才对）"
[ "$rc" = 0 ] || { echo "基线就不过，先修 test.S / helper"; exit 1; }

echo "== 变异（每个都应当 FAIL）"
survived=0
i=0
for m in "${MUTANTS[@]}"; do
	i=$((i + 1))
	IFS='|' read -r name _op pat rep xfail <<<"$m"
	d="$TMP/m$i"
	mkdir -p "$d"
	python3 - "$SRC" "$d/UniXNUHelper.S" "$pat" "$rep" <<'PY'
import sys
src, dst, pat, rep = sys.argv[1:5]
s = open(src).read()
rep = rep.replace("\\n", "\n")
if pat not in s:
    sys.exit("变异模式在 helper 里找不到: %r" % pat)
open(dst, "w").write(s.replace(pat, rep, 1))
PY
	[ $? = 0 ] || { echo "  [$i] $name: 变异没应用上，跳过"; survived=$((survived + 1)); continue; }
	run_one "$d" "m$i"; rc=$?
	last="$(grep -aE 'FAIL|TRAP|UNEXPECTED|IRQ ROUTED|TEST' "$TMP/m$i.log" | head -2 | tr '\n' ';' | cut -c1-110)"
	if [ "$rc" = 0 ] && [ -n "$xfail" ]; then
		echo "  [$i] 存活（已知限制）  $name"
		echo "        原因：$xfail"
	elif [ "$rc" = 0 ]; then
		echo "  [$i] 存活 ✗  $name   <-- 测试没发现它！"
		survived=$((survived + 1))
	else
		echo "  [$i] 被杀 ✓  rc=$rc  $name   (${last:-无输出/超时})"
	fi
done
echo "== 未预期的存活变异: $survived / ${#MUTANTS[@]}（已知限制的不算）"
exit "$survived"
