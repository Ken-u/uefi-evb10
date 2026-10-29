#!/bin/bash
# 宿主机测试：编译固件真正用的 UniXNUBootWdtArgs.h，再做变异测试确认测试不是摆设。
#
#   ./run.sh            # 在构建机上跑（gcc + ASan/UBSan）
#
# 退出码 0 = 真头文件通过，且所有"非等价"变异都被杀死。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HDR="$HERE/../../UniXNUEvb10/BootWdt/UniXNUBootWdtArgs.h"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
echo 'int main(void){return 0;}' > "$TMP/probe.c"
gcc $SAN -o "$TMP/probe" "$TMP/probe.c" 2>/dev/null || { echo "(没有 ASan，退回无 sanitizer)"; SAN=""; }

build_and_run() {   # $1 = 放头文件的目录；返回 0 = TEST PASS，1 = 测试失败，2 = 编译失败
  gcc -O1 -g -Wall -Wextra -Werror $SAN -I"$1" -o "$1/t" "$HERE/test.c" 2> "$1/cc.log" || return 2
  "$1/t" > "$1/out.log" 2>&1 || return 1
  grep -q '^TEST PASS' "$1/out.log" || return 1
  return 0
}

echo "== 真实头文件 (sanitizer: ${SAN:-无})"
mkdir -p "$TMP/real" && cp "$HDR" "$TMP/real/"
build_and_run "$TMP/real"; rc=$?
if [ $rc -ne 0 ]; then
  echo "真实头文件没过 (rc=$rc)"; cat "$TMP/real/cc.log" "$TMP/real/out.log" 2>/dev/null | head -n 30; exit 1
fi
tail -n 1 "$TMP/real/out.log"

echo "== 变异测试（每个变异都必须被杀死）"
SAN_FLAGS="$SAN" python3 - "$HDR" "$TMP" <<'PY' || exit 1
import os, subprocess, sys
hdr, tmp = sys.argv[1], sys.argv[2]
src = open(hdr).read()
# (说明, 原文, 替换)。原文必须恰好出现一次。
mutants = [
  ("词长用 >= 而不是 ==",            "((Index - Start) == WordLength)", "((Index - Start) >= WordLength)"),
  ("漏掉末尾的词 (< 而不是 <=)",     "Index <= Length", "Index < Length"),
  ("词起点不前进",                   "Start = Index + 1;", "Start = Index;"),
  ("NUL 不算分隔符",                 "(Args[Index] == '\\0') || (Args[Index] == ' ')", "(Args[Index] == ' ')"),
  ("第一个 NUL 之后继续找",          "if ((Index < Length) && (Args[Index] == '\\0')) {\n        return FALSE;\n      }", "if (0) {\n        return FALSE;\n      }"),
  ("读 Args[Length] (越界)",         "if ((Index < Length) && (Args[Index] == '\\0')) {", "if (Args[Index] == '\\0') {"),
  ("tab 不算分隔符",                 " || (Args[Index] == '\\t')", ""),
  ("换行不算分隔符",                 " || (Args[Index] == '\\n')", ""),
  ("比较结果取反",                   "CompareMem (&Args[Start], Word, WordLength) == 0", "CompareMem (&Args[Start], Word, WordLength) != 0"),
  ("少比较一个字节",                 "CompareMem (&Args[Start], Word, WordLength) == 0", "CompareMem (&Args[Start], Word, WordLength - 1) == 0"),
  ("空词也算命中",                   "if ((WordLength == 0) || (Args == NULL)) {\n    return FALSE;\n  }", "if (Args == NULL) {\n    return FALSE;\n  }"),
]
bad = 0
for i, (name, old, new) in enumerate(mutants):
    n = src.count(old)
    if n != 1:
        print(f"  [{i:2}] 变异无效（原文出现 {n} 次）: {name}"); bad += 1; continue
    d = os.path.join(tmp, f"m{i}"); os.makedirs(d)
    open(os.path.join(d, "UniXNUBootWdtArgs.h"), "w").write(src.replace(old, new))
    test_c = os.path.join(os.path.dirname(hdr), "..", "..", "tests", "bootwdt-args", "test.c")
    cc = subprocess.run(["bash", "-c", f'cd "{d}" && gcc -O1 -g -Wall -Wextra {os.environ.get("SAN_FLAGS","")} -I. -o t "{test_c}" 2> cc.log'])
    if cc.returncode != 0:
        # 编译不过的变异体不能算"被杀死"，否则会虚报
        print(f"  [{i:2}] 变异体编译失败（不算杀死）: {name}"); bad += 1; continue
    run = subprocess.run(["bash", "-c", f'cd "{d}" && ./t > out.log 2>&1'])
    passed = run.returncode == 0 and "TEST PASS" in open(os.path.join(d, "out.log")).read()
    print(f"  [{i:2}] {'SURVIVED' if passed else 'killed  '}  {name}")
    if passed: bad += 1
sys.exit(1 if bad else 0)
PY
rc=$?
[ $rc -eq 0 ] && echo "== ALL OK" || echo "== 有变异存活或无效"
exit $rc
