// Drives ethmin_vm_core (the VM, the DMA, the packet RAM and the I/O space)
// on its MAC-side streams with ethmodel's canned frames, one at a time, and
// prints what comes back: "eth: TX <len> <bytes>" for each frame sent (for
// tools/check_frames.py) and the UART output.
#include "Vethmin_vm_core.h"
#include "verilated.h"
#include "ethmodel.h"
#include <cstdio>
#include <string>

static Vethmin_vm_core *top;
static uint64_t ticks;           // 4 ns: eth_clk 125 MHz, clk_sys 25 MHz
static std::string uart_line;
static int uart_state = -1, uart_cnt, uart_byte, uart_last = 1;
static std::string tx_frame;

static void sys_edge_checks() {  // at each clk_sys rising edge
  const int bit = 25000000 / 115200;
  int tx = top->UART_TX;
  if (uart_state < 0) {
    if (uart_last && !tx) { uart_state = 0; uart_cnt = bit + bit / 2; uart_byte = 0; }
  } else if (--uart_cnt == 0) {
    if (uart_state < 8) { uart_byte |= tx << uart_state++; uart_cnt = bit; }
    else {
      if (uart_byte == '\n') { printf("uart: %s\n", uart_line.c_str()); uart_line.clear(); }
      else uart_line += (char)uart_byte;
      uart_state = -1;
    }
  }
  uart_last = tx;
}

static void eth_edge_checks() {  // at each eth_clk rising edge
  if (top->tx_axis_tvalid && top->tx_axis_tready) {
    char b[4]; snprintf(b, sizeof b, " %02x", top->tx_axis_tdata); tx_frame += b;
    if (top->tx_axis_tlast) {
      printf("eth: TX %zu%s\n", tx_frame.size() / 3, tx_frame.c_str());
      tx_frame.clear();
    }
  }
}

// One 4 ns step: eth_clk toggles every step, clk_sys every 5.
static void step() {
  ticks++;
  bool eth_rise = (ticks % 2) == 0, sys_rise = (ticks % 10) == 0;
  top->eth_clk = eth_rise ? 1 : 0;
  top->clk_sys = ((ticks % 10) < 5) ? 0 : 1;
  if (sys_rise) top->clk_sys = 1;
  top->eval();
  if (eth_rise) eth_edge_checks();
  if (sys_rise) sys_edge_checks();
}

static void run_sys_cycles(uint64_t n) { for (uint64_t i = 0; i < n * 10; i++) step(); }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vethmin_vm_core;
  top->tx_axis_tready = 1;
  top->pcspma_status = 0x0303;
  top->UART_RX = 1;
  top->resetn = 0; top->eth_rst = 1;
  run_sys_cycles(20);
  top->resetn = 1; top->eth_rst = 0;

  unsigned char buf[2048];
  for (int f = 0;; f++) {
    // wait for the program to be polling: LEDs 1 after start-up, then
    // 2 | count << 2 after each frame
    int want = f == 0 ? 0x01 : (2 | (f << 2));
    uint64_t waited = 0;
    while (top->LED != want && waited < 3000000) { run_sys_cycles(100); waited += 100; }
    if (top->LED != want) { printf("tb: timeout waiting for LEDs %02x (have %02x)\n", want, top->LED); break; }
    int len = ethmodel_frame(f, buf);
    if (!len) break;
    printf("tb: frame %d (%d bytes) in\n", f, len);
    for (int i = 0; i < len;) {          // one byte per eth_clk rising edge
      top->rx_axis_tdata = buf[i]; top->rx_axis_tvalid = 1; top->rx_axis_tlast = i == len - 1;
      top->rx_axis_tuser = 0;
      step(); step(); i++;
    }
    top->rx_axis_tvalid = 0; top->rx_axis_tlast = 0;
  }
  run_sys_cycles(200000);                // let the last UART output drain
  printf("tb: done at %.3f ms, LEDs %02x\n", ticks * 4e-6, top->LED);
  delete top;
  return 0;
}
