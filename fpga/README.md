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
from xc7-bitstream-tools' `examples/vc707-ethmin`.

- `vc707-sim/run.sh`: Verilator simulation of the whole harness with
  pass-through stand-ins for the clocking primitives, decoding the UART.
- `vc707-vivado/build.tcl`: a Vivado build of the same harness from the VM's
  original SystemVerilog, for Vivado's warnings and as a reference bitstream.

## Status

The Vivado bitstream runs on the board and matches simulation exactly
(`cycles=0000067d` for fact).  The apio/nextpnr bitstream does not: it prints
nothing and ends `PC!!`.  yosys's synthesis is not at fault (gate-level
simulation of its netlist with the unisim BRAM models halts correctly), and
every FASM feature resolves in prjxray-db, so the fault lies in nextpnr's
placement, routing or BRAM configuration.  The narrow RAMB36 modes this design
uses (x1 for the stack and heap, x9 for globals) are the prime suspect.

nextpnr also cannot place memories deep enough for yosys to build cascaded
RAMB36 pairs, which is why the harness sets `STACK_AW`/`HEAP_AW` to 15.
