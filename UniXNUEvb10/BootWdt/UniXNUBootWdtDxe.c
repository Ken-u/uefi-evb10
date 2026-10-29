/** @file
  Hardware watchdog safety net for bring-up on the RK3588 EVB10.

  Why: this board has no remote power control (no PDU, the hub cannot switch
  port power, the serial adapter's DTR/RTS are not wired to it), and the owner
  asked that nobody ever has to touch it. A hang therefore has to end in a reset
  by itself. The DesignWare watchdog at 0xFEAF0000 does that: the TF-A of this
  SoC routes its expiry into the first global reset (the one PSCI SYSTEM_RESET
  uses too), and the sweet bring-up proved on this very board that after such a
  reset it is disarmed again (bring-up notes).

  Facts about this block that shape the code (bring-up notes 91, measured):
    * Once armed it cannot be disarmed: CR.EN stays set, CCVR keeps counting
      (WDT_ALWAYS_EN). Only a reset clears it. So everything that can fail
      happens BEFORE arming, and nothing here ever tries to "undo" it.
    * TORR 0xF is the longest period, 2^31 counts. At the 24 MHz that CCVR was
      measured to run at this is about 89.5 s, not the "about 20 s" of the
      first guess. This driver measures the rate and prints the real window.
    * Writing CRR 0x76 restarts the count. CRR must be written once before CR
      is set to arm, or nothing happens.

  What it does:
    * The probe stub (tools/stub/probe.S) already arms the watchdog before it
      jumps into the firmware, so even a hang in SEC/PEI/early DXE ends in a
      reset. If the watchdog is already armed this driver only keeps it fed.
      If it is not armed (a flash image without the stub) it arms it itself,
      unless the boot image command line holds the word `unixnu.wdt=0`.
    * A periodic timer event kicks it every 5 s while boot services exist.
    * At ExitBootServices it cancels that event and kicks once more: the kernel
      gets one full window (about 89 s) to produce output. Nothing in UniXNU
      kicks this watchdog yet, so after the hand-off the SoC always resets about
      89 s later, which is what bring-up wants: a hung kernel cannot strand the
      board. Whatever the kernel does later (its own driver, a reset) is its own
      business.

  `unixnu.wdt=0` (mk-bootimg.sh CMDLINE=...) only decides whether THIS driver
  arms the watchdog; it cannot disarm one that is already running. For a run
  without any watchdog, build the probe without the stub arming
  (PROBE_WDT=0 tools/stub/build.sh) AND pass `unixnu.wdt=0`. The command line
  comes from the FDT whose address the probe stub leaves in TPIDRRO_EL0 (same
  hand-off UniXNURamDiskDxe uses). A missing FDT or bootargs leaves things
  armed: failing safe means failing towards a reset, never towards a hang.

  Copyright (c) 2026, UniXNU contributors. All rights reserved.
  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

#include <Uefi.h>

#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/FdtLib.h>
#include <Library/IoLib.h>
#include <Library/TimerLib.h>
#include <Library/UefiBootServicesTableLib.h>

#include "UniXNUBootWdtArgs.h"

//
// Synopsys DesignWare APB watchdog, RK3588 WDT0.
//
#define WDT_BASE      0xFEAF0000ULL
#define WDT_CR        0x00
#define WDT_TORR      0x04
#define WDT_CCVR      0x08
#define WDT_CRR       0x0C
#define WDT_CR_EN     0x01
#define WDT_CR_ARM    0x09   // EN, RMOD 0 (reset, no interrupt first), RPL 2 (8 pclk)
#define WDT_TORR_MAX  0x0F   // 2^(16+15) counts
#define WDT_KICK      0x76
#define WDT_COUNTS    0x7FFFFFFFULL   // CCVR right after a kick at TORR 0xF

#define KICK_PERIOD_100NS  (5ULL * 10 * 1000 * 1000)   // 5 s
#define SAMPLE_US          10000

STATIC EFI_EVENT  mKickEvent;
STATIC EFI_EVENT  mExitEvent;
STATIC UINT64     mWindowSeconds;   // 0 until measured

STATIC
VOID
Kick (
  VOID
  )
{
  MmioWrite32 (WDT_BASE + WDT_CRR, WDT_KICK);
}

STATIC
VOID
EFIAPI
KickNotify (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  Kick ();
}

STATIC
VOID
EFIAPI
ExitBootServicesNotify (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  //
  // Memory services are already closed here: no allocation, only what a plain
  // timer cancel and a register write need.
  //
  gBS->SetTimer (mKickEvent, TimerCancel, 0);
  Kick ();
  DEBUG ((
    DEBUG_ERROR,
    "UniXNUBootWdt: ExitBootServices: last kick done, the SoC resets in about %lu s unless the OS kicks 0x%lx\n",
    (mWindowSeconds != 0) ? mWindowSeconds : 89ULL,
    (UINT64)WDT_BASE
    ));
}

/**
  Read how fast the counter runs and print the real window. Informational:
  nothing depends on the result except the number shown at ExitBootServices.
**/
STATIC
VOID
MeasureWindow (
  IN CONST CHAR8  *How
  )
{
  UINT32  First;
  UINT32  Second;
  UINT64  Rate;

  //
  // MicroSecondDelay reads the ARM generic counter directly. gBS->Stall would
  // answer EFI_NOT_AVAILABLE_YET if the Metronome protocol is not there yet,
  // and this driver does not wait for it.
  //
  First = MmioRead32 (WDT_BASE + WDT_CCVR);
  MicroSecondDelay (SAMPLE_US);
  Second = MmioRead32 (WDT_BASE + WDT_CCVR);

  if ((Second >= First) || ((First - Second) == 0)) {
    DEBUG ((
      DEBUG_ERROR,
      "UniXNUBootWdt: %a, but the counter is not running as expected (CCVR 0x%x -> 0x%x)\n",
      How,
      First,
      Second
      ));
    return;
  }

  Rate           = (UINT64)(First - Second) * (1000000ULL / SAMPLE_US);
  mWindowSeconds = WDT_COUNTS / Rate;
  DEBUG ((
    DEBUG_ERROR,
    "UniXNUBootWdt: %a, CR 0x%x TORR 0x%x, counter about %lu Hz => window about %lu s, kicked every 5 s until ExitBootServices\n",
    How,
    MmioRead32 (WDT_BASE + WDT_CR),
    MmioRead32 (WDT_BASE + WDT_TORR),
    Rate,
    mWindowSeconds
    ));
}

