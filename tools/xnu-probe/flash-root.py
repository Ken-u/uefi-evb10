#!/usr/bin/env python3
"""Write a `userdata-root.img` into a window of the board's `userdata` partition, and prove it landed.

Runs on the board host (as root, because it opens a block device) against the partition node U-Boot's
`ums 0 mmc 0` exposes. `flash-root.sh` drives the board side; this file is only the writer.

    flash-root.py IMAGE DEVICE --offset BYTES [--expect-bytes N] [--expect-label userdata]
                  [--expect-sha256 HEX] [--write | --verify-only]
    flash-root.py find-target --before sda,sdb --disk-bytes N --userdata-bytes N
    flash-root.py --selftest

Without --write it is a dry run: it checks everything it can and writes nothing.
`find-target` picks the partition node to write: among the USB disks that were NOT there before
`ums` started it wants exactly one of exactly --disk-bytes, and on it exactly one partition with
label `userdata` of exactly --userdata-bytes; it prints that node (exit 0), exits 1 when there is
none yet (the caller retries) and 3 when the answer is ambiguous (the caller gives up).

What it will not do (each is a refusal, not a warning):
  * touch a block device that is mounted, that is not on USB, whose size is not exactly
    --expect-bytes, or whose partition label is not --expect-label (the host's own disks are
    /dev/sda*; the only thing this may ever write is the board's `userdata`);
  * write past the end of the device: OFFSET + padded image size must fit;
  * write when the source file's SHA-256 is not --expect-sha256 (a copy that got damaged on the
    way to 宿主机 would otherwise be "verified" against itself);
  * report success without reading everything back through the page cache's back door
    (O_DIRECT, after BLKFLSBUF) and comparing it chunk by chunk.

Why an OFFSET: `userdata` still holds the earlier HFS+ install in its first 20 GiB. The root image
goes to a later window (the kernel is told where with the boot-arg emmc-root-lba=N, N = the card's
absolute LBA = userdata first LBA + OFFSET / 512), so that install is not touched. OFFSET 0 is the
layout `unixnu build userdata` documents (it overwrites that install).
"""
import argparse
import fcntl
import hashlib
import json
import mmap
import os
import stat
import struct
import subprocess
import sys
import tempfile
import time

CHUNK = 4 << 20            # 4 MiB, a multiple of every logical block size involved
ALIGN = 4096               # O_DIRECT granularity; offsets and lengths are padded to it
BLKGETSIZE64 = 0x80081272
BLKFLSBUF = 0x1261


def log(msg):
    print(msg, flush=True)


