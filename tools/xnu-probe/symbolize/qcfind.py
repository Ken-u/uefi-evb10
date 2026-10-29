#!/usr/bin/env python3
"""qcfind.py IMAGE-SUBSTR STRING...  -> find cstring, cfstring objects and the code that references them (adrp+add)."""
import sys, struct
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dsc

def scan_refs(c, base, segs, targets):
    # code refs: adrp xN,page ; add xM,xN,#imm  (within next 8 insns)
    res = {}
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if name not in ('__TEXT',):
            continue
        raw = c.read(vmaddr, vmsize)
        n = len(raw) // 4
        words = struct.unpack_from('<%dI' % n, raw, 0)
        for i, w in enumerate(words):
            if (w & 0x9f000000) == 0x90000000:
                rd = w & 31
                immlo = (w >> 29) & 3
                immhi = (w >> 5) & 0x7ffff
                imm = (immhi << 2) | immlo
                if imm & (1 << 20): imm -= 1 << 21
                pc = vmaddr + i * 4
                page = (pc & ~0xfff) + (imm << 12)
                for j in range(i + 1, min(i + 9, n)):
                    x = words[j]
                    if (x & 0xffc00000) == 0x91000000 and ((x >> 5) & 31) == rd:
                        t = page + ((x >> 10) & 0xfff)
                        if t in targets:
                            res.setdefault(t, []).append(pc)
                    # ldr xN,[xrd,#imm]
                    if (x & 0xffc00000) == 0xf9400000 and ((x >> 5) & 31) == rd:
                        t = page + (((x >> 10) & 0xfff) << 3)
                        if t in targets:
                            res.setdefault(t, []).append(pc)
    return res

def main():
    c = dsc.Cache()
    sub = sys.argv[1]
    ims = c.image_by_name(sub)
    base, path = ims[0]
    print('image', path, hex(base))
    info = c.macho(base)
    for s in info['segs']:
        print(' seg', s[0], hex(s[1]), hex(s[2]))
    for text in sys.argv[2:]:
        needle = text.encode() + b'\0'
        found = []
        for name, vmaddr, vmsize, fileoff, filesize in info['segs']:
            if name != '__TEXT': continue
            raw = c.read(vmaddr, vmsize)
            pos = 0
            while True:
                k = raw.find(needle, pos)
                if k < 0: break
                if k == 0 or raw[k-1] == 0:
                    found.append(vmaddr + k)
                pos = k + 1
        print('string', text, [hex(f) for f in found])
        targets = set(found)
        # cfstrings: words in data segs whose low 36 bits match
        cf = []
        for name, vmaddr, vmsize, fileoff, filesize in info['segs']:
            if not name.startswith('__DATA'): continue
            raw = c.read(vmaddr, vmsize)
            if raw is None: continue
            n = len(raw) // 8
            words = struct.unpack_from('<%dQ' % n, raw, 0)
            for i, w in enumerate(words):
                if (w & 0xfffffffff) in targets or ((w & 0xfffffffff) + 0x180000000) in targets:
                    cf.append(vmaddr + i * 8 - 16)
        print(' cfstring objs', [hex(x) for x in cf])
        refs = scan_refs(c, base, info['segs'], set(found) | set(cf))
        for t, pcs in refs.items():
            for pc in pcs:
                print('  ref %#x from %#x  %s' % (t, pc, c.describe(pc)))

main()
