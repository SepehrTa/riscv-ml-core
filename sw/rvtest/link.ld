/* link.ld - memory layout of the single-cycle core
   IMEM: instruction memory, 4 KB at address 0x00000000 (code)
   DMEM: data memory,        4 KB at address 0x00010000 (data, constants, stack) */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 4K
    DMEM (rw) : ORIGIN = 0x00010000, LENGTH = 4K
}

SECTIONS
{
    .text   : { *(.text.start) *(.text*) }                 > IMEM
    .rodata : { *(.rodata*) *(.srodata*) }                 > DMEM
    .data   : { *(.data*) *(.sdata*) }                     > DMEM
    .bss    : { *(.bss*) *(.sbss*) *(COMMON) }             > DMEM

    __stack_top = ORIGIN(DMEM) + LENGTH(DMEM);  /* stack starts at the top of DMEM */
}