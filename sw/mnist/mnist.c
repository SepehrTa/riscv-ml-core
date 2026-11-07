/* mnist.c -- fully integer MNIST on the user's RV32IM + custom-0 core.
 *
 * The generated mnist_model.h MUST be next to this file.  It provides
 * W1, B1, W2, B2, TEST_X, TEST_Y, TEST_LOGITS, M1 and S1.
 *
 * Both implementations execute the same two layers:
 *   int8 x -> int32 acc1 -> fixed-point requant/ReLU -> int8 hidden
 *          -> int32 acc2 -> argmax
 *
 * Diagnostic results are written to DMEM (no UART/printf required):
 *   scalar_cycles[t] and dot4_cycles[t]: cycle counts per image
 *   scalar_logits[t][c] and dot4_logits[t][c]: all computed logits
 *   mismatch_count, first_error: correctness diagnostics
 *   scalar_predictions[t], dot4_predictions[t]: computed digit
 *   correct_scalar, correct_dot4: dataset-label accuracy counts (out of N_TEST)
 *
 * At the end: main returns 1 = PASS, or odd >1 = FAIL; crt0 writes gp.
 * LEDs show 0x1 for pass and 0xf for failure.  TEST_Y is informational;
 * hardware should match reference logits even when the model misclassifies.
 */
#include <stdint.h>
#include "mnist_model.h"

#if (N_IN % 4 != 0) || (N_HID % 4 != 0)
#error "dot4.acc requires both layer dimensions to be multiples of four"
#endif
#if (S1 < 0) || (S1 > 30)
#error "This requant implementation requires 0 <= S1 <= 30"
#endif

_Static_assert(sizeof(W1) == N_IN * N_HID, "W1 shape mismatch");
_Static_assert(sizeof(W2) == N_HID * N_OUT, "W2 shape mismatch");
_Static_assert(sizeof(TEST_X) == N_TEST * N_IN, "TEST_X shape mismatch");
_Static_assert(sizeof(TEST_LOGITS) == N_TEST * N_OUT * 4, "TEST_LOGITS shape mismatch");

#define CYCLE_COUNTER ((volatile uint32_t *)(uintptr_t)0x80000008u)
#define LED_REG       ((volatile uint32_t *)(uintptr_t)0x80000000u)

/* Volatile ensures these fields remain observable in the Vivado testbench. */
volatile uint32_t scalar_cycles[N_TEST];
volatile uint32_t dot4_cycles[N_TEST];
volatile int32_t scalar_logits[N_TEST][N_OUT];
volatile int32_t dot4_logits[N_TEST][N_OUT];
volatile uint8_t scalar_predictions[N_TEST];
volatile uint8_t dot4_predictions[N_TEST];
volatile uint32_t mismatch_count;
volatile uint32_t first_error;
volatile uint32_t correct_scalar;
volatile uint32_t correct_dot4;

static inline uint32_t read_cycles(void)
{
#ifdef __riscv
    return *CYCLE_COUNTER;
#else
    return 0;  /* Host-only logic testing; timing requires the core. */
#endif
}

static inline void write_led(uint32_t value)
{
#ifdef __riscv
    *LED_REG = value;
#else
    (void)value;
#endif
}

/* Rounding contract MUST match train_mnist.py:
 * v = (acc*M1 + (1<<30)) >> 31;
 * v = (v + (1<<(S1-1))) >> S1;   if S1 > 0
 * Both shifts are arithmetic for negative operands.
 *
 * On RV32IM, mul+mulh obtain the exact signed 64-bit product without a
 * software 64-bit multiply helper.  The lower-word addition propagates
 * its carry to the high word before shifting down by 31 bits.
 */
static inline int32_t requant_relu(int32_t acc)
{
    uint32_t lo;
    int32_t hi;
#ifdef __riscv
    __asm__ volatile (
        "mul  %0, %2, %3\n\t"
        "mulh %1, %2, %3"
        : "=&r"(lo), "=&r"(hi)
        : "r"(acc), "r"((int32_t)M1)
    );
#else
    int64_t product = (int64_t)acc * (int64_t)M1;
    lo = (uint32_t)product;
    hi = (int32_t)(product >> 32);
#endif
    uint32_t rounded_lo = lo + (1u << 30);
    hi = (int32_t)((uint32_t)hi + (uint32_t)(rounded_lo < lo));
    int32_t v = (int32_t)(((uint32_t)hi << 1) | (rounded_lo >> 31));
#if S1 > 0
    v = (v + (1 << (S1 - 1))) >> S1;
#endif
    if (v <= 0) return 0;
    if (v >= 127) return 127;
    return v;
}

static inline int32_t scalar_dot(const int8_t *a, const int8_t *b,
                                 uint32_t count, int32_t bias)
{
    int32_t acc = bias;
    for (uint32_t i = 0; i < count; ++i)
        acc += (int32_t)a[i] * (int32_t)b[i];
    return acc;
}

/* The RV32IM core is little-endian.  Input, weight rows, and local hidden
 * arrays are 4-byte-aligned; each dot count is a multiple of four.
 * __builtin_memcpy permits an alias-safe 4-byte read; combined with the
 * alignment assumption, GCC should generate one lw for each packed vector.
 */
