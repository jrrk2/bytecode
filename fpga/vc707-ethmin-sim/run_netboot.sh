#!/bin/bash
# run_netboot.sh [program.ml] : simulate netboot end to end -- the resident
# loader (io/netboot.ml) in ethmin_vm_core leases an address, fetches
# program.ml's image (default ../../hellofor.ml) by TFTP from ethmodel, and
# boots it; the booted program's output appears on the UART.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PROJ=$REPO/fpga/vc707-ethmin
ETH=$REPO/fpga/eth-rtl
OBJ=${OBJ:-$HOME/bytecode-work/vc707-netboot-sim-obj}
PAYLOAD=$(realpath -m "${1:-$REPO/hellofor.ml}")
WORK=${WORK:-$HOME/bytecode-work/netboot}
"$REPO/tools/progimage.sh" "$REPO/io/netboot.ml" "$PROJ" > /dev/null
"$REPO/tools/progimage.sh" "$PAYLOAD" "$WORK/payload" > /dev/null
"$REPO/tools/mkvmimage.py" "$WORK/payload" "$WORK/payload.img"
cd "$PROJ"
verilator --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-style --top-module ethmin_vm_core \
  -I"$REPO" -I"$PROJ" -CFLAGS -I"$REPO" -Mdir "$OBJ" \
  "$REPO/ocaml4142_vm_rtl.sv" ethmin_vm_core.v "$ETH/eth_stream_dma.sv" "$ETH/simpleuart.v" \
  "$HERE/tb_netboot.cpp" "$REPO/ethmodel.c" > "$OBJ.log" 2>&1 || { tail -20 "$OBJ.log"; exit 1; }
ETHMODEL_TFTP_FILE=$WORK/payload.img ETHMODEL_FAST_DHCP=1 "$OBJ/Vethmin_vm_core" "${SECONDS_LIMIT:-2}" \
  | grep -E '^(eth|uart|tb):'
