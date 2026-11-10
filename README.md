# RISC-V ML Core

I built a RISC-V processor from scratch in SystemVerilog and run it on a PYNQ-Z2 FPGA board. On top of the standard RV32IM instruction set, it has custom instructions for int8 neural-network math. They make an int8 dot product **4.8x faster** than the same code in plain RV32IM, and a complete quantized MNIST classifier **4.37x faster**.

The Zynq chip on the board also has an ARM processor, and it now drives the core from Python: it loads programs into the core's memories, starts it, and reads the results back, with no bitstream rebuild. That's how the core classified the **whole MNIST test set, all 10,000 images, at 96.60%**, bit-exact with the Python model on every single image.

The repo has two working RV32IM cores:

- **`core`** is a simple single-cycle design. It was the first thing I got working, and I keep it as a reference model for testing the faster one.
- **`core_pipe`** is a 5-stage pipeline (fetch, decode, execute, memory, write-back) with forwarding, stalls, block-RAM memories, an iterative divider, a multiplier in its own stage, and the custom ML unit.

Both pass all 48 official [riscv-tests](https://github.com/riscv/riscv-tests) for RV32I and RV32M, and both have run programs on the board.

## Results

| | Single-cycle `core` | Pipelined `core_pipe` with ML unit |
|---|---|---|
| Clock on the board | 10 MHz | 65 MHz standalone (1.05 ns to spare); 50 MHz from the ARM side's clock in the current build (4.5 ns to spare) |
| Official riscv-tests | 48 / 48 | 48 / 48, plus the custom ML test |
| int8 dot product, 256 elements | | 4.8x faster with the custom instructions |
| Quantized MNIST inference (784 → 32 → 10) | | 4.37x faster with `dot4.acc`, measured on the board |
| Full MNIST test set, run on the FPGA | | 96.60% on 10,000 images, 0 differences from the reference |

The whole pipelined core with the ML unit uses only a small corner of the Zynq-7020: 1,884 LUTs (3.5%), 756 flip-flops (0.7%), 4 DSP blocks (1.8%). These figures, and the 1.05 ns timing margin, are from the earlier small-memory build. The current build adds the 64 KB data memory and the ARM connection: its two memories take 17 block RAMs (16 for data, 1 for instructions), and it meets timing at 50 MHz with 4.5 ns to spare.

## How the pipeline works

```
   IF            ID            EX                 MEM                 WB
 PC +         decoder,      forwarding,        data memory, I/O,   result
 instruction  register      ALU, branch        multiplier,         mux
 memory       file, imm     unit, divider      ML unit
```

An instruction moves one stage to the right every clock cycle, so five instructions are in flight at once. The interesting part is what happens when they get in each other's way:

- **An instruction needs a result that isn't written back yet.** The value is forwarded directly from the MEM or WB stage into EX instead of waiting for the register file.
- **A result comes out late** (a load, a multiply, an ML result). The next instruction waits one cycle if it needs that value right away.
- **A branch or jump is taken.** It's resolved in EX, so the two instructions fetched after it are thrown away.
- **A division is running.** Everything behind it freezes for about 34 cycles while the divider works, and the instructions ahead of it finish normally.

A few decisions worth explaining:

**Block RAM for both memories.** Block RAM takes a cycle to read, which would normally cost a cycle on every fetch. I avoid that by giving the instruction memory the *next* PC instead of the current one, so the instruction is ready exactly when it's needed.

**An iterative divider.** The one-cycle divider was by far the slowest thing in the design, around 100 ns of logic. The new one computes one bit of the quotient per cycle. Division is rare in real programs, so 34 cycles per divide is a good trade for a much faster clock everywhere else.

**The multiplier lives in the MEM stage.** This one came straight out of the timing report. The slowest path was a value loaded from memory, forwarded into the multiplier, all in one cycle (about 17.6 ns). Moving the multiplier one stage later cut that to about 15.2 ns. The cost was 8 extra cycles across the entire riscv-tests suite, which is nothing.

The slowest path now is a value loaded from memory that feeds a jump target, going through the ALU into the instruction memory's address. Shortening it further would mean giving up cycles on every taken branch, so I stopped there.

There are no exceptions or interrupts yet; `ecall`, `ebreak` and `fence` do nothing.

## The ML extension

Most of the work in a quantized neural network is dot products of 8-bit numbers. The ML unit packs four int8 values into one 32-bit register and does four multiply-adds per instruction. The instructions use RISC-V's reserved `custom-0` opcode (`0001011`):

| Instruction | What it does |
|---|---|
| `dot4 rd, rs1, rs2` | rd = sum of the four products of the signed bytes in rs1 and rs2 |
| `dot4.acc rs1, rs2` | adds that sum to an internal accumulator |
| `acc.set rs1` | sets the accumulator (use `x0` to clear it) |
| `acc.rd rd` | copies the accumulator into rd |

I went with an accumulator inside the ML unit rather than accumulating into a normal register. A normal register would need a third register-file read port, and in a dot-product loop every iteration would stall waiting for the previous one. With an internal accumulator, back-to-back `dot4.acc` instructions run without stalls.

The unit sits in the MEM stage next to the multiplier. It reuses the multiplier's registered operands and its result path, so the only real addition to the pipeline was one control bit that has to be cleared in every bubble. Otherwise a flushed `dot4.acc` from a mispredicted path would still change the accumulator.

GCC doesn't know these instructions, but the assembler's `.insn` directive can encode them directly:

```asm
.insn r 0x0b, 1, 0, x0, a0, a1     # dot4.acc a0, a1
```

### Measured speedup

`bench_dot.s` computes the same 256-element int8 dot product four ways and times each one with the cycle counter. All four give the same answer, which the program checks itself.

| Version | Cycles | Cycles per element |
|---|---|---|
| Plain RV32IM | 3,075 | 12.0 |
| Plain RV32IM, loop unrolled 4x | 1,411 | 5.5 |
| `dot4.acc` | 644 | 2.5 |
| `dot4.acc`, loop unrolled 4x | 292 | 1.14 |

The custom instructions are **4.8x faster** in both comparisons: simple loop against simple loop, and unrolled against unrolled. (The best custom version is 10.5x faster than the simplest plain loop, but that compares an optimized loop with an unoptimized one, so 4.8x is the fair number.) Adding the ML unit didn't lower the clock at all.

## Quantized MNIST inference

After verifying the custom instructions on the small 256-element dot-product benchmark above, I used them to run a complete quantized MNIST classifier on the pipelined core. This is a separate, larger application benchmark; the **4.8x** result above is for `bench_dot.s`, not the official RV32I/RV32M instruction tests.

The model is an integer-only **784 → 32 → 10** multilayer perceptron: 784 int8 pixel inputs, a 32-neuron hidden layer with bias, fixed-point requantization and ReLU, and 10 output logits. The firmware runs both implementations with the same weights, biases and images:

- **Plain RV32IM:** scalar int8 multiplies and integer accumulation.
- **With custom instructions:** `acc.set`, four-lane `dot4.acc` and `acc.rd` for each dot product.

Both versions are the same C code, compiled with GCC `-O2`, with the same loop structure. Only the inner operation differs, so the comparison is fair.

For each of **16 MNIST test images**, the self-checking RTL test compares all 10 logits from *both* implementations against the exported software reference. It also records the inference cycles separately for each implementation.

| Measurement | Plain RV32IM | With `dot4.acc` |
|---|---:|---:|
| Cycles per image | 255,073 | 58,318 |
| Cycles for 16 images | 4,081,168 | 933,088 |
| Time per image at 65.104 MHz (estimated) | 3.92 ms | 0.896 ms |
| Reference logits, all 16 images | PASS | PASS |

This gives a **4.37x full-inference speedup** in CPU cycles. The complete simulation (startup, both inference paths and checks) finished after **5,024,963 cycles**, with `gp = 1` and `led = 0001`.

### On the board

The board build of the firmware (`build_mnist.py --board`) runs the same self-check first, then turns into a small demo: the LEDs show the predicted digit for the current test image in binary, and BTN1 steps to the next one. The first test image is a 7, so the board shows `0111`. Across all 16 images, the predictions on the board match the labels: 7, 2, 1, 0, 4, 1, 4, 9, 5, 9, 0, 6, 9, 0, 1, 5. If the self-check ever fails, all four LEDs light up instead.

The cycle counts above come from RTL simulation. Later, with the ARM reading the cycle counter for me, the board confirmed them to the cycle (see below).

### Where the cycles go

In the `dot4.acc` version, the inner loop is two loads, one `dot4.acc`, two address increments and a branch. Counting one load-use stall and the two instructions flushed after the taken branch, that's **9 cycles for every four multiply-adds**, and only one of those cycles is the multiply-add itself. The first layer's loop is about 97% of the inference time; requantization is only about 1%.

So the next speedups will come from the loop around `dot4.acc`, not from the math: unrolling the loop (about 2x more, by my estimate), several accumulators so one loaded input word feeds several neurons, or loads that increment their own address.

The MNIST firmware uses **4 KB instruction memory** and **64 KB data memory** to hold the model, test images, intermediate values and performance counters. The ELF/linker sets the memory locations, while `build_mnist.py` creates the initialization files: `mnist_imem.mem` and `mnist_dmem.mem` for simulation, and `mnist_board_imem.mem` and `mnist_board_dmem.mem` for the board.

## Running it from the ARM

Up to this point, every new program meant a new bitstream, and the only way to see a result was four LEDs. But the Zynq-7020 isn't just an FPGA: it also has a dual-core ARM processor on the same chip, and the PYNQ image runs Linux and Python on it. So the last step was to let the ARM drive the core.

```
   Python on the ARM (PYNQ)
          │ AXI
     SmartConnect ──── AXI BRAM controller ──── port B of the instruction memory
          │       ├─── AXI BRAM controller ──── port B of the data memory
          │       └─── AXI GPIO ──────────────── "run" bit in, LEDs out
          │
   FCLK0 (50 MHz) ──────────────────────────── the core's clock
```

**Dual-port memories.** Each memory got a second port. The core keeps using port A exactly as before, and port B goes to an AXI BRAM controller, so from Python the core's memories look like ordinary memory-mapped regions. A GPIO bit holds the core in reset while the ARM writes a program and its data; setting it to 1 starts the core at address 0.

**A trap I fell into:** with two ports, the memory array has two writers, and I first wrote both as `always_ff`. SystemVerilog only allows one `always_ff` to write a variable. The simulator didn't mind, so every test passed, but synthesis stopped recognizing the memory as block RAM and tried to build 64 KB out of flip-flops. It sat there eating 14 GB of RAM. Plain `always` blocks, which is exactly what Xilinx's own dual-port template uses, fixed it.

**The clock.** The core now runs on FCLK0, a clock generated by the ARM side, at 50 MHz. That also ends the Ethernet-clock problem described further down. The first run on the board came out at 31.25 MHz instead: PYNQ copies the clock dividers from the design's hardware description, and those assume processor settings that don't quite match how the board actually boots. Setting the clock explicitly from Python (`Clocks.fclk0_mhz = 50`) fixed it.

The 16-image MNIST firmware, loaded and run this way, gave **255,073 and 58,318 cycles per image, exactly the simulation's numbers**, so the hardware behaves just like the RTL I verified: 5.10 ms per image for plain RV32IM and 1.17 ms with `dot4.acc`, at 50 MHz.

### The full test set

For the full test set, the firmware has a server mode (`build_mnist.py --server`). After its self-check, the core waits on a small mailbox at `0x0001_E000`. Python writes an image (784 int8 pixels) and a new sequence number; the core classifies it, writes back the prediction, the 10 logits and the cycle count, and then echoes the sequence number to say it's done. Using sequence numbers instead of a done flag means a stale value can never be mistaken for a fresh answer.

`run_mnist_full.py` streams all 10,000 test images through that mailbox and checks every answer against the bit-exact integer model, computed on the ARM with NumPy:

| Measurement | Result |
|---|---|
| Images classified on the FPGA | 10,000 (the whole MNIST test set) |
| Accuracy | **96.60%**, the same as the Python reference |
| Images with any logit different from the reference | **0**: all 100,000 logits are bit-exact |
| Cycles per image, `dot4.acc` | 58,416 (1.17 ms at 50 MHz) |
| Speedup over plain RV32IM | **4.37x**, measured on the board |
| Throughput of the core | 856 images per second |

A few images take 7 cycles fewer than the rest: the ReLU has a branch, so the number of negative activations changes the cycle count very slightly. The whole run takes 77 seconds, but the core only computes for about 12 of them. The rest is Python writing the pixels one word at a time.

## Memory map

| Address | What's there |
|---|---|
| `0x0000_0000` | instruction memory (4 KB), also reachable from the ARM |
| `0x0001_0000` | data memory (64 KB; 4 KB in the earlier demos), also reachable from the ARM |
| `0x0001_E000` | mailbox for the ARM, in the server build |
| `0x8000_0000` | LEDs, write bits 3:0 |
| `0x8000_0004` | buttons, read bits 3:0 |
| `0x8000_0008` | cycle counter, read |

Anything with bit 31 set is I/O.

## Testing

I lean on the official riscv-tests, with a small custom environment header so they report pass or fail through the `gp` register instead of needing exception support. The testbench loads each test, runs it to its final `j .` instruction and checks the result.

To make sure those tests actually catch pipeline bugs, I removed each hazard mechanism one at a time (forwarding, the register-file bypass, branch flushing, the load-use stall). Every removal made tests fail, so passing all 48 means something.

The divider and the ML unit each have their own self-checking testbench: 4,400 divisions and 5,012 ML operations, compared against reference models, including corner cases like division by zero, signed overflow, and -128 x -128.

The custom instructions also have a self-checking program, `ml_test.s`, that runs in the same testbench as the riscv-tests. It covers back-to-back accumulation, results used immediately, operands that were just loaded, a divide between two accumulations, and an accumulation fetched after a taken branch, which must be thrown away without touching the accumulator.

For MNIST, `tb_mnist` checks all 10 logits of both implementations, for all 16 test images, against the Python reference, bit for bit. `tb_loader` does in simulation what the ARM does on the board: it loads the program and data only through port B, runs MNIST, and reads the results back through port B.

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

To run the riscv-tests, build them with `sw/build_tests.py`, set `tb_riscv_tests` as the simulation top in Vivado and run it. Swap `core` and `core_pipe` in the testbench to choose which core gets tested. `tb_bench` runs the dot-product benchmark and prints the cycle table above.

For the board, `top` contains the core and the block design `ps_sys` (the ARM side, the BRAM controllers and the GPIO). Build the bitstream in Vivado, then copy two files into one folder with the same base name, because PYNQ pairs them by name:

```
RISCV_ML_ACC.runs/impl_1/top.bit                              ->  riscv_ml.bit
RISCV_ML_ACC.gen/sources_1/bd/ps_sys/hw_handoff/ps_sys.hwh    ->  riscv_ml.hwh
```

The board boots PYNQ from its SD card, and Python loads the bitstream itself, so there's no programming from Vivado anymore. Any program then runs in a few lines:

```python
from riscv_loader import RiscvCore
core = RiscvCore("riscv_ml.bit")                       # programs the FPGA, sets 50 MHz
core.load("bench_dot.text.mem", "bench_dot.data.mem")  # through port B, verified
core.run()                                             # starts the core, waits for an LED
print(core.leds())                                     # 4 (0100): the measured 4x speedup
```

For MNIST, `train_mnist.py` trains the network and generates `mnist_model.h` (the header is already in the repo, so you only need this to retrain). Then build the firmware:

```sh
cd sw/mnist
python build_mnist.py            # simulation: build/mnist_imem.mem, build/mnist_dmem.mem
python build_mnist.py --board    # board:      build/mnist_board_imem.mem, build/mnist_board_dmem.mem
```

```sh
python build_mnist.py --server   # server:     build/mnist_server_imem.mem, build/mnist_server_dmem.mem
```

`core_pipe` takes `IMEM_DEPTH=1024` and `DMEM_DEPTH=16384`. Set `tb_mnist` as the simulation top to check both inference paths and print the cycle comparison; the simulation build ends with LD0 on (`0001`) for PASS. Loaded on the board, the board build shows the predicted digit on the LEDs, and BTN1 steps through the 16 images.

For the full test set, put these next to `riscv_ml.bit` and `riscv_ml.hwh` on the board: the three `mnist_server` files (`_imem.mem`, `_dmem.mem`, `.map`), `model_int8.npz`, the two MNIST test files from `sw/mnist/data`, `riscv_loader.py` and `run_mnist_full.py`. Then `python3 run_mnist_full.py` (or `python3 run_mnist_full.py 500` for a quick check).

**One Vivado trap worth knowing:** the `.mem` files given to `top` go into the block RAMs during synthesis, and Vivado doesn't always notice when only a `.mem` file has changed. Since the ARM can now load programs, this only matters for the memories' starting contents, but if you change them, run `reset_run synth_1` before generating the bitstream.

**One thing that cost me an afternoon, back when the core still ran on the board's 125 MHz oscillator:** plug in an Ethernet cable, even though nothing uses the network. On the PYNQ-Z2, the 125 MHz clock on pin H16 comes from the Ethernet chip, and without a link that chip keeps resetting itself, so the clock drops out every few seconds. To me it looked like my core was randomly restarting. The cable can go to any router, switch or PC. (The current build runs on the ARM side's clock instead, and PYNQ uses the network anyway.)

