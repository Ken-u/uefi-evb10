/** @file
  UniXNURamDiskDxe: publish the UniXNU payload FAT volume as a RAM disk.

  Two sources, tried in this order:

   1. The initrd the bootloader left in RAM. U-Boot's Android boot flow loads
      the boot image ramdisk to ramdisk_addr_r and writes its range into the
      FDT it hands over as /chosen/linux,initrd-start and linux,initrd-end.
      The probe stub (tools/stub/probe.S) parks that FDT address in
      TPIDRRO_EL0 before it jumps into this firmware; PeilessSec only touches
      that register when it is given a TransferList, which a probe boot never
      is. The payload built by "unixnu build payload" arrives this way.

   2. A small FAT image stored in the firmware volume (FILE FREEFORM, see
      UniXNUEvb10.Modules.fdf.inc). It only carries a menu with exit/restart
      entries, which is enough to prove the volume scan works when no payload
      was supplied.

  The range is claimed at driver start, before anything else can allocate over
  it, but registered at EndOfDxe so that PartitionDxe and Fat are already
  dispatched when RamDiskRegister() calls ConnectController().

  Copyright (c) 2026, UniXNU contributors. All rights reserved.
  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

#include <Uefi.h>

#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/DxeServicesLib.h>
#include <Library/DxeServicesTableLib.h>
#include <Library/FdtLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiLib.h>
#include <Protocol/RamDisk.h>

#define SECTOR_SIZE  512

//
// FILE FREEFORM name of the fallback FAT image. Keep in sync with
// UniXNUEvb10.Modules.fdf.inc.
//
STATIC CONST EFI_GUID  mEspImageGuid = {
  0x7A3C9E10, 0x5B6D, 0x4F2A, { 0x9D, 0x14, 0x8E, 0x0C, 0x5A, 0x1B, 0x2F, 0x47 }
};

//
// The disk to register at EndOfDxe. Base/Size describe the FAT image itself;
// Pages is what has to be freed again if registration fails.
//
STATIC EFI_PHYSICAL_ADDRESS  mDiskBase;
STATIC UINT64                mDiskSize;
STATIC EFI_PHYSICAL_ADDRESS  mPagesBase;
STATIC UINTN                 mPages;
STATIC CONST CHAR8           *mDiskOrigin = "none";

STATIC
UINT64
ReadHandoffFdtAddress (
  VOID
  )
{
  UINT64  Value;

  __asm__ __volatile__ ("mrs %0, tpidrro_el0" : "=r" (Value));
  return Value;
}

STATIC
UINT64
ReadCells (
  IN CONST VOID  *Data,
  IN UINT32      Cells
  )
{
  if (Cells == 2) {
    return Fdt64ToCpu (ReadUnaligned64 (Data));
  }

  return Fdt32ToCpu (ReadUnaligned32 (Data));
}

STATIC
BOOLEAN
LooksLikeFat (
  IN CONST UINT8  *Boot
  )
{
  //
  // Boot sector signature plus a plausible BPB (bytes per sector 512..4096,
  // power of two). A superfloppy FAT starts here; an MBR/GPT disk image would
  // also carry the signature, which is fine: PartitionDxe sorts that out.
  //
  UINT32  BytesPerSector;

  if ((Boot[510] != 0x55) || (Boot[511] != 0xAA)) {
    return FALSE;
  }

  BytesPerSector = Boot[11] | ((UINT32)Boot[12] << 8);
  if ((BytesPerSector == 0) || ((BytesPerSector & (BytesPerSector - 1)) != 0)) {
    //
    // Not a superfloppy BPB. Accept it as a partitioned image if the first
    // partition entry has a boot flag of 0x00/0x80 and a nonzero type.
    //
    return ((Boot[446] == 0x00) || (Boot[446] == 0x80)) && (Boot[450] != 0);
  }

  return (BytesPerSector >= SECTOR_SIZE) && (BytesPerSector <= 4096);
}

/**
  Claim the bootloader's initrd. Returns TRUE and fills mDisk* on success.
**/
STATIC
BOOLEAN
ClaimInitrd (
  VOID
  )
{
  EFI_STATUS                       Status;
  UINT64                           Dtb;
  CONST VOID                       *Fdt;
  INT32                            Chosen;
  CONST VOID                       *StartProp;
  CONST VOID                       *EndProp;
  INT32                            StartLength;
  INT32                            EndLength;
  UINT64                           Start;
  UINT64                           End;
  UINT64                           Size;
  EFI_PHYSICAL_ADDRESS             PageBase;
  UINTN                            Pages;
  EFI_PHYSICAL_ADDRESS             Copy;
  EFI_GCD_MEMORY_SPACE_DESCRIPTOR  Space;

  Dtb = ReadHandoffFdtAddress ();
  if (Dtb == 0) {
    DEBUG ((DEBUG_INFO, "UniXNURamDisk: no handoff FDT (TPIDRRO_EL0 is 0)\n"));
    return FALSE;
  }

  if (((Dtb & 3) != 0) || (FdtCheckHeader ((VOID *)(UINTN)Dtb) != 0)) {
    DEBUG ((DEBUG_WARN, "UniXNURamDisk: TPIDRRO_EL0 0x%lx is not an FDT\n", Dtb));
    return FALSE;
  }

  Fdt = (CONST VOID *)(UINTN)Dtb;
  DEBUG ((DEBUG_INFO, "UniXNURamDisk: handoff FDT at 0x%lx, %u bytes\n", Dtb, (UINT32)FdtTotalSize (Fdt)));

  Chosen = FdtPathOffset (Fdt, "/chosen");
  if (Chosen < 0) {
    DEBUG ((DEBUG_WARN, "UniXNURamDisk: handoff FDT has no /chosen\n"));
    return FALSE;
  }

  StartProp = FdtGetProp (Fdt, Chosen, "linux,initrd-start", &StartLength);
  EndProp   = FdtGetProp (Fdt, Chosen, "linux,initrd-end", &EndLength);
  if ((StartProp == NULL) || (EndProp == NULL) ||
      ((StartLength != 4) && (StartLength != 8)) || ((EndLength != 4) && (EndLength != 8)))
  {
    DEBUG ((DEBUG_INFO, "UniXNURamDisk: no initrd in /chosen (the boot image had no ramdisk)\n"));
    return FALSE;
  }

  Start = ReadCells (StartProp, StartLength / 4);
  End   = ReadCells (EndProp, EndLength / 4);
  if ((End <= Start) || ((End - Start) < SECTOR_SIZE)) {
    DEBUG ((DEBUG_WARN, "UniXNURamDisk: initrd 0x%lx-0x%lx is empty\n", Start, End));
    return FALSE;
  }

  Size = End - Start;
  DEBUG ((DEBUG_INFO, "UniXNURamDisk: initrd 0x%lx-0x%lx (%lu bytes)\n", Start, End, Size));

  if (!LooksLikeFat ((CONST UINT8 *)(UINTN)Start)) {
    DEBUG ((DEBUG_WARN, "UniXNURamDisk: initrd does not start with a FAT/MBR boot sector\n"));
    return FALSE;
  }

  PageBase = Start & ~(EFI_PHYSICAL_ADDRESS)EFI_PAGE_MASK;
  Pages    = (UINTN)(((End + EFI_PAGE_MASK) & ~(UINT64)EFI_PAGE_MASK) - PageBase) >> EFI_PAGE_SHIFT;

  //
  // Keep it where it is when that memory is still free: no copy, and nothing
  // else can be handed those pages any more.
  //
  Status = gBS->AllocatePages (AllocateAddress, EfiBootServicesData, Pages, &PageBase);
  if (!EFI_ERROR (Status)) {
    mDiskBase   = Start;
    mDiskSize   = Size;
    mPagesBase  = PageBase;
    mPages      = Pages;
    mDiskOrigin = "initrd, claimed in place";
    return TRUE;
  }

  Status = gDS->GetMemorySpaceDescriptor (Start, &Space);
  DEBUG ((
    DEBUG_WARN,
    "UniXNURamDisk: cannot claim 0x%lx in place (%r); GCD type %d, attributes 0x%lx\n",
    Start,
    Status,
    EFI_ERROR (Status) ? -1 : (INT32)Space.GcdMemoryType,
    EFI_ERROR (Status) ? 0 : Space.Attributes
    ));
  if (EFI_ERROR (Status) || (Space.GcdMemoryType != EfiGcdMemoryTypeSystemMemory)) {
    return FALSE;
  }

  //
  // Somebody owns the pages already (or they are not plain conventional
  // memory). The data may still be intact; copy it out of the way.
  //
  Status = gBS->AllocatePages (AllocateAnyPages, EfiBootServicesData, Pages, &Copy);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "UniXNURamDisk: AllocatePages(%u) for the copy: %r\n", (UINT32)Pages, Status));
    return FALSE;
  }

  CopyMem ((VOID *)(UINTN)Copy, (VOID *)(UINTN)Start, (UINTN)Size);
  mDiskBase   = Copy;
  mDiskSize   = Size;
  mPagesBase  = Copy;
  mPages      = Pages;
  mDiskOrigin = "initrd, copied";
  return TRUE;
}

