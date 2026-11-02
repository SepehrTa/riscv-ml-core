# led_demo.s - LED demo for the RISC-V core on the PYNQ-Z2
#   - The LEDs count up in binary, about twice per second.
#   - While BTN1 is held, the LEDs show the buttons instead.
#   - BTN0 is the reset button (handled in top.sv).

    .ifndef DELAY
    .equ DELAY, 2500000         # 10 MHz clock, 2 instructions per loop -> about 0.5 s
    .endif

    .section .text.start
    .globl _start
_start:
    li   t0, 0x80000000         # I/O base: LEDs at +0, buttons at +4
    li   t1, 0                  # counter

loop:
    lw   t3, 4(t0)              # read the buttons
    andi t3, t3, 2              # is BTN1 pressed?
    bnez t3, show_buttons

    sw   t1, 0(t0)              # LEDs = counter
    addi t1, t1, 1

    li   t2, DELAY              # wait about 0.5 s
delay:
    addi t2, t2, -1
    bnez t2, delay
    j    loop

show_buttons:
    lw   t3, 4(t0)              # read the buttons again
    sw   t3, 0(t0)              # LEDs = buttons
    j    loop