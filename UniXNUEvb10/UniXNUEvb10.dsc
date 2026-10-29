## @file
#
#  UniXNU hosted in upstream edk2-rk3588 firmware, Rockchip RK3588 EVB10 V10.
#
#  Same idea as UniXNURock5B.dsc, but every board-level value comes from
#  Rockchip's own EVB10 device tree (kernel-6.12: rk3588-evb10.dtsi,
#  rk3588-rk806-single.dtsi, rk3588-evb.dtsi) instead of ROCK 5B:
#
#    - three CPU/NPU bucks (rk8602@42 + rk8603@43 on I2C0, rk8602@42 on I2C1)
#    - HYM8563 RTC on I2C6, ES8388 codec on I2C7
#    - fan on PWM3 channel 0 / PWM3_M1
#    - HDMI0 + HDMI1 + type-C DP, PCIe 3.0 PHY in NABINB mode
#
#  Nothing in the upstream tree is modified: the platform DSC/FDF, the vendor
#  DTB and the ACPI DSDT all live under , and UniXNU is pulled in
#  through PACKAGES_PATH. AcpiTables' shared .asl files and the logo still come
#  from upstream through RK_COMMON_ACPI_DIR / VENDOR_DIRECTORY.
#
#  Copyright (c) 2014-2018, Linaro Limited. All rights reserved.
#  Copyright (c) 2022, Xilin Wu <wuxilin123@gmail.com>
#  Copyright (c) 2023-2025, Mario Bălănică <mariobalanica02@gmail.com>
#  Copyright (c) 2026, UniXNU contributors. All rights reserved.
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
#
##

################################################################################
#
# Defines Section - statements that will be processed to create a Makefile.
#
################################################################################
[Defines]
  PLATFORM_NAME                  = UniXNUEvb10
  PLATFORM_VENDOR                = Radxa
  PLATFORM_GUID                  = 3C1E7A54-9D62-4F80-B1C5-7E2A6F0D3B91
  PLATFORM_VERSION               = 0.1
  DSC_SPECIFICATION              = 0x00010019
  OUTPUT_DIRECTORY               = Build/$(PLATFORM_NAME)
  #
  # VENDOR_DIRECTORY stays Radxa so that $(VENDOR_DIRECTORY)/Drivers/LogoDxe
  # still resolves to upstream's logo driver. PLATFORM_DIRECTORY is just this
  # directory's name: build.sh puts  on PACKAGES_PATH, so
  # $(PLATFORM_DIRECTORY)/AcpiTables/... resolves here.
  #
  VENDOR_DIRECTORY               = Platform/$(PLATFORM_VENDOR)
  PLATFORM_DIRECTORY             = $(PLATFORM_NAME)
  SUPPORTED_ARCHITECTURES        = AARCH64
  BUILD_TARGETS                  = DEBUG|RELEASE
  SKUID_IDENTIFIER               = DEFAULT
  FLASH_DEFINITION               = Silicon/Rockchip/RK3588/RK3588.fdf
  # GenFds resolves this relative to the platform directory (this DSC's folder).
  RK_PLATFORM_FVMAIN_MODULES     = UniXNUEvb10.Modules.fdf.inc

  # EVB10 has no GMAC enabled in its device tree
  DEFINE RK3588_GMAC_ENABLE = FALSE

  #
  # HYM8563 RTC on I2C6 (EVB10 wiring, same bus number as ROCK 5B)
  #
  DEFINE RK_RTC8563_ENABLE = TRUE

  #
  # RK3588-based platform
  #
!include Silicon/Rockchip/RK3588/RK3588Platform.dsc.inc

################################################################################
#
# Library Class section - list of all Library Classes needed by this Platform.
#
################################################################################

[LibraryClasses.common]
  RockchipPlatformLib|$(PLATFORM_DIRECTORY)/Library/RockchipPlatformLib/RockchipPlatformLib.inf

  # Upstream's RK3588 PlatformLib plus an EL2 -> EL1 drop at the very start of
  # SEC. DarwinBoot only hands off from EL1, TF-A and U-Boot enter us at EL2.
  ArmPlatformLib|$(PLATFORM_DIRECTORY)/Library/UniXNUPlatformLib/UniXNUPlatformLib.inf

  # UniXNU boot manager core, shared by the application and the registrar.
  UniXNULib|UniXNUPkg/Library/UniXNULib/UniXNULib.inf

################################################################################
#
# BuildOptions Section
#
################################################################################

[BuildOptions]
  #
  # Newer clang treats several upstream patterns as errors:
  #   - RK806.c compares UINT8 vsel_reg against NA (-1);
  #   - Edid.c may return an uninitialized status;
  #   - I2cDxe.c assigns EFI_SUCCESS to an EFI_STATUS pointer instead of
  #     *I2cStatus (a genuine upstream bug, harmless here because the only
  #     caller ignores the field).
  # None of them is worth patching an upstream submodule for, so downgrade
  # them to warnings for this platform only.
  #
  *_CLANGDWARF_*_CC_FLAGS = -Wno-error=tautological-constant-out-of-range-compare -Wno-error=sometimes-uninitialized -Wno-error=non-literal-null-conversion -Wno-error=c23-extensions

