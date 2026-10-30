#!/usr/bin/env python3
"""EVB10: 在 U-Boot 命令行里给 AP6398S（BCM4359）Wi-Fi 模块上电，并通过 SDIO 读出它的身份（不用内核）。

    tools/board/sdio-probe.py [--enter] [--log FILE]

板子要停在 U-Boot 的 `=> ` 提示符上（tools/board/uboot-enter.sh；先 hw-reset.sh reset 回到干净状态）。--enter 会在板子宿主机上跑
uboot-enter.sh（需要板子在线：recovery+adb 或已经在 18d1:4d00）。命令经 ssh 交给宿主机上的 uboot-cmd.py（~/unixnu-probe，
run-kernel.sh 部署）。

做的事和 Linux 的 mmc-pwrseq-simple + dw_mmc 一致，只是手工：

  1. IOMUX：sdiom0 = GPIO2_A6/A7（D0/D1）、GPIO2_B0/B1（D2/D3）、GPIO2_B2（CMD）、GPIO2_B3（CLK），功能 2，在 BUS_IOC
     （0xfd5f8000）里：GPIO2A_IOMUX_SEL_H 0x44、GPIO2B_IOMUX_SEL_L 0x48。
     **注意**：pinctrl-rockchip.c 里 rk3588_ds_regs / rk3588_p_regs 表的偏移是驱动强度 / 上下拉寄存器（在 VCCIO3_5_IOC 等），
     不是复用寄存器；把它们当复用寄存器写，时钟脚就一直是低电平（这个脚本的第一版就踩了）。
  2. WL_REG_ON = GPIO0_C4（GPIO0 在 0xfd8a0000，DR_H 0x04 / DDR_H 0x0c）：拉低再拉高，等待 >200 ms（pwrseq 的 post-power-on-delay）。
     32.768 kHz 的 LPO 由 HYM8563 RTC 的 CLKOUT 提供，复位后默认就是开的（寄存器 0x0d = 0x80）。
  3. CRU：cclk_src_sdio（CLKSEL_CON(172) = 0xfd7c05b0）选 xin24m、不分频；DW-MSHC（0xfe2d0000）CLKDIV 0x1e → 400 kHz。
  4. CMD0 → CMD5（读 OCR：0x?0ffff00 表示 3 个 IO 功能、2.0–3.6 V）→ CMD5(OCR) → CMD3（RCA）→ CMD7。
  5. CMD52 读 CCCR、CIS 指针和 CIS（CISTPL_MANFID 0x20）；打开功能 1、请求 ALP 时钟，把背板窗口指到 ChipCommon（0x18000000），
     读 CHIPID 寄存器。

期望：MANFID 02d0:4359，CHIPID 0x17294359（BCM4359，chiprev 9 = C0，AP6398S 的固件是 fw_bcm4359c0_ag*.bin）。

读响应前要给控制器留出时间：命令在 400 kHz 下要 100 多微秒，而 md.l 紧跟在 mw.l 后面会读到上一条命令的响应，所以每条命令后
读三次 RINTSTS 再读 RESP0。
"""
import argparse
import os
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def env_value(key):
    path = os.path.join(REPO, ".env")
    for line in open(path):
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit(f"{path}: {key} is not set")


HOST = env_value("BOARD_HOST")
ADB = env_value("ADB")
LOG = []

B = 0xFE2D0000  # SDIO host (DW-MSHC)
RINTSTS, RESP0, CMDARG, CMD = B + 0x44, B + 0x30, B + 0x28, B + 0x2C


def board(cmds, to=3):
    """Send U-Boot command lines through uboot-cmd.py on the board host, return the console text."""
    remote = "cd ~/unixnu-probe && TO=%d python3 uboot-cmd.py %s" % (to, " ".join(shlex.quote(c) for c in cmds))
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST, remote],
                       capture_output=True, text=True, timeout=300)
    out = r.stdout + r.stderr
    LOG.append(out)
    return out


