#!/usr/bin/env python3
"""Summarize the Mesa shader-db lines of a board run (boot-arg mali-bifrost-debug=shaderdb).

    python3 tools/xnu-probe/gpu_shaderdb.py TAG [TOP]

Line format (one per compiled shader, printed by the render server's compiler):
  mali: user: MESA_SHADER_FRAGMENT shader: 26 instrs, 2.000000 cycles, 0.031250 fma, ..., 256 code size, 2 threads, 0 loops, 0:0 spill
"""
import re
import sys
from pathlib import Path

tag = sys.argv[1]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 12
log = Path(__file__).resolve().parents[2] / "runs" / f"{tag}.kernel.log"   # uefi-evb10/runs
pat = re.compile(
    r"^\[\s*([\d.]+)\] mali: user: (MESA_SHADER_\w+) shader: (\d+) instrs, ([\d.]+) cycles, "
    r"([\d.]+) fma, ([\d.]+) cvt, ([\d.]+) sfu, ([\d.]+) v, ([\d.]+) t, ([\d.]+) ls, (\d+) code size, (\d+) threads, (\d+) loops, (\d+):(\d+) spill"
)
rows = []
for line in log.read_text(errors="replace").splitlines():
    m = pat.match(line)
    if m:
        g = m.groups()
        rows.append(
            dict(t=float(g[0]), stage=g[1][len("MESA_SHADER_"):], instrs=int(g[2]), cycles=float(g[3]), tex=float(g[8]),
                 code=int(g[10]), threads=int(g[11]), spill=f"{g[13]}:{g[14]}")
        )
print(f"{tag}: {len(rows)} shaders")
for stage in sorted({r['stage'] for r in rows}):
    rs = [r for r in rows if r['stage'] == stage]
    rs.sort(key=lambda r: -r['cycles'])
    print(f"  {stage}: n={len(rs)} sum cycles={sum(r['cycles'] for r in rs):.1f} sum instrs={sum(r['instrs'] for r in rs)}")
    for r in rs[:top]:
        print(f"    t={r['t']:8.3f}  instrs {r['instrs']:6d}  cycles {r['cycles']:8.2f}  tex {r['tex']:6.2f}  code {r['code']:7d} B  threads {r['threads']}  spill {r['spill']}")
