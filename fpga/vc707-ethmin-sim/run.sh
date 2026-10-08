#!/bin/bash
# run.sh : simulate ethmin_vm_core with its real DMA on canned frames (after
# tools/progimage.sh io/ethmin.ml fpga/vc707-ethmin), then check the replies.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PROJ=$REPO/fpga/vc707-ethmin
ETH=$REPO/fpga/eth-rtl
OBJ=${OBJ:-$HOME/bytecode-work/vc707-ethmin-sim-obj}
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
verilator --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-style --top-module ethmin_vm_core \
  -I"$REPO" -I"$PROJ" -I"$REPO/fpga/sd-lowrisc" -CFLAGS -I"$REPO" -Mdir "$OBJ" \
  "$REPO/ocaml4142_vm_rtl.sv" "$OBJ.rom.v" "$HERE/unisim_sd_stubs.v" "$REPO/fpga/sd-lowrisc/sd_top.sv" "$REPO/fpga/sd-lowrisc/sd_data_serial_host.sv" "$REPO/fpga/sd-lowrisc/sd_cmd_serial_host.v" "$REPO/fpga/sd-lowrisc/sd_crc_7.v" "$REPO/fpga/sd-lowrisc/sd_crc_16.v" "$REPO/fpga/sd-lowrisc/sd_clock_divider.v" sd_wrap.v vm_trace.v ethmin_vm_core.v "$REPO/fpga/fpu-rtl/fpu_hardfloat.v" "$REPO/fpga/fpu-rtl/recode64.v" "$REPO/fpga/fpu-rtl/hardfloat.v" "$ETH/eth_stream_dma.sv" "$ETH/simpleuart.v" \
  "$HERE/tb.cpp" "$REPO/ethmodel.c" > "$OBJ.log" 2>&1 || { tail -20 "$OBJ.log"; exit 1; }
"$OBJ/Vethmin_vm_core" | grep -E '^(eth|uart|tb):' | tee "$OBJ.out"
python3 "$REPO/tools/check_frames.py" "$OBJ.out"
