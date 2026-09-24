#include "Vfpu_hardfloat.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <random>
#include <vector>

static uint64_t bits(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static double dbl(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }

static Vfpu_hardfloat *dut;
static vluint64_t tick_count = 0;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); tick_count++; }

enum { OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_SQRT, OP_LT, OP_LE, OP_EQ, OP_NEG, OP_ABS };
static const char *opname[] = {"add","sub","mul","div","sqrt","lt","le","eq","neg","abs"};

// returns result bits; for comparisons the flag is in *flag
static uint64_t run(int op, uint64_t a, uint64_t b, bool *flag) {
    dut->op = op; dut->a = a; dut->b = b; dut->start = 1;
    tick();
    dut->start = 0;
    for (int i = 0; i < 400 && !dut->done; i++) tick();
    if (!dut->done) { printf("  TIMEOUT op=%s\n", opname[op]); return 0; }
    if (flag) *flag = dut->flag;
    uint64_t r = dut->result;
    tick();
    return r;
}

struct Stats { int n = 0, bad = 0; };
static Stats stats[10];

static void check(int op, uint64_t ua, uint64_t ub) {
    double a = dbl(ua), b = dbl(ub);
    bool flag = false;
    uint64_t got = run(op, ua, ub, &flag);
    stats[op].n++;
    bool ok;
    if (op == OP_LT) ok = (flag == (a < b));
    else if (op == OP_LE) ok = (flag == (a <= b));
    else if (op == OP_EQ) ok = (flag == (a == b));
    else {
        double want;
        switch (op) {
            case OP_ADD: want = a + b; break;
            case OP_SUB: want = a - b; break;
            case OP_MUL: want = a * b; break;
            case OP_DIV: want = a / b; break;
            case OP_SQRT: want = std::sqrt(a); break;
            case OP_NEG: want = -a; break;
            default:     want = std::fabs(a); break;
        }
        ok = std::isnan(want) ? std::isnan(dbl(got)) : (got == bits(want));
    }
    if (!ok) {
        if (stats[op].bad < 4)
            printf("  %-4s a=%-16.9g b=%-16.9g  got=%016lx (%g)\n",
                   opname[op], a, b, got, dbl(got));
        stats[op].bad++;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vfpu_hardfloat;
    dut->resetn = 0; dut->start = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->resetn = 1;
    for (int i = 0; i < 4; i++) tick();

    std::vector<uint64_t> corners = {
        0x0000000000000000ULL, 0x8000000000000000ULL,   // +0 -0
        0x0000000000000001ULL, 0x000fffffffffffffULL,   // subnormals
        0x0010000000000000ULL, 0x7fefffffffffffffULL,   // min/max normal
        0x3ff0000000000000ULL, 0xbff0000000000000ULL,   // +-1
        0x4000000000000000ULL, 0x400921fb54442d18ULL,   // 2, pi
        0x7ff0000000000000ULL, 0xfff0000000000000ULL,   // +-inf
        0x7ff8000000000000ULL,                          // NaN
        0x3fe0000000000000ULL, 0x4330000000000000ULL,   // 0.5, 2^52
    };
    int ops[] = {OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_SQRT, OP_LT, OP_LE, OP_EQ, OP_NEG, OP_ABS};
    printf("corner pairs (%zu x %zu, every operation):\n", corners.size(), corners.size());
    for (int op : ops)
        for (uint64_t a : corners)
            for (uint64_t b : corners) check(op, a, b);

    std::mt19937_64 rng(2026);
    printf("random values:\n");
    for (int i = 0; i < 4000; i++) {
        uint64_t a = rng(), b = rng();
        for (int op : ops) check(op, a, b);
    }
    // values of similar magnitude, where cancellation and rounding bite
    for (int i = 0; i < 4000; i++) {
        int e = 1000 + (rng() % 60);
        uint64_t a = ((uint64_t)(e) << 52) | (rng() & 0xfffffffffffffULL);
        uint64_t b = ((uint64_t)(e + (rng() % 3)) << 52) | (rng() & 0xfffffffffffffULL);
        if (rng() & 1) a |= 1ULL << 63;
        if (rng() & 1) b |= 1ULL << 63;
        for (int op : ops) check(op, a, b);
    }

    int total = 0, bad = 0;
    printf("\n%-6s %10s %8s\n", "op", "cases", "wrong");
    for (int op : ops) {
        printf("%-6s %10d %8d\n", opname[op], stats[op].n, stats[op].bad);
        total += stats[op].n; bad += stats[op].bad;
    }
    printf("%-6s %10d %8d\n", "TOTAL", total, bad);
    delete dut;
    return bad ? 1 : 0;
}