/**
  The fallback: the FAT image stored in this firmware volume.
**/
STATIC
BOOLEAN
ClaimFvImage (
  VOID
  )
{
  EFI_STATUS            Status;
  VOID                  *Image;
  UINTN                 ImageSize;
  EFI_PHYSICAL_ADDRESS  Buffer;
  UINTN                 Pages;

  Image     = NULL;
  ImageSize = 0;
  Status    = GetSectionFromAnyFv (&mEspImageGuid, EFI_SECTION_RAW, 0, &Image, &ImageSize);
  if (EFI_ERROR (Status) || (ImageSize < SECTOR_SIZE)) {
    DEBUG ((DEBUG_ERROR, "UniXNURamDisk: ESP image not in any FV: %r\n", Status));
    return FALSE;
  }

  //
  // The RAM disk keeps using this buffer, so it must outlive the pool copy
  // returned above and be page aligned.
  //
  Pages  = EFI_SIZE_TO_PAGES (ImageSize);
  Status = gBS->AllocatePages (AllocateAnyPages, EfiBootServicesData, Pages, &Buffer);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "UniXNURamDisk: AllocatePages(%u): %r\n", (UINT32)Pages, Status));
    FreePool (Image);
    return FALSE;
  }

  CopyMem ((VOID *)(UINTN)Buffer, Image, ImageSize);
  FreePool (Image);

  mDiskBase   = Buffer;
  mDiskSize   = ImageSize;
  mPagesBase  = Buffer;
  mPages      = Pages;
  mDiskOrigin = "firmware volume image";
  return TRUE;
}

