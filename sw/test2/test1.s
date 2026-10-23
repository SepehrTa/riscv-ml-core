# test1.s - the hand-encoded test program, now written in assembly
    .section .text.start
    .globl _start
_start:
    addi x1, x0, 5          # x1 = 5
    addi x2, x0, 10         # x2 = 10
    add  x3, x1, x2         # x3 = 15
    sub  x4, x2, x1         # x4 = 5
    sw   x3, 0(x0)          # memory[0] = 15
    lw   x5, 0(x0)          # x5 = 15
    beq  x4, x1, skip1      # taken: 5 == 5
    addi x6, x0, 1          # skipped
skip1:
    addi x7, x0, 7          # x7 = 7
    jal  x8, skip2          # x8 = return address, jump
    addi x9, x0, 9          # skipped
skip2:
    lui   x10, 0x12345      # x10 = 0x12345000
    auipc x11, 0            # x11 = this instruction's address
    jal   x13, func         # "call" func, x13 = return address
halt:
    jal   x0, halt          # loop forever
func:
    addi x14, x0, 14        # x14 = 14
    jalr x0, 0(x13)         # "return"