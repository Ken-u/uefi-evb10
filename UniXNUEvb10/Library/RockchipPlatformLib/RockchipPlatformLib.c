/** @file
*
*  Rockchip RK3588 EVB10 (V10) platform hooks.
*
*  Board data here is taken from Rockchip's own device tree
*  (kernel-6.12: rk3588-evb10.dtsi + rk3588-rk806-single.dtsi), not from
*  ROCK 5B. Anything that differs between the two boards lives here:
*
*    - RK806 single PMIC on SPI2 in SPI2_M2 mux (same as ROCK 5B), but the
*      rail set/voltages follow the EVB10 device tree. DCDC_REG2
*      (vdd_cpu_lit_s0) boots at 800 mV and DCDC_REG4 (vdd_vdenc_s0) at
*      750 mV, per regulator-init-microvolt.
*    - Three CPU/NPU bucks: rk8602@42 + rk8603@43 on I2C0 and rk8602@42 on
*      I2C1 (the NPU rail; ROCK 5B has no NPU buck at all).
*    - HYM8563 RTC on I2C6, same address 0x51.
*    - Fan is PWM3 channel 0 via PWM3_M1 (GPIO3_B2, func 11). ROCK 5B drives
*      PWM1_M0 instead.
*    - HDMI0 on M0 pins, HDMI1 on the EVB10 mux (CEC on M2, HPD on M0,
*      SCL/SDA on M1) - see the pinctrl in rk3588-evb10.dtsi / rk3588s.dtsi.
*    - PCIe 3.0 PHY is NABINB (x4 + x1) as in the EVB10 FDT, and the x2 slot
*      never exists.
*    - USB host power is GPIO4_A5 (ROCK 5B: GPIO4_B0).
*
*  Copyright (c) 2021, Rockchip Limited. All rights reserved.
*  Copyright (c) 2023-2025, Mario Bălănică <mariobalanica02@gmail.com>
*  Copyright (c) 2026, UniXNU contributors. All rights reserved.
*
*  SPDX-License-Identifier: BSD-2-Clause-Patent
*
**/

#include <Base.h>
#include <Library/DebugLib.h>
#include <Library/IoLib.h>
#include <Library/GpioLib.h>
#include <Library/RK806.h>
#include <Library/Rk3588Pcie.h>
#include <Library/PWMLib.h>
#include <Soc.h>
#include <VarStoreData.h>

//
// EVB10 RK806 single-PMIC rail set.
//
// Only rails whose EVB10 setting differs from the reset default, or which
// must be raised before the SoC is usable, are listed. Values come from
// rk3588-rk806-single.dtsi:
//
//   DCDC_REG1 vdd_gpu_s0      boot-on, 550..950 mV (no init value: leave alone)
//   DCDC_REG2 vdd_cpu_lit_s0  boot-on, init 800 mV  -> the A55 cluster
//   DCDC_REG3 vdd_log_s0      boot-on, 675..800 mV, suspend 750 mV
//   DCDC_REG4 vdd_vdenc_s0    boot-on, init 750 mV
//   DCDC_REG5 vdd_ddr_s0      boot-on, 675..900 mV
//   DCDC_REG6..10             fixed, always-on
//   PLDO1..6, NLDO1..5        fixed, always-on
//
// Rails that are already correct after reset are still listed so that a warm
// reboot with a half-configured PMIC lands in a known state, matching what
// upstream does for ROCK 5B.
//
static struct regulator_init_data  rk806_init_data[] = {
  /* Master PMIC, buck 1..10 */
  RK8XX_VOLTAGE_INIT (MASTER_BUCK1,  750000),   // vdd_gpu_s0, EVB10 default
  RK8XX_VOLTAGE_INIT (MASTER_BUCK2,  800000),   // vdd_cpu_lit_s0, regulator-init-microvolt
  RK8XX_VOLTAGE_INIT (MASTER_BUCK3,  750000),   // vdd_log_s0, suspend-microvolt
  RK8XX_VOLTAGE_INIT (MASTER_BUCK4,  750000),   // vdd_vdenc_s0, regulator-init-microvolt
  RK8XX_VOLTAGE_INIT (MASTER_BUCK5,  850000),   // vdd_ddr_s0, suspend-microvolt
  // BUCK6..10 are fixed or DDR-only; leave them to the PMIC defaults.

