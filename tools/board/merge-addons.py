#!/usr/bin/env python3
"""Merge payload addons (NGPUADD2, the format of UniXNU's scripts/make-gpu-addon.py) into one.

  merge-addons.py OUTPUT INPUT...

`unixnu build payload --gpu-addon FILE` takes one file; the Metal plugin's addon (MaliMetal) and the audio plug-in's (UniXNU-evb10
scripts/build-evb10-audio-hal.py) are built apart. The files keep their order and their compressed streams; a path in two inputs is an
error (the kernel writes each path once)."""
import struct
import sys
from pathlib import Path


def entries(path):
    data = Path(path).read_bytes()
    if len(data) < 24 or data[:8] != b'NGPUADD2':
        sys.exit('%s: not an NGPUADD2 addon' % path)
    count, _zero, total = struct.unpack_from('<IIQ', data, 8)
    if total != len(data):
        sys.exit('%s: the header says %d bytes, the file has %d' % (path, total, len(data)))
    at = 24
    for _ in range(count):
        name_bytes, _mode, _size, packed = struct.unpack_from('<IIQQ', data, at)
        start = at
        at += 24
        name = data[at:at + name_bytes - 1].decode()
        at += (name_bytes + 7) & ~7
        at += (packed + 7) & ~7
        yield name, data[start:at]
    if at != len(data):
        sys.exit('%s: trailing bytes after the last file' % path)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    seen = {}
    body = b''
    for path in sys.argv[2:]:
        for name, raw in entries(path):
            if name in seen:
                sys.exit('%s: %s is already in %s' % (path, name, seen[name]))
            seen[name] = path
            body += raw
    blob = b'NGPUADD2' + struct.pack('<IIQ', len(seen), 0, 24 + len(body)) + body
    Path(sys.argv[1]).write_bytes(blob)
    print('%s: %d files, %d bytes' % (sys.argv[1], len(seen), len(blob)))


if __name__ == '__main__':
    main()
