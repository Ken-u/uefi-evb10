#!/usr/bin/env python3
"""生成塞进固件卷的小号 FAT16 ESP（4 MiB，1 扇区/簇）。由 qemu-test/mkesp.py 改来。

本机没有 mtools/mkfs.vfat 可用（沙箱拦），所以这里手写 FAT16：
单分区、512 字节扇区、4 扇区/簇、512 个根目录项。
只支持 8.3 大写短名，够 ESP 用（\\EFI\\BOOT\\BOOTAA64.EFI 本来就是 8.3）。
"""
import os
import struct
import sys

SECTOR = 512
SEC_PER_CLUS = 1
RESERVED = 1
NUM_FATS = 2
ROOT_ENTRIES = 512
TOTAL_SECTORS = 8192           # 4 MiB（FAT16 至少 4085 簇；固件卷里压缩后几乎为空）
MEDIA = 0xF8

ROOT_SECTORS = (ROOT_ENTRIES * 32 + SECTOR - 1) // SECTOR
DATA_START = RESERVED + NUM_FATS  # 先填，算完 FAT 大小再修正


def fat_size_sectors(total, reserved, num_fats, root_secs, spc):
    fatsz = 1
    while True:
        data = total - reserved - num_fats * fatsz - root_secs
        clusters = data // spc
        need = ((clusters + 2) * 2 + SECTOR - 1) // SECTOR
        if need <= fatsz:
            return fatsz, clusters
        fatsz = need


