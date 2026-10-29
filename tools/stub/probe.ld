/*
 * probe.ld — 布局刻意让 stub 代码落在 FV 之后。
 *
 *   +0x000000  64 字节 arm64 Image 头，code0 直接 b 到 +0x501000（stub）
 *   +0x002000  UEFI FV（5 MiB，原样）
 *   +0x502000  stub 代码
 *
 * 这样 stub 把 FV 从 +0x1000 拷到 0x200000 时，写区间 0x200000..0x700000
 * 碰不到正在执行的 stub（0x701000 起），不会边跑边被自己覆盖。
 */
ENTRY(_head)

SECTIONS
{
	. = 0x0;
	.head : { *(.text.head) }

	. = 0x2000;
	.fv : {
		_fv_start = .;
		KEEP(*(.fv))
		_fv_end = .;
	}

	. = 0x502000;
	.text : { *(.text) *(.text.*) *(.rodata) *(.rodata.*) *(.data) }
	.bss : { *(.bss) *(COMMON) }

	_end = .;
}
