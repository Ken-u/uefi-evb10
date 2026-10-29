#!/usr/bin/env python3
"""把「改过几百字节的内核」写回 payload.img，做法是**原地改写**那段连续的簇，不动 FAT 结构。

    patch-payload-kernel.py PAYLOAD_IN ORIG_KERNEL PATCHED_KERNEL PAYLOAD_OUT

为什么不用 `mcopy -o`：2026-10-27 实测，mcopy 覆盖 50 MB 的 kernel.macho 时，旧链释放后新文件
从「第一个空闲簇」往后分配，结果被切成两段 `<98882-129023> <32-68737>`——第一段一直排到卷的
**最后一个簇**。fsck.vfat 认为镜像完全合法，但 EDK2 的 FatDiskIo 读卷尾部那一页时越过缓存页边界：

    FatDiskIo: Cache Page OutBound occurred!
    FatDiskIo: error Invalid Parameter
    DARWINBOOT: boot refused: Invalid Parameter; firmware retained

看上去像「DarwinBoot 拒绝了被改过的内核」，其实是固件的 FAT 驱动读不了卷尾。原版 payload.img 里
内核是连续的 <32-98879>，卷尾 3 万多个簇全空，所以一直没事。

所以：保持原版的簇布局，只覆盖内核那段连续区域的字节。本脚本要求：
  * 内核在镜像里是**一段连续**的簇（mshowfat 只有一个 <a-b>），否则拒绝；
  * 镜像里现有的字节必须逐字节等于 ORIG_KERNEL（确认偏移换算没错、也确认 PAYLOAD_IN 是干净的原版）；
  * PATCHED_KERNEL 与 ORIG_KERNEL 同样大小；
  * 写完用 mcopy 读出来逐字节比较，簇链仍是同一段；并且内核的簇链不得压在卷尾 256 个簇以内（见上面的 FatDiskIo 问题）。

环境变量 MTOOLS_BIN：mtools 所在目录（没有系统 mtools 时指向自带的那份）。
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

KERNEL_PATH = '::/EFI/UniXNU/Payloads/kernel.macho'
MTOOLS = os.environ.get('MTOOLS_BIN', '')
TAIL_CLUSTERS = 256


def mt(tool, *args):
    return subprocess.run([os.path.join(MTOOLS, tool), *args], check=True, capture_output=True, text=True).stdout


def extents(img, path):
    out = mt('mshowfat', '-i', img, path).strip()
    ext = re.findall(r'<(\d+)-(\d+)>', out)
    if not ext:
        # 单簇文件 mshowfat 打 <N>
        ext = [(m, m) for m in re.findall(r'<(\d+)>', out)]
    return [(int(a), int(b)) for a, b in ext]


def bpb(img):
    with open(img, 'rb') as f:
        b = f.read(512)
    bps, spc, reserved, nfats = struct.unpack_from('<HBHB', b, 11)
    fatsz32, = struct.unpack_from('<I', b, 36)
    total16, = struct.unpack_from('<H', b, 19)
    total32, = struct.unpack_from('<I', b, 32)
    if bps != 512 and bps not in (1024, 2048, 4096):
        sys.exit('不像 FAT 引导扇区：bytes/sector=%d' % bps)
    if fatsz32 == 0:
        sys.exit('不是 FAT32（FATSz32 = 0），本脚本只处理 FAT32')
    total = total32 or total16
    data_start = (reserved + nfats * fatsz32) * bps
    clusters = (total - (reserved + nfats * fatsz32)) // spc
    return bps, spc, data_start, clusters


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    payload_in, orig_path, patched_path, payload_out = sys.argv[1:]
    orig = open(orig_path, 'rb').read()
    patched = open(patched_path, 'rb').read()
    if len(orig) != len(patched):
        sys.exit('ORIG(%d) 和 PATCHED(%d) 大小不同；本脚本只做同尺寸的原地改写' % (len(orig), len(patched)))
    diff = sum(1 for a, b in zip(orig, patched) if a != b)
    if diff == 0:
        sys.exit('PATCHED 和 ORIG 完全相同，没什么可改的')

    ext = extents(payload_in, KERNEL_PATH)
    if len(ext) != 1:
        sys.exit('内核在 %s 里不是连续的一段：%s。先用干净的原版 payload.img' % (payload_in, ext))
    first, last = ext[0]
    bps, spc, data_start, clusters = bpb(payload_in)
    csize = bps * spc
    if (last - first + 1) * csize < len(orig):
        sys.exit('簇链 <%d-%d> 放不下 %d 字节' % (first, last, len(orig)))
    if last > clusters + 1 - TAIL_CLUSTERS:
        sys.exit('内核簇链 <%d-%d> 压在卷尾（共 %d 个簇）：EDK2 FatDiskIo 读不了卷尾' % (first, last, clusters))
    offset = data_start + (first - 2) * csize

    shutil.copyfile(payload_in, payload_out)
    with open(payload_out, 'r+b') as f:
        f.seek(offset)
        cur = f.read(len(orig))
        if cur != orig:
            os.unlink(payload_out)
            bad = next(i for i, (a, b) in enumerate(zip(cur, orig)) if a != b)
            sys.exit('镜像里偏移 %#x 处的内核和 ORIG_KERNEL 不一致（首个差异在文件偏移 %#x）；'
                     '偏移换算错了，或者 PAYLOAD_IN 不是干净的原版' % (offset, bad))
        f.seek(offset)
        f.write(patched)

    # ---- 验证 ----
    with tempfile.TemporaryDirectory() as tmp:
        back = os.path.join(tmp, 'k.macho')
        mt('mcopy', '-i', payload_out, KERNEL_PATH, back)
        if open(back, 'rb').read() != patched:
            os.unlink(payload_out)
            sys.exit('验证失败：mcopy 读出来的内核和 PATCHED 不一致')
    ext2 = extents(payload_out, KERNEL_PATH)
    if ext2 != ext:
        os.unlink(payload_out)
        sys.exit('验证失败：簇链变了 %s -> %s' % (ext, ext2))
    print('ok: %s 里的内核（簇 <%d-%d>，镜像偏移 %#x）改写了 %d 个字节；簇链未变，mcopy 读回一致'
          % (payload_out, first, last, offset, diff))


if __name__ == '__main__':
    main()
