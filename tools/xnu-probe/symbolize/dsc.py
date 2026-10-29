#!/usr/bin/env python3
"""dsc.py: toolbox for the iPad7,1 17.7.11 dyld shared cache (arm64, 52 subcaches), host side.

  dsc.py img ADDR...                 which image holds ADDR (unslid addresses; --slide HEX shifts first)
  dsc.py sym [--slide HEX] ADDR...   name an address: local symbols (.symbols) + exports (LINKEDIT)
  dsc.py dis [--slide HEX] ADDR [N]  disassemble N (default 40) instructions at ADDR, targets symbolized
  dsc.py exports IMAGE-SUBSTRING     list the exports of one image
"""
import bisect, mmap, os, struct, subprocess, sys

# Everything lives in a scratch directory (default /tmp/uland), see README.md for how it is filled.
ULAND = os.environ.get('ULAND', '/tmp/uland')
DIR = ULAND + '/dsc/System/Library/Caches/com.apple.dyld'
MAIN = DIR + '/dyld_shared_cache_arm64'
SYMFILE = ULAND + '/dsc/dyld_shared_cache_arm64.symbols'
# The two .dyldlinkedit subcaches are decmpfs-compressed on the volume (data fork empty): decoded by decmpfs14.py.
LINKEDIT_DECODED = {'.34.dyldlinkedit': ULAND + '/dsc/dsc.34.linkedit',
                    '.52.dyldlinkedit': ULAND + '/dsc/dsc.52.linkedit'}
BASE = 0x180000000


def uleb(buf, pos):
    result = shift = 0
    while True:
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7


