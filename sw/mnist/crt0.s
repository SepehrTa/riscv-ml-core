/* crt0.s -- bare-metal startup for the RV32IM PYNQ-Z2 core.
 *
 * Unlike a normal executable, .rodata and .data are already loaded into
 * DMEM by $readmemh(mnist_dmem.mem).  Do not try to copy them from IMEM.
 * main returns 1 for PASS, or an odd number > 1 for FAIL.  The final
 * self-loop lets the existing riscv-tests-style testbench inspect gp (x3).
 */
    .option push
    .option norvc
    .option norelax

    .section .text.start, "ax", @progbits
    .globl _start
    .type  _start, @function
_start:
    /* The linker locates the descending stack at the high end of DMEM. */
    la      sp, __stack_top
    li      gp, 0

    /* Clear [__bss_start, __bss_end), which is word-aligned. */
    la      t0, __bss_start
    la      t1, __bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b

2:
    call    main
    /* Save result in x3: 1=PASS; larger odd value=FAIL. */
    mv      gp, a0
3:
    j       3b

    .size _start, . - _start
    .option pop
