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
    // the software flash: a mode 0 SPI slave answering READ (0x03) with a 24-bit address, from $FLASH_FILE placed at $FLASH_BASE (default 0xA00000);
    // 0xFF elsewhere, as a blank chip reads.  Also counts the commands it saw.
    std::string flash;
    if (const char *fn = getenv("FLASH_FILE")) { FILE *f = fopen(fn, "rb"); int c; while (f && (c = fgetc(f)) != EOF) flash += (char)c; if (f) fclose(f); }
    uint32_t flash_base = getenv("FLASH_BASE") ? strtoul(getenv("FLASH_BASE"), nullptr, 0) : 0xA00000;
    int f_bits = 0, f_prev_clk = 0, f_miso = 1, f_cmd_seen[256] = {0}; uint32_t f_cmd = 0, f_addr = 0; unsigned f_bytes = 0;
    Vintcode_sys *top = new Vintcode_sys;
    top->uart_rx_in = 1; top->clk = 0; top->spi_miso = 1;
    // the receiver: bits of the typed text, 10 per byte
    size_t ni = getenv("INPUT_FILE") ? filetext.size() : strlen(input), ib = 0; int ibit = -1, icnt = 0; uint32_t ibyte = 0;
    // the transmitter: sample the line in the middle of each bit
    int ts = -1, tcnt = 0, tbyte = 0, last = 1;
    uint64_t clocks = 0; unsigned chars = 0;
    uint64_t halted_at = 0;
    int credit = 96;                                             // CREDIT=1: type only what the board has asked for (ENQ gives 32 more)
    while (clocks < max && !(halted_at && clocks > halted_at + 40ULL * 10 * div)) {      // after the halt, long enough for the UART to finish
        if ((top->led & 2) && !halted_at) halted_at = clocks;
        top->clk = 0; top->eval(); top->clk = 1; top->eval(); clocks++;
        // the flash slave
        {
            int cs_n = top->spi_cs_n, sck = top->spi_clk, mosi = top->spi_mosi;
            if (cs_n) { f_bits = 0; f_cmd = 0; f_addr = 0; f_miso = 1; }
            else {
                if (sck && !f_prev_clk) {                                // rising edge: the master's bit, in
                    if (f_bits < 8) { f_cmd = (f_cmd << 1) | mosi; if (f_bits == 7) f_cmd_seen[f_cmd & 255]++; }
                    else if (f_bits < 32) f_addr = (f_addr << 1) | mosi;
                    f_bits++;
                }
                if (!sck && f_prev_clk && f_bits >= 32 && f_cmd == 0x03) {  // falling edge in the data phase: the next bit, out
                    uint32_t bit = f_bits - 32, a = f_addr + bit / 8;
                    int byte = (a >= flash_base && a - flash_base < flash.size()) ? (unsigned char)flash[a - flash_base] : 0xFF;
                    f_miso = (byte >> (7 - bit % 8)) & 1;
                    if (bit % 8 == 7) f_bytes++;
                }
            }
            f_prev_clk = sck;
            top->spi_miso = f_miso;
        }
        if (clocks < 100) continue;
        // typing
        if (ibit < 0) { if (ib < ni && clocks > 40000 && (!getenv("CREDIT") || credit > 0)) { ibyte = (unsigned char)input[ib++]; credit--; ibit = 0; icnt = div; top->uart_rx_in = 0; } }
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
            else { if (tbyte == 5) credit += 32; else { putchar(tbyte); fflush(stdout); } chars++; ts = -1; }
        }
        if (getenv("TX_EDGES") && tx != last) fprintf(stderr, "%llu:%d ", (unsigned long long)clocks, tx);
        last = tx;
    }
    fprintf(stderr, "\n[flash: reset %d%d, read %d, %u bytes]", f_cmd_seen[0x66], f_cmd_seen[0x99], f_cmd_seen[0x03], f_bytes);
    fprintf(stderr, "\n[%llu clocks, %u characters, %s, led=%02x]\n", (unsigned long long)clocks, chars, (top->led & 2) ? "halted" : "still running", (unsigned)top->led);
    delete top;
    return 0;
}