def sd_cmd(tag, idx, arg, flags=0, resp=True):
    """A DW-MSHC command: start | wait_prvdata | response_expect | flags | index (flags 0x100 = check CRC)."""
    c = 0x80002000 | (0x40 if resp else 0) | flags | idx
    return [f"echo @@{tag}", f"mw.l 0x{RINTSTS:x} 0xffffffff", f"mw.l 0x{CMDARG:x} 0x{arg:x}", f"mw.l 0x{CMD:x} 0x{c:x}",
            f"md.l 0x{RINTSTS:x} 1", f"md.l 0x{RINTSTS:x} 1", f"md.l 0x{RINTSTS:x} 1", f"md.l 0x{RESP0:x} 1"]


def sd_cmd52(tag, func, addr, write=False, val=0):
    arg = (func << 28) | (addr << 9) | (0x80000000 if write else 0) | (val & 0xFF)
    return sd_cmd(tag, 52, arg, 0x100)


def parse(out):
    """tag -> (RINTSTS, RESP0) from the markers in the console text."""
    res, tag, rint, resp = {}, None, None, None
    for line in out.splitlines():
        m = re.match(r"^@@(\S+)$", line.strip())
        if m:
            tag = m.group(1)
            continue
        m = re.match(r"^([0-9a-f]{8}): ([0-9a-f]{8})", line.strip())
        if m and tag:
            if int(m.group(1), 16) == RINTSTS:
                rint = int(m.group(2), 16)
            elif int(m.group(1), 16) == RESP0:
                resp = int(m.group(2), 16)
                res[tag] = (rint, resp)
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--enter", action="store_true", help="run uboot-enter.sh on the board host first")
    ap.add_argument("--log", help="write the console log here")
    args = ap.parse_args()

    if args.enter:
        r = subprocess.run(["ssh", "-o", "BatchMode=yes", HOST, f"cd ~/unixnu-probe && ADB={shlex.quote(ADB)} bash uboot-enter.sh"],
                           capture_output=True, text=True, timeout=300)
        print(r.stdout.strip())
        if r.returncode:
            sys.exit(f"uboot-enter.sh failed ({r.returncode})\n{r.stderr}")

    print("== 1. IOMUX + WL_REG_ON low")
    board(["mw.l 0xfd5f8044 0xff002200", "mw.l 0xfd5f8048 0xffff2222",   # sdiom0 function 2 (BUS_IOC)
           "mw.l 0xfd8a000c 0x00100010", "mw.l 0xfd8a0004 0x00100000",   # GPIO0_C4 output, low
           "echo @@mux", "md.l 0xfd5f8044 2"])
    time.sleep(1.0)
    print("== 2. WL_REG_ON high, wait 1 s (pwrseq wants 200 ms)")
    board(["mw.l 0xfd8a0004 0x00100010"])
    time.sleep(1.0)

    print("== 3. clock + controller + CMD0/CMD5/CMD3/CMD7")
    cmds = ["mw.l 0xfd7c05b0 0x03fc0200",                                    # cclk_src_sdio = xin24m / 1
            "echo @@gate", "md.l 0xfd7c092c 1", "md.l 0xfd7c05b0 1",
            f"mw.l 0x{B:x} 7", f"mw.l 0x{B+4:x} 1", f"mw.l 0x{B+8:x} 0x1e",  # reset, PWREN, CLKDIV: 24 MHz / 60 = 400 kHz
            f"mw.l 0x{B+0x10:x} 1", f"mw.l 0x{CMD:x} 0x80202000", f"mw.l 0x{CMD:x} 0x80202000",
            "echo @@clkpad"] + ["md.l 0xfec30070 1"] * 10                    # GPIO2 EXT_PORT, bit 11 = CLK pad
    cmds += sd_cmd("cmd0", 0, 0, 0x8000, resp=False)                         # send_init, no response
    cmds += sd_cmd("cmd5a", 5, 0)
    cmds += sd_cmd("cmd5b", 5, 0xFF8000)
    cmds += sd_cmd("cmd5c", 5, 0xFF8000)
    cmds += sd_cmd("cmd3", 3, 0, 0x100)
    out = board(cmds)
    pads = [int(m.group(1), 16) for m in re.finditer(r"^fec30070: ([0-9a-f]{8})", out, re.M)]
    toggles = sum(1 for p in pads if p & 0x800)
    print(f"   CLK pad (GPIO2_B3): high in {toggles} of {len(pads)} samples -> {'toggling' if 0 < toggles < len(pads) else 'NOT toggling'}")
    r = parse(out)
    for k in ("cmd5a", "cmd5b", "cmd5c", "cmd3"):
        if k in r:
            print(f"   {k}: RINTSTS {r[k][0]:#x} RESP0 {r[k][1]:#010x}")
    if "cmd3" not in r or "cmd5c" not in r or not (r["cmd5c"][1] >> 31):
        sys.exit("   no card answer (CMD5 response timeout?)")
    ocr = r["cmd5c"][1]
    rca = r["cmd3"][1] >> 16
    print(f"   OCR {ocr & 0xffffff:#08x}, {(ocr >> 28) & 7} IO functions, RCA {rca}")

    cmds = sd_cmd("cmd7", 7, rca << 16, 0x100)
    for tag, addr in (("cccr0", 0x00), ("caps", 0x08), ("cis0", 0x09), ("cis1", 0x0A), ("cis2", 0x0B)):
        cmds += sd_cmd52(tag, 0, addr)
    r = parse(board(cmds))
    cisptr = sum((r[f"cis{i}"][1] & 0xFF) << (8 * i) for i in range(3))
    print(f"   CCCR rev {r['cccr0'][1] & 0xff:#04x}, capabilities {r['caps'][1] & 0xff:#04x}, CIS at {cisptr:#x}")

    cmds = []
    for i in range(12):
        cmds += sd_cmd52(f"cis{i:02d}", 0, cisptr + i)
    r = parse(board(cmds))
    cis = bytes(r[f"cis{i:02d}"][1] & 0xFF for i in range(12))
    print("   CIS:", cis.hex(" "))
    k = cis.find(b"\x20\x04")
    if k < 0:
        sys.exit("   no CISTPL_MANFID in the first 12 bytes")
    manf = cis[k + 2] | cis[k + 3] << 8
    prod = cis[k + 4] | cis[k + 5] << 8
    print(f"   CISTPL_MANFID: {manf:04x}:{prod:04x}")

    cmds = (sd_cmd52("ioe", 0, 2, True, 2) + sd_cmd52("ior", 0, 3) +
            sd_cmd52("clkw", 1, 0x1000E, True, 0x08) + sd_cmd52("clkr", 1, 0x1000E) + sd_cmd52("clkr2", 1, 0x1000E) +
            sd_cmd52("w0", 1, 0x1000A, True, 0x00) + sd_cmd52("w1", 1, 0x1000B, True, 0x00) + sd_cmd52("w2", 1, 0x1000C, True, 0x18))
    for i in range(4):
        cmds += sd_cmd52(f"id{i}", 1, i)
    r = parse(board(cmds))
    chipid = sum((r[f"id{i}"][1] & 0xFF) << (8 * i) for i in range(4))
    print(f"   IORx {r['ior'][1] & 0xff:#04x}, CHIPCLKCSR {r['clkr2'][1] & 0xff:#04x} (ALP available = 0x40)")
    print(f"   ChipCommon CHIPID {chipid:#010x}: chip {chipid & 0xffff:#x} rev {(chipid >> 16) & 0xf}")

    if args.log:
        open(args.log, "w").write("\n".join(LOG))
    ok = (manf, prod) == (0x02D0, 0x4359) and chipid & 0xFFFF == 0x4359
    print("RESULT:", "AP6398S (BCM4359) identified over SDIO" if ok else "unexpected identity")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
