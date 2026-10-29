## @file
#
#  Main firmware volume module list for the UniXNU RK3588 EVB10 build.
#
#  Same structure as upstream's ROCK5B.Modules.fdf.inc: ACPI + device tree +
#  logo, then the UniXNU trio. Everything else (GPIO, display, storage, PCIe,
#  network, shell) comes from edk2-rockchip's shared FDF includes unchanged.
#
#  Note there is only one DTB here: Rockchip's vendor tree for EVB10. The
#  mainline kernel has no rk3588-evb10 board file, and RockchipPlatformLib
#  only answers FDT_COMPAT_MODE_VENDOR, so building a mainline DTB would just
#  add dead weight.
#
#  Copyright (c) 2023-2025, Mario Bălănică <mariobalanica02@gmail.com>
#  Copyright (c) 2026, UniXNU contributors. All rights reserved.
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
#
##

  # ACPI Support
  INF RuleOverride = ACPITABLE $(PLATFORM_DIRECTORY)/AcpiTables/AcpiTables.inf

  # Device Tree Support
  INF RuleOverride = DTB $(PLATFORM_DIRECTORY)/DeviceTree/Vendor.inf

  # Splash screen logo
  INF $(VENDOR_DIRECTORY)/Drivers/LogoDxe/LogoDxe.inf

  #
  # UniXNU
  #
  # Order matters: the registrar driver looks up the application in the same
  # firmware volume, and DarwinBoot produces the loader protocol UniXNU asks
  # for when a menu entry is of type "xnu".
  #
  INF UniXNUPkg/Application/UniXNU/UniXNU.inf
  INF UniXNUPkg/Driver/UniXNUDxe/UniXNUDxe.inf
  INF DarwinBootPkg/Driver/DarwinBoot.inf

  #
  # RAM disk with the ESP (\EFI\UniXNU\unixnu.toml). The board has no file
  # system volume, so UniXNU would otherwise fall back to its built-in menu.
  # The FAT image is built by build.sh (tools/mkesp-fv.py); the FILE GUID is
  # also in RamDisk/UniXNURamDiskDxe.c.
  #
  INF $(PLATFORM_DIRECTORY)/RamDisk/UniXNURamDiskDxe.inf
  FILE FREEFORM = 7A3C9E10-5B6D-4F2A-9D14-8E0C5A1B2F47 {
    SECTION RAW = $(PLATFORM_DIRECTORY)/RamDisk/esp.img
  }

  #
  # Hardware watchdog safety net (see BootWdt/UniXNUBootWdtDxe.c).
  #
  INF $(PLATFORM_DIRECTORY)/BootWdt/UniXNUBootWdtDxe.inf
