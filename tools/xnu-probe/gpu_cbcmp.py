#!/usr/bin/env python3
"""Per render-pass-count medians of the command buffers' GPU time ('status: K' rows), run against run.

  python3 tools/xnu-probe/gpu_cbcmp.py TAG TAG... [MIN_N]

A K row: `status: K<idx> t=<s> rp<N> dr<N> kpx<N> cs<N> bl<N> ctc=<us> gpu=<us> st=<us>`; `gpu` is the command buffer's
GPU time, `ctc` commit-to-callback. Groups the rows of each run by render passes (rp) and prints count, median and
p90 of gpu (ms), so the same kind of frame is compared across runs (the plain median of all rows depends on the mix).
"""
import re
import statistics
import sys
from pathlib import Path

RUNS = Path(__file__).resolve().parents[2] / "runs"   # uefi-evb10/runs
KLINE = re.compile(r'status: K\d+ t=([\d.]+)s rp(\d+) dr(\d+) kpx(\d+) cs\d+ bl\d+\s+ctc=(\d+)us gpu=(\d+)us st=(\d+)us')


def load(tag):
    groups = {}
    seen = set()   # a status row lists the last three command buffers again until a new one is committed: count each (t=) once
    for line in (RUNS / f'{tag}.kernel.log').open(errors='replace'):
        m = KLINE.search(line)
        if m:
            key = m.group(1)
            if key in seen:
                continue
            seen.add(key)
            rp, dr, gpu, ctc = int(m.group(2)), int(m.group(3)), int(m.group(6)), int(m.group(5))
            groups.setdefault(rp, []).append((gpu, ctc, dr))
    return groups


def p90(v):
    v = sorted(v)
    return v[min(len(v) - 1, int(0.9 * len(v)))]


def main():
    tags = [a for a in sys.argv[1:] if not a.isdigit()]
    min_n = next((int(a) for a in sys.argv[1:] if a.isdigit()), 2)
    data = {t: load(t) for t in tags}
    rps = sorted({rp for g in data.values() for rp, rows in g.items() if len(rows) >= min_n})
    head = f"{'rp':>3} " + ' | '.join(f"{t:^26}" for t in tags)
    print(head)
    print(f"{'':>3} " + ' | '.join(f"{'n   gpu med/p90  ctc med':^26}" for _ in tags))
    for rp in rps:
        cells = []
        for t in tags:
            rows = data[t].get(rp, [])
            if not rows:
                cells.append(f"{'-':^26}")
                continue
            gpu = [r[0] for r in rows]
            ctc = [r[1] for r in rows]
            cells.append(f"{len(rows):>3} {statistics.median(gpu)/1000:6.1f}/{p90(gpu)/1000:5.1f} {statistics.median(ctc)/1000:7.1f}")
        print(f"{rp:>3} " + ' | '.join(f"{c:<26}" for c in cells))
    for t in tags:
        rows = [r for g in data[t].values() for r in g]
        gpu = [r[0] for r in rows]
        print(f"{t}: {len(rows)} CBs, total gpu {sum(gpu)/1000:.0f} ms, mean {sum(gpu)/len(gpu)/1000:.2f} ms")


if __name__ == '__main__':
    main()
