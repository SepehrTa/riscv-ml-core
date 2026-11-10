"""
run_mnist_full.py - M4: classify the whole MNIST test set (10,000 images) on the FPGA.

The core runs the server build of the firmware (build_mnist.py --server). Python
sends one image at a time through the mailbox at 0x0001_E000, and checks every
answer against the bit-exact integer model computed here with NumPy.

Needs, in the same folder on the board:
  riscv_ml.bit, riscv_ml.hwh
  mnist_server_imem.mem, mnist_server_dmem.mem, mnist_server.map
  model_int8.npz                       (from the same train_mnist.py run as mnist_model.h)
  t10k-images-idx3-ubyte.gz, t10k-labels-idx1-ubyte.gz
  riscv_loader.py
Run:  python3 run_mnist_full.py            (all 10,000 images)
      python3 run_mnist_full.py 500        (only the first 500, for a quick test)
"""
import gzip
import sys
import time

import numpy as np
from pynq import Clocks

from riscv_loader import RiscvCore, read_map_symbols, read_mem_file

# mailbox layout (must match mailbox_t in mnist.c)
MAILBOX = 0x0001_E000
CMD, ACK, PRED, CYCLES, LOGITS, FLAGS, CYCLES_PLAIN, IMAGE = (
    0x000, 0x004, 0x008, 0x00C, 0x010, 0x038, 0x03C, 0x040)
PLAIN_EVERY = 100            # also time the plain RV32IM version on every 100th image


def load_idx(path):
    with gzip.open(path, "rb") as f:
        data = f.read()
    magic = int.from_bytes(data[0:4], "big")
    if magic == 2051:
        n, rows, cols = (int.from_bytes(data[i:i + 4], "big") for i in (4, 8, 12))
        return np.frombuffer(data, np.uint8, offset=16).reshape(n, rows * cols)
    return np.frombuffer(data, np.uint8, offset=8)


def requant(acc, M, S):
    """Same integer arithmetic as train_mnist.py and the firmware."""
    v = (acc.astype(np.int64) * M + (1 << 30)) >> 31
    if S > 0:
        v = (v + (1 << (S - 1))) >> S
    return v


def reference_logits(q, x_q):
    acc1 = x_q.astype(np.int64) @ q["W1"].astype(np.int64).T + q["B1"]
    h_q = np.clip(requant(acc1, int(q["M1"]), int(q["S1"])), 0, 127)
    return h_q @ q["W2"].astype(np.int64).T + q["B2"]


def main():
    n_images = int(sys.argv[1]) if len(sys.argv) > 1 else 10000

    # ---- the reference model, and a check that it matches the firmware ----
    x = load_idx("t10k-images-idx3-ubyte.gz")[:n_images]
    y = load_idx("t10k-labels-idx1-ubyte.gz")[:n_images].astype(np.int64)
    x_q = (x >> 1).astype(np.int8)                     # what the core receives
    q = np.load("model_int8.npz")
    ref = reference_logits(q, x_q)

    sym = read_map_symbols("mnist_server.map")
    dmem_image = read_mem_file("mnist_server_dmem.mem")
    start = (sym["TEST_LOGITS"] - 0x10000) // 4
    fw_logits = np.array(dmem_image[start:start + 16 * 10], np.uint32).view(np.int32).reshape(16, 10)
    if n_images >= 16 and not np.array_equal(fw_logits, ref[:16]):
        sys.exit("model_int8.npz does not match the firmware's mnist_model.h: "
                 "use the files from the same train_mnist.py run")

    # ---- load the server firmware and wait until it is ready ----
    core = RiscvCore("riscv_ml.bit")
    core.load("mnist_server_imem.mem", "mnist_server_dmem.mem")
    core.write_word(MAILBOX + CMD, 0)
    core.write_word(MAILBOX + ACK, 0xFFFFFFFF)          # "not ready" until the core says so
    core.start()
    t0 = time.time()
    while core.read_word(MAILBOX + ACK) != core.read_word(MAILBOX + CMD):
        if core.leds() == 0xF:
            sys.exit("the firmware's self-check failed (LEDs = 1111)")
        if time.time() - t0 > 5:
            sys.exit("the core did not become ready (is this the --server build?)")
        time.sleep(0.001)
    print(f"server ready after {(time.time() - t0) * 1000:.0f} ms (self-check passed)")

    # ---- send every image ----
    words = x_q.view(np.uint32)                          # 196 little-endian words per image
    image_off = MAILBOX + IMAGE
    preds = np.zeros(n_images, np.int64)
    cycles = np.zeros(n_images, np.int64)
    plain = []
    logit_mismatch_images = 0
    t_start = time.time()
    for i in range(n_images):
        for w in range(196):
            core.write_word(image_off + 4 * w, words[i, w])
        timed = (i % PLAIN_EVERY == 0)
        core.write_word(MAILBOX + FLAGS, 1 if timed else 0)
        n = i + 1
        core.write_word(MAILBOX + CMD, n)
        t_wait = time.time()
        while core.read_word(MAILBOX + ACK) != n:
            if time.time() - t_wait > 1.0:
                sys.exit(f"no answer for image {i}")
        logits = np.array(core.read_words(MAILBOX + LOGITS, 10), np.uint32).view(np.int32)
        preds[i] = core.read_word(MAILBOX + PRED)
        cycles[i] = core.read_word(MAILBOX + CYCLES)
        if timed:
            plain.append(core.read_word(MAILBOX + CYCLES_PLAIN))
        if not np.array_equal(logits, ref[i]):
            logit_mismatch_images += 1
            if logit_mismatch_images <= 5:
                print(f"  image {i}: hardware {logits.tolist()} vs reference {ref[i].tolist()}")
        if (i + 1) % 1000 == 0:
            acc = (preds[:i + 1] == y[:i + 1]).mean() * 100
            print(f"  {i + 1:5d} images, accuracy so far {acc:.2f}%, "
                  f"{logit_mismatch_images} with logit mismatches")
    wall = time.time() - t_start

    # ---- results ----
    mhz = Clocks.fclk0_mhz
    accuracy = (preds == y).mean() * 100
    ref_accuracy = (ref.argmax(1) == y).mean() * 100
    dot4 = cycles.mean()
    plain_mean = float(np.mean(plain)) if plain else 0.0
    print()
    print(f"images                 : {n_images}")
    print(f"accuracy on the FPGA   : {accuracy:.2f}%   (reference model: {ref_accuracy:.2f}%)")
    print(f"images with any logit  : {logit_mismatch_images} differ from the reference (0 = bit-exact)")
    print(f"dot4.acc               : {dot4:,.0f} cycles per image ({dot4 / mhz / 1000:.3f} ms at {mhz:.0f} MHz)"
          f", min {cycles.min():,}, max {cycles.max():,}")
    if plain:
        print(f"plain RV32IM (sampled) : {plain_mean:,.0f} cycles per image over {len(plain)} images"
              f" -> speedup {plain_mean / dot4:.2f}x")
    print(f"inference throughput   : {mhz * 1e6 / dot4:,.0f} images/s on the core alone")
    print(f"wall clock             : {wall:.1f} s for {n_images} images (mostly Python writing pixels)")


if __name__ == "__main__":
    main()
