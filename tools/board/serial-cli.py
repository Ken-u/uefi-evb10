#!/usr/bin/env python3
"""在板子宿主机上驱动 RK3588 的串口控制台（UEFI UiApp / UniXNU 菜单 / U-Boot CLI）。

UEFI 的图形界面同时镜像到串口（ANSI 转义序列），所以整套菜单可以用串口操作，
不需要人去按键、不需要人断电。

用法（必须在板子宿主机上跑，板子的 USB 串口在那边）：

    python3 serial-cli.py screen            打印当前高亮项 + 屏幕尾部
    python3 serial-cli.py down 3            下移 3 次
    python3 serial-cli.py enter             回车
    python3 serial-cli.py esc               Esc
    python3 serial-cli.py reset             导航到 UiApp 的 Reset 并回车（替代人工断电）
    python3 serial-cli.py ctrlc [N]         Ctrl+C 突发：N 次(默认 25，上限 40)、间隔 100 ms、
                                            单个 fd（抢 U-Boot CLI 用）。**只在 USB 稳定显示
                                            18d1:4d00 时才发**，否则拒绝（--force 才放行）
    python3 serial-cli.py cmd "setenv fdt_addr_r 0x30000000"   发一行命令（先开抓取再发，回显不丢）
    python3 serial-cli.py selftest          不需要板子：验证 UiApp 高亮识别（合成帧 + 真板日志）
    python3 serial-cli.py log 30            抓 30 秒原始日志到 stdout
    python3 serial-cli.py watch 60          抓 60 秒，剥掉 ANSI，只打人眼能读的行

串口参数固定：/dev/ttyUSB0，1500000 8N1，raw。这块板子**不是 115200**。

⚠️ 菜单是有状态的，而且 UniXNU 的菜单画在 GOP 上、**串口没有回显**：按过的 Down 都算数，
哪怕串口什么都没吐。2026-10-27 靠串口盲按 Down + Enter 选中了 UniXNU 菜单的 shutdown，
PSCI SYSTEM_OFF 把板子整个断了电，没有任何远程手段能拉起来。所以：
  * 不要在看不见高亮的菜单上盲按 enter；
  * payload 里的 unixnu.toml 只能留 xnu / reset（见 patch-payload-toml.py）。
"""

import os
import re
import subprocess
import sys
import time

DEV = os.environ.get("SER", "/dev/ttyUSB0")
BAUD = os.environ.get("SER_BAUD", "1500000")

# UiApp 的菜单项顺序。改固件 PCD 后可能要跟着改。
ITEMS = [
    "Select Language",
    "Device Manager",
    "Boot Manager",
    "Boot Maintenance Manager",
    "Continue",
    "Reset",
]

ANSI = re.compile(rb"\x1b\[[0-9;]*[A-Za-z]")


def stty():
    subprocess.run(f"stty -F {DEV} {BAUD} raw -echo", shell=True, check=False)


def send(data: bytes):
    with open(DEV, "wb", buffering=0) as f:
        f.write(data)


def key(seq: str, wait: float = 0.45):
    send(seq.encode("latin1").decode("unicode_escape").encode("latin1"))
    time.sleep(wait)


def capture(seconds: float, keys=()) -> bytes:
    """开一个后台 cat 收串口，期间发 keys，最后返回原始字节。"""
    cap = "/tmp/serial-cli-cap.bin"
    p = subprocess.Popen(
        f"timeout {seconds + 3} cat {DEV} > {cap} 2>/dev/null", shell=True
    )
    time.sleep(0.35)
    stty()
    for k in keys:
        key(k)
    time.sleep(seconds)
    p.kill()
    p.wait()
    try:
        return open(cap, "rb").read()
    except FileNotFoundError:
        return b""


def plain(raw: bytes) -> str:
    """剥掉 ANSI 与不可打印字符。"""
    t = ANSI.sub(b"", raw).decode("latin1")
    return "".join(c for c in t if c in "\n\r\t" or ord(c) >= 32)


def vt_segments(raw: bytes):
    """极简 VT 解析：返回每段文字的 (行, 列, 前景, 背景, 文本)。

    UiApp 用反色表示高亮项：前景 37 + 背景 40。**`>` 是子菜单标记，不是光标**，
    旧版靠 `>` 前缀判断会把项认错。"""
    row = col = 1
    fg, bg = 30, 47
    segs = []
    buf = ""
    s = raw.decode("latin1")
    i = 0

    def flush():
        nonlocal buf
        if buf.strip():
            segs.append((row, col - len(buf), fg, bg, buf))
        buf = ""

    while i < len(s):
        c = s[i]
        if c == "\x1b" and i + 1 < len(s) and s[i + 1] == "[":
            m = re.match(r"\x1b\[([0-9;]*)([A-Za-z])", s[i:])
            if not m:
                i += 1
                continue
            flush()
            a, op = m.group(1), m.group(2)
            nums = [int(x) if x else 0 for x in a.split(";")] if a else []
            if op == "H":
                row = nums[0] if nums else 1
                col = nums[1] if len(nums) > 1 else 1
            elif op == "C":
                col += nums[0] if nums else 1
            elif op == "D":
                col -= nums[0] if nums else 1
            elif op == "m":
                for n in nums or [0]:
                    if n == 0:
                        fg, bg = 37, 40
                    elif 30 <= n <= 37:
                        fg = n
                    elif 40 <= n <= 47:
                        bg = n
            i += len(m.group(0))
        elif c == "\r":
            col = 1
            i += 1
        elif c == "\n":
            row += 1
            i += 1
        elif ord(c) >= 32:
            buf += c
            col += 1
            i += 1
        else:
            i += 1
    flush()
    return segs