static inline uint32_t packed4(const int8_t *p)
{
    uint32_t word;
    const void *aligned = __builtin_assume_aligned(p, 4);
    __builtin_memcpy(&word, aligned, sizeof(word));
    return word;
}

#ifdef __riscv
static inline void ml_acc_set(int32_t bias)
{
    __asm__ volatile (".insn r 0x0b, 2, 0, x0, %0, x0" :: "r"(bias) : "memory");
}
static inline void ml_dot4_acc(uint32_t a, uint32_t b)
{
    __asm__ volatile (".insn r 0x0b, 1, 0, x0, %0, %1" :: "r"(a), "r"(b) : "memory");
}
static inline int32_t ml_acc_rd(void)
{
    int32_t v;
    __asm__ volatile (".insn r 0x0b, 3, 0, %0, x0, x0" : "=r"(v) :: "memory");
    return v;
}
#else
/* Native-host fallback lets us regression-test both C paths without RTL. */
static int32_t ml_emulated_acc;
static inline void ml_acc_set(int32_t bias) { ml_emulated_acc = bias; }
static inline void ml_dot4_acc(uint32_t a, uint32_t b)
{
    for (unsigned k = 0; k < 4; ++k) {
        int8_t av = (int8_t)(a >> (8 * k));
        int8_t bv = (int8_t)(b >> (8 * k));
        ml_emulated_acc += (int32_t)av * (int32_t)bv;
    }
}
static inline int32_t ml_acc_rd(void) { return ml_emulated_acc; }
#endif

static inline int32_t accelerated_dot(const int8_t *a, const int8_t *b,
                                      uint32_t count, int32_t bias)
{
    ml_acc_set(bias);
    for (uint32_t i = 0; i < count; i += 4)
        ml_dot4_acc(packed4(a + i), packed4(b + i));
    return ml_acc_rd();
}

static void infer_scalar(const int8_t *x, int32_t logits[N_OUT])
{
    int8_t hidden[N_HID] __attribute__((aligned(4)));
    for (uint32_t h = 0; h < N_HID; ++h) {
        int32_t acc = scalar_dot(W1[h], x, N_IN, B1[h]);
        hidden[h] = (int8_t)requant_relu(acc);
    }
    for (uint32_t o = 0; o < N_OUT; ++o)
        logits[o] = scalar_dot(W2[o], hidden, N_HID, B2[o]);
}

static void infer_dot4(const int8_t *x, int32_t logits[N_OUT])
{
    int8_t hidden[N_HID] __attribute__((aligned(4)));
    for (uint32_t h = 0; h < N_HID; ++h) {
        int32_t acc = accelerated_dot(W1[h], x, N_IN, B1[h]);
        hidden[h] = (int8_t)requant_relu(acc);
    }
    for (uint32_t o = 0; o < N_OUT; ++o)
        logits[o] = accelerated_dot(W2[o], hidden, N_HID, B2[o]);
}

static uint8_t argmax(const int32_t logits[N_OUT])
{
    uint8_t best = 0;
    for (uint32_t o = 1; o < N_OUT; ++o)
        if (logits[o] > logits[best]) best = (uint8_t)o;
    return best;
}

static void record_mismatch(uint32_t test, uint32_t output, uint32_t mode)
{
    /* Odd failure code; 1 means PASS.  0=scalar, 1=accelerated.
     * A failing mode/test/output is distinguishable by gp:
     * gp = 2*(1 + mode*N_TEST*N_OUT + test*N_OUT + output) + 1.
     */
    uint32_t code = 2u * (1u + mode * (N_TEST * N_OUT)
                           + test * N_OUT + output) + 1u;
    if (mismatch_count == 0) first_error = code;
    ++mismatch_count;
}

int main(void)
{
    mismatch_count = 0;
    first_error = 1;
    correct_scalar = 0;
    correct_dot4 = 0;
    for (uint32_t t = 0; t < N_TEST; ++t) {
        int32_t baseline[N_OUT];
        int32_t accelerated[N_OUT];
        uint32_t t0, t1;

        t0 = read_cycles();
        infer_scalar(TEST_X[t], baseline);
        t1 = read_cycles();
        scalar_cycles[t] = t1 - t0; /* unsigned subtraction handles wrap */

        t0 = read_cycles();
        infer_dot4(TEST_X[t], accelerated);
        t1 = read_cycles();
        dot4_cycles[t] = t1 - t0;

        scalar_predictions[t] = argmax(baseline);
        dot4_predictions[t] = argmax(accelerated);
        if (scalar_predictions[t] == TEST_Y[t]) ++correct_scalar;
        if (dot4_predictions[t] == TEST_Y[t]) ++correct_dot4;
        for (uint32_t o = 0; o < N_OUT; ++o) {
            scalar_logits[t][o] = baseline[o];
            dot4_logits[t][o] = accelerated[o];
            if (baseline[o] != TEST_LOGITS[t][o])
                record_mismatch(t, o, 0);
            if (accelerated[o] != TEST_LOGITS[t][o])
                record_mismatch(t, o, 1);
        }
    }
    write_led(mismatch_count ? 0xFu : 0x1u);
    return (int)(mismatch_count ? first_error : 1u);
}