  /* Master PMIC, NLDO 1..5 (all fixed on EVB10) */
  RK8XX_VOLTAGE_INIT (MASTER_NLDO1,  750000),   // vdd_0v75_s3
  RK8XX_VOLTAGE_INIT (MASTER_NLDO2,  850000),   // vdd_ddr_pll_s0
  RK8XX_VOLTAGE_INIT (MASTER_NLDO3,  837500),   // avdd_0v75_s0
  RK8XX_VOLTAGE_INIT (MASTER_NLDO4,  850000),   // vdd_0v85_s0
  RK8XX_VOLTAGE_INIT (MASTER_NLDO5,  750000),   // vdd_0v75_s0

  /* Master PMIC, PLDO 1..6 (all fixed on EVB10) */
  RK8XX_VOLTAGE_INIT (MASTER_PLDO1,  1800000),  // avcc_1v8_s0
  RK8XX_VOLTAGE_INIT (MASTER_PLDO2,  1800000),  // vcc_1v8_s0
  RK8XX_VOLTAGE_INIT (MASTER_PLDO3,  1200000),  // avdd_1v2_s0
  RK8XX_VOLTAGE_INIT (MASTER_PLDO4,  3300000),  // vcc_3v3_s0
  RK8XX_VOLTAGE_INIT (MASTER_PLDO5,  3300000),  // vccio_sd_s0 (3.3 V until the SD driver switches to 1.8 V)
  RK8XX_VOLTAGE_INIT (MASTER_PLDO6,  1800000),  // pldo6_s3

  /* No dual PMICs on this platform */
};

VOID
EFIAPI
SdmmcIoMux (
  VOID
  )
{
  /* sdmmc0 iomux (microSD socket). EVB10 keeps the SDMMC_M0 pins:
   * CLK/CMD on GPIO4_D5/D4, D0-D3 on GPIO4_D0..D3, DET on GPIO0_A4. */
  BUS_IOC->GPIO4D_IOMUX_SEL_L  = (0xFFFFUL << 16) | (0x1111); // SDMMC_D0..D3
  BUS_IOC->GPIO4D_IOMUX_SEL_H  = (0x00FFUL << 16) | (0x0011); // SDMMC_CLK,SDMMC_CMD
  PMU1_IOC->GPIO0A_IOMUX_SEL_H = (0x000FUL << 16) | (0x0001); // SDMMC_DET
}

VOID
EFIAPI
SdhciEmmcIoMux (
  VOID
  )
{
  /* sdhci0 iomux (eMMC socket) */
  BUS_IOC->GPIO2A_IOMUX_SEL_L = (0xFFFFUL << 16) | (0x1111); // EMMC_CMD,EMMC_CLKOUT,EMMC_DATASTROBE,EMMC_RSTN
  BUS_IOC->GPIO2D_IOMUX_SEL_L = (0xFFFFUL << 16) | (0x1111); // EMMC_D0,EMMC_D1,EMMC_D2,EMMC_D3
  BUS_IOC->GPIO2D_IOMUX_SEL_H = (0xFFFFUL << 16) | (0x1111); // EMMC_D4,EMMC_D5,EMMC_D6,EMMC_D7
}

#define NS_CRU_BASE       0xFD7C0000
#define CRU_CLKSEL_CON59  0x03EC
#define CRU_CLKSEL_CON78  0x0438

VOID
EFIAPI
Rk806SpiIomux (
  VOID
  )
{
  /* spi2_m2: CLK GPIO0_A5, MOSI GPIO0_A6, MISO GPIO0_B3, CS0 GPIO0_B1,
   * PMIC_INT GPIO0_A7. Same wiring as ROCK 5B / EVB1. */
  PMU1_IOC->GPIO0A_IOMUX_SEL_H = (0x0FF0UL << 16) | 0x0110;
  PMU1_IOC->GPIO0B_IOMUX_SEL_L = (0xF0FFUL << 16) | 0x1011;
  MmioWrite32 (NS_CRU_BASE + CRU_CLKSEL_CON59, (0x00C0UL << 16) | 0x0080);
}

