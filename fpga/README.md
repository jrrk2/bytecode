# The VM on the VC707

`vc707/` is an apio project (VC707 board, himbaechel/openXC7 flow) that runs
one OCaml program on `ocaml4142_vm_rtl` and prints on the USB UART
(115200 8N1):

    == OCaml bytecode VM on VC707 ==
    00120
    == halt pc=000000df accu=00000001 cycles=0000067d ==

The first and last lines come from the harness (`vc707_vm_top.v`), not the
program: a banner, then pc, accu and the cycle count when the VM halts.  If
the pc leaves the program, the report begins `PC!!` instead of `halt`.
CPU_RESET runs the program again.

LEDs: 0 heartbeat, 1 MMCM locked, 2 running, 3 halted, 4 pc out of range,
5 output FIFO overflowed, 6 output pending, 7 CPU_RESET held.

The VM runs at 25 MHz (MMCM from the 200 MHz system clock) with 32K-word
stack and heap.

## Build

    cd vc707
    ./gen.sh ../../hellofor.ml      # default ../../fact.ml; needs sv2v and ocamlc
    apio build && apio upload

`gen.sh` writes the VM as Verilog-2005 (`vm_sv2v.v`, via sv2v), the program's
code (`program.hex`) and its constants (`heap.hex`, `globals.hex`, from
`tools/bc2image`).  Intermediate files go to `$GEN` (default
`~/bytecode-work/vc707-gen`) because apio compiles every `.v`/`.sv` under the
project.  The UART is picosoc's `simpleuart.v` (ISC licence, header kept),
kept in `eth-rtl/` with the rest of the borrowed RTL.

- `vc707-sim/run.sh`: Verilator simulation of the whole harness with
  pass-through stand-ins for the clocking primitives, decoding the UART.
- `vc707-vivado/build.tcl`: a Vivado build of the same harness from the VM's
  original SystemVerilog, for Vivado's warnings and as a reference bitstream.

## Status

The Vivado bitstream runs on the board and matches simulation exactly
(`cycles=0000067d` for fact).  The apio/nextpnr one used to print nothing and
end `PC!!`: nextpnr's FASM left out the RAMB36-level width bits
(`RAMB36.BRAM36_{READ,WRITE}_WIDTH_{A,B}_1`) that join the two halves into one
32K x 1 memory, which this design's stack and heap need.  With that fixed
(openXC7 nextpnr branch `xilinx-ramb36-x1-width`) its bitstream runs fact
correctly on the board.

nextpnr also cannot place memories deep enough for yosys to build cascaded
RAMB36 pairs, which is why the harness sets `STACK_AW`/`HEAP_AW` to 15.

# Ethernet: `vc707-ethmin/`

The VC707 ethmin design (clocking, LiteEth's SGMII PCS/PMA on the GTX, the
1G MAC and the DMA, no Xilinx IP) with the VM in place of picorv32.  Those
parts are in `eth-rtl/`, copied from xc7-bitstream-tools so this repository
builds on its own; see `eth-rtl/README.md` for each file's origin.  Only the
open flow's tools stay external.  `ethmin_vm_core.v` holds the VM, a packet
RAM shared with the DMA, a staging RAM, the program code RAM and the boot
sequencer, and answers the VM's `vm_io_read`/`vm_io_write` with this I/O
space (the one `ethmodel.c` simulates):

| address | |
|---|---|
| 0x0000–0x07FF | RX window, a byte per address |
| 0x0800–0x0FFF | TX window |
| 0x1000 | r: rx valid, tx busy, rx truncated |
| 0x1001 | r: PHY status |
| 0x1002 | r: received length; w: release the RX window |
| 0x1003 | w: send the TX window |
| 0x1004 | LEDs |
| 0x1005 | w: UART byte (a FIFO, shared with `caml_ml_output_char`) |
| 0x1006 | r: milliseconds since reset |
| 0x1007 | w: boot the staged image |
| 0x10000–0x1FFFF | staging RAM (64 KiB) |

The resident program, run after every reset (CPU_RESET works; see the note
in `vc707_ethmin_vm.v`), is one of:

- `io/ethmin.ml`: ARP and ping at 192.168.1.42 (MAC …:31)
- `io/dhcp.ml`: the same, with the address leased by DHCP (MAC …:32)
- `io/netboot.ml`: a loader (MAC …:33).  It leases an address by DHCP,
  fetches `vm.img` by TFTP (from the DHCP reply's `siaddr`/`file`, else
  192.168.1.106 port 6969), checks it (magic, sizes, the primitive-table
  digest, CRC-16) and writes BOOT: the sequencer loads the image's code into
  the code RAM and its heap and globals into the VM, and starts it.  The
  next reset brings the loader back.

## Build and boot

    tools/progimage.sh io/netboot.ml fpga/vc707-ethmin     # the resident program
    cd <work dir>; vivado -mode batch -source <repo>/fpga/vc707-ethmin/build.tcl

A program to boot is packed by `tools/mkvmimage.py` and served per MAC by
xc7-bitstream-tools' `scripts/tftp_serve.py`:

    tools/progimage.sh fact.ml build/fact
    tools/mkvmimage.py build/fact ~/tftp-vc707/02:00:00:4d:47:33/vm.img

`io/repl.ml`, a small ML read-eval-print loop on the UART and on UDP port
7777, is the usual program to boot; `tools/vmcat.py` talks to it a line at a
time.

The core's memories are much smaller than the regression's defaults (heap
2^14 words, stack 2^13), and the heap's semi-spaces reach the top of the
address space, so the garbage collector runs in a corner the default model
never reaches.  `HEAP_AW=14 tools/regress.sh heap14` runs the whole regression
there.

`open_build.sh` builds the same design with the open flow (sv2v, yosys,
openXC7's nextpnr, prjxray) using `vc707_ethmin_vm_open.xdc`, whose
hand-placed clocking that flow needs.  It produces a bitstream; on the board
the frames come out corrupt, from three 0.05 ns hold violations on the packet
RAM that `-o hold-fix` does not yet repair.  Vivado's build is the one to
flash.

Simulation: `vc707-ethmin-sim/run.sh` runs the core with ethmin on canned
frames; `vc707-ethmin-sim/run_netboot.sh [prog.ml]` runs the loader against
`ethmodel`'s DHCP server, ARP and TFTP host, and shows the booted program's
output ($TB_UART_INPUT is typed at it, $TB_QUIET_MS is how long a silence ends
the run).  The Vivado build is used for the board; nextpnr's has the fault
described above.
