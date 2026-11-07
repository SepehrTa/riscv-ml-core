/* link.ld -- Harvard memory layout for core_pipe (64 KiB DMEM variant).
 * The FPGA has physically separate IMEM and DMEM.  All constants MUST live
 * in DMEM, not in instruction memory.  .rodata + .data are pre-initialized
 * using mnist_dmem.mem; startup only clears .bss.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    DMEM (rw)  : ORIGIN = 0x00010000, LENGTH = 64K
}

STACK_BYTES = 4096;

SECTIONS
{
    . = ORIGIN(IMEM);
    .text : ALIGN(4)
    {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > IMEM

    . = ORIGIN(DMEM);
    .rodata : ALIGN(4)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > DMEM

    .data : ALIGN(4)
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > DMEM

    /* The initialized image must end at __data_end. */
    __data_end = ALIGN(4);

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DMEM

    __stack_top   = ORIGIN(DMEM) + LENGTH(DMEM);
    __stack_limit = __stack_top - STACK_BYTES;

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame.*)
        *(.riscv.attributes)
    }
}

ASSERT(SIZEOF(.text) <= LENGTH(IMEM), "MNIST program exceeds 4 KiB IMEM: increase IMEM_DEPTH")
ASSERT(__bss_end <= __stack_limit, "MNIST data/BSS overlaps reserved 4 KiB stack")
