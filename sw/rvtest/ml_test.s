# ml_test.s - self-checking test of the custom ML instructions (custom-0)
#   dot4 rd,rs1,rs2 / dot4.acc rs1,rs2 / acc.set rs1 / acc.rd rd
# Pass: gp = 1.  Fail: gp = (test number << 1) | 1.  Both end in "j .".

    .macro DOT4 rd, rs1, rs2
        .insn r 0x0b, 0, 0, \rd, \rs1, \rs2
    .endm
    .macro DOT4ACC rs1, rs2
        .insn r 0x0b, 1, 0, x0, \rs1, \rs2
    .endm
    .macro ACCSET rs1
        .insn r 0x0b, 2, 0, x0, \rs1, x0
    .endm
    .macro ACCRD rd
        .insn r 0x0b, 3, 0, \rd, x0, x0
    .endm

    .section .text.start
    .globl _start
_start:
    li   t0, 0x10000                # data memory

    # 1-3: dot4 with known values
    li   gp, 1
    li   a0, 0x04030201
    li   a1, 0x01010101
    DOT4 a2, a0, a1                 # 1+2+3+4
    li   t6, 10
    bne  a2, t6, fail

    li   gp, 2
    li   a0, 0x80808080
    DOT4 a2, a0, a0                 # 4 x (-128 * -128), the largest result
    li   t6, 0x10000
    bne  a2, t6, fail

    li   gp, 3
    li   a0, 0xFF02FD04
    li   a1, 0x05FB0307
    DOT4 a2, a0, a1                 # mixed signs: 28 - 9 - 10 - 5
    li   t6, 4
    bne  a2, t6, fail

    # 4: back-to-back accumulation, result used immediately
    li   gp, 4
    li   a0, 0x7F80017F
    li   a1, 0x80FF7F02
    li   a2, 0x11223344
    li   a3, 0xF0E0D0C0
    li   a4, 0x01FF02FE
    li   a5, 0x03FD04FC
    ACCSET zero
    DOT4ACC a0, a1
    DOT4ACC a2, a3
    DOT4ACC a4, a5
    ACCRD s0
    addi s1, s0, 0                  # uses acc.rd immediately (1-cycle stall)
    li   t6, -23885
    bne  s1, t6, fail

    # 5: start from a bias
    li   gp, 5
    li   t1, 100
    ACCSET t1
    DOT4ACC a0, a1
    ACCRD s0
    li   t6, -15647
    bne  s0, t6, fail

    # 6: operand just loaded from memory (load-use stall + forwarding)
    li   gp, 6
    sw   a0, 0(t0)
    sw   a1, 4(t0)
    ACCSET zero
    lw   s2, 0(t0)
    lw   s3, 4(t0)
    DOT4ACC s2, s3
    ACCRD s0
    li   t6, -15747
    bne  s0, t6, fail

    # 7: dot4 result used immediately by a branch
    li   gp, 7
    li   t6, -15747
    DOT4 s4, a0, a1
    bne  s4, t6, fail

    # 8: instructions flushed by a taken branch must not touch the accumulator
    li   gp, 8
    ACCSET zero
    DOT4ACC a0, a1
    beq  zero, zero, 1f
    DOT4ACC a0, a1                  # wrong path: flushed
    DOT4ACC a0, a1                  # wrong path: flushed
1:  ACCRD s0
    li   t6, -15747
    bne  s0, t6, fail

    # 9: dot4.acc and acc.set must not write rd, even if the rd field is set
    li   gp, 9
    li   s5, 0x12345678
    .insn r 0x0b, 1, 0, s5, a0, a1  # dot4.acc with rd = s5
    .insn r 0x0b, 2, 0, s5, a0, x0  # acc.set  with rd = s5
    li   t6, 0x12345678
    bne  s5, t6, fail
    ACCRD s0
    bne  s0, a0, fail               # acc.set loaded a0

    # 10: a divide between accumulations (its stall must not repeat a MAC)
    li   gp, 10
    ACCSET zero
    DOT4ACC a0, a1
    li   t1, 1000
    li   t2, 7
    div  t3, t1, t2
    DOT4ACC a0, a1
    ACCRD s0
    li   t6, -31494
    bne  s0, t6, fail
    li   t6, 142
    bne  t3, t6, fail

    # 11: 16-element int8 dot product, plain RV32IM versus custom instructions
    li   gp, 11
    li   t1, 0x18CA4DA5
    sw   t1, 16(t0)
    li   t1, 0x1DBB3025
    sw   t1, 20(t0)
    li   t1, 0xDE2C136D
    sw   t1, 24(t0)
    li   t1, 0x2E7B23D6
    sw   t1, 28(t0)
    li   t1, 0x723F1ED9
    sw   t1, 32(t0)
    li   t1, 0x7119CB1F
    sw   t1, 36(t0)
    li   t1, 0xD6944417
    sw   t1, 40(t0)
    li   t1, 0x5C9D3C49
    sw   t1, 44(t0)

    addi s6, t0, 16                 # plain version: one byte pair per iteration
    addi s7, t0, 32
    li   s8, 16
    li   s9, 0
2:  lb   t1, 0(s6)
    lb   t2, 0(s7)
    mul  t3, t1, t2
    add  s9, s9, t3
    addi s6, s6, 1
    addi s7, s7, 1
    addi s8, s8, -1
    bnez s8, 2b

    addi s6, t0, 16                 # custom version: four byte pairs per iteration
    addi s7, t0, 32
    li   s8, 4
    ACCSET zero
3:  lw   t1, 0(s6)
    lw   t2, 0(s7)
    DOT4ACC t1, t2
    addi s6, s6, 4
    addi s7, s7, 4
    addi s8, s8, -1
    bnez s8, 3b
    ACCRD s10

    bne  s9, s10, fail
    li   t6, -3088
    bne  s10, t6, fail

pass:
    li   gp, 1
4:  j    4b
fail:
    slli gp, gp, 1
    ori  gp, gp, 1
5:  j    5b