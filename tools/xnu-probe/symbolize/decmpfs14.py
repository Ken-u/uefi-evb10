#!/usr/bin/env python3
"""decmpfs14.py DECMPFS RSRC OUT: decode a type-14 (LZBITMAP, resource fork) decmpfs file with libzbitmap."""
import ctypes, struct, sys
import os
lib = ctypes.CDLL(os.environ.get('ULAND', '/tmp/uland') + '/libzbitmap/libzbitmap.so')
lib.zbm_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
lib.zbm_decompress.restype = ctypes.c_int

hdr = open(sys.argv[1], 'rb').read()
magic, ctype, size = struct.unpack('<4sIQ', hdr[:16])
assert magic == b'fpmc', magic
assert ctype in (14,), ctype
rsrc = open(sys.argv[2], 'rb').read()
first = struct.unpack_from('<I', rsrc, 0)[0]
n = first // 4 - 1
offs = struct.unpack_from('<%dI' % (n + 1), rsrc, 0)
print('uncompressed', size, 'chunks', n)
CH = 65536
out = open(sys.argv[3], 'wb')
bad = 0
for i in range(n):
    a, b = offs[i], (offs[i + 1] if i + 1 < n + 1 else len(rsrc))
    want = min(CH, size - i * CH)
    src = rsrc[a:b]
    buf = ctypes.create_string_buffer(want + 64)
    outlen = ctypes.c_size_t(0)
    rc = lib.zbm_decompress(buf, want + 64, src, len(src), ctypes.byref(outlen))
    if rc == 0 and outlen.value == want:
        out.write(buf.raw[:want])
    elif len(src) == want + 1 and src[0] == 0xff:      # stored, with a 0xFF marker in front
        out.write(src[1:]); bad += 1
    elif len(src) == want:      # stored
        out.write(src); bad += 1
    else:
        print('chunk', i, 'rc', rc, 'out', outlen.value, 'want', want, 'src', len(src), src[:8].hex())
        raise SystemExit(1)
out.close()
print('done; stored chunks', bad)
