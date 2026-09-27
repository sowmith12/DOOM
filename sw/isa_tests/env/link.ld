/* Linker script for ISA tests: everything in one RAM starting at 0x0
 * (the core's reset PC). The simulation memory is 1 MB. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x00000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x100);
  .text      : { *(.text) *(.text.*) }
  . = ALIGN(0x100);
  .data      : { *(.data) *(.data.*) *(.sdata) *(.rodata) *(.rodata.*) }
  .bss       : { *(.bss) *(.bss.*) *(.sbss) }
  _end = .;
}