class Cache:
    def __init__(self):
        self.maps = []      # (address, size, fileoff, mmap)
        self.mm = {}
        main = self._open(MAIN)
        self.main = main
        self._add_mappings(main)
        (sub_off, sub_cnt) = struct.unpack_from('<II', main, 0x188)
        # dyld_subcache_entry: uuid[16], cacheVMOffset u64, fileSuffix[32] (56 bytes)
        for i in range(sub_cnt):
            ent = sub_off + i * 56
            suffix = main[ent + 24:ent + 56].split(b'\0')[0].decode()
            path = MAIN + suffix
            if suffix in LINKEDIT_DECODED:
                path = LINKEDIT_DECODED[suffix]
            self._add_mappings(self._open(path))
        self.maps.sort(key=lambda m: m[0])
        self.map_addrs = [m[0] for m in self.maps]
        off, cnt = struct.unpack_from('<II', main, 0x1c0)
        self.images = []
        for i in range(cnt):
            addr, mod, ino, pathOff, pad = struct.unpack_from('<QQQII', main, off + i * 32)
            path = main[pathOff:pathOff + 256].split(b'\0')[0].decode()
            self.images.append((addr, path))
        self.images.sort()
        self.image_addrs = [a for a, _ in self.images]
        self._sym = None
        self._img_cache = {}

    def _open(self, path):
        if path not in self.mm:
            fd = os.open(path, os.O_RDONLY)
            self.mm[path] = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)
        return self.mm[path]

    def _add_mappings(self, m):
        # mappingOffset / mappingCount; each dyld_cache_mapping_info is 32 bytes
        off, cnt = struct.unpack_from('<II', m, 0x10)
        for i in range(cnt):
            addr, size, fileoff, maxprot, initprot = struct.unpack_from('<QQQII', m, off + i * 32)
            self.maps.append((addr, size, fileoff, m))

    def read(self, va, n):
        i = bisect.bisect_right(self.map_addrs, va) - 1
        while i >= 0:
            addr, size, fileoff, m = self.maps[i]
            if addr <= va < addr + size:
                if va + n > addr + size:
                    n = addr + size - va
                return bytes(m[fileoff + va - addr:fileoff + va - addr + n])
            i -= 1
            break
        return None

    def image_of(self, addr):
        i = bisect.bisect_right(self.image_addrs, addr) - 1
        return self.images[i] if i >= 0 else None

    def image_by_name(self, sub):
        return [im for im in self.images if sub in im[1]]

    # -- Mach-O of an image --------------------------------------------------------------------
    def macho(self, base):
        if base in self._img_cache:
            return self._img_cache[base]
        head = self.read(base, 0x4000)
        magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', head, 0)
        assert magic == 0xfeedfacf, hex(magic)
        if sizeofcmds + 32 > len(head):
            head = self.read(base, sizeofcmds + 32)
        pos = 32
        segs, trie, symtab = [], None, None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', head, pos)
            if cmd == 0x19:  # LC_SEGMENT_64
                name = head[pos + 8:pos + 24].split(b'\0')[0].decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<4Q', head, pos + 24)
                segs.append((name, vmaddr, vmsize, fileoff, filesize))
            elif cmd == 0x80000033:  # LC_DYLD_EXPORTS_TRIE
                trie = struct.unpack_from('<II', head, pos + 8)
            elif cmd == 0x2:  # LC_SYMTAB
                symtab = struct.unpack_from('<4I', head, pos + 8)
            pos += size
        info = {'segs': segs, 'trie': trie, 'symtab': symtab}
        self._img_cache[base] = info
        return info

    def linkedit_va(self, base, fileoff):
        info = self.macho(base)
        for name, vmaddr, vmsize, segoff, filesize in info['segs']:
            if name == '__LINKEDIT':
                return vmaddr + (fileoff - segoff)
        return None

    def exports(self, base):
        info = self.macho(base)
        if not info['trie']:
            return []
        dataoff, datasize = info['trie']
        va = self.linkedit_va(base, dataoff)
        trie = self.read(va, datasize)
        if trie is None:
            return []
        out = []
        stack = [(0, b'')]
        seen = 0
        while stack:
            node, prefix = stack.pop()
            seen += 1
            if seen > 3000000:
                break
            tsize, p = uleb(trie, node)
            if tsize:
                flags, q = uleb(trie, p)
                if not flags & 0x8:  # not a re-export
                    value, q = uleb(trie, q)
                    out.append((base + value, prefix.decode(errors='replace')))
            childp = p + tsize
            count = trie[childp]
            childp += 1
            for _ in range(count):
                end = trie.index(b'\0', childp)
                edge = trie[childp:end]
                off, childp = uleb(trie, end + 1)
                stack.append((off, prefix + edge))
        out.sort()
        return out

    # -- local symbols ----------------------------------------------------------------------------
    def _load_sym(self):
        if self._sym is not None:
            return
        fd = os.open(SYMFILE, os.O_RDONLY)
        s = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)
        locOff, locSize = struct.unpack_from('<QQ', s, 0x48)
        nlistOff, nlistCount, strOff, strSize, entOff, entCount = struct.unpack_from('<6I', s, locOff)
        entries = {}
        for i in range(entCount):
            dylibOffset, start, count = struct.unpack_from('<QII', s, locOff + entOff + i * 16)
            entries[BASE + dylibOffset] = (start, count)
        self._sym = (s, locOff + nlistOff, locOff + strOff, entries)

    def locals(self, base):
        self._load_sym()
        s, nbase, sbase, entries = self._sym
        ent = entries.get(base)
        syms = []
        if ent:
            start, count = ent
            for k in range(start, start + count):
                strx, ntype, nsect, ndesc, value = struct.unpack_from('<IBBHQ', s, nbase + k * 16)
                if ntype & 0xe0 or (ntype & 0x0e) != 0x0e:
                    continue
                name = s[sbase + strx:sbase + strx + 300].split(b'\0')[0].decode(errors='replace')
                syms.append((value, name))
        return syms

    def symbols(self, base):
        key = ('syms', base)
        if key not in self._img_cache:
            syms = self.locals(base) + self.exports(base)
            syms.sort()
            self._img_cache[key] = (syms, [v for v, _ in syms])
        return self._img_cache[key]

    def describe(self, addr):
        img = self.image_of(addr)
        if not img:
            return '?'
        base, path = img
        syms, keys = self.symbols(base)
        short = path.rsplit('/', 1)[-1]
        i = bisect.bisect_right(keys, addr) - 1
        if i >= 0 and addr - keys[i] < 0x10000:
            return '%s`%s+%#x' % (short, syms[i][1], addr - keys[i])
        return '%s+%#x' % (short, addr - base)


