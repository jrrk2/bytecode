// Runs vc707_vm_top with its clock at the 25 MHz VM clock and decodes the UART.
#include "Vvc707_vm_top.h"
#include "verilated.h"
#include <cstdio>
#include <string>
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vvc707_vm_top;
  const int bit = 25000000 / 115200;  // BAUD_DIV
  std::string out;
  int last_tx = 1, rx_state = -1, rx_cnt = 0, rx_byte = 0, reports = 0;
  uint64_t cyc = 0, quiet_since = 0;
  top->cpu_reset = 0;
  for (; cyc < 400000000ULL; cyc++) {
    top->clk200_p = 0; top->clk200_n = 1; top->eval();
    top->clk200_p = 1; top->clk200_n = 0; top->eval();
    int tx = top->serial_tx;
    if (rx_state < 0) {
      if (last_tx && !tx) { rx_state = 0; rx_cnt = bit + bit / 2; rx_byte = 0; }
    } else if (--rx_cnt == 0) {
      if (rx_state < 8) { rx_byte |= tx << rx_state; rx_state++; rx_cnt = bit; }
      else {
        if (!tx) printf("[framing error]\n");
        out += (char)rx_byte; putchar(rx_byte); fflush(stdout);
        rx_state = -1; quiet_since = cyc;
        if (out.size() >= 4 && out.compare(out.size() - 4, 4, "==\r\n") == 0) reports++;
      }
    }
    last_tx = tx;
    // banner + report seen, and the line has been idle for 20 characters
    if (reports >= 2 && cyc - quiet_since > 20 * 11 * bit) break;
  }
  printf("\n[tb: %llu cycles, leds=0x%02x]\n", (unsigned long long)cyc, top->leds);
  delete top;
  return 0;
}
