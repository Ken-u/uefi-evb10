#!/usr/bin/env python3
"""Frames per second the panel got while the finger was down (the demo's 0.8 s swipe) and while the animation settled, per gesture.

    python3 tools/xnu-probe/frame_phases.py TAG [TAG...]
"""
import statistics
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import frame_timeline as tl


def run(tag):
    syncs, cbs, frames, swaps, gestures = tl.parse(tag)
    off = statistics.median([u - h * 1e6 for h, u in syncs])
    shown = tl.frame_times(frames)
    rows = []
    for host, index, what in gestures:
        t0 = host * 1e6 + off
        down = [t for t in shown if t0 + 0.05e6 <= t < t0 + 0.85e6]
        settle = [t for t in shown if t0 + 0.85e6 <= t < t0 + 2.0e6]
        # the settle phase ends at the last frame before a 250 ms silence
        end = None
        last = None
        for t in settle:
            if last is not None and t - last > 250e3:
                break
            last = t
        settle = [t for t in settle if last is None or t <= last]
        cb_down = [c for c in cbs if t0 + 0.05e6 <= c['t'] < t0 + 0.85e6]
        gpu_down = sum(c['gpu'] for c in cb_down) / 1000
        gaps = [(b - a) / 1000 for a, b in zip(down, down[1:])]
        rows.append((index, what, len(down) / 0.8, len(settle), gpu_down / 800 * 100, statistics.mean(gaps) if gaps else 0,
                     len([g for g in gaps if g > 25]), len(cb_down), statistics.median([c['gpu'] for c in cb_down]) / 1000 if cb_down else 0))
    return rows


for tag in sys.argv[1:]:
    print(f"{tag}: per gesture, finger down (0.8 s): fps, mean gap ms, gaps > 25 ms; GPU busy %, CBs, median CB gpu ms; settle: frames")
    rows = run(tag)
    for index, what, fps, nsettle, busy, mean, slow, ncb, med in rows:
        if fps == 0 and nsettle == 0:
            continue
        print(f"  g{index:2d} {what:12} {fps:5.1f} fps  gap {mean:5.1f} ms  slow {slow:2d}   GPU {busy:5.1f}%  CBs {ncb:3d} med {med:5.1f} ms   settle {nsettle:3d} frames")
    moving = [r for r in rows if r[2] > 10]
    if moving:
        print(f"  mean over {len(moving)} moving gestures: {statistics.mean(r[2] for r in moving):.1f} fps while the finger is down; median CB gpu {statistics.median(r[8] for r in moving):.1f} ms")
    # The first two gestures (the unlock and the first page) run while the shell is still loading; every run has gestures 3 to 11.
    steady = [r for r in rows if 3 <= r[0] <= 11]
    if steady:
        print(f"  gestures 3-11 ({len(steady)}): {statistics.mean(r[2] for r in steady):.1f} fps, {sum(r[6] for r in steady)} gaps > 25 ms, "
              f"{max(r[2] for r in steady):.1f} fps best, median CB gpu {statistics.median(r[8] for r in steady):.1f} ms")
