#!/usr/bin/env python3
"""Turn the addresses of a UniXNU panic backtrace into symbol+offset.

The native kernel is linked at the addresses the panic prints ("Kernel text base 0xfffffff007004000"
is its own link address), so its unstripped Mach-O, which the kernel build leaves in the build tree,
names them directly. The prelinked ORIGINAL components (AMFI, apfs, sandbox ...) sit below that, at
their kernelcache address minus the prelink slide (board.toml [kernel.prelink] slide, -0x1000000);
for those the nearest symbol of the decompressed kernelcache (the exports that survive in its
LINKEDIT) is the best that exists, and the component name comes from the kmod ranges in kernel.json.

    symbolicate.py LOG [--nm FILE] [--kernelcache-nm FILE] ...
    symbolicate.py runs/emmc5c.kernel.log            # every "lr: 0x..." / "pc 0x..." line of the log

First time (or after a kernel rebuild) make the two symbol lists:

    llvm-nm -n --defined-only <unstripped native kernel>      > /tmp/kernel-syms.txt
    llvm-nm -n --defined-only <kernelcache.decompressed>      > /tmp/kernelcache-syms.txt
"""
import argparse
import bisect
import re
import sys

SLIDE = -0x1000000
NATIVE_FLOOR = 0xfffffff007004000   # the native kernel's text base; anything below is a prelinked component


def load(path):
    addrs, names = [], []
    try:
        for line in open(path):
            parts = line.split()
            if len(parts) >= 3 and re.fullmatch(r'[0-9a-fA-F]{16}', parts[0]) and parts[1] in 'tTsSdDbBwWiI':
                addrs.append(int(parts[0], 16))
                names.append(parts[2])
    except OSError:
        pass
    order = sorted(range(len(addrs)), key=addrs.__getitem__)
    return [addrs[i] for i in order], [names[i] for i in order]


def lookup(table, address):
    addrs, names = table
    if not addrs:
        return None
    index = bisect.bisect_right(addrs, address) - 1
    if index < 0:
        return None
    return '%s+0x%x' % (names[index], address - addrs[index])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('log', nargs='?', help='serial/kernel log; default stdin')
    parser.add_argument('--nm', default='/tmp/kernel-syms.txt')
    parser.add_argument('--kernelcache-nm', default='/tmp/kernelcache-syms.txt')
    args = parser.parse_args()
    native = load(args.nm)
    original = load(args.kernelcache_nm)
    text = open(args.log).read() if args.log else sys.stdin.read()
    seen = set()
    for match in re.finditer(r'(?:\blr:|\bpc|\bfar:|\bcaller)\s+0x([0-9a-fA-F]{16})', text):
        address = int(match.group(1), 16)
        if address in seen or address < 0xfffffff000000000:
            continue
        seen.add(address)
        if address >= NATIVE_FLOOR:
            where = lookup(native, address) or '?'
            print('0x%016x  %s' % (address, where))
        else:
            original_address = address - SLIDE
            where = lookup(original, original_address)
            print('0x%016x  [prelinked component, kernelcache 0x%016x]  nearest export: %s' %
                  (address, original_address, where or '?'))


if __name__ == '__main__':
    main()
