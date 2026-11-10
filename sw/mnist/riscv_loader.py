"""
riscv_loader.py - load and run programs on the RISC-V core from the Zynq ARM (PYNQ).

The ARM talks to the core through the block design ps_sys:
  axi_bram_ctrl_imem : port B of the 4 KB instruction memory
  axi_bram_ctrl_dmem : port B of the 64 KB data memory
  axi_gpio_ctrl      : channel 1 bit 0 = run (0 holds the core in reset)
                       channel 2 bits 3:0 = the core's LEDs

Usage in a notebook:
    from riscv_loader import RiscvCore
    core = RiscvCore("riscv_ml.bit")
    core.load("mnist_imem.mem", "mnist_dmem.mem")
    core.run()
    print(core.leds())
"""
import re
import time

from pynq import MMIO, Clocks, Overlay

DMEM_CPU_BASE = 0x0001_0000          # where the core sees data memory
GPIO_RUN = 0x0                       # AXI GPIO channel 1 data register
GPIO_STATUS = 0x8                    # AXI GPIO channel 2 data register


def read_mem_file(path):
    """A .mem file (one 32-bit hex word per line) -> list of ints."""
    words = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("//"):
                words.append(int(line, 16))
    return words


def read_map_symbols(path):
    """Symbol addresses from a GNU ld .map file: {'scalar_cycles': 0x19ce8, ...}."""
    symbols = {}
    pattern = re.compile(r"^\s+0x([0-9a-fA-F]+)\s+([A-Za-z_]\w*)\s*$")
    with open(path) as f:
        for line in f:
            m = pattern.match(line)
            if m:
                symbols[m.group(2)] = int(m.group(1), 16)
    return symbols


class RiscvCore:
    def __init__(self, bitfile, addresses=None, fclk_mhz=50.0):
        """Load the bitstream (+ .hwh with the same name) and find the three blocks.

        addresses: optional {'imem': (base, size), 'dmem': (base, size),
                   'gpio': (base, size)} if the .hwh cannot be read.
        fclk_mhz:  the core's clock. Set explicitly, because the clock dividers
                   stored in the .hwh assume the PS settings of the design, which
                   may not match the PLLs the board actually booted with.
        """
        if addresses is None:
            self.overlay = Overlay(bitfile)          # programs the FPGA
            Clocks.fclk0_mhz = fclk_mhz              # then set the core clock exactly
            imem = self._find("axi_bram_ctrl_imem")
            dmem = self._find("axi_bram_ctrl_dmem")
            gpio = self._find("axi_gpio_ctrl")
        else:
            from pynq import Bitstream
            Bitstream(bitfile).download()
            Clocks.fclk0_mhz = fclk_mhz              # no .hwh: set the clock by hand
            imem, dmem, gpio = addresses["imem"], addresses["dmem"], addresses["gpio"]

        self.imem = MMIO(imem[0], imem[1])
        self.dmem = MMIO(dmem[0], dmem[1])
        self.gpio = MMIO(gpio[0], gpio[1])
        self.imem_words = imem[1] // 4
        self.dmem_words = dmem[1] // 4
        self.stop()
        print(f"IMEM at 0x{imem[0]:08x} ({imem[1] // 1024} KB), "
              f"DMEM at 0x{dmem[0]:08x} ({dmem[1] // 1024} KB), "
              f"GPIO at 0x{gpio[0]:08x}, FCLK0 = {Clocks.fclk0_mhz:.1f} MHz")

    def _find(self, name):
        """Base address and size of a block, from the overlay's ip_dict or mem_dict."""
        for table in (self.overlay.ip_dict, self.overlay.mem_dict):
            for key, info in table.items():
                if key == name or key.endswith("/" + name):
                    base = info.get("phys_addr", info.get("base_address"))
                    return int(base), int(info["addr_range"])
        raise KeyError(f"{name} not found in the overlay; check the .hwh file")

    # ---------------------------------------------------------------- control
    def stop(self):
        """Hold the core in reset (run = 0). Needed before loading memories."""
        self.gpio.write(GPIO_RUN, 0)

    def start(self):
        """Release the core: it starts at PC = 0."""
        self.gpio.write(GPIO_RUN, 1)

    def leds(self):
        return self.gpio.read(GPIO_STATUS) & 0xF

    # ---------------------------------------------------------------- memories
    def load(self, imem_file, dmem_file, verify=True):
        """Write a program and its data through port B, with the core in reset."""
        self.stop()
        imem = read_mem_file(imem_file)
        dmem = read_mem_file(dmem_file)
        if len(imem) > self.imem_words or len(dmem) > self.dmem_words:
            raise ValueError("program or data does not fit in the core's memories")
        for i, w in enumerate(imem):
            self.imem.write(4 * i, w)
        for i, w in enumerate(dmem):
            self.dmem.write(4 * i, w)
        if verify:
            bad = sum(self.imem.read(4 * i) != w for i, w in enumerate(imem))
            bad += sum(self.dmem.read(4 * i) != w for i, w in enumerate(dmem))
            if bad:
                raise RuntimeError(f"{bad} words read back wrong after loading")
        print(f"loaded {len(imem)} instruction words and {len(dmem)} data words"
              + (", read back OK" if verify else ""))

    def read_word(self, cpu_addr):
        """A 32-bit word of data memory, by the address the core uses (0x0001_xxxx)."""
        return self.dmem.read(cpu_addr - DMEM_CPU_BASE)

    def write_word(self, cpu_addr, value):
        """Write a 32-bit word of data memory, by the address the core uses."""
        self.dmem.write(cpu_addr - DMEM_CPU_BASE, int(value) & 0xFFFFFFFF)

    def read_words(self, cpu_addr, n):
        return [self.read_word(cpu_addr + 4 * i) for i in range(n)]

    def read_bytes(self, cpu_addr, n):
        out = []
        for i in range(n):
            a = cpu_addr + i
            out.append((self.read_word(a & ~3) >> (8 * (a & 3))) & 0xFF)
        return out

    # ---------------------------------------------------------------- running
    def run(self, timeout=5.0):
        """Reset, start, and wait until the program lights an LED. Returns seconds."""
        self.stop()
        time.sleep(0.001)
        t0 = time.time()
        self.start()
        while self.leds() == 0:
            if time.time() - t0 > timeout:
                raise TimeoutError(f"no LED after {timeout} s: the program did not finish")
            time.sleep(0.001)
        return time.time() - t0
