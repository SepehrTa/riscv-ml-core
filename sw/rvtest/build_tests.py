# build_tests.py - build the official rv32ui tests for our core.
#
# Folder layout expected:
#   C:\fpga\sw\riscv-tests\      (the cloned repository)
#   C:\fpga\sw\rvtest\           (this script, riscv_test.h, link.ld)
#
# For every test it creates, in rvtest\build\:
#   <name>.text.mem   -> instruction memory contents
#   <name>.data.mem   -> data memory contents
#
# usage:  python build_tests.py

import glob
import os
import subprocess

PREFIX  = os.environ.get("RISCV_PREFIX", "riscv-none-elf-")   # tool name prefix
HERE    = os.path.dirname(os.path.abspath(__file__))
TESTS   = os.path.join(HERE, "..", "riscv-tests")
SRC_DIR = os.path.join(TESTS, "isa", "rv32ui")
MACROS  = os.path.join(TESTS, "isa", "macros", "scalar")
OUT_DIR = os.path.join(HERE, "build")

# Tests for features our core intentionally does not have:
SKIP = {"fence_i",    # self-modifying code (needs one shared memory)
        "ma_data"}    # misaligned loads/stores


def run(cmd):
    subprocess.run(cmd, check=True)


def bin2mem(bin_path, mem_path):
    data = open(bin_path, "rb").read()
    data += b"\x00" * (-len(data) % 4)
    if not data:
        data = b"\x00" * 4                 # never write an empty .mem file
    with open(mem_path, "w") as f:
        for i in range(0, len(data), 4):
            f.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")


os.makedirs(OUT_DIR, exist_ok=True)
built = []

for src in sorted(glob.glob(os.path.join(SRC_DIR, "*.S"))):
    name = os.path.splitext(os.path.basename(src))[0]
    if name in SKIP:
        continue
    elf      = os.path.join(OUT_DIR, name + ".elf")
    text_bin = os.path.join(OUT_DIR, name + ".text.bin")
    data_bin = os.path.join(OUT_DIR, name + ".data.bin")

    # 1) compile + link with our environment and memory layout
    run([PREFIX + "gcc", "-march=rv32i", "-mabi=ilp32", "-nostdlib", "-nostartfiles",
         "-T", os.path.join(HERE, "link.ld"),
         "-I", HERE, "-I", MACROS,
         src, "-o", elf])

    # 2) extract code and data as raw bytes
    run([PREFIX + "objcopy", "-O", "binary", "-j", ".text", elf, text_bin])
    run([PREFIX + "objcopy", "-O", "binary", "-j", ".rodata", "-j", ".data", elf, data_bin])

    # 3) convert to .mem files for $readmemh
    bin2mem(text_bin, os.path.join(OUT_DIR, name + ".text.mem"))
    bin2mem(data_bin, os.path.join(OUT_DIR, name + ".data.mem"))
    built.append(name)

print(f"built {len(built)} tests into {OUT_DIR}:")
print(" ".join(built))