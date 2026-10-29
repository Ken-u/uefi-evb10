#!/usr/bin/env python3
"""改写 payload.img 里的 \\EFI\\UniXNU\\unixnu.toml：去掉 shutdown 动作项。

为什么：`unixnu build payload` 固定往 toml 末尾追加 `reset` 和 `shutdown` 两个
动作项。这块板（RK3588 EVB10）上 shutdown = PSCI SYSTEM_OFF，板子整个断电，
**没有任何远程手段能再把它拉起来**（bring-up notes 127：hub 不支持端口断电，
没有 PDU，DTR/RTS 没接），只能让人按电源键。UniXNU 菜单画在 GOP 上，串口没有
回显，靠串口按键导航时数错一次就会选中它。2026-10-27 就这样断电过一次。

所以：payload 里只留 xnu / reset。reset 是 SYSTEM_RESET，板子会回到 U-Boot→
Android recovery，`adb reboot bootloader` 再进 fastboot，全程不要人。

用法（构建机上，用 deps-root 里的 mtools）：
    patch-payload-toml.py PAYLOAD.img [--check]

--check 只检查不改，toml 里还有 shutdown 就返回 1。可重复执行。
"""
import os
import re
import subprocess
import sys
import tempfile

MTOOLS = os.environ.get("MTOOLS_BIN", "")
TOML = "::/EFI/UniXNU/unixnu.toml"


def mt(tool, *args, **kw):
    return subprocess.run([os.path.join(MTOOLS, tool), *args], check=True, **kw)


def strip_shutdown(text):
    # 按 [[entry]] 切块，丢掉 action = "shutdown" 的块。
    head, *blocks = re.split(r"(?m)^(?=\[\[entry\]\])", text)
    kept = [b for b in blocks if not re.search(r'(?m)^\s*action\s*=\s*"shutdown"\s*$', b)]
    return head + "".join(kept), len(blocks) - len(kept)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    img = sys.argv[1]
    check = "--check" in sys.argv[2:]
    text = mt("mtype", "-i", img, TOML, capture_output=True).stdout.decode()
    new, dropped = strip_shutdown(text)
    if check:
        print("shutdown 项还在" if dropped else "ok: 没有 shutdown 项")
        return 1 if dropped else 0
    if not dropped:
        print("ok: 没有 shutdown 项，不用改")
        return 0
    with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
        f.write(new)
        tmp = f.name
    try:
        mt("mcopy", "-o", "-i", img, tmp, TOML)
    finally:
        os.unlink(tmp)
    after = mt("mtype", "-i", img, TOML, capture_output=True).stdout.decode()
    assert "shutdown" not in after, "改写后 toml 里还有 shutdown"
    print(f"ok: 去掉了 {dropped} 个 shutdown 项，剩余 entry: "
          + ", ".join(re.findall(r'(?m)^id\s*=\s*"([^"]+)"', after)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