VOID
EFIAPI
Rk806Configure (
  VOID
  )
{
  UINTN  RegCfgIndex;

  RK806Init ();

  RK806PinSetFunction (MASTER, 1, 2); // rk806_dvs1_pwrdn

  for (RegCfgIndex = 0; RegCfgIndex < ARRAY_SIZE (rk806_init_data); RegCfgIndex++) {
    RK806RegulatorInit (rk806_init_data[RegCfgIndex]);
  }
}

VOID
EFIAPI
SetCPULittleVoltage (
  IN UINT32  Microvolts
  )
{
  struct regulator_init_data  Rk806CpuLittleSupply =
    RK8XX_VOLTAGE_INIT (MASTER_BUCK2, Microvolts);

  RK806RegulatorInit (Rk806CpuLittleSupply);
}

VOID
EFIAPI
NorFspiIomux (
  VOID
  )
{
  /* io mux */
  MmioWrite32 (
    NS_CRU_BASE + CRU_CLKSEL_CON78,
    (((0x3 << 12) | (0x3f << 6)) << 16) | (0x0 << 12) | (0x3f << 6)
    );
  #define FSPI_M1
 #if defined (FSPI_M0)
  /*FSPI M0*/
  BUS_IOC->GPIO2A_IOMUX_SEL_L = ((0xF << 0) << 16) | (2 << 0);   // FSPI_CLK_M0
  BUS_IOC->GPIO2D_IOMUX_SEL_L = (0xFFFFUL << 16) | (0x2222);     // FSPI_D0_M0,FSPI_D1_M0,FSPI_D2_M0,FSPI_D3_M0
  BUS_IOC->GPIO2D_IOMUX_SEL_H = ((0xF << 8) << 16) | (0x2 << 8); // FSPI_CS0N_M0
 #elif defined (FSPI_M1)
  /*FSPI M1*/
  BUS_IOC->GPIO2A_IOMUX_SEL_H = (0xFF00UL << 16) | (0x3300); // FSPI_D0_M1,FSPI_D1_M1
  BUS_IOC->GPIO2B_IOMUX_SEL_L = (0xF0FFUL << 16) | (0x3033); // FSPI_D2_M1,FSPI_D3_M1,FSPI_CLK_M1
  BUS_IOC->GPIO2B_IOMUX_SEL_H = (0xF << 16) | (0x3);         // FSPI_CS0N_M1
 #else
  /*FSPI M2*/
  BUS_IOC->GPIO3A_IOMUX_SEL_L = (0xFFFFUL << 16) | (0x5555); // [FSPI_D0_M2-FSPI_D3_M2]
  BUS_IOC->GPIO3A_IOMUX_SEL_H = (0xF0UL << 16) | (0x50);     // FSPI_CLK_M2
  BUS_IOC->GPIO3C_IOMUX_SEL_H = (0xF << 16) | (0x2);         // FSPI_CS0_M2
 #endif
}

VOID
EFIAPI
GmacIomux (
  IN UINT32  Id
  )
{
  /* No GMAC on EVB10 (both gmac0 and gmac1 are disabled in its FDT) */
}

VOID
EFIAPI
NorFspiEnableClock (
  UINT32  *CruBase
  )
{
  UINTN  BaseAddr = (UINTN)CruBase;

  MmioWrite32 (BaseAddr + 0x087C, 0x0E000000);
}

