#!/usr/bin/env python3
"""Lay the command buffers and the panel's frames of a scroll-demo run on one time axis.

    python3 tools/xnu-probe/frame_timeline.py TAG [--gesture N] [--slot MS] [--before MS] [--after MS]

Inputs, all in runs/TAG.kernel.log (boot-args mali-timeline=1 and the kernel's "display gaps" lines):
  "mali: user: tl sync U"        the plugin's uptime clock (CLOCK_UPTIME_RAW, microseconds), stamped by the host when the line arrives
  "mali: user: tl t age st gpu ctc rp.dr.kpx [rep.sub.sch.ca.cb];..."   command buffers, times in 100 us (t: commit time on the uptime clock;
                                  the bracketed field, where the commit's time went on the encoding thread and its cores, only in newer logs)
  "evb10: display gaps t+Ns S first=U from=I: g g g ..."   frames the panel showed (S) or swaps handed over (W): first frame's uptime
                                  in microseconds, then the gaps in 100 us (the same clock, as the kernel's mach_absolute_time)
  "evb10: touch: demo gesture N: ..."   the scripted swipes, stamped by the host: put on the uptime clock through the sync lines.

For each gesture, one column per slot (default 16.67 ms, one vsync): F frames shown, c command buffers committed, G the GPU's busy
milliseconds (digit, + for 10 or more).  Under it, the hitches: frame gaps over 25 ms and what the GPU and the committer were doing.
"""
import argparse
import re
import statistics
import sys
from pathlib import Path

RUNS = Path(__file__).resolve().parents[2] / "runs"   # uefi-evb10/runs
HOST = re.compile(r"^\[\s*([\d.]+)\]")


def parse(tag):
    syncs, cbs, frames, swaps, gestures = [], [], [], [], []
    for line in (RUNS / f"{tag}.kernel.log").open(errors="replace"):
        h = HOST.match(line)
        host = float(h.group(1)) if h else None
        m = re.search(r"mali: user: tl sync (\d+)", line)
        if m and host is not None:
            syncs.append((host, int(m.group(1))))
            continue
        m = re.search(r"mali: user: tl (\d[^\n]*)$", line)
        if m:
            for rec in m.group(1).split(";"):
                f = rec.strip().split(" ")
                if len(f) not in (6, 7):
                    continue
                try:
                    t, age, st, gpu, ctc = (int(x) for x in f[:5])
                    rp, dr, kpx = (int(x) for x in f[5].split("."))
                    # newer logs: rep.sub.sch.ca.cb, where the commit's time went before the GPU (100 us) and the cores it began and ended on
                    rep, sub, sch, ca, cb = (int(x) for x in f[6].split(".")) if len(f) == 7 else (None,) * 5
                except ValueError:
                    continue
                cbs.append(dict(t=t * 100, age=age * 100, st=st * 100 if st >= 0 else None, gpu=gpu * 100, ctc=ctc * 100, rp=rp, dr=dr, kpx=kpx,
                                rep=rep * 100 if rep is not None else None, sub=sub * 100 if sub is not None else None,
                                sch=sch * 100 if sch is not None and sch >= 0 else None, ca=ca, cb=cb))
            continue
        m = re.search(r"evb10: display gaps t\+(\d+)s ([SW]) first=(\d+) from=(\d+):((?: \d+)+)", line)
        if m:
            kind, first, start = m.group(2), int(m.group(3)), int(m.group(4))
            gaps = [int(x) * 100 for x in m.group(5).split()]
            (frames if kind == "S" else swaps).append((int(m.group(1)), first, start, gaps))
            continue
        m = re.search(r"evb10: touch: demo gesture (\d+): (.*)$", line)
        if m and host is not None:
            gestures.append((host, int(m.group(1)), m.group(2).strip()))
    return syncs, cbs, frames, swaps, gestures


