#!/usr/bin/env python3
"""Add up the render server's sampling profiler (boot-arg mali-profile=1) over a whole run.

The plugin samples two threads, every mali-profile-us microseconds (default 4000), and every six seconds prints what it saw:
  prof[D] ...  the display thread (com.apple.coreanimation.display.primary: it renders the frame and commits the command buffers)
  prof[E] ...  the thread that replays the recorded Metal calls (native-metal-encode), then submits

Lines whose names the plugin could work out itself (the plugin's own functions, the exported symbols of system libraries) carry integer
percentages of that interval's running samples; this script turns them back into sample counts and adds them up.  The Vulkan driver is
linked without its local symbols, so its lines ("v self": where the sample was; "v outer": the outermost driver frame, the entry point the
plugin called) carry image offsets, which are named here from the linker map of the driver (mesa-build/panvk.map).  The plugin's own
functions ("m nearest": the innermost plugin function of a sample; "m incl": every plugin function on its stack) carry the image offset
of the function's start too, so the long Rust names the console lines cannot hold are read from the plugin's symbol table instead
(llvm-nm, demangled with llvm-cxxfilt: LLVM_BIN, or --llvm-bin, names their directory).

    prof_report.py runs/TAG.kernel.log [--map mesa-build/panvk.map] [--plugin PATH] [--from SECONDS --to SECONDS] [--top N]

Seconds are the kernel's uptime stamps at the start of every log line.
"""
import argparse
import bisect
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

# Not anchored at the start of the line: the kernel's own printf (the thread sampler's "evb10: thr ..." lines) and the plugin's lines
# share the console and now and then run together, "... cont 0xfffffff007a630f0 kernmali: user: prof[E]: 61 running ...".
LINE = re.compile(r"mali: user: prof(?:\[(\w)\])?(?: ([^:]+))?: (.*)$")
STAMP = re.compile(r"^\[\s*(\d+\.\d+)\]")
HEADER = re.compile(r"^(\d+) running samples of (\d+) \((.*)\)$")


def load_map(path):
    """(addresses, sizes, names) of the linker map's symbol table, sorted by address."""
    rows = []
    in_symbols = False
    for text in Path(path).read_text(errors="replace").splitlines():
        if text.startswith("# Symbols:"):
            in_symbols = True
            continue
        if not in_symbols or text.startswith("#"):
            continue
        fields = text.split("\t")
        if len(fields) < 3:
            continue
        try:
            address = int(fields[0], 16)
            size = int(fields[1], 16)
        except ValueError:
            continue
        name = fields[2].split("]", 1)[-1].strip()
        rows.append((address, size, name))
    rows.sort()
    return [r[0] for r in rows], [r[1] for r in rows], [r[2] for r in rows]


def llvm_tool(name, directory):
    """The path of an LLVM tool: in `directory`, in the directories LLVM_BIN lists (whitespace separated), or on PATH."""
    candidates = []
    if directory:
        candidates.append(directory)
    candidates += os.environ.get("LLVM_BIN", "").split()
    for d in candidates + os.environ.get("PATH", "").split(os.pathsep):
        path = Path(d) / name
        if path.exists():
            return str(path)
    return None


def load_plugin(path, nm):
    """(addresses, sizes, names) of the plugin's defined symbols, from llvm-nm; sizes are unknown (0)."""
    out = subprocess.run([nm, "-n", "--defined-only", path], capture_output=True, text=True, errors="replace").stdout
    rows = []
    for text in out.splitlines():
        fields = text.split(None, 2)
        if len(fields) < 3:
            continue
        try:
            rows.append((int(fields[0], 16), 0, fields[2]))
        except ValueError:
            continue
    rows.sort()
    return [r[0] for r in rows], [r[1] for r in rows], [r[2] for r in rows]


def demangle(names, cxxfilt):
    """Rust (v0) and C++ names, readable; Mach-O adds an underscore to every C symbol."""
    if not cxxfilt or not names:
        return {n: n for n in names}
    plain = [n[1:] if n.startswith("_") else n for n in names]
    out = subprocess.run([cxxfilt], input="\n".join(plain) + "\n", capture_output=True, text=True, errors="replace").stdout.splitlines()
    if len(out) != len(names):
        return {n: n for n in names}
    return dict(zip(names, out))


