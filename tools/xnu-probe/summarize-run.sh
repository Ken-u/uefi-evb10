#!/bin/bash
# 对 runs/TAG.ts（serial-capture.py 带时间戳的日志）做摘要，并切出内核那一段到 runs/TAG.kernel.log。
#   ./summarize-run.sh TAG
# run-kernel.sh 跑完会自动调；旧日志也可以单独重放。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS="${RUNS_DIR:-$(cd "$HERE/../.." && pwd)/runs}"
TAG="${1:?用法: summarize-run.sh TAG}"
TS="$RUNS/$TAG.ts"
[ -f "$TS" ] || { echo "error: 没有 $TS" >&2; exit 1; }

s=$(grep -n "kprintf initialized" "$TS" | head -n 1 | cut -d: -f1 || true)
if [ -z "$s" ]; then
	echo "== 内核没有输出（没有 'kprintf initialized'）。日志最后几行："
	tail -n 15 "$TS" | cut -c1-180
	exit 2
fi
# 内核那一段：从第一条 kprintf 到 panic 回溯结束（Stackshot Incomplete / MACH Reboot），找不到就取到文件尾
e=$(grep -n "Stackshot Incomplete\|MACH Reboot" "$TS" | tail -n 1 | cut -d: -f1 || true)
[ -n "$e" ] || e=$(wc -l < "$TS")
sed -n "${s},${e}p" "$TS" > "$RUNS/$TAG.kernel.log"

# 取某个关键字第一次出现那行的时间戳（行首 "[  12.345]"）
t() { awk -v pat="$1" 'index($0, pat) { sub(/^\[ */, ""); sub(/\].*/, ""); print; found=1; exit } END { if (!found) print "-" }' "$TS"; }
# DDR 横幅：只数真正的 SPL 横幅（"DDR c82c943893 cym 26/01/23…"），不要把 LPDDR4X 之类算进去
ddr() { awk '/DDR [0-9a-f]+ cym/ { sub(/^\[ */, ""); sub(/\].*/, ""); printf "%s ", $0; n++ } END { if (!n) printf "-" }' "$TS"; }

echo "== $TAG：内核 $(wc -l < "$RUNS/$TAG.kernel.log") 行 → runs/$TAG.kernel.log"
printf '   %-34s %s\n' "EBS（最后一次喂狗）" "$(t 'last kick done')"
printf '   %-34s %s\n' "内核第一行 kprintf" "$(t 'kprintf initialized')"
printf '   %-34s %s\n' "Waiting on <IOMedia …>" "$(t 'Waiting on')"
printf '   %-34s %s\n' "Still waiting for root device" "$(t 'Still waiting for root device')"
printf '   %-34s %s\n' "panic(" "$(t 'panic(cpu')"
printf '   %-34s %s\n' "MACH Reboot（有 PSCI 兜底时来不及打）" "$(t 'MACH Reboot')"
printf '   %-34s %s\n' "BL31 'system reset'（PSCI 复位）" "$(t 'system reset')"
printf '   %-34s %s\n' "DDR 横幅（SPL 重新起来，每次复位一条）" "$(ddr)"
printf '   %-34s %s\n' "复位后 recovery 内核起来" "$(t 'Linux version 6.1')"
echo "   --- 内核最后的 panic / 等待信息："
grep -E "panic\(cpu|Waiting on|Still waiting|Failed to|pthread kernel" "$RUNS/$TAG.kernel.log" | tail -n 4 | cut -c1-200

# 根卷镜像写进 userdata 之后才会出现的里程碑（M3a 正例 / M3b）：每一条是该字样第一次出现的时间戳，"-" = 没出现。
# 字样都是 NativeEmmc.cpp 和 evb10-root-trust.patch 里 IOLog/printf 的原文。
echo "   --- 根卷里程碑（M3a 正例之后才会有）："
printf '   %-34s %s\n' "驱动读到 SHNGROOT 清单" "$(t 'NativeEmmc: root image at block')"
printf '   %-34s %s\n' "SystemOS 窗口发布" "$(t 'published SystemOS')"
printf '   %-34s %s\n' "OS 窗口发布" "$(t 'published OS')"
printf '   %-34s %s\n' "所有窗口发布完" "$(t 'root windows published')"
printf '   %-34s %s\n' "IOMedia 报告" "$(t 'NativeEmmc: media report')"
printf '   %-34s %s\n' "根设备被驱动接受（只读 OS 卷）" "$(t "accepted without Apple's root authentication")"
printf '   %-34s %s\n' "bsd_init 跳过根认证" "$(t 'rootauth: skipped')"
printf '   %-34s %s\n' "喂狗线程第 12 次（≈55 s）" "$(t 'wdt-kick: feed 12')"
printf '   %-34s %s\n' "launchd 字样第一次出现" "$(t 'launchd')"
printf '   %-34s %s\n' "SpringBoard / backboardd" "$(t 'SpringBoard')"
echo "   --- 驱动的 root/media/APFS 相关行（最多 14 条）："
grep -E "NativeEmmc: (root image|  window|publication order|published|all [0-9]+ root windows|.* settled|media report|root device)|NativeEmmc(Block)?.*media |volume \"|apfs|APFS" "$RUNS/$TAG.kernel.log" | head -n 14 | cut -c1-210 || true
echo "   --- 内核日志最后 10 行："
tail -n 10 "$RUNS/$TAG.kernel.log" | cut -c1-200
