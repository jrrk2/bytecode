# lowRISC SD host controller (vendored, unmodified)

`sd_top.sv`, `sd_cmd_serial_host.v`, `sd_data_serial_host.sv`, `sd_crc_7.v`, `sd_crc_16.v`, `sd_clock_divider.v` and
`sd_defines.h`, copied unchanged from `src/main/verilog/` of https://github.com/lowRISC/lowrisc-chip.git
(commit 091fa17).  A native 1/4-bit SD host: command send/response with CRC7, data transfer with CRC16, no DMA.  The
processor sets the command registers, starts it, and moves each 512-byte block through a 4 KB dual-port buffer.

The files carry their own notices: an Xilinx header (the controller derives from Xilinx's SDIO host reference) and the
ETH Zurich / University of Bologna Solderpad Hardware License v0.51.  Keep them as they are.

Glue, written for this machine: `../vc707-ethmin/sd_wrap.v` (register file after lowRISC's `periph_soc.sv`, the data
buffer, the pads and the clock).  The register meanings come from the Linux driver in the same project
(`drivers/mmc/host/lowrisc_sd.c`; the cva6-sdk patch `0001-Incorporate-lowrisc-drivers-for-latest-kernel-releas.patch`).
The CVA6 bootrom `sd.c` is SPI mode, 1 bit, and does not use this controller.