STATIC
VOID
EFIAPI
OnEndOfDxe (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  EFI_STATUS                Status;
  EFI_RAM_DISK_PROTOCOL     *RamDisk;
  EFI_DEVICE_PATH_PROTOCOL  *DevicePath;

  gBS->CloseEvent (Event);

  if (mDiskSize == 0) {
    return;
  }

  Status = gBS->LocateProtocol (&gEfiRamDiskProtocolGuid, NULL, (VOID **)&RamDisk);
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "UniXNURamDisk: no RAM disk protocol: %r\n", Status));
    return;
  }

  DevicePath = NULL;
  Status     = RamDisk->Register (
                          (UINT64)mDiskBase,
                          mDiskSize,
                          &gEfiVirtualDiskGuid,
                          NULL,
                          &DevicePath
                          );
  if (EFI_ERROR (Status)) {
    DEBUG ((DEBUG_ERROR, "UniXNURamDisk: Register: %r\n", Status));
    gBS->FreePages (mPagesBase, mPages);
    return;
  }

  DEBUG ((
    DEBUG_INFO,
    "UniXNURamDisk: registered %lu bytes at 0x%lx (%a)\n",
    mDiskSize,
    mDiskBase,
    mDiskOrigin
    ));
}

EFI_STATUS
EFIAPI
UniXNURamDiskDxeEntry (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_EVENT  Event;

  if (!ClaimInitrd () && !ClaimFvImage ()) {
    return EFI_NOT_FOUND;
  }

  return gBS->CreateEventEx (
                EVT_NOTIFY_SIGNAL,
                TPL_CALLBACK,
                OnEndOfDxe,
                NULL,
                &gEfiEndOfDxeEventGroupGuid,
                &Event
                );
}
