#!/usr/bin/env python3
"""One row per run, from the plugin's command-buffer timeline (boot-arg mali-timeline=1).

    cb_table.py TAG [TAG...] [--split N] [--latency]

Heavy command buffers are the ones with at least 50 draws (the render server's frames while a page scrolls).  Per run:

  ctc p50 / p90 / p99   commit to completion handler, ms
  >19.3ms               share of them that took longer than a frame can (two vsyncs minus the render server's 14 ms offset: it misses V+2)
  rep p50 / p90         commit until the encode thread has replayed the recorded Metal calls, ms
  on A55                how many of them began their replay on a logical CPU of 4 or more (the Cortex-A55s when the device tree lists the A76s first)
  gpu50 / sub50         the GPU's time and the encode thread's record+submit time, median, ms

--split N prints N slices of each run (equal numbers of command buffers, in time order) instead of the whole (a soak test: does it get slower?).
--latency adds, for the demo gestures from the third on (touch driver boot-arg evb10-touch-demo), the time from the touch to the first command buffer
and to the first frame of a run of frames at most 20 ms apart, for left and right swipes.
"""
import argparse
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import frame_timeline as ft  # noqa: E402


def q(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else float("nan")


def table(tags, split):
    print("%-8s %5s %7s %7s %7s %8s %7s %8s %9s %6s %6s" % ("run", "CBs", "ctc p50", "p90", "p99", ">19.3ms", "rep p50", "rep p90", "on A55", "gpu50", "sub50"))
    for tag in tags:
        try:
            _, cbs, _, _, _ = ft.parse(tag)
        except OSError as e:
            print(tag, "no log:", e)
            continue
        heavy_all = [c for c in cbs if c["dr"] >= 50]
        n = len(heavy_all)
        parts = [("%s/%d" % (tag, i + 1), heavy_all[i * n // split:(i + 1) * n // split]) for i in range(split)] if split > 1 else [(tag, heavy_all)]
        for label, heavy in parts:
            row(label, heavy)


def row(tag, heavy):
    ctc = [c["ctc"] / 1000 for c in heavy if c.get("ctc") is not None]
    rep = [c["rep"] / 1000 for c in heavy if c.get("rep") is not None]
    gpu = [c["gpu"] / 1000 for c in heavy if c.get("gpu") is not None]
    sub = [c["sub"] / 1000 for c in heavy if c.get("sub") is not None]
    if not ctc:
        print(tag, "no heavy command buffers (mali-timeline=1?)")
        return
    a55 = sum(1 for c in heavy if c.get("ca") is not None and c["ca"] >= 4)
    over = sum(1 for x in ctc if x > 19.3)
    print("%-8s %5d %7.1f %7.1f %7.1f %7.1f%% %7.1f %8.1f %5d/%-4d %6.1f %6.1f" % (
        tag, len(heavy), statistics.median(ctc), q(ctc, .9), q(ctc, .99), 100 * over / len(ctc), statistics.median(rep) if rep else float("nan"),
        q(rep, .9), a55, len(heavy), statistics.median(gpu), statistics.median(sub) if sub else float("nan")))


def latency(tags):
    for tag in tags:
        try:
            syncs, cbs, frames, _, gestures = ft.parse(tag)
        except OSError:
            continue
        if not syncs or not frames:
            continue
        offset = statistics.median([u - h * 1e6 for h, u in syncs])    # kernel uptime -> the plugin's clock
        shown = ft.frame_times(frames)
        first_frame = {"left": [], "right": []}
        first_cb = {"left": [], "right": []}
        for host, index, what in gestures:
            if index < 3 or "up" in what:
                continue
            key = "left" if "left" in what else "right"
            t0 = host * 1e6 + offset
            later = [t for t in shown if t >= t0]
            start = None
            for i in range(len(later) - 6):
                if max(later[i + k + 1] - later[i + k] for k in range(5)) <= 20000:
                    start = (later[i] - t0) / 1000
                    break
            first_frame[key].append(start)
            cb = [c["t"] for c in cbs if c["t"] >= t0]
            first_cb[key].append((cb[0] - t0) / 1000 if cb else None)

        def show(values):
            values = [v for v in values if v is not None]
            return "median %4.0f ms %s" % (statistics.median(values), [round(v) for v in values]) if values else "-"

        print(f"{tag}: touch -> first command buffer: left {show(first_cb['left'])} | right {show(first_cb['right'])}")
        print(f"{'':{len(tag)}}  touch -> first animated frame: left {show(first_frame['left'])} | right {show(first_frame['right'])}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tags", nargs="+")
    ap.add_argument("--latency", action="store_true")
    ap.add_argument("--split", type=int, default=1, metavar="N", help="print N slices of each run (equal numbers of heavy command buffers, in time order): does a long run get slower?")
    args = ap.parse_args()
    table(args.tags, args.split)
    if args.latency:
        print()
        latency(args.tags)


if __name__ == "__main__":
    main()