################################################################################
#
# Pcd Section - list of all EDK II PCD Entries defined by this Platform.
#
################################################################################

[PcdsFixedAtBuild.common]
  # SMBIOS platform config
  gRockchipTokenSpaceGuid.PcdPlatformName|"RK3588 EVB10 V10 (UniXNU)"
  gRockchipTokenSpaceGuid.PcdPlatformVendorName|"Rockchip"
  gRockchipTokenSpaceGuid.PcdFamilyName|"RK3588 EVB"
  gRockchipTokenSpaceGuid.PcdProductUrl|"https://opensource.rock-chips.com/wiki_RK3588"
  # File name used for /dtb override lookups on the ESP; matches the blob in
  # DeviceTree/ so a user can drop a rebuilt one there.
  gRockchipTokenSpaceGuid.PcdDeviceTreeName|"rk3588-evb10-v10"

  #
  # I2C
  #
  #   bus 0: rk8602@0x42 (vdd_cpu_big0_s0), rk8603@0x43 (vdd_cpu_big1_s0)
  #   bus 1: rk8602@0x42 (vdd_npu_s0)
  #   bus 6: hym8563@0x51 (RTC, runtime access)
  #   bus 7: es8388@0x11 (audio codec, exported to the DSDT)
  #
  gRockchipTokenSpaceGuid.PcdI2cSlaveAddresses|{ 0x42, 0x43, 0x42, 0x51, 0x11 }
  gRockchipTokenSpaceGuid.PcdI2cSlaveBuses|{ 0x0, 0x0, 0x1, 0x6, 0x7 }
  gRockchipTokenSpaceGuid.PcdI2cSlaveBusesRuntimeSupport|{ FALSE, FALSE, FALSE, TRUE, FALSE }
  gRockchipTokenSpaceGuid.PcdRk860xRegulatorAddresses|{ 0x42, 0x43, 0x42 }
  gRockchipTokenSpaceGuid.PcdRk860xRegulatorBuses|{ 0x0, 0x0, 0x1 }
  gRockchipTokenSpaceGuid.PcdRk860xRegulatorTags|{ $(SCMI_CLK_CPUB01), $(SCMI_CLK_CPUB23), $(SCMI_CLK_NPU) }
  gPcf8563RealTimeClockLibTokenSpaceGuid.PcdI2cSlaveAddress|0x51
  gRockchipTokenSpaceGuid.PcdRtc8563Bus|0x6

  #
  # PCIe/SATA/USB Combo PIPE PHY support flags and default values
  #
  # EVB10 wiring, from rk3588-evb10.dtsi:
  #   combphy0_ps  -> pcie2x1l2 (fe190000, M.2 M-key) OR sata0 (fe210000)
  #                   (Rockchip's FDT enables both; they share the same PHY,
  #                    so only one can be active. Default to PCIe and leave it
  #                    switchable in the setup menu.)
  #   combphy1_ps  -> pcie2x1l0 (fe170000)
  #   combphy2_psu -> pcie2x1l1 (fe180000); sata2 / usbhost3 are disabled
  #
  gRK3588TokenSpaceGuid.PcdPcie30PhyModeDefault|$(PCIE30_PHY_MODE_NABINB)
  gRK3588TokenSpaceGuid.PcdPcie30x2Supported|TRUE
  gRK3588TokenSpaceGuid.PcdComboPhy0Switchable|TRUE
  gRK3588TokenSpaceGuid.PcdComboPhy1Switchable|FALSE
  gRK3588TokenSpaceGuid.PcdComboPhy2Switchable|FALSE
  gRK3588TokenSpaceGuid.PcdComboPhy0ModeDefault|$(COMBO_PHY_MODE_PCIE)
  gRK3588TokenSpaceGuid.PcdComboPhy1ModeDefault|$(COMBO_PHY_MODE_PCIE)
  gRK3588TokenSpaceGuid.PcdComboPhy2ModeDefault|$(COMBO_PHY_MODE_PCIE)

  #
  # USB/DP Combo PHY support flags and default values
  #
  # usbdp_phy0 is the type-C port (DP altmode, 2 DP lanes + USB3). Its EVB10 FDT
  # node has no rockchip,dp-lane-mux, i.e. the kernel uses the type-C alt-mode
  # table; the firmware has no alt-mode negotiation, so keep the static {2,3}
  # value upstream uses for ROCK 5B (2 DP lanes + 2 USB3 lanes).
  #
  # usbdp_phy1 is shared between USB3 (dwc3_1 on /usb@fc400000, enabled) and
  # DP1, and the EVB10 FDT pins it with rockchip,dp-lane-mux = <2 3>. Keep that
  # value so the PHY comes up in the same DP+USB mode the kernel uses.
  # Note /dp@fde60000 itself is status="disabled" in the EVB10 FDT: there is no
  # DP1 connector, and PcdDisplayConnectors below does not advertise one, so
  # nothing drives the DP half of this PHY.
  #
  gRK3588TokenSpaceGuid.PcdUsbDpPhy0Supported|TRUE
  gRK3588TokenSpaceGuid.PcdUsbDpPhy1Supported|TRUE
  gRK3588TokenSpaceGuid.PcdDp0LaneMux|{ 0x2, 0x3 }
  gRK3588TokenSpaceGuid.PcdDp1LaneMux|{ 0x2, 0x3 }

  #
  # I2S
  #
  gRK3588TokenSpaceGuid.PcdI2S0Supported|TRUE

  #
  # On-Board fan output (PWM3 channel 0, PWM3_M1 on GPIO3_B2)
  #
  gRK3588TokenSpaceGuid.PcdHasOnBoardFanOutput|TRUE

  #
  # Display support flags and default values
  #
  # EVB10 has HDMI0, HDMI1 and DP0 (type-C altmode); the DSI panel and eDP
  # outputs are not modelled by the firmware.
  #
  gRK3588TokenSpaceGuid.PcdDisplayConnectors|{CODE({
    VOP_OUTPUT_IF_HDMI0,
    VOP_OUTPUT_IF_HDMI1,
    VOP_OUTPUT_IF_DP0
  })}

  #
  # ACPI / Device Tree
  #
  # EVB10 only has a Rockchip vendor device tree; the mainline kernel has no
  # rk3588-evb10 board file. RockchipPlatformLib only answers
  # FDT_COMPAT_MODE_VENDOR, so make that the default explicitly instead of
  # relying on RK3588Dxe's "first supported mode" fallback.
  #
  gRK3588TokenSpaceGuid.PcdFdtCompatModeDefault|$(FDT_COMPAT_MODE_VENDOR)

  #
  # UniXNU: keep the boot manager's own log at DEBUG_INFO, the firmware's at
  # its default.
  #
  gUniXNUPkgTokenSpaceGuid.PcdUniXNUDebugLevel|0x00000040

