#!/usr/bin/env python3
"""dataref.py IMAGE-SUBSTR ADDR... -> code in the image's __TEXT that computes ADDR via adrp + (add|ldr*|str*) within 12 insns."""
import sys, struct
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dsc
c = dsc.Cache()
base, path = c.image_by_name(sys.argv[1])[0]
info = c.macho(base)
targets = set(int(a, 16) for a in sys.argv[2:])
for name, vmaddr, vmsize, fo, fs in info['segs']:
    if name != '__TEXT': continue
    raw = c.read(vmaddr, vmsize); n = len(raw)//4
    words = struct.unpack_from('<%dI' % n, raw, 0)
    for i, w in enumerate(words):
        if (w & 0x9f000000) != 0x90000000: continue
        rd = w & 31
        imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3)
        if imm & (1 << 20): imm -= 1 << 21
        pc = vmaddr + i*4
        page = (pc & ~0xfff) + (imm << 12)
        for j in range(i+1, min(i+13, n)):
            x = words[j]
            if ((x >> 5) & 31) != rd: continue
            t = None; kind = ''
            if (x & 0xffc00000) == 0x91000000: t = page + ((x >> 10) & 0xfff); kind = 'add'
            elif (x & 0x3b000000) == 0x39000000:   # ldr/str unsigned imm
                size = x >> 30
                t = page + (((x >> 10) & 0xfff) << size); kind = 'ldst%d' % (1 << size) + (' ld' if (x >> 22) & 3 else ' st')
            if t in targets:
                print('%#x -> %#x %s  %s' % (pc, t, kind, c.describe(pc)))