VOID
EFIAPI
I2cIomux (
  UINT32  id
  )
{
  switch (id) {
    case 0:
      /* EVB10: i2c0m2_xfer -> GPIO0_D1/GPIO0_D2, func 3 */
      GpioPinSetFunction (0, GPIO_PIN_PD1, 3); // i2c0_scl_m2
      GpioPinSetFunction (0, GPIO_PIN_PD2, 3); // i2c0_sda_m2
      break;
    case 1:
      /* EVB10: i2c1m2_xfer -> GPIO0_D4/GPIO0_D5, func 9 */
      GpioPinSetFunction (0, GPIO_PIN_PD4, 9); // i2c1_scl_m2
      GpioPinSetFunction (0, GPIO_PIN_PD5, 9); // i2c1_sda_m2
      break;
    case 2:
      break;
    case 3:
      break;
    case 4:
      break;
    case 5:
      break;
    case 6:
      /* EVB10: i2c6m0_xfer -> GPIO0_PD0/GPIO0_PC7, func 9 (HYM8563 RTC) */
      GpioPinSetFunction (0, GPIO_PIN_PD0, 9); // i2c6_scl_m0
      GpioPinSetFunction (0, GPIO_PIN_PC7, 9); // i2c6_sda_m0
      break;
    case 7:
      /* EVB10: i2c7m0_xfer -> GPIO1_PD0/GPIO1_PD1, func 9 (ES8388 codec) */
      GpioPinSetFunction (1, GPIO_PIN_PD0, 9); // i2c7_scl_m0
      GpioPinSetFunction (1, GPIO_PIN_PD1, 9); // i2c7_sda_m0
      break;
    default:
      break;
  }
}

VOID
EFIAPI
UsbPortPowerEnable (
  VOID
  )
{
  DEBUG ((DEBUG_INFO, "UsbPortPowerEnable called\n"));
  /* EVB10: vcc5v0_host enable is GPIO4_A5 (active high) */
  GpioPinWrite (4, GPIO_PIN_PA5, TRUE);
  GpioPinSetDirection (4, GPIO_PIN_PA5, GPIO_PIN_OUTPUT);
}

VOID
EFIAPI
Usb2PhyResume (
  VOID
  )
{
  MmioWrite32 (0xfd5d0008, 0x20000000);
  MmioWrite32 (0xfd5d4008, 0x20000000);
  MmioWrite32 (0xfd5d8008, 0x20000000);
  MmioWrite32 (0xfd5dc008, 0x20000000);
  MmioWrite32 (0xfd7f0a10, 0x07000700);
  MmioWrite32 (0xfd7f0a10, 0x07000000);
}

VOID
EFIAPI
PcieIoInit (
  UINT32  Segment
  )
{
  /* Set reset and power IO to gpio output mode.
   *
   * EVB10 reset lines (all GPIO_ACTIVE_HIGH in the FDT):
   *   PCIE3x4   GPIO4_B6
   *   PCIE3x2   GPIO3_D0
   *   PCIE2x1l0 GPIO0_A4
   *   PCIE2x1l1 GPIO4_D5
   *   PCIE2x1l2 GPIO4_D4
   * Power enables handled here are the ones that are not always-on:
   *   vcc3v3_pciem1 GPIO4_B5, vcc3v3_pciem2 GPIO1_A1, vcc3v3_pciem3 GPIO1_A4
   *   (vcc3v3_pcie30 on GPIO2_C5 is regulator-always-on in the FDT.)
   */
  switch (Segment) {
    case PCIE_SEGMENT_PCIE30X4:
      GpioPinSetDirection (4, GPIO_PIN_PB6, GPIO_PIN_OUTPUT); // PERST#
      break;
    case PCIE_SEGMENT_PCIE30X2:
      GpioPinSetDirection (3, GPIO_PIN_PD0, GPIO_PIN_OUTPUT); // PERST#
      break;
    case PCIE_SEGMENT_PCIE20L0:
      GpioPinSetDirection (0, GPIO_PIN_PA4, GPIO_PIN_OUTPUT); // PERST#
      GpioPinSetDirection (1, GPIO_PIN_PA4, GPIO_PIN_OUTPUT); // vcc3v3_pciem3 enable
      break;
    case PCIE_SEGMENT_PCIE20L1:
      GpioPinSetDirection (4, GPIO_PIN_PD5, GPIO_PIN_OUTPUT); // PERST#
      GpioPinSetDirection (4, GPIO_PIN_PB5, GPIO_PIN_OUTPUT); // vcc3v3_pciem1 enable
      break;
    case PCIE_SEGMENT_PCIE20L2:
      GpioPinSetDirection (4, GPIO_PIN_PD4, GPIO_PIN_OUTPUT); // PERST#
      GpioPinSetDirection (1, GPIO_PIN_PA1, GPIO_PIN_OUTPUT); // vcc3v3_pciem2 enable
      break;
    default:
      break;
  }
}

