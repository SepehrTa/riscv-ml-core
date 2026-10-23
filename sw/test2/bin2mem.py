# bin2mem.py - convert a raw binary file into a .mem file for $readmemh
# usage: python bin2mem.py input.bin output.mem
# Each output line is one 32-bit word in hex. RISC-V is little-endian,
# so every 4 bytes are combined lowest-address-first.
import sys

data = open(sys.argv[1], "rb").read()
data += b"\x00" * (-len(data) % 4)          # pad to a whole number of words

with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 4):
        word = int.from_bytes(data[i:i + 4], "little")
        f.write(f"{word:08x}\n")

print(f"{sys.argv[2]}: {len(data) // 4} words")