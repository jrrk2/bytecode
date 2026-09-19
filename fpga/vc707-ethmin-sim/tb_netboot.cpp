// Netboot, end to end: ethmin_vm_core running the resident loader
// (io/netboot.ml) against ethmodel's network -- DHCP server, ARP, TFTP host
// -- at the MAC streams.  Frames the core sends go to the model; the model's
// replies are fed in whenever the DMA's RX window is free.  Prints the TX
// frames and UART lines; stops once the booted program has printed a line
// after "starting it", or at the time limit.
#include "Vethmin_vm_core.h"
#include "Vethmin_vm_core___024root.h"
#include "verilated.h"
#include "ethmodel.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static Vethmin_vm_core *top;
static uint64_t ticks;           // 4 ns: eth_clk 125 MHz, clk_sys 25 MHz
static std::string uart_line;
static int uart_state = -1, uart_cnt, uart_byte, uart_last = 1, lines_after_boot = -1;
static unsigned char tx_buf[2048];
static int tx_len;

static void sys_edge() {
  const int bit = 25000000 / 115200;
  int tx = top->UART_TX;
  if (uart_state < 0) {
    if (uart_last && !tx) { uart_state = 0; uart_cnt = bit + bit / 2; uart_byte = 0; }
  } else if (--uart_cnt == 0) {
    if (uart_state < 8) { uart_byte |= tx << uart_state++; uart_cnt = bit; }
    else {
      if (uart_byte == '\n') {
        printf("uart: %s\n", uart_line.c_str());
        if (lines_after_boot >= 0) lines_after_boot++;
        if (uart_line.find("starting it") != std::string::npos) lines_after_boot = 0;
        uart_line.clear();
      } else uart_line += (char)uart_byte;
      fflush(stdout);
      uart_state = -1;
    }
  }
  uart_last = tx;
}

static void eth_edge() {
  if (top->tx_axis_tvalid && top->tx_axis_tready) {
    if (tx_len < (int)sizeof tx_buf) tx_buf[tx_len++] = top->tx_axis_tdata;
    if (top->tx_axis_tlast) {
      printf("eth: TX %d", tx_len);
      for (int i = 0; i < tx_len && i < 48; i++) printf(" %02x", tx_buf[i]);
      printf("%s\n", tx_len > 48 ? " ..." : "");
      ethmodel_tx_frame(tx_buf, tx_len);
      tx_len = 0;
    }
  }
}

static void step() {
  ticks++;
  bool eth_rise = (ticks % 2) == 0, sys_rise = (ticks % 10) == 0;
  top->eth_clk = eth_rise ? 1 : 0;
  top->clk_sys = ((ticks % 10) < 5) ? 0 : 1;
  if (sys_rise) top->clk_sys = 1;
  top->eval();
  if (eth_rise) eth_edge();
  if (sys_rise) sys_edge();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vethmin_vm_core;
  top->tx_axis_tready = 1;
  top->pcspma_status = 0x0303;
  top->UART_RX = 1;
  top->resetn = 0; top->eth_rst = 1;
  for (int i = 0; i < 200; i++) step();
  top->resetn = 1; top->eth_rst = 0;

  unsigned char rx[2048];
  int rx_n = 0, rx_i = 0;          // a frame being fed, byte rx_i of rx_n
  int wait_taken = 0;              // fed: wait for rx_valid to rise, then fall
  bool last_rx_valid = false;
  uint64_t released_at = 0;
  uint64_t limit = (uint64_t)((argc > 1 ? atof(argv[1]) : 2.0) * 250e6);   // seconds, in 4 ns steps
  while (ticks < limit && lines_after_boot < 1) {
    bool rx_valid = top->rootp->ethmin_vm_core__DOT__rx_valid;
    if (rx_n == 0 && ticks % 2 == 1) {          // between eth_clk edges
      if (wait_taken == 1 && rx_valid) wait_taken = 2;
      else if (wait_taken == 2 && !rx_valid) { wait_taken = 3; released_at = ticks; }
      // the release crosses to eth_clk through a synchroniser: a frame fed
      // the instant rx_valid falls is dropped, so leave a gap, as a network would
      else if (wait_taken == 3 && ticks - released_at > 2000) wait_taken = 0;
      if (getenv("TB_DEBUG") && rx_valid != last_rx_valid) printf("tb: %.3f ms rx_valid %d\n", ticks * 4e-6, rx_valid);
      last_rx_valid = rx_valid;
      if (wait_taken == 0 && !rx_valid && (rx_n = ethmodel_rx_frame(rx)) > 0) {
        rx_i = 0;
        if (getenv("TB_DEBUG")) printf("tb: %.3f ms feed %d bytes\n", ticks * 4e-6, rx_n);
      }
    }
    if (rx_n > 0 && ticks % 2 == 1) {           // one byte per eth_clk rising edge
      top->rx_axis_tdata = rx[rx_i]; top->rx_axis_tvalid = 1;
      top->rx_axis_tlast = rx_i == rx_n - 1; top->rx_axis_tuser = 0;
      if (++rx_i == rx_n) { rx_n = 0; wait_taken = 1; }
    } else if (ticks % 2 == 1) {
      top->rx_axis_tvalid = 0; top->rx_axis_tlast = 0;
    }
    step();
    if (getenv("TB_DEBUG") && lines_after_boot >= 0 && ticks % 250000 == 0)   // every ms after boot
      printf("tb: %.0f ms seq_state %d code_bank %d pc %d prog_words %d\n", ticks * 4e-6,
             top->rootp->ethmin_vm_core__DOT__seq_state, top->rootp->ethmin_vm_core__DOT__code_bank,
             top->rootp->ethmin_vm_core__DOT__pc, top->rootp->ethmin_vm_core__DOT__prog_words);
  }
  printf("tb: stopped at %.1f ms%s\n", ticks * 4e-6, lines_after_boot >= 1 ? "" : " (time limit)");
  delete top;
  return lines_after_boot >= 1 ? 0 : 1;
}