VOID
EFIAPI
PciePowerEn (
  UINT32   Segment,
  BOOLEAN  Enable
  )
{
  /* output high to enable power */
  switch (Segment) {
    case PCIE_SEGMENT_PCIE30X4:
      /* vcc3v3_pcie30 is always-on; nothing to do */
      break;
    case PCIE_SEGMENT_PCIE30X2:
      break;
    case PCIE_SEGMENT_PCIE20L0:
      GpioPinWrite (1, GPIO_PIN_PA4, Enable); // vcc3v3_pciem3
      break;
    case PCIE_SEGMENT_PCIE20L1:
      GpioPinWrite (4, GPIO_PIN_PB5, Enable); // vcc3v3_pciem1
      break;
    case PCIE_SEGMENT_PCIE20L2:
      GpioPinWrite (1, GPIO_PIN_PA1, Enable); // vcc3v3_pciem2
      break;
    default:
      break;
  }
}

VOID
EFIAPI
PciePeReset (
  UINT32   Segment,
  BOOLEAN  Enable
  )
{
  /* Enable == TRUE means "assert PERST#", which drives the pin low.
   * Rockchip's EVB FDTs declare these as GPIO_ACTIVE_HIGH reset-gpios and
   * the vendor kernel asserts them by driving low, exactly like ROCK 5B,
   * so keep upstream's inversion. */
  switch (Segment) {
    case PCIE_SEGMENT_PCIE30X4:
      GpioPinWrite (4, GPIO_PIN_PB6, !Enable);
      break;
    case PCIE_SEGMENT_PCIE30X2:
      GpioPinWrite (3, GPIO_PIN_PD0, !Enable);
      break;
    case PCIE_SEGMENT_PCIE20L0:
      GpioPinWrite (0, GPIO_PIN_PA4, !Enable);
      break;
    case PCIE_SEGMENT_PCIE20L1:
      GpioPinWrite (4, GPIO_PIN_PD5, !Enable);
      break;
    case PCIE_SEGMENT_PCIE20L2:
      GpioPinWrite (4, GPIO_PIN_PD4, !Enable);
      break;
    default:
      break;
  }
}

VOID
EFIAPI
HdmiTxIomux (
  IN UINT32  Id
  )
{
  /* EVB10 pinctrl, from rk3588s-pinctrl.dtsi:
   *   hdmi0: hdmim0_tx0_cec / hdmim0_tx0_hpd / hdmim0_tx0_scl / hdmim0_tx0_sda
   *   hdmi1: hdmim2_tx1_cec (GPIO3_C4) / hdmim0_tx1_hpd (GPIO1_A6) /
   *          hdmim1_tx1_scl (GPIO3_C6) / hdmim1_tx1_sda (GPIO3_C5)
   */
  switch (Id) {
    case 0:
      GpioPinSetFunction (4, GPIO_PIN_PC1, 5); // hdmim0_tx0_cec
      GpioPinSetPull (4, GPIO_PIN_PC1, GPIO_PIN_PULL_NONE);
      GpioPinSetFunction (1, GPIO_PIN_PA5, 5); // hdmim0_tx0_hpd
      GpioPinSetPull (1, GPIO_PIN_PA5, GPIO_PIN_PULL_NONE);
      GpioPinSetFunction (4, GPIO_PIN_PB7, 5); // hdmim0_tx0_scl
      GpioPinSetPull (4, GPIO_PIN_PB7, GPIO_PIN_PULL_NONE);
      GpioPinSetFunction (4, GPIO_PIN_PC0, 5); // hdmim0_tx0_sda
      GpioPinSetPull (4, GPIO_PIN_PC0, GPIO_PIN_PULL_NONE);
      break;
    case 1:
      GpioPinSetFunction (3, GPIO_PIN_PC4, 5); // hdmim2_tx1_cec
      GpioPinSetPull (3, GPIO_PIN_PC4, GPIO_PIN_PULL_NONE);
      GpioPinSetFunction (1, GPIO_PIN_PA6, 5); // hdmim0_tx1_hpd
      GpioPinSetPull (1, GPIO_PIN_PA6, GPIO_PIN_PULL_NONE);
      GpioPinSetFunction (3, GPIO_PIN_PC6, 5); // hdmim1_tx1_scl
      GpioPinSetPull (3, GPIO_PIN_PC6, GPIO_PIN_PULL_NONE);
      GpioPinSetFunction (3, GPIO_PIN_PC5, 5); // hdmim1_tx1_sda
      GpioPinSetPull (3, GPIO_PIN_PC5, GPIO_PIN_PULL_NONE);
      break;
  }
}