The demo program `led_demo.s` counts in binary on the LEDs. Hold BTN1 to see the buttons mirrored on the LEDs instead, and press BTN0 to reset.

## Repo layout

```
RISCV_ML_ACC.srcs/
  sources_1/new/    RTL: both cores, their building blocks, the ML unit and the board top
  sources_1/bd/     ps_sys, the block design with the ARM side, BRAM controllers and GPIO
  sim_1/new/        testbenches
  constrs_1/new/    pin constraints for the PYNQ-Z2
sw/                 linker script, test environment, build scripts, demo and benchmark programs
  mnist/            quantized MNIST: training script, firmware, model header, build script, memory images,
                    and the Python that runs on the ARM (riscv_loader.py, run_mnist_full.py)
```

## What's next

- [x] Single-cycle RV32I, then RV32M
- [x] All 48 riscv-tests passing on both cores
- [x] LEDs and buttons, running on the board
- [x] 5-stage pipeline with forwarding, stalls and flushes
- [x] Block RAM and an iterative divider
- [x] Multiplier moved to its own stage after timing analysis
- [x] Custom ML instructions
- [x] Cycle counter and int8 benchmark: 4.8x speedup
- [x] Larger benchmark: full 784 → 32 → 10 quantized MNIST inference, 4.37x speedup
- [x] MNIST on the board: the LEDs show the predicted digit for 16 test images
- [x] Loading programs from the Zynq's ARM cores instead of rebuilding the bitstream
- [x] The full MNIST test set on the FPGA: 96.60%, bit-exact on all 10,000 images
- [ ] Unroll the inner loop (about 2x more, by my estimate), then several accumulators
- [ ] Faster image transfer from the ARM (bulk copies or DMA instead of one word at a time)
- [ ] Bigger networks: 64 or 128 hidden neurons, then a small CNN

---

Sepehr Tabrizchi, [github.com/SepehrTa](https://github.com/SepehrTa)
