#!/usr/bin/env python3
"""Build MNIST firmware and two word-oriented BRAM .mem images.

From sw/mnist:
    python train_mnist.py                # generates mnist_model.h (once)
    python build_mnist.py

Required xPack GNU RISC-V toolchain on PATH (or set RISCV_PREFIX).
Produces build/mnist_imem.mem, build/mnist_dmem.mem and diagnostics.
Image format matches sw/rvtest/build_tests.py: one little-endian uint32
per line, printed as 8 hex digits, suitable for SystemVerilog $readmemh.
"""

import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"
PREFIX = os.environ.get("RISCV_PREFIX", "riscv-none-elf-")
IMEM_BYTES = 4 * 1024
DMEM_BYTES = 64 * 1024


def run(*command):
    print("+", " ".join(map(str, command)), flush=True)
    try:
        subprocess.run([str(x) for x in command], check=True)
    except FileNotFoundError as exc:
        sys.exit(f"Missing tool: {exc.filename}. Set RISCV_PREFIX or add the xPack toolchain to PATH.")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"Build failed (exit code {exc.returncode}).")


def bin_to_mem(source, destination, capacity):
    data = source.read_bytes()
    if len(data) > capacity:
        sys.exit(f"{source.name}: {len(data)} bytes exceeds {capacity}-byte BRAM capacity")
    if not data:
        sys.exit(f"{source.name}: empty ELF section/image; refusing to create empty BRAM file")
    data += bytes((-len(data)) % 4)
    with destination.open("w", encoding="ascii", newline="\n") as out:
        for offset in range(0, len(data), 4):
            out.write(f"{int.from_bytes(data[offset:offset + 4], 'little'):08x}\n")
    print(f"  {destination}: {len(data)} bytes / {capacity} bytes ({len(data) // 4} words)")


def main():
    board = "--board" in sys.argv
    tag = "mnist_board" if board else "mnist"

    if not (HERE / "mnist_model.h").is_file():
        sys.exit("Missing sw/mnist/mnist_model.h. Run train_mnist.py first and commit the header.")
    BUILD.mkdir(parents=True, exist_ok=True)

    # -mno-relax and -msmall-data-limit=0 keep gcc from using x3 (gp),
    # which the hardware testbench reserves for its pass/fail result.
    flags = [
        "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-msmall-data-limit=0",
        "-O2", "-std=c11", "-ffreestanding", "-fno-builtin", "-fno-pic",
        "-fno-pie", "-fno-strict-aliasing", "-fno-stack-protector",
        "-fno-asynchronous-unwind-tables", "-fno-unwind-tables",
        "-fno-jump-tables", "-ffunction-sections", "-fdata-sections",
        "-Wall", "-Wextra", "-Wno-missing-braces", "-Werror",
    ]
    if board:
        flags.append("-DBOARD")
    gcc, objcopy = PREFIX + "gcc", PREFIX + "objcopy"
    crt_obj, c_obj = BUILD / "crt0.o", BUILD / "mnist.o"
    elf = BUILD / f"{tag}.elf"
    mapfile = BUILD / f"{tag}.map"

    run(gcc, "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-c", HERE / "crt0.s", "-o", crt_obj)
    run(gcc, *flags, "-c", HERE / "mnist.c", "-o", c_obj)
    run(gcc, "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-nostdlib",
        "-nostartfiles", "-no-pie", "-Wl,--build-id=none", "-Wl,--no-relax",
        "-Wl,--gc-sections", f"-Wl,-Map={mapfile}", "-T", HERE / "link.ld",
        crt_obj, c_obj, "-lgcc", "-o", elf)

    # .text starts at address zero.  .rodata and .data are contiguous in
    # DMEM, starting at 0x10000; objcopy fills any alignment gaps with zero.
    # .bss is NOLOAD and is explicitly zeroed by crt0.s on reset.
    imem_bin, dmem_bin = BUILD / f"{tag}_imem.bin", BUILD / f"{tag}_dmem.bin"
    run(objcopy, "-O", "binary", "-j", ".text", elf, imem_bin)
    run(objcopy, "-O", "binary", "-j", ".rodata", "-j", ".data", elf, dmem_bin)
    bin_to_mem(imem_bin, BUILD / f"{tag}_imem.mem", IMEM_BYTES)
    bin_to_mem(dmem_bin, BUILD / f"{tag}_dmem.mem", DMEM_BYTES)
    print(f"\nPASS: Firmware linked and BRAM images created ({tag}_imem.mem, {tag}_dmem.mem).")

if __name__ == "__main__":
    main()
