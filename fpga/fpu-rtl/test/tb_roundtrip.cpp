#include "Vroundtrip.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <random>

static uint64_t bits(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static double dbl(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vroundtrip *dut = new Vroundtrip;
    int bad = 0, n = 0;
    auto check = [&](uint64_t u, const char *what) {
        dut->in = u; dut->eval();
        uint64_t got = dut->out;
        n++;
        bool nan = std::isnan(dbl(u));
        bool ok = nan ? std::isnan(dbl(got)) : (got == u);
        if (!ok && bad < 12) {
            printf("  %-22s in=%016lx out=%016lx  (%g -> %g)\n", what, u, got, dbl(u), dbl(got));
            bad++;
        } else if (!ok) bad++;
    };
    struct { const char *name; uint64_t u; } corners[] = {
        {"+0",           0x0000000000000000ULL},
        {"-0",           0x8000000000000000ULL},
        {"min subnormal",0x0000000000000001ULL},
        {"mid subnormal",0x0008000000000000ULL},
        {"max subnormal",0x000fffffffffffffULL},
        {"min normal",   0x0010000000000000ULL},
        {"1.0",          0x3ff0000000000000ULL},
        {"-1.0",         0xbff0000000000000ULL},
        {"pi",           0x400921fb54442d18ULL},
        {"max normal",   0x7fefffffffffffffULL},
        {"+inf",         0x7ff0000000000000ULL},
        {"-inf",         0xfff0000000000000ULL},
        {"quiet NaN",    0x7ff8000000000000ULL},
    };
    printf("corners:\n");
    for (auto &c : corners) check(c.u, c.name);
    int corner_bad = bad;
    printf("  %d of %d corner cases wrong\n", corner_bad, n);

    std::mt19937_64 rng(12345);
    int before = bad;
    for (int i = 0; i < 200000; i++) check(rng(), "random");
    printf("random: %d of 200000 wrong\n", bad - before);
    // subnormals specifically -- the part most likely to be wrong
    before = bad; int sub_n = 0;
    for (int i = 0; i < 50000; i++) { uint64_t u = rng() & 0x000fffffffffffffULL; check(u, "subnormal"); sub_n++; }
    printf("subnormal: %d of %d wrong\n", bad - before, sub_n);
    printf("TOTAL: %d of %d round trips wrong\n", bad, n);
    delete dut;
    return bad ? 1 : 0;
}
