# bench_dot.s - int8 dot-product benchmark: plain RV32IM versus custom ML instructions
#   Times three versions of the same N-element dot product with the cycle counter
#   (lw from 0x8000_0008) and checks that all three give the same result.
#   Results: s0 = cycles (plain), s7 = cycles (plain, unrolled x4),
#            s1 = cycles (dot4.acc), s2 = cycles (dot4.acc, unrolled x4)
#            a2, s6, a3, a4 = the four dot products;  gp = 1 if they all match
#   On the board, the LEDs show the fair speedup: unrolled plain / unrolled dot4.acc.

    .equ N,  256                     # int8 elements per vector
    .equ IO, 0x80000000              # LEDs +0, buttons +4, cycle counter +8

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
    li   s11, IO
    li   a0, 0x10000                 # vector A
    li   a1, 0x10000 + N             # vector B, right after A

    # ---- fill A and B with pseudo-random bytes (not timed) ----
    li   t0, 12345                   # seed
    li   t1, 1103515245              # LCG multiplier
    li   t2, 12345                   # LCG increment
    mv   t3, a0
    li   t4, N / 2                   # 2N bytes = N/2 words
1:  mul  t0, t0, t1
    add  t0, t0, t2
    sw   t0, 0(t3)
    addi t3, t3, 4
    addi t4, t4, -1
    bnez t4, 1b

    # ---- version 1: plain RV32IM, one element per iteration ----
    lw   s0, 8(s11)                  # start time
    mv   t3, a0
    mv   t4, a1
    li   t5, N
    li   a2, 0
2:  lb   t0, 0(t3)
    lb   t1, 0(t4)
    mul  t2, t0, t1
    add  a2, a2, t2
    addi t3, t3, 1
    addi t4, t4, 1
    addi t5, t5, -1
    bnez t5, 2b
    lw   t6, 8(s11)                  # end time
    sub  s0, t6, s0

    # ---- version 1b: plain RV32IM unrolled x4, for a fair comparison ----
    lw   s7, 8(s11)
    mv   t3, a0
    mv   t4, a1
    li   t5, N / 4
    li   s6, 0
7:  lb   t0, 0(t3)                   # all loads first, so no multiply waits for a load
    lb   t1, 0(t4)
    lb   a5, 1(t3)
    lb   a6, 1(t4)
    lb   a7, 2(t3)
    lb   s3, 2(t4)
    lb   s4, 3(t3)
    lb   s5, 3(t4)
    mul  t0, t0, t1
    mul  a5, a5, a6
    mul  a7, a7, s3
    mul  s4, s4, s5
    add  s6, s6, t0
    add  s6, s6, a5
    add  s6, s6, a7
    add  s6, s6, s4
    addi t3, t3, 4
    addi t4, t4, 4
    addi t5, t5, -1
    bnez t5, 7b
    lw   t6, 8(s11)
    sub  s7, t6, s7

    # ---- version 2: dot4.acc, four elements per iteration ----
    lw   s1, 8(s11)
    mv   t3, a0
    mv   t4, a1
    li   t5, N / 4
    ACCSET zero
3:  lw   t0, 0(t3)
    lw   t1, 0(t4)
    DOT4ACC t0, t1
    addi t3, t3, 4
    addi t4, t4, 4
    addi t5, t5, -1
    bnez t5, 3b
    ACCRD a3
    lw   t6, 8(s11)
    sub  s1, t6, s1

    # ---- version 3: dot4.acc unrolled x4, sixteen elements per iteration ----
    lw   s2, 8(s11)
    mv   t3, a0
    mv   t4, a1
    li   t5, N / 16
    ACCSET zero
4:  lw   t0, 0(t3)                   # all loads first, so no MAC waits for a load
    lw   t1, 0(t4)
    lw   a5, 4(t3)
    lw   a6, 4(t4)
    lw   a7, 8(t3)
    lw   s3, 8(t4)
    lw   s4, 12(t3)
    lw   s5, 12(t4)
    DOT4ACC t0, t1
    DOT4ACC a5, a6
    DOT4ACC a7, s3
    DOT4ACC s4, s5
    addi t3, t3, 16
    addi t4, t4, 16
    addi t5, t5, -1
    bnez t5, 4b
    ACCRD a4
    lw   t6, 8(s11)
    sub  s2, t6, s2

    # ---- all four versions must agree ----
    li   gp, 4
    bne  a2, s6, fail
    li   gp, 2
    bne  a2, a3, fail
    li   gp, 3
    bne  a2, a4, fail

    divu t0, s7, s2                  # fair speedup: both versions unrolled x4
    sw   t0, 0(s11)                  # show it on the LEDs

pass:
    li   gp, 1
5:  j    5b
fail:
    slli gp, gp, 1
    ori  gp, gp, 1
6:  j    6b