################################################################################
#
# Components Section - list of all EDK II Modules needed by this Platform.
#
################################################################################
[Components.common]
  # ACPI Support (EVB10 DSDT: ES8388 on I2C7, jack detect on GPIO1_C4)
  $(PLATFORM_DIRECTORY)/AcpiTables/AcpiTables.inf

  # Device Tree Support (vendor only: mainline has no rk3588-evb10 board file)
  $(PLATFORM_DIRECTORY)/DeviceTree/Vendor.inf

  # Splash screen logo
  $(VENDOR_DIRECTORY)/Drivers/LogoDxe/LogoDxe.inf

  # UniXNU: boot manager application, registrar driver and the XNU loader.
  #
  # DebugLib is overridden for these three: the firmware default is
  # BaseDebugLibSerialPort on the hardcoded RK3588 debug UART (0xfeb50000),
  # which is right on the board but faults under emulation. StdErr goes to
  # ConOut, so the same binaries print on the board's serial console and in
  # QEMU. UniXNU's own log lines already prefer EFI_SERIAL_IO_PROTOCOL.
  UniXNUPkg/Application/UniXNU/UniXNU.inf {
    <LibraryClasses>
      DebugLib|MdePkg/Library/UefiDebugLibStdErr/UefiDebugLibStdErr.inf
  }
  UniXNUPkg/Driver/UniXNUDxe/UniXNUDxe.inf {
    <LibraryClasses>
      DebugLib|MdePkg/Library/UefiDebugLibStdErr/UefiDebugLibStdErr.inf
  }
  DarwinBootPkg/Driver/DarwinBoot.inf {
    <LibraryClasses>
      DebugLib|MdePkg/Library/UefiDebugLibStdErr/UefiDebugLibStdErr.inf
  }

  # RAM disk holding the payload (the bootloader's initrd) or the ESP image
  # from the FV (see RamDisk/). It registers at EndOfDxe, before any console
  # exists, so it keeps the firmware's serial DebugLib: StdErr would drop its
  # lines, and they are the only record of where the payload came from.
  $(PLATFORM_DIRECTORY)/RamDisk/UniXNURamDiskDxe.inf

  # Hardware watchdog safety net: this board cannot be power-cycled remotely, so
  # a hung firmware or kernel has to end in a reset by itself. The probe stub
  # arms the DW watchdog before it enters the firmware; this driver keeps it fed
  # until ExitBootServices and then leaves the kernel one window (about 89 s)
  # before the SoC resets. The watchdog cannot be disarmed once armed, see
  # BootWdt/UniXNUBootWdtDxe.c for the switches (PROBE_WDT=0, unixnu.wdt=0).
  $(PLATFORM_DIRECTORY)/BootWdt/UniXNUBootWdtDxe.inf