PWM_DATA  pwm_data = {
  .ControllerID = PWM_CONTROLLER3,
  .ChannelID    = PWM_CHANNEL0,
  .PeriodNs     = 4000000,
  .DutyNs       = 4000000,
  .Polarity     = FALSE,
}; // PWM3_CH0 = PWM3_IR on GPIO3_B2 (func 11), EVB10 4-wire fan

VOID
EFIAPI
PwmFanIoSetup (
  VOID
  )
{
  GpioPinSetFunction (3, GPIO_PIN_PB2, 0xB); // PWM3_IR_M1
  RkPwmSetConfig (&pwm_data);
  RkPwmEnable (&pwm_data);
}

VOID
EFIAPI
PwmFanSetSpeed (
  IN UINT32  Percentage
  )
{
  pwm_data.DutyNs = pwm_data.PeriodNs * Percentage / 100;
  RkPwmSetConfig (&pwm_data);
}

VOID
EFIAPI
PlatformInitLeds (
  VOID
  )
{
  /* EVB10 work LED is GPIO1_C6, active high */
  GpioPinWrite (1, GPIO_PIN_PC6, FALSE);
  GpioPinSetDirection (1, GPIO_PIN_PC6, GPIO_PIN_OUTPUT);
}

VOID
EFIAPI
PlatformSetStatusLed (
  IN BOOLEAN  Enable
  )
{
  GpioPinWrite (1, GPIO_PIN_PC6, Enable);
}

VOID
EFIAPI
PlatformPcieWiFiEnable (
  IN BOOLEAN  Enable
  )
{
  /* EVB10 SDIO WiFi: WL_REG_ON is GPIO0_C4 (active low reset), the SDIO
   * power sequence also gates the rail through it. Bluetooth on UART9:
   * reset GPIO0_C6, wake GPIO0_C5, host wake GPIO0_A0. */
  GpioPinWrite (0, GPIO_PIN_PC4, !Enable);
  GpioPinSetDirection (0, GPIO_PIN_PC4, GPIO_PIN_OUTPUT);

  GpioPinWrite (0, GPIO_PIN_PC6, Enable);
  GpioPinSetDirection (0, GPIO_PIN_PC6, GPIO_PIN_OUTPUT);
  GpioPinWrite (0, GPIO_PIN_PC5, Enable);
  GpioPinSetDirection (0, GPIO_PIN_PC5, GPIO_PIN_OUTPUT);
}

CONST EFI_GUID *
EFIAPI
PlatformGetDtbFileGuid (
  IN UINT32  CompatMode
  )
{
  STATIC CONST EFI_GUID  VendorDtbFileGuid = {
    // DeviceTree/Vendor.inf
    0xd58b4028, 0x43d8, 0x4e97, { 0x87, 0xd4, 0x4e, 0x37, 0x16, 0x13, 0x65, 0x80 }
  };

  //
  // EVB10 ships only the Rockchip vendor device tree: the mainline kernel has
  // no rk3588-evb10 board file to build from. FdtPlatformDxe falls back to the
  // first supported mode when the default (mainline) is missing, but returning
  // NULL here for mainline makes that explicit instead of relying on the
  // settings-var store being fresh.
  //
  switch (CompatMode) {
    case FDT_COMPAT_MODE_VENDOR:
      return &VendorDtbFileGuid;
  }

  return NULL;
}

VOID
EFIAPI
PlatformEarlyInit (
  VOID
  )
{
  // Configure various things specific to this platform
  PlatformPcieWiFiEnable (TRUE);
}