def highlighted_raw(raw: bytes):
    """原始字节里，当前高亮的 UiApp 菜单项（没认出来返回 None）。

    按「行」建模：UiApp 的高亮是反色（fg37/bg40），但落点不固定——
      * 普通项（Device Manager 等）：标签本身反色；
      * 首项 Select Language：标签是正常色，反色的是同一行的值 `<English>`。
    所以同一行上标签或 `<…>` 值任何一个反色，这一行就算高亮；后画的覆盖先画的
    （按键后 UiApp 会把旧高亮行用正常色重画、新行用反色重画）。帮助栏
    （`^v=Move Highlight`、`<Enter>=Select Entry`）也是反色，要排除。"""
    state = {}
    order = 0
    for r, _c, f, b, t in vt_segments(raw):
        txt = t.strip().lstrip("> ").strip()
        rev = (f, b) == (37, 40)
        if "=" in txt and rev:  # 帮助栏
            continue
        item = next((it for it in ITEMS if txt.startswith(it)), None)
        st = state.setdefault(r, {"label": None, "rl": False, "rv": False, "t": 0})
        if item:
            st["label"], st["rl"] = item, rev
        elif txt.startswith("<") and txt.endswith(">"):
            st["rv"] = rev
        else:
            continue
        order += 1
        st["t"] = order
    hits = [st for st in state.values() if st["label"] and (st["rl"] or st["rv"])]
    return max(hits, key=lambda st: st["t"])["label"] if hits else None


def selftest():
    """不需要板子：用合成的 VT 帧 + 保存的真板日志验证高亮识别。"""
    N, REV = "\x1b[30;47m", "\x1b[37;40m"

    def at(r, c, style, text):
        return f"\x1b[{r};{c}H{style}{text}"

    def frame(sel):
        # 和真板日志里的布局一致：r08 Select Language(+<English>)，r10-12 子菜单，r14 Continue，r15 Reset
        rows = [(8, "Select Language", "<English>"), (10, "> Device Manager", None),
                (11, "> Boot Manager", None), (12, "> Boot Maintenance Manager", None),
                (14, "Continue", None), (15, "Reset", None)]
        out = ""
        for r, label, val in rows:
            on = label.lstrip("> ") == sel
            if val:  # 首项：标签正常色，值反色（和真板日志一致）
                out += at(r, 81, N, label) + at(r, 111, REV if on else N, val)
            else:
                out += at(r, 4, REV if on else N, label)
        out += at(23, 3, REV, "^v=Move Highlight") + at(23, 27, REV, "<Enter>=Select Entry")
        return out.encode()

    ok = True
    for sel in ["Select Language", "Device Manager", "Boot Manager", "Boot Maintenance Manager", "Continue", "Reset"]:
        got = highlighted_raw(frame(sel))
        ok &= got == sel
        print(f"  帧 {sel!r:30} -> {got!r:30} {'ok' if got == sel else 'FAIL'}")
    # 按 Down：旧项用正常色重画、新项用反色重画（两帧拼起来，后者覆盖前者）
    got = highlighted_raw(frame("Select Language") + frame("Device Manager"))
    ok &= got == "Device Manager"
    print(f"  Down 之后（两帧拼接）-> {got!r} {'ok' if got == 'Device Manager' else 'FAIL'}")
    # 只重画了变化的两行（常见的增量重绘）
    inc = at(8, 111, N, "<English>") + at(10, 4, REV, "Device Manager")
    got = highlighted_raw(frame("Select Language") + inc.encode())
    ok &= got == "Device Manager"
    print(f"  增量重绘            -> {got!r} {'ok' if got == 'Device Manager' else 'FAIL'}")
    # 没有菜单的纯日志
    got = highlighted_raw(b"UNIXNU: menu: shown 2 entries\r\n")
    ok &= got is None
    print(f"  纯日志              -> {got!r} {'ok' if got is None else 'FAIL'}")
    # 真板保存的日志（首项高亮）
    here = os.path.dirname(os.path.abspath(__file__))
    real = os.path.join(here, "ser-uefi-first-boot.log")
    if os.path.exists(real):
        got = highlighted_raw(open(real, "rb").read())
        ok &= got == "Select Language"
        print(f"  真板日志 first-boot -> {got!r} {'ok' if got == 'Select Language' else 'FAIL'}")
    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def highlighted(txt: str):
    """（旧，兜底）剥掉 ANSI 之后按 '>' 前缀猜。不可靠，优先用 highlighted_raw。"""
    hits = []
    for m in re.finditer(r">\s*([A-Z][A-Za-z ]{3,40}?)\s{2,}", txt):
        name = m.group(1).strip()
        for it in ITEMS:
            if name.startswith(it):
                hits.append(it)
    return hits[-1] if hits else None