/**
  TRUE only if the boot image command line holds the word `unixnu.wdt=0`.
**/
STATIC
BOOLEAN
DisabledByBootArgs (
  VOID
  )
{
  UINT64       Dtb;
  CONST VOID   *Fdt;
  INT32        Chosen;
  INT32        Length;
  CONST CHAR8  *Args;
  CHAR8        Shown[161];

  __asm__ __volatile__ ("mrs %0, tpidrro_el0" : "=r" (Dtb));
  if ((Dtb == 0) || ((Dtb & 3) != 0) || (FdtCheckHeader ((VOID *)(UINTN)Dtb) != 0)) {
    DEBUG ((DEBUG_ERROR, "UniXNUBootWdt: no handoff FDT (TPIDRRO_EL0 0x%lx), command line unknown\n", Dtb));
    return FALSE;
  }

  Fdt    = (CONST VOID *)(UINTN)Dtb;
  Chosen = FdtPathOffset (Fdt, "/chosen");
  if (Chosen < 0) {
    return FALSE;
  }

  Length = 0;
  Args   = FdtGetProp (Fdt, Chosen, "bootargs", &Length);
  if ((Args == NULL) || (Length <= 0)) {
    DEBUG ((DEBUG_ERROR, "UniXNUBootWdt: /chosen has no bootargs\n"));
    return FALSE;
  }

  ZeroMem (Shown, sizeof (Shown));
  CopyMem (Shown, Args, MIN ((UINTN)Length, sizeof (Shown) - 1));
  DEBUG ((DEBUG_ERROR, "UniXNUBootWdt: bootargs (%d bytes): %a\n", Length, Shown));

  return BootArgsHasWord (Args, (UINTN)Length, "unixnu.wdt=0", 12);
}

EFI_STATUS
EFIAPI
UniXNUBootWdtEntry (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS  Status;
  BOOLEAN     Armed;
  BOOLEAN     Off;

  Armed = (MmioRead32 (WDT_BASE + WDT_CR) & WDT_CR_EN) != 0;
  Off   = DisabledByBootArgs ();

  if (!Armed && Off) {
    DEBUG ((DEBUG_ERROR, "UniXNUBootWdt: not arming 0x%lx (unixnu.wdt=0)\n", (UINT64)WDT_BASE));
    return EFI_SUCCESS;
  }

  //
  // Everything that can fail comes first, because an armed watchdog cannot be
  // disarmed. Kicking is known to work before this driver arms anything.
  //
  Status = gBS->CreateEvent (EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK, KickNotify, NULL, &mKickEvent);
  if (!EFI_ERROR (Status)) {
    Status = gBS->SetTimer (mKickEvent, TimerPeriodic, KICK_PERIOD_100NS);
  }

  if (!EFI_ERROR (Status)) {
    Status = gBS->CreateEventEx (
                    EVT_NOTIFY_SIGNAL,
                    TPL_CALLBACK,
                    ExitBootServicesNotify,
                    NULL,
                    &gEfiEventExitBootServicesGuid,
                    &mExitEvent
                    );
  }

  if (EFI_ERROR (Status)) {
    if (mKickEvent != NULL) {
      gBS->CloseEvent (mKickEvent);
      mKickEvent = NULL;
    }

    DEBUG ((
      DEBUG_ERROR,
      "UniXNUBootWdt: cannot set up kicking (%r); %a\n",
      Status,
      Armed ? "the watchdog was armed earlier and nothing will feed it: the board resets" : "left unarmed"
      ));
    return EFI_SUCCESS;
  }

  if (Armed) {
    Kick ();
    if (Off) {
      DEBUG ((DEBUG_ERROR, "UniXNUBootWdt: unixnu.wdt=0, but the watchdog is armed already (probe stub) and cannot be disarmed: feeding it\n"));
    }

    MeasureWindow ("already armed");
  } else {
    MmioWrite32 (WDT_BASE + WDT_CR, 0);
    MmioWrite32 (WDT_BASE + WDT_TORR, WDT_TORR_MAX);
    Kick ();
    MmioWrite32 (WDT_BASE + WDT_CR, WDT_CR_ARM);
    MeasureWindow ("armed here");
  }

  return EFI_SUCCESS;
}