class Fat:
    def __init__(self):
        self.fatsz, self.clusters = fat_size_sectors(
            TOTAL_SECTORS, RESERVED, NUM_FATS, ROOT_SECTORS, SEC_PER_CLUS)
        self.data_start = RESERVED + NUM_FATS * self.fatsz + ROOT_SECTORS
        self.clusters = (TOTAL_SECTORS - self.data_start) // SEC_PER_CLUS
        assert 4085 <= self.clusters < 65525, self.clusters
        self.img = bytearray(TOTAL_SECTORS * SECTOR)
        self.fat = [0] * (self.clusters + 2)
        self.fat[0] = 0xFF00 | MEDIA
        self.fat[1] = 0xFFFF
        self.next_free = 2
        self.root = []            # (name83, attr, first_clus, size)
        self.write_boot()

    # ---------------------------------------------------------------- 结构
    def write_boot(self):
        b = bytearray(SECTOR)
        b[0:3] = b"\xEB\x3C\x90"
        b[3:11] = b"MSWIN4.1"
        struct.pack_into("<HBHBHHBHHHII", b, 11,
                         SECTOR, SEC_PER_CLUS, RESERVED, NUM_FATS,
                         ROOT_ENTRIES, TOTAL_SECTORS if TOTAL_SECTORS < 65536 else 0,
                         MEDIA, self.fatsz, 32, 2, 0, 0)
        struct.pack_into("<I", b, 32, TOTAL_SECTORS)
        b[36] = 0x80              # drive number
        b[38] = 0x29              # extended boot signature
        struct.pack_into("<I", b, 39, 0x554E4958)   # volume id "UNIX"
        b[43:54] = b"UNIXNU ESP "
        b[54:62] = b"FAT16   "
        b[510] = 0x55
        b[511] = 0xAA
        self.img[0:SECTOR] = b

    def alloc(self, count):
        first = self.next_free
        for i in range(count):
            cur = first + i
            self.fat[cur] = 0xFFFF if i == count - 1 else cur + 1
        self.next_free += count
        return first

    def write_chain(self, first, data):
        off = self.data_start * SECTOR + (first - 2) * SEC_PER_CLUS * SECTOR
        self.img[off:off + len(data)] = data

    def add_83(self, name, attr, data=b"", first=None, size=None):
        if first is None:
            need = max(1, (len(data) + SEC_PER_CLUS * SECTOR - 1) // (SEC_PER_CLUS * SECTOR))
            first = self.alloc(need)
            self.write_chain(first, data)
        if size is None:
            size = len(data)
        self.root.append((name, attr, first, size))

    # ---------------------------------------------------------------- 布局
    def flush(self, root_dir_raw):
        # FAT 表
        fat_bytes = bytearray(self.fatsz * SECTOR)
        for i, v in enumerate(self.fat):
            struct.pack_into("<H", fat_bytes, i * 2, v)
        for n in range(NUM_FATS):
            start = (RESERVED + n * self.fatsz) * SECTOR
            self.img[start:start + len(fat_bytes)] = fat_bytes
        # 根目录
        start = (RESERVED + NUM_FATS * self.fatsz) * SECTOR
        self.img[start:start + len(root_dir_raw)] = root_dir_raw


def name83(name):
    """把普通文件名转成 11 字节的 8.3 短名域（不足补空格）。"""
    upper = name.upper()
    if "." in upper:
        base, _, ext = upper.rpartition(".")
    else:
        base, ext = upper, ""
    if len(base) > 8 or len(ext) > 3:
        raise ValueError("name not 8.3 compatible: %s" % name)
    return (base.ljust(8) + ext.ljust(3)).encode("ascii")


def is_83(name):
    try:
        name83(name)
        return True
    except ValueError:
        return False


def short_candidate(name, taken):
    """为长文件名造一个唯一的 8.3 短名：前 6 个字符 + ~N + 扩展名前 3 个。"""
    upper = name.upper()
    if "." in upper:
        base, _, ext = upper.rpartition(".")
    else:
        base, ext = upper, ""
    base = "".join(c for c in base if c.isalnum() or c in "_~")[:6] or "FILE"
    ext = "".join(c for c in ext if c.isalnum() or c in "_~")[:3]
    n = 1
    while True:
        cand = ("%s~%d" % (base, n)).ljust(8)[:8] + ext.ljust(3)
        if cand not in taken:
            taken.add(cand)
            return cand
        n += 1
        if n > 9:
            raise ValueError("too many colliding 8.3 names")


def lfn_checksum(short11):
    s = 0
    for c in short11:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def lfn_entries(long_name, short11):
    """生成长文件名的 VFAT 目录项（按倒序写在短名项之前）。"""
    units = [ord(c) for c in long_name]
    for i in range(len(long_name), 13):
        if i == len(long_name):
            units.append(0x0000)
        elif i > len(long_name):
            units.append(0xFFFF)
    chk = lfn_checksum(short11)
    count = (len(long_name) + 12) // 13 or 1
    units = units[:count * 13]
    while len(units) < count * 13:
        units.append(0xFFFF)
    out = []
    for seq in range(count, 0, -1):
        chunk = units[(seq - 1) * 13: seq * 13]
        b = bytearray(32)
        b[0] = seq | (0x40 if seq == count else 0)
        b[1:11] = bytes().join(struct.pack("<H", u) for u in chunk[0:5])
        b[11] = 0x0F
        b[12] = 0x00
        b[13] = chk
        b[14:26] = bytes().join(struct.pack("<H", u) for u in chunk[5:11])
        b[26:28] = b"\x00\x00"
        b[28:32] = bytes().join(struct.pack("<H", u) for u in chunk[11:13])
        out.append(bytes(b))
    return out


def dirent(name, attr, first, size, taken):
    """一个目录项：必要时先写 LFN 项，再写短名项。"""
    if not is_83(name):
        short11 = short_candidate(name, taken).encode("ascii")
        head = b"".join(lfn_entries(name, short11))
    else:
        short11 = name83(name)
        head = b""
    b = bytearray(32)
    b[0:11] = short11
    b[11] = attr
    struct.pack_into("<H", b, 26, first & 0xFFFF)
    struct.pack_into("<I", b, 28, size)
    return head + bytes(b)


def build(src_dir, out_path):
    fs = Fat()

    def entries_of(host):
        out = []
        for name in sorted(os.listdir(host)):
            full = os.path.join(host, name)
            out.append((name, os.path.isdir(full), full))
        return out

    def walk(host, taken):
        """返回 (files_raw, subdirs)，files_raw 带 LFN，子目录延后分配。"""
        raw = bytearray()
        subdirs = []
        for name, isdir, full in entries_of(host):
            if isdir:
                subdirs.append((name, full))
                continue
            data = open(full, "rb").read()
            need = max(1, (len(data) + SEC_PER_CLUS * SECTOR - 1) // (SEC_PER_CLUS * SECTOR))
            first = fs.alloc(need)
            fs.write_chain(first, data)
            raw += dirent(name, 0x20, first, len(data), taken)
        return raw, subdirs

    def emit(host, taken, raw_dir):
        """把 host 目录写成 raw_dir 里的目录项，返回该目录占的簇号。"""
        raw, subdirs = walk(host, taken)
        out = bytearray(raw_dir) + raw
        for name, full in subdirs:
            sub = emit(full, taken, b"")
            out += dirent(name, 0x10, sub, 0, taken)
        if not out:
            out = bytearray(32)          # 空目录也要占一个簇
        need = max(1, (len(out) + SEC_PER_CLUS * SECTOR - 1) // (SEC_PER_CLUS * SECTOR))
        first = fs.alloc(need)
        fs.write_chain(first, bytes(out))
        return first

    # 根目录在 FAT16 里是固定区，不占簇：先递归铺好子目录，再把根项目写进固定区。
    taken = set()
    raw, subdirs = walk(src_dir, taken)
    root_raw = bytearray(raw)
    for name, full in subdirs:
        sub = emit(full, taken, b"")
        root_raw += dirent(name, 0x10, sub, 0, taken)

    fs.flush(root_raw)
    open(out_path, "wb").write(fs.img)
    print("wrote %s (%d bytes, %d clusters, %d FAT sectors)" %
          (out_path, len(fs.img), fs.clusters, fs.fatsz))


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2])