def usb_4d00_stable(need: int = 5, interval: float = 0.2, limit: float = 12.0) -> bool:
    """U-Boot fastboot（18d1:4d00）连续 need 次轮询都在，才算稳定。"""
    n = 0
    end = time.time() + limit
    while time.time() < end:
        out = subprocess.run(["lsusb"], capture_output=True, text=True).stdout
        n = n + 1 if "18d1:4d00" in out else 0
        if n >= need:
            return True
        time.sleep(interval)
    return False


def ctrlc_burst(n: int, interval: float = 0.1, tail: float = 2.0) -> bytes:
    """Ctrl+C 突发：单个 fd、间隔 interval，同时后台抓串口。

    实测配方（2026-10-27）：U-Boot 的 fastboot 稳定在 18d1:4d00 之后，25 次 x 100 ms
    就能抢到 `=>`。每次重开串口 + 0.45 s 间隔（旧 key()）会让 Linux 照常起来；
    400 次 x 50 ms 又会让 U-Boot 进复位环、USB 和串口一起消失。"""
    cap = "/tmp/serial-cli-cap.bin"
    p = subprocess.Popen(
        f"timeout {n * interval + tail + 3} cat {DEV} > {cap} 2>/dev/null", shell=True
    )
    time.sleep(0.35)
    fd = os.open(DEV, os.O_WRONLY | os.O_NOCTTY)
    try:
        for _ in range(n):
            os.write(fd, b"\x03")
            time.sleep(interval)
    finally:
        os.close(fd)
    time.sleep(tail)
    p.kill()
    p.wait()
    try:
        return open(cap, "rb").read()
    except FileNotFoundError:
        return b""


def goto_reset(max_tries: int = 8):
    """UiApp 的 Reset 项。走完就等于一次人工断电重启，但不用人动手。

    严格模式：必须**亲眼确认**（反色高亮）停在 Reset 才按回车；确认不了就退出，
    不会对一个不知道是什么的菜单项盲按 Enter。"""
    for attempt in range(max_tries):
        raw = capture(1.0, ["\\033"])  # Esc 先关掉可能开着的下拉框，同时逼 UiApp 重绘
        cur = highlighted_raw(raw)
        print(f"[{attempt}] highlight={cur}", file=sys.stderr)
        if cur == "Reset":
            break
        if cur is None:
            continue
        n = (len(ITEMS) - 1 - ITEMS.index(cur)) % len(ITEMS)
        for _ in range(n):
            key("\\033[B", 0.3)
        time.sleep(0.5)
    else:
        sys.exit("没能确认高亮停在 Reset（屏幕上没认出 UiApp 菜单？），不按回车")
    key("\\r", 0.5)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "screen"
    if cmd != "selftest":
        stty()

    if cmd == "selftest":
        sys.exit(selftest())
    if cmd == "screen":
        raw = capture(1.2)
        t = plain(raw)
        print("highlight:", highlighted_raw(raw) or highlighted(t))
        print(t[-600:])
    elif cmd in ("down", "up"):
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 1
        seq = "\\033[B" if cmd == "down" else "\\033[A"
        raw = capture(1.2, [seq] * n)
        print("highlight:", highlighted_raw(raw) or highlighted(plain(raw)))
    elif cmd == "enter":
        print(plain(capture(2.0, ["\\r"]))[-600:])
    elif cmd == "esc":
        raw = capture(1.2, ["\\033"])
        print("highlight:", highlighted_raw(raw) or highlighted(plain(raw)))
    elif cmd == "reset":
        goto_reset()
        print(plain(capture(6.0))[-600:])
    elif cmd == "ctrlc":
        args = [a for a in sys.argv[2:] if a != "--force"]
        force = "--force" in sys.argv[2:]
        n = int(args[0]) if args else 25
        if n > 40:
            sys.exit("拒绝：Ctrl+C 超过 40 次（400 次 x 50 ms 弄死过板子）")
        if not force and not usb_4d00_stable():
            sys.exit("拒绝：USB 里没有稳定的 18d1:4d00。Ctrl+C 只在 U-Boot fastboot 稳定之后发"
                     "（先 adb reboot bootloader）；确实要发加 --force")
        t = plain(ctrlc_burst(n))
        print(t[-400:])
        print("has =>:", "=>" in t)
    elif cmd == "cmd":
        line = sys.argv[2] if len(sys.argv) > 2 else ""
        esc = line.encode("unicode_escape").decode("ascii")
        # 先开抓取、再发命令，回显才不会丢
        print(plain(capture(2.0, [esc + "\\r\\n"]))[-800:])
    elif cmd == "log":
        secs = float(sys.argv[2]) if len(sys.argv) > 2 else 30
        sys.stdout.buffer.write(capture(secs))
    elif cmd == "watch":
        secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60
        print(plain(capture(secs)))
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
