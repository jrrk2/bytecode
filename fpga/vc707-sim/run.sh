#!/bin/bash
# run.sh : simulate the VC707 harness (../vc707, after its gen.sh) in Verilator,
# with pass-through stand-ins for IBUFDS/MMCME2_ADV/BUFG, decoding the UART.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PROJ=$HERE/../vc707
OBJ=${OBJ:-$HOME/bytecode-work/vc707-sim-obj}
cd "$PROJ"
verilator --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-style --top-module vc707_vm_top \
  -Mdir "$OBJ" "$HERE/xilinx_stubs.v" vm_sv2v.v simpleuart.v vc707_vm_top.v "$HERE/tb.cpp" > "$OBJ.log" 2>&1 \
  || { tail -20 "$OBJ.log"; exit 1; }
# run in the project directory: $readmemh finds program.hex, heap.hex, globals.hex there
"$OBJ/Vvc707_vm_top" | grep -vE '^( |Fetch |caml_|CLOSURE|MAKEBLOCK|\[)'