def device_bytes(fd):
    mode = os.fstat(fd).st_mode
    if stat.S_ISBLK(mode):
        return struct.unpack("<Q", fcntl.ioctl(fd, BLKGETSIZE64, b"\0" * 8))[0]
    return os.fstat(fd).st_size


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb", buffering=0) as f:
        while True:
            b = f.read(8 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def lsblk(dev, *cols):
    out = subprocess.run(["lsblk", "-dno", ",".join(cols), dev], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def parent_disk(dev):
    out = subprocess.run(["lsblk", "-no", "PKNAME", dev], capture_output=True, text=True)
    name = out.stdout.strip().splitlines()[0] if out.returncode == 0 and out.stdout.strip() else ""
    return "/dev/" + name if name else dev


def target_refusal(dev, mounted_at, tran, label, expect_label):
    """The decision of check_target on plain facts, so the selftest can feed it every case."""
    if mounted_at:
        return "refusing: %s is mounted (%s)" % (dev, mounted_at)
    if tran != "usb":
        return "refusing: %s sits on a disk whose transport is %r, not usb" % (dev, tran)
    if expect_label is not None and label != expect_label:
        return "refusing: %s has partition label %r, expected %r" % (dev, label, expect_label)
    return None


def check_target(dev, expect_bytes, expect_label):
    """Refusals for block devices; regular files (selftest) are not checked here."""
    st = os.stat(dev)
    if not stat.S_ISBLK(st.st_mode):
        return
    mounted_at = None
    with open("/proc/mounts") as f:
        for line in f:
            if line.split()[0].startswith(dev):
                mounted_at = line.split()[1]
                break
    why = target_refusal(dev, mounted_at, lsblk(parent_disk(dev), "TRAN"), lsblk(dev, "PARTLABEL"), expect_label)
    if why:
        raise SystemExit(why)


class Direct:
    """Aligned buffers and O_DIRECT access to a block device or file."""

    def __init__(self, path, write):
        flags = os.O_RDWR if write else os.O_RDONLY
        self.direct = True
        try:
            self.fd = os.open(path, flags | os.O_DIRECT)
        except OSError:
            if stat.S_ISBLK(os.stat(path).st_mode):
                raise SystemExit("cannot open %s with O_DIRECT; without it a read-back proves nothing" % path)
            self.fd = os.open(path, flags)          # a regular file in the selftest on a filesystem without O_DIRECT
            self.direct = False
        self.block = stat.S_ISBLK(os.fstat(self.fd).st_mode)
        self.buf = mmap.mmap(-1, CHUNK)

    def flush_cache(self):
        if self.block:
            fcntl.ioctl(self.fd, BLKFLSBUF, 0)
        else:
            os.posix_fadvise(self.fd, 0, 0, os.POSIX_FADV_DONTNEED)

    def pwrite(self, data, offset):
        self.buf[:len(data)] = data
        view = memoryview(self.buf)[:len(data)]
        done = 0
        while done < len(data):
            done += os.pwritev(self.fd, [view[done:]], offset + done)

    def pread(self, length, offset):
        view = memoryview(self.buf)[:length]
        got = 0
        while got < length:
            n = os.preadv(self.fd, [view[got:]], offset + got)
            if n == 0:
                raise EOFError("short read at %d" % (offset + got))
            got += n
        return bytes(view)

    def sync(self):
        os.fsync(self.fd)

    def close(self):
        os.close(self.fd)


def find_target(before, disk_bytes, userdata_bytes, lsblk_json=None):
    """Return '/dev/NAME' of the unique userdata partition on the unique new USB disk, or None.
    Raises ValueError when more than one candidate qualifies."""
    if lsblk_json is None:
        out = subprocess.run(["lsblk", "-J", "-b", "-o", "NAME,SIZE,TRAN,TYPE,PARTLABEL"],
                             capture_output=True, text=True)
        if out.returncode != 0:
            return None
        lsblk_json = out.stdout
    found = []
    for disk in json.loads(lsblk_json).get("blockdevices", []):
        if disk.get("type") != "disk" or disk.get("tran") != "usb" or disk.get("name") in before:
            continue
        if int(disk.get("size") or 0) != disk_bytes:
            continue
        parts = [c for c in disk.get("children") or []
                 if c.get("partlabel") == "userdata" and int(c.get("size") or 0) == userdata_bytes]
        if len(parts) > 1:
            raise ValueError("%s has %d partitions labelled userdata of that size" % (disk["name"], len(parts)))
        if parts:
            found.append("/dev/" + parts[0]["name"])
    if len(found) > 1:
        raise ValueError("more than one new USB disk qualifies: %s" % ", ".join(found))
    return found[0] if found else None


def padded(n):
    return (n + ALIGN - 1) // ALIGN * ALIGN


def source_chunks(path, skip=0):
    with open(path, "rb", buffering=0) as f:
        f.seek(skip)
        pos = skip
        while True:
            b = f.read(CHUNK)
            if not b:
                return
            if len(b) % ALIGN:
                b += b"\0" * (padded(len(b)) - len(b))
            yield pos, b
            pos += CHUNK


def flash(args):
    img = args.image
    size = os.path.getsize(img)
    need = padded(size)
    if args.offset % ALIGN:
        raise SystemExit("--offset must be a multiple of %d" % ALIGN)
    if args.skip % CHUNK:
        raise SystemExit("--skip must be a multiple of %d" % CHUNK)

    ro = Direct(args.device, write=False)
    total = device_bytes(ro.fd)
    ro.close()
    log("image   %s: %d bytes (%.2f GiB), written as %d" % (img, size, size / 2**30, need))
    log("target  %s: %d bytes (%.2f GiB)" % (args.device, total, total / 2**30))
    log("window  [%d, %d) = device offset %.2f GiB .. %.2f GiB" %
        (args.offset, args.offset + need, args.offset / 2**30, (args.offset + need) / 2**30))
    if args.expect_bytes is not None and total != args.expect_bytes:
        raise SystemExit("refusing: device is %d bytes, expected exactly %d" % (total, args.expect_bytes))
    if args.offset + need > total:
        raise SystemExit("refusing: the window does not fit in the device")
    check_target(args.device, args.expect_bytes, args.expect_label)
    if args.expect_sha256:
        t0 = time.time()
        have = sha256_file(img)
        if have != args.expect_sha256.lower():
            raise SystemExit("refusing: %s has sha256 %s, expected %s" % (img, have, args.expect_sha256))
        log("source sha256 ok (%s, %.0f s)" % (have, time.time() - t0))

    if not (args.write or args.verify_only):
        log("dry run: nothing was written (add --write)")
        return 0

    digests = {}
    if args.write:
        dev = Direct(args.device, write=True)
        t0 = time.time()
        written = 0
        for pos, chunk in source_chunks(img, args.skip):
            digests[pos] = hashlib.sha256(chunk).digest()
            dev.pwrite(chunk, args.offset + pos)
            written += len(chunk)
            if (pos // CHUNK) % 32 == 0:
                el = time.time() - t0
                log("  wrote %.2f / %.2f GiB  %.1f MB/s" % ((pos + len(chunk)) / 2**30, need / 2**30,
                                                            written / 2**20 / el if el else 0))
        dev.sync()
        dev.flush_cache()
        dev.close()
        log("write done: %.2f GiB in %.0f s; reading back" % (written / 2**30, time.time() - t0))

    dev = Direct(args.device, write=False)
    dev.flush_cache()
    t0 = time.time()
    bad = 0
    checked = 0
    for pos, chunk in source_chunks(img, args.skip):
        want = digests.get(pos) or hashlib.sha256(chunk).digest()
        back = dev.pread(len(chunk), args.offset + pos)
        if hashlib.sha256(back).digest() != want:
            # find the first differing 4 KiB for the report
            first = next(i for i in range(0, len(chunk), ALIGN) if back[i:i + ALIGN] != chunk[i:i + ALIGN])
            log("MISMATCH in chunk at image offset %d (first bad block at +%d, device offset %d)" %
                (pos, first, args.offset + pos + first))
            bad += 1
            if bad >= 4:
                break
        checked += len(chunk)
        if (pos // CHUNK) % 64 == 0:
            el = time.time() - t0
            log("  verified %.2f / %.2f GiB  %.1f MB/s" % ((pos + len(chunk)) / 2**30, need / 2**30,
                                                          checked / 2**20 / el if el else 0))
    dev.close()
    if bad:
        log("VERIFY FAILED: %d bad chunk(s)" % bad)
        return 1
    log("VERIFY OK: %.2f GiB read back from the device equals the image (%.0f s)" % (checked / 2**30, time.time() - t0))
    return 0


def selftest():
    """No board, no root: files stand in for the device. Checks the window arithmetic, the refusals
    and that a flipped byte in the 'device' is caught by --verify-only."""
    rc = 0

    def check(cond, what):
        nonlocal rc
        print(("ok:   " if cond else "FAIL: ") + what)
        if not cond:
            rc = 1

    def run(*argv):
        ns = parse(list(argv))
        try:
            return flash(ns)
        except SystemExit as exc:
            return exc.code if isinstance(exc.code, int) else str(exc.code)

    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR", "/var/tmp")) as d:
        img = os.path.join(d, "img")
        dev = os.path.join(d, "dev")
        data = bytearray(os.urandom(CHUNK * 2 + 12288))       # 2 chunks + 3 blocks: a short last chunk
        data[CHUNK:CHUNK + (1 << 20)] = bytes(1 << 20)        # a zero run in the middle
        open(img, "wb").write(data)
        sha = hashlib.sha256(bytes(data)).hexdigest()
        devsize = 40 << 20
        background = os.urandom(devsize)
        open(dev, "wb").write(background)
        offset = 8 << 20

        r = run(img, dev, "--offset", str(offset), "--expect-bytes", str(devsize), "--expect-sha256", sha)
        check(r == 0 and open(dev, "rb").read() == background, "dry run succeeds and writes nothing")

        r = run(img, dev, "--offset", str(offset), "--expect-bytes", str(devsize + 4096), "--write")
        check(isinstance(r, str) and "refusing" in r and open(dev, "rb").read() == background,
              "wrong device size is refused, nothing written")

        r = run(img, dev, "--offset", str(offset), "--expect-sha256", "0" * 64, "--write")
        check(isinstance(r, str) and "refusing" in r and open(dev, "rb").read() == background,
              "wrong source sha256 is refused, nothing written")

        r = run(img, dev, "--offset", str((devsize - len(data)) // ALIGN * ALIGN + ALIGN), "--write")
        check(isinstance(r, str) and "does not fit" in r and open(dev, "rb").read() == background,
              "a window past the end is refused, nothing written")

        r = run(img, dev, "--offset", str(offset + 1), "--write")
        check(isinstance(r, str) and "multiple" in r, "an unaligned offset is refused")

        r = run(img, dev, "--offset", str(offset), "--expect-bytes", str(devsize), "--expect-sha256", sha, "--write")
        after = open(dev, "rb").read()
        need = padded(len(data))
        check(r == 0, "write + read-back verify reports success")
        check(after[offset:offset + len(data)] == bytes(data), "the window holds the image")
        check(after[offset + len(data):offset + need] == bytes(need - len(data)), "the padding of the last block is zero")
        check(after[:offset] == background[:offset] and after[offset + need:] == background[offset + need:],
              "every byte outside the window is untouched")

        r = run(img, dev, "--offset", str(offset), "--verify-only")
        check(r == 0, "verify-only agrees on an intact window")

        with open(dev, "r+b") as f:
            f.seek(offset + CHUNK + (3 << 20) + 77)
            b = f.read(1)
            f.seek(offset + CHUNK + (3 << 20) + 77)
            f.write(bytes([b[0] ^ 1]))
        r = run(img, dev, "--offset", str(offset), "--verify-only")
        check(r == 1, "verify-only catches one flipped bit in the second chunk")
    # ---- the refusals for a real block device, on plain facts ----
    check(target_refusal("/dev/sdb15", None, "usb", "userdata", "userdata") is None, "target: the board's partition passes")
    check("mounted" in str(target_refusal("/dev/sdb15", "/mnt/x", "usb", "userdata", "userdata")), "target: a mounted partition is refused")
    check("not usb" in str(target_refusal("/dev/sda7", None, "sata", "userdata", "userdata")), "target: a non-USB disk is refused")
    check("not usb" in str(target_refusal("/dev/nvme0n1p7", None, None, "userdata", "userdata")), "target: a disk with no transport is refused")
    check("label" in str(target_refusal("/dev/sdb14", None, "usb", "super", "userdata")), "target: another label is refused")
    check(target_refusal("/dev/sdb15", None, "usb", None, None) is None, "target: no --expect-label means the label is not checked")

    # ---- find-target on canned lsblk output ----
    DISK, UD = 62537072640, 58205896704

    def lj(*disks):
        return json.dumps({"blockdevices": list(disks)})

    def disk(name, size=DISK, tran="usb", parts=None):
        d = {"name": name, "size": size, "tran": tran, "type": "disk", "partlabel": None}
        if parts is not None:
            d["children"] = parts
        return d

    def part(name, label, size):
        return {"name": name, "size": size, "tran": None, "type": "part", "partlabel": label}

    # the host's own disk, nasty on purpose: same size, same label, same partition size -- only the transport differs
    sda = disk("sda", DISK, "sata", [part("sda7", "userdata", UD)])
    board = disk("sdb", parts=[part("sdb1", "security", 4194304), part("sdb14", "super", 3263168512),
                               part("sdb15", "userdata", UD)])

    def ft(*disks, before=()):
        try:
            return find_target(set(before), DISK, UD, lj(*disks))
        except ValueError as exc:
            return "ambiguous: %s" % exc

    check(ft(sda, board) == "/dev/sdb15", "find-target: the board's userdata partition is found")
    check(ft(sda) is None, "find-target: the host's own disk never qualifies (not usb), even with a userdata partition of that size")
    check(ft(sda, board, before=("sdb",)) is None, "find-target: a USB disk that was there before ums is ignored")
    check(ft(disk("sdb", DISK - 512, parts=board["children"])) is None, "find-target: a disk of the wrong size is ignored")
    check(ft(disk("sdb", parts=[part("sdb15", "userdata", UD - 512)])) is None, "find-target: a userdata partition of the wrong size is ignored")
    check(ft(disk("sdb", parts=[part("sdb15", "data", UD)])) is None, "find-target: a partition with another label is ignored")
    check(ft(disk("sdb")) is None, "find-target: a disk whose partitions are not there yet gives None (caller retries)")
    check(str(ft(disk("sdb", parts=[part("sdb14", "userdata", UD), part("sdb15", "userdata", UD)]))).startswith("ambiguous"),
          "find-target: two userdata partitions on one disk is ambiguous")
    check(str(ft(board, disk("sdc", parts=board["children"]))).startswith("ambiguous"),
          "find-target: two qualifying USB disks is ambiguous")
    check(ft(disk("sdb", size=str(DISK), parts=[part("sdb15", "userdata", str(UD))])) == "/dev/sdb15",
          "find-target: sizes given as strings (older util-linux) work too")

    print("selftest: %s" % ("all ok" if rc == 0 else "FAILED"))
    return rc


def parse(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("image")
    ap.add_argument("device")
    ap.add_argument("--offset", type=lambda s: int(s, 0), required=True,
                    help="byte offset of the window inside the device (0 = start of userdata)")
    ap.add_argument("--expect-bytes", type=lambda s: int(s, 0), help="the device must be exactly this big")
    ap.add_argument("--expect-label", help="GPT partition label the device must have (block devices)")
    ap.add_argument("--expect-sha256", help="refuse unless the image file has this SHA-256")
    ap.add_argument("--skip", type=lambda s: int(s, 0), default=0, help="resume: skip this many image bytes (multiple of 4 MiB)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--verify-only", action="store_true", help="read back and compare, write nothing")
    return ap.parse_args(argv)


def main_find_target(argv):
    ap = argparse.ArgumentParser(prog="flash-root.py find-target")
    ap.add_argument("--before", default="", help="comma separated names of the USB disks that existed before ums")
    ap.add_argument("--disk-bytes", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--userdata-bytes", type=lambda s: int(s, 0), required=True)
    ns = ap.parse_args(argv)
    try:
        node = find_target(set(n for n in ns.before.split(",") if n), ns.disk_bytes, ns.userdata_bytes)
    except ValueError as exc:
        print("ambiguous: %s" % exc, file=sys.stderr)
        return 3
    if node is None:
        return 1
    print(node)
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) >= 2 and sys.argv[1] == "find-target":
        sys.exit(main_find_target(sys.argv[2:]))
    sys.exit(flash(parse(sys.argv[1:])))
