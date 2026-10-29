#!/usr/bin/env python3
"""U-Boot CLI 助手（在板子宿主机上跑）：
    uboot-cmd.py "cmd1" "cmd2" ...
每条命令发出后一直读到下一个 `=> ` 提示符（或超时），把回显打出来。
环境变量 TO：每条命令的超时秒数（默认 8）。

只在 U-Boot CLI 里用（先用 board-launch.sh 抢到 `=>`）。`fastboot usb 0` 这类
会接管串口的命令没有提示符返回，用 TO=3 让它超时即可。
"""
import os
import re
import select
import subprocess
import sys
import time

DEV = "/dev/ttyUSB0"
subprocess.run(f"stty -F {DEV} 1500000 raw -echo", shell=True, check=False)
fd = os.open(DEV, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)


def drain(t=0.3):
    end = time.time() + t
    out = b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                out += os.read(fd, 65536)
            except BlockingIOError:
                pass
    return out


def run(cmd, timeout=8.0, prompt=b"=> "):
    drain(0.2)
    os.write(fd, (cmd + "\r").encode())
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                buf += os.read(fd, 65536)
            except BlockingIOError:
                pass
            if buf.rstrip().endswith(prompt.rstrip()) and len(buf) > len(cmd):
                time.sleep(0.15)
                buf += drain(0.1)
                break
    t = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", buf).decode("latin1")
    return "".join(c for c in t if c in "\n\r\t" or ord(c) >= 32)


if __name__ == "__main__":
    to = float(os.environ.get("TO", "8"))
    for c in sys.argv[1:]:
        print(run(c, to).replace("\r", ""), end="")
