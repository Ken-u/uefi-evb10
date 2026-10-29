#!/usr/bin/env /usr/bin/python3
"""串口日志里的 `evb10: img SEQ Y X BASE64` 行（内核 evb10-shot-img=N）拼回 PNG。

    shot2png.py LOG [OUTDIR]        # 每个 SEQ 一张：OUTDIR/SEQ.png（默认 /tmp/shots）

每块 60 像素 RGB565（4:1 缩小的帧缓冲），丢了的块留黑并统计。日志可以是 .raw / .ts / .kernel.log
（行里任何位置出现 `evb10: img …` 都认；行被别的输出拼接时按期望长度截取 base64）。
"""
import base64
import re
import sys
from collections import defaultdict
from PIL import Image

CHUNK = 60


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    log = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "/tmp/shots"
    import os
    os.makedirs(out, exist_ok=True)
    size = {}
    rows = defaultdict(dict)
    begin = re.compile(r"evb10: img begin (\d+) (\d+) (\d+)")
    chunk = re.compile(r"evb10: img (\d+) (\d+) (\d+) ([A-Za-z0-9+/=]+)")
    with open(log, "rb") as f:
        for raw in f:
            line = raw.decode("latin-1")
            m = begin.search(line)
            if m:
                size[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
                continue
            for m in chunk.finditer(line):
                seq, y, x0 = int(m.group(1)), int(m.group(2)), int(m.group(3))
                if seq not in size:
                    continue
                ow, oh = size[seq]
                n = min(CHUNK, ow - x0)
                want = ((n * 2 + 2) // 3) * 4
                text = m.group(4)
                if len(text) < want:
                    continue
                try:
                    data = base64.b64decode(text[:want])[: n * 2]
                except Exception:
                    continue
                if len(data) == n * 2:
                    rows[seq][(y, x0)] = data
    for seq, (ow, oh) in sorted(size.items()):
        img = Image.new("RGB", (ow, oh))
        px = img.load()
        have = 0
        for (y, x0), data in rows[seq].items():
            have += 1
            for i in range(len(data) // 2):
                v = (data[2 * i] << 8) | data[2 * i + 1]
                r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
                px[x0 + i, y] = ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
        total = oh * ((ow + CHUNK - 1) // CHUNK)
        path = os.path.join(out, "%d.png" % seq)
        ys = [y for (y, _x) in rows[seq]]
        if ys and (max(ys) - min(ys) + 1) < oh:   # evb10-shot-y / evb10-shot-rows sent only a band: keep the band
            img = img.crop((0, min(ys), ow, max(ys) + 1))
        img.save(path)
        print("%s: %dx%d, %d of %d chunks" % (path, ow, oh, have, total))


if __name__ == "__main__":
    main()
