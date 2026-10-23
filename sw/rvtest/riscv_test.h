// riscv_test.h - minimal test environment for running the official
// riscv-tests (rv32ui) on our single-cycle core.
//
// It replaces env/p/riscv_test.h, which needs CSRs and ecall.
// Result convention (same as the official environment):
//   PASS: gp (x3) = 1, then halt
//   FAIL: gp (x3) = (number of the failed test case << 1) | 1, then halt
// "halt" = a jump to itself (j .), which the testbench detects.

#ifndef RISCV_TEST_H
#define RISCV_TEST_H

#define RVTEST_RV32U  .macro init; .endm
#define RVTEST_RV64U  .macro init; .endm

#define TESTNUM gp

// Start of the test: put _start at address 0 and clear all registers.
#define RVTEST_CODE_BEGIN                                               \
        .section .text.start;                                           \
        .globl _start;                                                  \
_start:                                                                 \
        li x1, 0;  li x2, 0;  li x3, 0;  li x4, 0;                      \
        li x5, 0;  li x6, 0;  li x7, 0;  li x8, 0;                      \
        li x9, 0;  li x10, 0; li x11, 0; li x12, 0;                     \
        li x13, 0; li x14, 0; li x15, 0; li x16, 0;                     \
        li x17, 0; li x18, 0; li x19, 0; li x20, 0;                     \
        li x21, 0; li x22, 0; li x23, 0; li x24, 0;                     \
        li x25, 0; li x26, 0; li x27, 0; li x28, 0;                     \
        li x29, 0; li x30, 0; li x31, 0;                                \
        init;

#define RVTEST_CODE_END                                                 \
1:      j 1b;

#define RVTEST_PASS                                                     \
        li TESTNUM, 1;                                                  \
1:      j 1b;

#define RVTEST_FAIL                                                     \
1:      beqz TESTNUM, 1b;                                               \
        sll TESTNUM, TESTNUM, 1;                                        \
        or  TESTNUM, TESTNUM, 1;                                        \
2:      j 2b;

#define RVTEST_DATA_BEGIN  .align 4; .global begin_signature; begin_signature:
#define RVTEST_DATA_END    .align 4; .global end_signature; end_signature:

#endif