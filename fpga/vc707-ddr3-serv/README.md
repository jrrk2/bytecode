# vc707-ddr3-serv: 1 GB of DDR3, calibrated by a SERV, as a bigger RAM disk for the bytecode machine

The bytecode machine's RAM disk is 512 KiB of block RAM (`ethmin_vm_core.v`, `DISK_WORDS`).  The VC707 has a 1 GB
DDR3 SODIMM (MT8JTF12864, 64 bits).  This sub-project brings it up and makes it the RAM disk.

## The pieces

1. **DDR3 controller and PHY**: LiteDRAM's 7-series PHY (`s7ddrphy.V7DDRPHY`, 4:1, 100 MHz system clock) as
   `xc7-bitstream-tools/examples/vc707-litex` already instantiates it.
2. **The calibrator**: a SERV (bit-serial RV32I, about 200 LUTs) running LiteX's BIOS from block RAM.  The PHY
   leaves the training (write levelling, read levelling, bitslip, delay taps) to software; SERV's slowness
   does not matter, calibration happens once.
3. **The RAM disk device** (phase 2): a master on the SoC bus that the bytecode machine's I/O space reaches.  It
   turns the byte-at-a-time disk window (0x100000..) into DDR accesses, through a small write-back cache so a
   run of bytes costs one burst.
4. **The bytecode machine as a LiteX module** (phase 3), the way `hp2000/litex/hp2000.py` adds the HP 2000
   machine: its disk port becomes a Wishbone master onto the DDR3.

## Phases

| | goal | done when |
| --- | --- | --- |
| 0 | SERV + DDR3 SoC builds and calibrates | the BIOS prints `Memtest OK` for the 1 GB region over the UART |
| 1 | the DDR as one flat byte-addressed region for a hardware master | a Verilog test master writes and reads back patterns across the whole 1 GB through the crossbar |
| 2 | RAM disk device with the cache | the VM's disk window reads and writes DDR; RFS on it |
| 3 | one bitstream: VM + SERV + DDR3 | `#image` of the compiler on a 1 GB disk |

## Status

**Phase 0 done (2026-10-07):** the SERV SoC built with Vivado (WNS +0.82 ns at 100 MHz), loaded over JTAG, and the
BIOS on the SERV calibrated the 1 GiB SODIMM (`1.0GiB 64-bit @ 800MT/s (CL-6 CWL-5)`): write levelling, write
latency, write DQ-DQS training, read levelling per lane, then `Memtest OK` over 2 MiB and `Write speed: 3.7MiB/s`
(SERV is slow; calibration takes a couple of minutes and the memtest the rest, all in the background of the
boot).  Console log is in the build's serial capture; the BIOS prompt follows.

## Build

    make gateware        # Vivado, SERV + DDR3 1 GB (about 40 minutes)
    make load            # JTAG, volatile (openFPGALoader)
    make term            # the BIOS console

The generator is the template's (`vc707_litex.py`, `--cpu-type serv --with-ddr --with-ddr64`).  The BIOS runs
`sdram_init` at boot and prints the calibration result for each byte lane.

## Things to carry over to the bytecode side

* The RFS directory stores offsets in 24 bits (`d32` in `io/comp.ml` reads three bytes: a 32-bit word with its top
  bit set does not fit a 31-bit OCaml int).  For 1 GB the offsets need 30 bits: read four bytes, the top one
  below 0x40.
* The disk size register (0x100d) is a byte count: 2^30 fits.
* The disk is lost at power-off unless the SERV or an SD card (the HP 2000 project already has one) saves it.
