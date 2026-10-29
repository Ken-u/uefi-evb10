//
//  ArmPlatformPeiBootAction for UniXNU on RK3588: drop from EL2 to EL1.
//
//  DarwinBoot (the UniXNU kernel loader) can only hand off from EL1, see
//  DarwinEnter in DarwinBoot/Entry.S, and TF-A and U-Boot both enter the
//  firmware at EL2. This runs first thing in the SEC entry point
//  (PeilessSec ModuleEntryPoint calls it before it sets up a stack and before
//  any C code), so the rest of the firmware starts life at EL1.
//
//  The code has to do three jobs:
//
//   1. Leave EL2 permissive: everything EL1 will want must work without a
//      hypervisor, i.e. nothing trapped, no stage 2, EL1 is AArch64, EL1 owns
//      the physical timer and the GICv3 CPU interface. These registers are
//      the same ones Linux's el2_setup programs, and they stay in force for
//      the kernel that DarwinBoot starts later: XNU runs at EL1 on this
//      board and talks to the GIC and the arch timer from there.
//   2. Give EL1 a known SCTLR_EL1 (MMU, caches, alignment checks off).
//   3. ERET to the caller, at EL1h, with DAIF masked. x30 is the return
//      address of the "bl ArmPlatformPeiBootAction" in the entry point; the
//      SP is not touched (the entry point loads it afterwards, and it is
//      SP_EL1 from then on).
//
//  Already at EL1 (or EL3): nothing to do, plain return.
//
//  Clobbers x0-x2 only, which the entry point does not rely on.
//
//  Copyright (c) 2026, UniXNU contributors. All rights reserved.
//
//  SPDX-License-Identifier: BSD-2-Clause-Patent
//

#include <AsmMacroLib.h>

// ICC_SRE_EL2 (S3_4_C12_C9_5), spelled numerically: older binutils do not
// know the GICv3 register names.
#define ICC_SRE_EL2  S3_4_C12_C9_5

ASM_FUNC (ArmPlatformPeiBootAction)
  mrs   x0, CurrentEL
  cmp   x0, #(2 << 2)
  b.ne  .Lnodrop

  // EL1 is AArch64; every other HCR_EL2 bit zero: no stage 2 (VM), no TGE,
  // no interrupt/abort routing to EL2, no WFI/WFE or SMC traps.
  mov   x0, #(1 << 31)
  msr   hcr_el2, x0

  // EL1 may use the physical counter and timer; no virtual counter offset.
  mrs   x0, cnthctl_el2
  orr   x0, x0, #3                // EL1PCTEN | EL1PCEN
  msr   cnthctl_el2, x0
  msr   cntvoff_el2, xzr

  // GICv3 system register interface (ID_AA64PFR0_EL1.GIC != 0): let EL1 use
  // ICC_SRE_EL1. ICC_SRE_EL2.SRE=1 makes ICC_SRE_EL1.SRE read as one.
  mrs   x0, id_aa64pfr0_el1
  ubfx  x0, x0, #24, #4
  cbz   x0, .Lnogic
  mrs   x0, ICC_SRE_EL2
  orr   x0, x0, #(1 << 0)         // SRE
  orr   x0, x0, #(1 << 3)         // Enable (lower ELs may use ICC_SRE_EL1)
  msr   ICC_SRE_EL2, x0
  isb
.Lnogic:

  // No trapping of FP/SIMD (or anything else CPTR_EL2 controls) to EL2. The
  // value is the RES1 pattern for a core without SVE.
  mov   x0, #0x33ff
  msr   cptr_el2, x0

  // EL1 sees the real MIDR/MPIDR.
  mrs   x0, midr_el1
  mrs   x1, mpidr_el1
  msr   vpidr_el2, x0
  msr   vmpidr_el2, x1

  // Debug and PMU: no traps; HPMN covers every counter when there is a PMU.
  mov   x0, xzr
  mrs   x1, id_aa64dfr0_el1
  ubfx  x1, x1, #8, #4            // PMUVer
  cbz   x1, .Lnopmu
  cmp   x1, #0xf                  // IMPLEMENTATION DEFINED PMU
  b.eq  .Lnopmu
  mrs   x0, pmcr_el0
  ubfx  x0, x0, #11, #5           // PMCR_EL0.N
.Lnopmu:
  msr   mdcr_el2, x0

  // SCTLR_EL1: little endian, MMU/caches/alignment checks off, RES1 bits set.
  mov   x0, #0x0800
  movk  x0, #0x30d0, lsl #16
  msr   sctlr_el1, x0

  // ERET to the caller at EL1h with D, A, I and F masked.
  mov   x0, #0x3c5
  msr   spsr_el2, x0
  msr   elr_el2, x30
  isb
  eret

.Lnodrop:
  ret
