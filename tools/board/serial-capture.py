#!/usr/bin/env python3
"""串口抓取：原样存一份，再存一份「每行前面带相对秒数」的。

    serial-capture.py DEV SECS RAW TS

和原来的 `timeout SECS cat DEV > RAW` 等价（单个读者，不改串口参数——串口参数由调用方
先 `stty -F DEV 1500000 raw -echo`），多写一份 TS：

    [  12.345] DARWINBOOT: hand-off to the kernel
    [ 100.020] DDR c82c943893 cym 26/01/23-15:55:28,fwver: v1.23

为什么要有它：板子上现在看不到显示器，内核入口探针（unixnu-rk3588/tools/xnu-probe/）靠
「板子在 ExitBootServices 之后过多久自己重启」来传信号，所以串口日志必须带时间。
cat 抓出来的日志没有时间，只能事后猜。

时间零点 = 本脚本启动的瞬间（单调时钟）。一行没写完就闲置 0.5 s 的话，先把半行落盘
（行尾标 `⏎` 之外不加东西），后面接着来的字节另起一行、另打时间戳。
"""
import os
import select
import signal
import sys
import time


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    dev, secs, raw_path, ts_path = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
    fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    raw = open(raw_path, "wb", buffering=0)
    ts = open(ts_path, "w", buffering=1, encoding="utf-8", errors="replace")
    t0 = time.monotonic()
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    ts.write("# capture start %s, dev %s, %.0f s\n" % (time.strftime("%F %T"), dev, secs))

    buf = b""
    line_t = 0.0
    # UEFI 自己的 eMMC 初始化抖动（HS400 CRC Error）这一轮就作废了（run-kernel.sh 会自动重跑）：
    # 不必把整个 CAPTURE_SECS 抓完（板子此时已经回 Android，白等几分钟），再抓几秒就收。EARLY_STOP=0 关掉。
    early = os.environ.get("EARLY_STOP", "1") != "0"
    deadline = None

    def clean(b):
        out = []
        for c in b.decode("latin-1"):
            if c == "\r" or c == "\x00":
                continue
            out.append(c if (c == "\t" or " " <= c <= "~") else "?")
        return "".join(out)

    def emit(b, t, partial=False):
        ts.write("[%8.3f] %s%s\n" % (t, clean(b), " ⏎" if partial else ""))

    while not stop:
        now = time.monotonic() - t0
        if now >= secs:
            break
        if deadline is not None and now >= deadline:
            ts.write("# stopped early: UEFI's eMMC init flaked\n")
            break
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 4096)
            except BlockingIOError:
                data = b""
            except OSError as e:
                ts.write("# read error: %s\n" % e)
                break
            if data:
                raw.write(data)
                if not buf:
                    line_t = time.monotonic() - t0
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    emit(line, line_t)
                    if early and deadline is None and b"EmmcSetBusMode: Switch to HS400 CRC Error" in line:
                        deadline = (time.monotonic() - t0) + 8
                    line_t = time.monotonic() - t0
        elif buf and (time.monotonic() - t0 - line_t) > 0.5:
            emit(buf, line_t, partial=True)
            buf = b""
    if buf:
        emit(buf, line_t, partial=True)
    ts.write("# capture end %.3f s, %d raw bytes\n" % (time.monotonic() - t0, os.fstat(raw.fileno()).st_size))
    ts.close()
    raw.close()
    os.close(fd)


if __name__ == "__main__":
    main()
