#!/bin/bash
# run_netboot.sh [program.ml] : simulate netboot end to end -- the resident
# loader (io/netboot.ml) in ethmin_vm_core leases an address, fetches
# program.ml's image (default ../../hellofor.ml) by TFTP from ethmodel, and
# boots it; the booted program's output appears on the UART.  A .bc is served as it is, for
# the loader to strip; $DISK_IMG (an RFS disk image, tools/mkdisk.py) is served as disk.img for the RAM disk; $TB_UART_INPUT is typed at the UART once the booted program has spoken.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PROJ=$REPO/fpga/vc707-ethmin
ETH=$REPO/fpga/eth-rtl
OBJ=${OBJ:-$HOME/bytecode-work/vc707-netboot-sim-obj}
PAYLOAD=$(realpath -m "${1:-$REPO/hellofor.ml}")
WORK=${WORK:-$HOME/bytecode-work/netboot}
"$REPO/tools/progimage.sh" "$REPO/io/netboot.ml" "$PROJ" > /dev/null
mkdir -p "$WORK"
case "$PAYLOAD" in
*.bc)   # a bytecode executable as ocamlc wrote it: the loader strips it itself
  cp "$PAYLOAD" "$WORK/payload.img" ;;
*)
  "$REPO/tools/progimage.sh" "$PAYLOAD" "$WORK/payload" > /dev/null
  "$REPO/tools/mkvmimage.py" "$WORK/payload" "$WORK/payload.img" ;;
esac
# the code ROM as the simulator sees it: the board's is x1 block RAMs (program_bram.v), a behavioural one reads the same program.hex
cat > "$OBJ.rom.v" <<ROM
module code_rom_bram (input wire clk, input wire en, input wire [14:0] addr, output reg [31:0] dout);
	reg [31:0] mem [0:32767];
	initial \$readmemh("$PROJ/program.hex", mem);
	always @(posedge clk) if (en) dout <= mem[addr];
endmodule
module data_rom_bram (input wire clk, input wire en, input wire [14:0] addr, output reg [31:0] dout);
	reg [31:0] mem [0:32767];
	initial \$readmemh("$PROJ/data.hex", mem);
	always @(posedge clk) if (en) dout <= mem[addr];
endmodule
ROM
cd "$PROJ"
verilator --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-style --top-module ethmin_vm_core ${TRACE_LOG2:+-GTRACE_LOG2=$TRACE_LOG2} \
  -I"$REPO" -I"$PROJ" -CFLAGS -I"$REPO" -Mdir "$OBJ" \
  "$REPO/ocaml4142_vm_rtl.sv" "$OBJ.rom.v" vm_trace.v ethmin_vm_core.v "$REPO/fpga/fpu-rtl/fpu_hardfloat.v" "$REPO/fpga/fpu-rtl/recode64.v" "$REPO/fpga/fpu-rtl/hardfloat.v" "$ETH/eth_stream_dma.sv" "$ETH/simpleuart.v" \
  "$HERE/tb_netboot.cpp" "$REPO/ethmodel.c" > "$OBJ.log" 2>&1 || { tail -20 "$OBJ.log"; exit 1; }
ETHMODEL_TFTP_DISK=$DISK_IMG ETHMODEL_TFTP_FILE=$WORK/payload.img ETHMODEL_FAST_DHCP=1 "$OBJ/Vethmin_vm_core" "${SECONDS_LIMIT:-2}" \
  | grep -E '^(eth|uart|tb):'
