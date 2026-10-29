#!/usr/bin/env python3
"""Render passes of the heavy command buffers of a `mali-trace=print` run ("gt R WxH rtN FORMAT tileT Nus" lines, then "gt cb ...").

    python3 tools/xnu-probe/gpu_passes.py TAG [--min-passes 14] [--max-passes 99] [--show 3]

Groups the command buffers by their pass count and, for each group, prints the mean GPU time of every pass by position (size, targets, format), so
the pass that makes a frame heavy shows up. Also the group's mean CB time and how much of it the passes explain.
"""
import argparse
import re
import statistics
from collections import defaultdict
from pathlib import Path

RUNS = Path(__file__).resolve().parents[2] / "runs"   # uefi-evb10/runs
R = re.compile(r"mali: user: gt R (\d+)x(\d+) rt(\d+) (\S+) tile(\d+) (\d+)us")
CB = re.compile(r"mali: user: gt cb (\d+)us: (\d+) passes/(\d+)us \(longest (\d+)us (\d+)x(\d+)\) wait (\d+)us flush (\d+)us barrier (\d+)us")
OTHER = re.compile(r"mali: user: gt (dispatch|meta|barrier|wait) (\d+)us")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("--min-passes", type=int, default=14)
    ap.add_argument("--max-passes", type=int, default=99)
    ap.add_argument("--show", type=int, default=3, help="print this many example command buffers per group")
    args = ap.parse_args()
    cbs = []
    cur = []
    for line in (RUNS / f"{args.tag}.kernel.log").open(errors="replace"):
        m = R.search(line)
        if m:
            w, h, rt, fmt, tile, us = m.groups()
            cur.append((int(w), int(h), int(rt), fmt, int(us)))
            continue
        m = CB.search(line)
        if m:
            # the numbers of the cb line itself are unreliable (a flush time that underflows); the passes before it are the command buffer's
            cbs.append(dict(n=len(cur), passes_us=sum(p[4] for p in cur), passes=cur))
            cur = []
    print(f"{args.tag}: {len(cbs)} command buffers with a trace; pass counts: "
          + ", ".join(f"{n}:{c}" for n, c in sorted(((n, sum(1 for c in cbs if c['n'] == n)) for n in {c['n'] for c in cbs}))[:30]))
    groups = defaultdict(list)
    for c in cbs:
        if args.min_passes <= c["n"] <= args.max_passes and len(c["passes"]) == c["n"]:
            groups[c["n"]].append(c)
    for n, rows in sorted(groups.items()):
        shapes = [tuple(p[:4]) for p in rows[0]["passes"]]
        same = [r for r in rows if [tuple(p[:4]) for p in r["passes"]] == shapes]
        print(f"\n{n} passes: {len(rows)} command buffers ({len(same)} with the same pass shapes); the passes' GPU time sums to {statistics.mean(r['passes_us'] for r in rows) / 1000:.1f} ms")
        for i, shape in enumerate(shapes):
            us = [r["passes"][i][4] for r in same]
            print(f"   #{i:2d} {shape[0]:5d}x{shape[1]:<5d} rt{shape[2]} {shape[3]:22s} mean {statistics.mean(us):7.0f} us  min {min(us):6d}  max {max(us):6d}")
    if not groups:
        print("no group; try --min-passes lower")


if __name__ == "__main__":
    main()
