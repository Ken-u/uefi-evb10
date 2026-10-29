# uefi-evb10

UEFI firmware platform for the **Rockchip RK3588 EVB10 V10** that boots UniXNU. It builds on
[edk2-rk3588](https://github.com/edk2-porting/edk2-rk3588) without modifying it: the platform DSC/FDF
fragments live here, the UniXNU packages are attached through `PACKAGES_PATH`, and the result is an
8 MB SPI NOR image (GPT + idblock + FIT with BL31, OP-TEE and the UEFI firmware volume).

See the [UEFI firmware guide](https://unixnu.com/porting/uefi-firmware). Board repository:
`UniXNU-evb10`; SoC: `UniXNU-rk3588-common`.

## Layout

| Path | Contents |
| --- | --- |
| `UniXNUEvb10/` | The platform: `UniXNUEvb10.dsc`, `UniXNUEvb10.Modules.fdf.inc`, ACPI tables (codec differences), `Library/RockchipPlatformLib` (PMIC, I2C, PCIe, fan, LED, WiFi hooks), `Library/UniXNUPlatformLib` (adds the EL2 to EL1 drop that DarwinBoot needs), `BootWdt` (hardware watchdog safety net), `RamDisk` (publishes the payload that U-Boot passes as initrd, and the built-in `unixnu.toml`) |
| `build.sh` | One command: build the firmware and pack the NOR image |
| `tools/build-evb10-dtb.sh` | Generates the vendor dtb of the firmware from the Rockchip kernel's EVB10 dts |
| `tools/mkesp-fv.py` | Packs `RamDisk/esp/` into the FAT image that goes into the firmware volume |
| `tools/stub/` | The stub that moves the firmware volume to 0x200000 and jumps into it, so U-Boot can `fastboot boot` the firmware without flashing the NOR |
| `tools/board/` | Boot-image assembly and board control: `make-payload-boot.sh`, `mk-bootimg.sh`, `patch-payload-toml.py`, `board-launch.sh`, `hw-reset.sh`, serial helpers |
| `tools/xnu-probe/` | Run loop and analysis: `run-kernel.sh`, `summarize-run.sh`, trust-cache and Data-seed generators, screenshot and symbolication helpers |
| `tests/` | Host tests: `bootwdt-args` (watchdog argument parser under ASan/UBSan, with mutation testing) and `el2drop` (the EL2 to EL1 assembly under QEMU) |

## Build

All machine-specific paths, hosts and accounts go into `.env` (git-ignored); copy `.env.example`
and fill it in. Required: an edk2-rk3588 checkout with submodules (`UPSTREAM`), a UniXNU checkout
at `f85b5a6` or newer (`UNIXNU`), clang 20 (`CLANG_BIN`) and `iasl` on `PATH`.

```sh
tools/build-evb10-dtb.sh        # regenerate UniXNUEvb10/DeviceTree/rk3588-evb10-v10.dtb (needs KERNEL_TREE)
./build.sh -b DEBUG             # firmware + NOR image into out/
```

Outputs in `out/`: `RK3588_NOR_FLASH-unixnu-evb10.img` (8 MB, the flashable image),
`BL33_AP_UEFI-evb10.Fv`, `unixnu-evb10_EFI.itb` and the single modules (`UniXNU.efi`,
`UniXNUDxe.efi`, `DarwinBoot.efi`). DEBUG is required for bring-up: the serial log depends on it.

To try the firmware without touching SPI, `tools/stub/build.sh` wraps the firmware volume into a
Linux Image and `tools/board/make-payload-boot.sh` packs it with the payload into a `boot.img`
for U-Boot's fastboot. `tools/board/board-launch.sh` runs on the board host and drives the
sequence (it never writes flash). The boot image is limited to 112 MiB by U-Boot's fastboot buffer.

## Status

Verified on the EVB10 board: UEFI starts, `UniXNURamDiskDxe` finds the payload, the UniXNU menu and
DarwinBoot hand off to the kernel (serial console at 1.5 Mbaud on UART2). Host tests pass.
The eMMC controller initialization of the vendor firmware fails about once in five boots
(`EmmcSetBusMode: Switch to HS400 CRC Error`); `run-kernel.sh` repeats such a run.

Not in this repository: the vendor binaries of edk2-rk3588 (DDR blob, BL31, OP-TEE; they come with
the upstream checkout) and the generated dtb and ESP image.

## Safety notes for the tools

- `hw-reset.sh` presses the board's RESET/RECOVERY/MASKROM keys through an ESP32-S3 controller. It makes
  one attempt and never retries: repeating RESET interrupts the boot chain.
- `patch-payload-toml.py` removes the `shutdown` entry from the payload menu: on this board shutdown is
  PSCI SYSTEM_OFF and nothing can power the board on again remotely.
- Only one serial reader at a time; `board-launch.sh` takes a lock.

## License

BSD-2-Clause-Patent, see `LICENSE`. The platform files derive from edk2-rk3588 and EDK II
(also BSD-2-Clause-Patent).