LLVM = os.environ.get('LLVM_BIN', '')


def disassemble(c, addr, count, annotate=True):
    """Disassemble count instructions at the unslid address addr; branch/adr targets get names."""
    import re, tempfile
    raw = c.read(addr, count * 4)
    if raw is None:
        return ['no mapping for %#x' % addr]
    tmp = tempfile.mkdtemp()
    open(tmp + '/fn.bin', 'wb').write(raw)
    subprocess.check_call([LLVM + '/llvm-objcopy', '-I', 'binary', '-O', 'elf64-littleaarch64',
                           '--rename-section', '.data=.text,code,alloc,load,readonly,contents',
                           tmp + '/fn.bin', tmp + '/fn.elf'])
    out = subprocess.check_output([LLVM + '/llvm-objdump', '-d', '--mattr=+v8.5a,+pauth,+crc,+lse,+rcpc',
                                   '--no-show-raw-insn', tmp + '/fn.elf'], text=True)
    res = []
    for line in out.splitlines():
        m = re.match(r'^\s*([0-9a-f]+):\s*(.*)$', line)
        if not m:
            continue
        pc = int(m.group(1), 16) + addr
        rest = re.sub(r'<[^>]*>', '', m.group(2)).rstrip()
        note = ''
        if annotate:
            t = re.match(r'^(b|bl|b\.\w+|cbz|cbnz|tbz|tbnz|adr|adrp)\s.*?(?:#|0x)(-?[0-9a-fx]+)\s*$', rest)
            if t:
                try:
                    v = int(t.group(2), 16)
                    if t.group(1) == 'adrp':
                        target = ((pc & ~0xfff) + (v - ((pc - addr) & ~0xfff))) & 0xffffffffffffffff
                    else:
                        target = (v + addr) & 0xffffffffffffffff
                    note = '   ; -> %#x %s' % (target, c.describe(target))
                    rest = re.sub(r'(#|0x)(-?[0-9a-fx]+)\s*$', '0x%x' % target, rest)
                except ValueError:
                    pass
        res.append('%#x: %s%s' % (pc, rest, note))
    return res


def main():
    args = sys.argv[1:]
    slide = 0
    if '--slide' in args:
        i = args.index('--slide')
        slide = int(args[i + 1], 16)
        del args[i:i + 2]
    cmd, args = args[0], args[1:]
    c = Cache()
    if cmd == 'img':
        for a in args:
            v = int(a, 16) - slide
            img = c.image_of(v)
            print('%#x -> %s +%#x' % (v, img[1], v - img[0]) if img else '%#x -> ?' % v)
    elif cmd == 'sym':
        for a in args:
            v = int(a, 16) - slide
            print('%s -> %s' % (a, c.describe(v)))
    elif cmd == 'dis':
        v = int(args[0], 16) - slide
        n = int(args[1]) if len(args) > 1 else 40
        for line in disassemble(c, v, n):
            print(line)
    elif cmd == 'fn':
        v = int(args[0], 16) - slide
        after = int(args[1], 0) if len(args) > 1 else 0x40
        img = c.image_of(v)
        syms, keys = c.symbols(img[0])
        i = bisect.bisect_right(keys, v) - 1
        start = keys[i] if i >= 0 else v
        print('# %s starts at %#x (slid %#x)' % (syms[i][1] if i >= 0 else '?', start, start + slide))
        for line in disassemble(c, start, (v + after - start) // 4 + 1):
            print(line)
    elif cmd == 'exports':
        for base, path in c.image_by_name(args[0]):
            print('==', path, hex(base))
            for a, name in c.exports(base):
                print('%#x %s' % (a, name))


if __name__ == '__main__':
    main()
