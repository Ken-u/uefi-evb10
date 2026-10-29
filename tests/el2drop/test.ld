/* QEMU virt：RAM 从 0x40000000 开始，-kernel 加载 ELF 并从 _start 开始执行 */
ENTRY(_start)
SECTIONS
{
  . = 0x40000000;
  .text   : { *(.text.boot) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data   : { *(.data .data.*) }
  .bss    : { *(.bss .bss.*) }
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