def name_of(table, offset, plain=True):
    """The symbol `offset` is in; `plain` drops the underscores Mach-O puts in front (the plugin's names are kept as they are, to be demangled)."""
    addresses, sizes, names = table
    i = bisect.bisect_right(addresses, offset) - 1
    if i < 0:
        return "?+%#x" % offset
    delta = offset - addresses[i]
    name = names[i].lstrip("_") if plain else names[i]
    if sizes[i] and delta >= sizes[i]:
        # between symbols (padding, or a static function the map did not list): say so
        return "%s+%#x(past end)" % (name, delta)
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log")
    parser.add_argument("--map", default=str(Path(__file__).resolve().parents[3] / "mesa-build" / "panvk.map"))
    parser.add_argument("--from", dest="start", type=float, default=0.0)
    parser.add_argument("--to", dest="end", type=float, default=1e9)
    parser.add_argument("--top", type=int, default=25)
    parser.add_argument("--plugin", default=str(Path(__file__).resolve().parents[3] / "MaliMetal" / "metal-plugin" / "out" / "NativeMaliMetal.bundle" / "NativeMaliMetal"),
                        help="the plugin the run used (its symbol table names the plugin's functions)")
    parser.add_argument("--llvm-bin", default=None, help="directory of llvm-nm and llvm-cxxfilt")
    args = parser.parse_args()

    table = load_map(args.map) if Path(args.map).exists() else None
    if table is None:
        print("no linker map at %s: driver frames stay as offsets" % args.map, file=sys.stderr)
    nm = llvm_tool("llvm-nm", args.llvm_bin)
    cxxfilt = llvm_tool("llvm-cxxfilt", args.llvm_bin)
    plugin = load_plugin(args.plugin, nm) if nm and Path(args.plugin).exists() else None
    if plugin is None:
        print("no llvm-nm or no plugin at %s: plugin frames stay as offsets (--llvm-bin, --plugin)" % args.plugin, file=sys.stderr)

    running = defaultdict(int)       # thread -> running samples
    attempts = defaultdict(int)      # thread -> all samples taken
    intervals = defaultdict(int)
    # (thread, kind) -> name -> sample count
    counts = defaultdict(lambda: defaultdict(float))
    current = {}
    stamp = 0.0
    for raw in open(args.log, errors="replace"):
        text = raw.rstrip("\n")
        s = STAMP.match(text)
        if s:
            stamp = float(s.group(1))
        m = LINE.search(text)
        if not m:
            continue
        thread, kind, body = m.group(1) or "D", m.group(2), m.group(3)
        if not (args.start <= stamp <= args.end):
            continue
        if kind is None:
            h = HEADER.match(body)
            if h:
                current[thread] = int(h.group(1))
                running[thread] += int(h.group(1))
                attempts[thread] += int(h.group(2))
                intervals[thread] += 1
            continue
        total = current.get(thread, 0)
        raw_counts = kind in ("v self", "v outer", "m nearest", "m incl")
        for entry in body.split(" | "):
            entry = entry.strip()
            if not entry:
                continue
            name, _, value = entry.rpartition(" ")
            if not name:
                continue
            if raw_counts:
                try:
                    counts[(thread, kind)][name] += int(value)
                except ValueError:
                    pass
            elif value.endswith("%"):
                try:
                    counts[(thread, kind)][name] += int(value[:-1]) * total / 100.0
                except ValueError:
                    pass

    if not running:
        print("no profiler lines in %s (boot-arg mali-profile=1, and at least 25 running samples in an interval)" % args.log)
        return 1

    names = {"D": "display thread", "E": "encode thread"}
    for thread in sorted(running):
        print("=" * 100)
        print("%s [%s]: %d running samples of %d attempts in %d reports (%.0f%% of the samples found it running)" %
              (names.get(thread, thread), thread, running[thread], attempts[thread], intervals[thread], 100.0 * running[thread] / max(1, attempts[thread])))
        print("(shares are of the running samples; the plugin keeps only the top entries of every 6 s report, so the lists undercount their tails)")
        for kind, title in (("self by image", "self time by image"), ("inclusive images", "inclusive by image"),
                            ("self by function", "self time by function (exported names only; <redacted> = a local symbol of the shared cache)"),
                            ("plugin nearest", "plugin: the nearest plugin function (self + what it calls outside the plugin)"),
                            ("plugin inclusive", "plugin: every plugin function on the stack")):
            rows = counts.get((thread, kind))
            if not rows:
                continue
            print("\n-- %s" % title)
            for name, value in sorted(rows.items(), key=lambda kv: -kv[1])[:args.top]:
                print("  %6.1f%%  %7.0f  %s" % (100.0 * value / running[thread], value, name))
        for kind, title, symbols, source in (
                ("v self", "driver: where the sample was", table, "linker map"),
                ("v outer", "driver: the outermost driver frame (the entry point called)", table, "linker map"),
                ("m nearest", "plugin: the innermost plugin function of the sample", plugin, "plugin symbols"),
                ("m incl", "plugin: every plugin function on the stack", plugin, "plugin symbols")):
            rows = counts.get((thread, kind))
            if not rows:
                continue
            merged = defaultdict(float)
            for offset, value in rows.items():
                try:
                    merged[name_of(symbols, int(offset, 16), symbols is not plugin) if symbols else offset] += value
                except ValueError:
                    merged[offset] += value
            top = sorted(merged.items(), key=lambda kv: -kv[1])[:args.top]
            shown = demangle([n for n, _ in top], cxxfilt) if symbols is plugin and plugin else {n: n for n, _ in top}
            print("\n-- %s, by function of the %s" % (title, source))
            for name, value in top:
                print("  %6.1f%%  %7.0f  %s" % (100.0 * value / running[thread], value, shown[name][:150]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
