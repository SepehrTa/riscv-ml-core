# RISC-V ML Core

I'm building a RISC-V processor from scratch in SystemVerilog and running it on a PYNQ-Z2 FPGA board. The end goal is a core with custom instructions for int8 neural-network math, so I can measure how much a few well-chosen instructions speed up real ML kernels.

So far the repo has two working RV32IM cores:

- **`core`** is a simple single-cycle design. It was the first thing I got working, and I keep it around as a reference model for testing the faster one.
- **`core_pipe`** is a classic 5-stage pipeline (fetch, decode, execute, memory, write-back) with forwarding, stalls, block-RAM memories, an iterative divider and a multiplier in its own stage.

Both pass all 48 official [riscv-tests](https://github.com/riscv/riscv-tests) for RV32I and RV32M, and both have run programs on the board.

## Where things stand

The single-cycle core runs at 10 MHz, mostly because its one-cycle divider is a huge block of logic (around 100 ns). The pipelined core currently runs on the board at 52 MHz with 4 ns of timing slack to spare, which puts its limit at roughly 66 MHz. I plan to settle on 62.5 MHz.

The custom ML instructions are what I'm working on now.

## How the pipeline works

```
   IF            ID            EX                 MEM                 WB
 PC +         decoder,      forwarding,        data memory,        result
 instruction  register      ALU, branch        LEDs/buttons,       mux
 memory       file, imm     unit, divider      multiplier
```

An instruction moves one stage to the right every clock cycle, so five instructions are in flight at once. The interesting part is what happens when they get in each other's way:

- **An instruction needs a result that isn't written back yet.** The value is forwarded directly from the MEM or WB stage into EX instead of waiting for the register file.
- **A result comes out late** (a load, a multiply). The next instruction waits one cycle if it needs that value right away.
- **A branch or jump is taken.** It's resolved in EX, so the two instructions fetched after it are thrown away.
- **A division is running.** Everything behind it freezes for about 34 cycles while the divider works, and the instructions ahead of it finish normally.

A few decisions worth explaining:

**Block RAM for both memories.** Block RAM takes a cycle to read, which would normally cost a cycle on every fetch. I avoid that by giving the instruction memory the *next* PC instead of the current one, so the instruction is ready exactly when it's needed.

**An iterative divider.** The one-cycle divider was by far the slowest thing in the design. The new one computes one bit of the quotient per cycle. Division is rare in real programs, so 34 cycles per divide is a good trade for a much faster clock everywhere else.

**The multiplier lives in the MEM stage.** This one came straight out of the timing report. The slowest path in the design was a value loaded from memory, forwarded into the multiplier, all in one cycle (about 17.6 ns). Moving the multiplier one stage later cut that to about 15.2 ns. The cost was 8 extra cycles across the entire riscv-tests suite, which is nothing.

There are no exceptions or interrupts yet; `ecall`, `ebreak` and `fence` do nothing.

## The ML extension (in progress)

Most of the work in a quantized neural network is dot products of 8-bit numbers. My plan is to pack four int8 values into one 32-bit register and do four multiply-adds per instruction. The instructions use RISC-V's reserved `custom-0` opcode (`0001011`):

| Instruction | What it does |
|---|---|
| `dot4 rd, rs1, rs2` | rd = sum of the four products of the signed bytes in rs1 and rs2 |
| `dot4.acc rs1, rs2` | adds that sum to an internal accumulator |
| `acc.set rs1` | sets the accumulator (use `x0` to clear it) |
| `acc.rd rd` | copies the accumulator into rd |

I went with an accumulator inside the ML unit rather than accumulating into a normal register. A normal register would need a third register-file read port, and in a dot-product loop every iteration would stall waiting for the previous one. With an internal accumulator, back-to-back `dot4.acc` instructions run without stalls.

GCC doesn't know these instructions, but the assembler's `.insn` directive can encode them directly:

```asm
.insn r 0x0b, 1, 0, x0, a0, a1     # dot4.acc a0, a1
```

To measure the payoff, I'll write an int8 dot product and a small matrix-vector multiply both ways, plain RV32IM and with the new instructions, and time them with a cycle counter. My back-of-the-envelope estimate is a 4 to 5x speedup on the dot product, but I'd rather report a measured number.

## Memory map

| Address | What's there |
|---|---|
| `0x0000_0000` | instruction memory (4 KB) |
| `0x0001_0000` | data memory (4 KB) |
| `0x8000_0000` | LEDs, write bits 3:0 |
| `0x8000_0004` | buttons, read bits 3:0 |
| `0x8000_0008` | cycle counter (coming with the ML work) |

Anything with bit 31 set is I/O.

## Testing

I lean on the official riscv-tests, with a small custom environment header so they report pass or fail through the `gp` register instead of needing exception support. The testbench loads each test, runs it to its final `j .` instruction and checks the result.

To make sure those tests actually catch pipeline bugs, I removed each hazard mechanism one at a time (forwarding, the register-file bypass, branch flushing, the load-use stall). Every removal made tests fail, so passing all 48 means something.

The divider has its own self-checking testbench: 400 corner cases and 4,000 random operand pairs compared against a reference model. It also scrambles the inputs right after a division starts, to prove the divider latched them.

For the trickier pipeline cases, I write stress programs (a multiply feeding another multiply, a load feeding a divide, a branch right after a multiply, and so on) and run them on both cores. The single-cycle core is simple enough to trust, so if the final register values differ, the pipeline has a bug.

## Building and running

You'll need Vivado 2025.2, the xPack RISC-V GCC toolchain (`riscv-none-elf-gcc`, I use 15.2.0), Python 3 and a PYNQ-Z2.

To turn an assembly program into something the core can load:

```sh
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -T link.ld prog.s -o prog.elf
riscv-none-elf-objcopy -O binary -j .text prog.elf prog.bin
python bin2mem.py prog.bin prog.mem
```

The core loads `prog.mem` into instruction memory through its `IMEM_FILE` parameter.

To run the riscv-tests, build them with `sw/build_tests.py`, set `tb_riscv_tests` as the simulation top in Vivado and run it. Swap `core` and `core_pipe` in the testbench to choose which core gets tested.

To run on the board, set `top` as the synthesis top (it handles the clock, reset and button synchronization), build the bitstream and program the board.

**One thing that cost me an afternoon:** plug in an Ethernet cable, even though nothing uses the network. On the PYNQ-Z2, the 125 MHz clock on pin H16 comes from the Ethernet chip, and without a link that chip keeps resetting itself, so the clock drops out every few seconds. To me it looked like my core was randomly restarting. The cable can go to any router, switch or PC.

The demo program `led_demo.s` counts in binary on the LEDs. Hold BTN1 to see the buttons mirrored on the LEDs instead, and press BTN0 to reset.

## Repo layout

```
RISCV_ML_ACC.srcs/
  sources_1/new/    RTL: both cores, their building blocks, and the board top
  sim_1/new/        testbenches
  constrs_1/new/    pin constraints for the PYNQ-Z2
sw/                 linker script, test environment, build scripts, demo programs
```

## What's next

- [x] Single-cycle RV32I, then RV32M
- [x] All 48 riscv-tests passing on both cores
- [x] LEDs and buttons, running on the board
- [x] 5-stage pipeline with forwarding, stalls and flushes
- [x] Block RAM and an iterative divider
- [x] Multiplier moved to its own stage after timing analysis
- [ ] Custom ML instructions
- [ ] Cycle counter and int8 benchmarks
- [ ] Final clock, resource usage and measured speedups
- [ ] Loading programs from the Zynq's ARM cores instead of rebuilding the bitstream

---

Sepehr Tabrizchi, [github.com/SepehrTa](https://github.com/SepehrTa)
