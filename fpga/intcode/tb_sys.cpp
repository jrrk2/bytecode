// Verilator harness for intcode_sys (the whole system: core, block-RAM store, UART console): a UART model on the pins.
//   tb_sys [max_clocks] [text to type at the console]      CLK_DIV = clocks per UART bit (default 217)
#include "Vintcode_sys.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    uint64_t max = argc > 1 ? strtoull(argv[1], nullptr, 0) : 200000000ULL;
    const char *input = argc > 2 ? argv[2] : "";
    std::string filetext;                                      // INPUT_FILE: the text to type, from a file (a program image is long)
    if (const char *fn = getenv("INPUT_FILE")) { FILE *f = fopen(fn, "rb"); int c; while (f && (c = fgetc(f)) != EOF) filetext += (char)c; if (f) fclose(f); input = filetext.c_str(); }
    int div = getenv("CLK_DIV") ? atoi(getenv("CLK_DIV")) : 217;
    Vintcode_sys *top = new Vintcode_sys;
    top->uart_rx_in = 1; top->clk = 0;
    // the receiver: bits of the typed text, 10 per byte
    size_t ni = getenv("INPUT_FILE") ? filetext.size() : strlen(input), ib = 0; int ibit = -1, icnt = 0; uint32_t ibyte = 0;
    // the transmitter: sample the line in the middle of each bit
    int ts = -1, tcnt = 0, tbyte = 0, last = 1;
    uint64_t clocks = 0; unsigned chars = 0;
    uint64_t halted_at = 0;
    while (clocks < max && !(halted_at && clocks > halted_at + 40ULL * 10 * div)) {      // after the halt, long enough for the UART to finish
        if ((top->led & 2) && !halted_at) halted_at = clocks;
        top->clk = 0; top->eval(); top->clk = 1; top->eval(); clocks++;
        if (clocks < 100) continue;
        // typing
        if (ibit < 0) { if (ib < ni && clocks > 40000) { ibyte = (unsigned char)input[ib++]; ibit = 0; icnt = div; top->uart_rx_in = 0; } }
        else if (--icnt == 0) {
            icnt = div;
            if (ibit < 8) top->uart_rx_in = (ibyte >> ibit++) & 1;
            else if (ibit == 8) { top->uart_rx_in = 1; ibit++; }
            else ibit = -1;
        }
        // receiving what the system sends
        int tx = top->uart_tx_out;
        if (ts < 0) { if (last && !tx) { ts = 0; tcnt = div + div / 2; tbyte = 0; } }
        else if (--tcnt == 0) {
            if (ts < 8) { tbyte |= tx << ts++; tcnt = div; }
            else { putchar(tbyte); fflush(stdout); chars++; ts = -1; }
        }
        if (getenv("TX_EDGES") && tx != last) fprintf(stderr, "%llu:%d ", (unsigned long long)clocks, tx);
        last = tx;
    }
    fprintf(stderr, "\n[%llu clocks, %u characters, %s, led=%02x]\n", (unsigned long long)clocks, chars, (top->led & 2) ? "halted" : "still running", (unsigned)top->led);
    delete top;
    return 0;
}
