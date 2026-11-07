"""
train_mnist.py - train a small MLP on MNIST, quantize it to int8, and export it
for the RISC-V core.

    784 inputs -> 32 hidden (ReLU) -> 10 outputs -> argmax

NumPy only (no PyTorch/TensorFlow needed). Steps:
  1. download MNIST (cached in ./data)
  2. train the float model
  3. quantize to int8 and build an integer-only reference model that computes
     exactly what the C code and the hardware must compute, bit for bit
  4. report float and int8 accuracy on the 10,000 test images
  5. export mnist_model.h (weights + test images + expected outputs) for C

Integer pipeline (identical in Python, C and on the core):
  x_q  = pixel >> 1                                   int8, 0..127
  acc1 = W1_q . x_q + B1_q                            int32
  h_q  = clamp(requant(acc1, M1, S1), 0, 127)         int8 (ReLU included)
  acc2 = W2_q . h_q + B2_q                            int32 logits
  pred = argmax(acc2)
  requant(a, M, S) = round(round(a * M / 2^31) / 2^S)  (fixed-point multiply)
"""

import gzip
import os
import urllib.request
import numpy as np

N_IN, N_HID, N_OUT = 784, 32, 10
EPOCHS, BATCH, LR = 15, 128, 1e-3
N_EXPORT = 16                      # test images exported for the core
SEED = 0

MIRRORS = [
    "https://storage.googleapis.com/cvdf-datasets/mnist/",
    "https://raw.githubusercontent.com/fgnt/mnist/master/",
]
FILES = {
    "train_x": "train-images-idx3-ubyte.gz",
    "train_y": "train-labels-idx1-ubyte.gz",
    "test_x":  "t10k-images-idx3-ubyte.gz",
    "test_y":  "t10k-labels-idx1-ubyte.gz",
}


# ----------------------------------------------------------------------------
# 1. Data
# ----------------------------------------------------------------------------
def download(name, folder="data"):
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, name)
    if not os.path.exists(path):
        for base in MIRRORS:
            try:
                print(f"downloading {name} from {base}")
                urllib.request.urlretrieve(base + name, path)
                break
            except Exception as e:
                print(f"  failed: {e}")
        else:
            raise RuntimeError(f"could not download {name}")
    return path


def load_idx(path):
    with gzip.open(path, "rb") as f:
        data = f.read()
    magic = int.from_bytes(data[0:4], "big")
    if magic == 2051:                                  # images
        n, rows, cols = (int.from_bytes(data[i:i + 4], "big") for i in (4, 8, 12))
        return np.frombuffer(data, np.uint8, offset=16).reshape(n, rows * cols)
    if magic == 2049:                                  # labels
        return np.frombuffer(data, np.uint8, offset=8)
    raise ValueError(f"{path}: not an MNIST idx file")


def load_mnist():
    d = {k: load_idx(download(v)) for k, v in FILES.items()}
    return d["train_x"], d["train_y"].astype(np.int64), d["test_x"], d["test_y"].astype(np.int64)


def quantize_input(pixels):
    """uint8 pixels 0..255 -> int8 0..127 (what the core receives)."""
    return (pixels >> 1).astype(np.int8)


# ----------------------------------------------------------------------------
# 2. Float training (plain NumPy, Adam, cross-entropy)
# ----------------------------------------------------------------------------
def train(x_train, y_train, x_test, y_test):
    rng = np.random.default_rng(SEED)
    p = {
        "W1": rng.normal(0, np.sqrt(2 / N_IN), (N_HID, N_IN)).astype(np.float32),
        "b1": np.zeros(N_HID, np.float32),
        "W2": rng.normal(0, np.sqrt(2 / N_HID), (N_OUT, N_HID)).astype(np.float32),
        "b2": np.zeros(N_OUT, np.float32),
    }
    m = {k: np.zeros_like(v) for k, v in p.items()}
    v = {k: np.zeros_like(v) for k, v in p.items()}
    t = 0

    for epoch in range(EPOCHS):
        order = rng.permutation(len(x_train))
        for i in range(0, len(order), BATCH):
            idx = order[i:i + BATCH]
            x, y = x_train[idx], y_train[idx]
            # forward
            z1 = x @ p["W1"].T + p["b1"]
            h = np.maximum(z1, 0)
            z2 = h @ p["W2"].T + p["b2"]
            z2 -= z2.max(axis=1, keepdims=True)
            prob = np.exp(z2)
            prob /= prob.sum(axis=1, keepdims=True)
            # backward
            d2 = prob
            d2[np.arange(len(y)), y] -= 1
            d2 /= len(y)
            g = {"W2": d2.T @ h, "b2": d2.sum(0)}
            d1 = (d2 @ p["W2"]) * (z1 > 0)
            g["W1"] = d1.T @ x
            g["b1"] = d1.sum(0)
            # Adam
            t += 1
            for k in p:
                m[k] = 0.9 * m[k] + 0.1 * g[k]
                v[k] = 0.999 * v[k] + 0.001 * g[k] ** 2
                mh = m[k] / (1 - 0.9 ** t)
                vh = v[k] / (1 - 0.999 ** t)
                p[k] -= LR * mh / (np.sqrt(vh) + 1e-8)
        acc = float_accuracy(p, x_test, y_test)
        print(f"epoch {epoch + 1:2d}/{EPOCHS}: float test accuracy {acc * 100:.2f}%")
    return p


def float_forward(p, x):
    h = np.maximum(x @ p["W1"].T + p["b1"], 0)
    return h @ p["W2"].T + p["b2"], h


def float_accuracy(p, x, y):
    return (float_forward(p, x)[0].argmax(1) == y).mean()