def frame_times(reports):
    """Absolute uptime (us) of every frame, from the 'display gaps' lines of one kind."""
    out = []
    by_window = {}
    for window, first, start, gaps in reports:
        w = by_window.setdefault((window, first), {})
        w[start] = gaps
    for (window, first), parts in sorted(by_window.items(), key=lambda kv: kv[0][1]):
        t = first
        out.append(t)
        for start in sorted(parts):
            for g in parts[start]:
                t += g
                out.append(t)
    return sorted(set(out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("--gesture", type=int, default=None)
    ap.add_argument("--slot", type=float, default=16.667)
    ap.add_argument("--before", type=float, default=100)
    ap.add_argument("--after", type=float, default=2400)
    ap.add_argument("--hitch", type=float, default=25.0)
    ap.add_argument("--quiet", action="store_true", help="no slot maps, only the per-gesture summary and hitches")
    args = ap.parse_args()
    syncs, cbs, frames, swaps, gestures = parse(args.tag)
    print(f"{args.tag}: {len(syncs)} sync lines, {len(cbs)} command buffers, {sum(len(r[3]) + 1 for r in frames)} shown-frame gaps, {len(gestures)} gestures")
    if not syncs or not cbs or not frames:
        sys.exit("missing timeline data (boot-args mali-timeline=1, a kernel with the 'display gaps' lines)")
    # host time -> uptime: the sync line is stamped when it arrives, a little after the plugin read the clock
    offsets = [u - h * 1e6 for h, u in syncs]
    offset = statistics.median(offsets)
    spread = max(offsets) - min(offsets)
    print(f"host->uptime offset {offset / 1e6:.3f} s (sync lines spread {spread / 1000:.1f} ms)")
    shown = frame_times(frames)
    print(f"frames shown: {len(shown)}, command buffers: {len(cbs)}")
    slot = args.slot * 1000
    for host, index, what in gestures:
        if args.gesture is not None and index != args.gesture:
            continue
        t0 = host * 1e6 + offset
        lo, hi = t0 - args.before * 1000, t0 + args.after * 1000
        n = int((hi - lo) / slot) + 1
        fr = [0] * n
        cm = [0] * n
        gp = [0.0] * n
        for t in shown:
            if lo <= t < hi:
                fr[int((t - lo) / slot)] += 1
        win_cbs = [c for c in cbs if lo <= c["t"] < hi]
        for c in win_cbs:
            cm[int((c["t"] - lo) / slot)] += 1
            if c["st"] is not None and c["gpu"]:
                b, e = c["t"] + c["st"], c["t"] + c["st"] + c["gpu"]
                s = b
                while s < e and lo <= s < hi:
                    k = int((s - lo) / slot)
                    cut = min(e, lo + (k + 1) * slot)
                    gp[k] += (cut - s) / 1000
                    s = cut
        fshow = "".join("." if x == 0 else ("F" if x == 1 else "2" if x == 2 else "+") for x in fr)
        cshow = "".join("." if x == 0 else str(min(x, 9)) for x in cm)
        gshow = "".join("." if x < 0.5 else (str(int(x)) if x < 10 else "+") for x in gp)
        print(f"\ngesture {index} ({what}) at uptime {t0 / 1e6:.3f} s; slot {args.slot:.2f} ms, from {-args.before:.0f} ms")
        for i in range(0, 0 if args.quiet else n, 90):
            print(f"  {i * args.slot - args.before:7.0f} ms  F {fshow[i:i + 90]}")
            print(f"  {'':10}  c {cshow[i:i + 90]}")
            print(f"  {'':10}  G {gshow[i:i + 90]}")
        wf = [t for t in shown if lo <= t < hi]
        gaps = [(b - a, a) for a, b in zip(wf, wf[1:])]
        long = [(g, a) for g, a in gaps if g > args.hitch * 1000]
        gpu_total = sum(c["gpu"] for c in win_cbs) / 1000
        print(f"  frames {len(wf)}, command buffers {len(win_cbs)}, GPU {gpu_total:.0f} ms, hitches (> {args.hitch:.0f} ms): {len(long)}")
        for g, a in long:
            # what the committer and the GPU did across the gap
            inside = [c for c in cbs if a - 0.02e6 <= c["t"] < a + g]
            busy = sum(c["gpu"] for c in inside) / 1000
            big = max(inside, key=lambda c: c["gpu"], default=None)
            print(f"    gap {g / 1000:6.1f} ms at +{(a - t0) / 1000:7.1f} ms: {len(inside):3d} CBs committed, GPU {busy:6.1f} ms"
                  + (f", biggest rp{big['rp']} gpu {big['gpu'] / 1000:.1f} ms ctc {big['ctc'] / 1000:.1f} ms age {big['age'] / 1000:.1f} ms" if big else ""))


if __name__ == "__main__":
    main()
