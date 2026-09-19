#!/bin/bash
# run.sh : simulate ethmin_vm_core with its real DMA on canned frames (after
# tools/progimage.sh io/ethmin.ml fpga/vc707-ethmin), then check the replies.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PROJ=$REPO/fpga/vc707-ethmin
ETH=${XC7BT:-$HOME/xc7-bitstream-tools}/examples/vc707-ethmin/rtl
OBJ=${OBJ:-$HOME/bytecode-work/vc707-ethmin-sim-obj}
cd "$PROJ"
verilator --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-style --top-module ethmin_vm_core \
  -I"$REPO" -I"$PROJ" -CFLAGS -I"$REPO" -Mdir "$OBJ" \
  "$REPO/ocaml4142_vm_rtl.sv" ethmin_vm_core.v "$ETH/eth_stream_dma.sv" "$ETH/simpleuart.v" \
  "$HERE/tb.cpp" "$REPO/ethmodel.c" > "$OBJ.log" 2>&1 || { tail -20 "$OBJ.log"; exit 1; }
"$OBJ/Vethmin_vm_core" | grep -E '^(eth|uart|tb):' | tee "$OBJ.out"
python3 "$REPO/tools/check_frames.py" "$OBJ.out"