# ----------------------------------------------------------------------------
# 3. Quantization and the integer reference model
# ----------------------------------------------------------------------------
def quantize_multiplier(m):
    """Real multiplier 0 < m < 1  ->  (M, S) with m ~= M / 2^31 / 2^S, M in [2^30, 2^31)."""
    s = 0
    while m < 0.5:
        m *= 2
        s += 1
    M = int(round(m * (1 << 31)))
    if M == (1 << 31):                                 # rounding pushed it to 1.0
        M //= 2
        s -= 1
    return M, s


def requant(acc, M, S):
    """round(round(acc * M / 2^31) / 2^S), integer only (matches the C code)."""
    acc = acc.astype(np.int64)
    v = (acc * M + (1 << 30)) >> 31
    if S > 0:
        v = (v + (1 << (S - 1))) >> S
    return v


def quantize(p, x_train_f):
    s_x = 1.0 / 127                                    # x_f = x_q / 127
    s_w1 = np.abs(p["W1"]).max() / 127
    s_w2 = np.abs(p["W2"]).max() / 127

    # hidden-activation scale from the training data (99.99th percentile)
    _, h = float_forward(p, x_train_f)
    s_h = np.percentile(h, 99.99) / 127

    q = {
        "W1": np.clip(np.round(p["W1"] / s_w1), -127, 127).astype(np.int8),
        "B1": np.round(p["b1"] / (s_w1 * s_x)).astype(np.int32),
        "W2": np.clip(np.round(p["W2"] / s_w2), -127, 127).astype(np.int8),
        "B2": np.round(p["b2"] / (s_w2 * s_h)).astype(np.int32),
    }
    q["M1"], q["S1"] = quantize_multiplier(s_w1 * s_x / s_h)
    return q


def int_forward(q, x_q):
    """Integer-only inference: exactly what the core computes."""
    acc1 = x_q.astype(np.int32) @ q["W1"].astype(np.int32).T + q["B1"]
    h_q = np.clip(requant(acc1, q["M1"], q["S1"]), 0, 127).astype(np.int8)
    acc2 = h_q.astype(np.int32) @ q["W2"].astype(np.int32).T + q["B2"]
    return acc2, acc1, h_q


# ----------------------------------------------------------------------------
# 4. Export for C
# ----------------------------------------------------------------------------
def c_array(ctype, name, arr, per_line=16):
    flat = arr.flatten().tolist()
    dims = "".join(f"[{d}]" for d in arr.shape)
    lines = [", ".join(str(int(x)) for x in flat[i:i + per_line]) for i in range(0, len(flat), per_line)]
    body = ",\n    ".join(lines)
    return f"const {ctype} {name}{dims} __attribute__((aligned(4))) = {{\n    {body}\n}};\n"


def export_header(q, x_q, y, acc2, path="mnist_model.h"):
    with open(path, "w") as f:
        f.write("// mnist_model.h - generated by train_mnist.py, do not edit\n")
        f.write("// 784 -> 32 (ReLU) -> 10 int8 MLP, plus test images and expected outputs\n")
        f.write("#pragma once\n#include <stdint.h>\n\n")
        f.write(f"#define N_IN   {N_IN}\n#define N_HID  {N_HID}\n#define N_OUT  {N_OUT}\n")
        f.write(f"#define N_TEST {len(y)}\n\n")
        f.write(f"#define M1 {q['M1']}   // requant multiplier (Q31)\n")
        f.write(f"#define S1 {q['S1']}            // requant extra right shift\n\n")
        f.write(c_array("int8_t",  "W1", q["W1"]))
        f.write(c_array("int32_t", "B1", q["B1"]))
        f.write(c_array("int8_t",  "W2", q["W2"]))
        f.write(c_array("int32_t", "B2", q["B2"]))
        f.write(c_array("int8_t",  "TEST_X", x_q))
        f.write(c_array("uint8_t", "TEST_Y", y.astype(np.uint8)))
        f.write("// expected int32 logits for each test image (bit-exact reference)\n")
        f.write(c_array("int32_t", "TEST_LOGITS", acc2))
    print(f"wrote {path} ({os.path.getsize(path) / 1024:.0f} KB of C source)")


# ----------------------------------------------------------------------------
def main():
    train_x, train_y, test_x, test_y = load_mnist()
    print(f"MNIST: {len(train_x)} training, {len(test_x)} test images")

    # the float model sees exactly the values the core will see: x_q / 127
    xq_train, xq_test = quantize_input(train_x), quantize_input(test_x)
    xf_train = xq_train.astype(np.float32) / 127
    xf_test = xq_test.astype(np.float32) / 127

    p = train(xf_train, train_y, xf_test, test_y)
    q = quantize(p, xf_train)

    acc2, acc1, _ = int_forward(q, xq_test)
    float_acc = float_accuracy(p, xf_test, test_y)
    int_acc = (acc2.argmax(1) == test_y).mean()
    print(f"\nfloat accuracy : {float_acc * 100:.2f}%")
    print(f"int8 accuracy  : {int_acc * 100:.2f}%   (integer-only, bit-exact with the core)")
    print(f"requant        : M1 = {q['M1']}, S1 = {q['S1']}")
    print(f"max |acc1|     : {np.abs(acc1).max()}   (int32 accumulator, no overflow risk)")

    np.savez("model_float.npz", **p)
    np.savez("model_int8.npz", **{k: np.asarray(v) for k, v in q.items()})
    export_header(q, xq_test[:N_EXPORT], test_y[:N_EXPORT], acc2[:N_EXPORT])


if __name__ == "__main__":
    main()