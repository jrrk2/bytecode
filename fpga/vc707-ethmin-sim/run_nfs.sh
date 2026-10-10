#!/bin/bash
# run_nfs.sh image.img : simulate a boot over NFS end to end -- the resident loader (io/netboot.ml) in ethmin_vm_core leases an
# address, is typed "nfs(0,0)vm.img" at its boot prompt, fetches the OCVM image (tools/mkvmimage.py, or one the compiler wrote) from
# ethmodel's NFS server (the directory $WORK/nfsroot) and boots it.  An image longer than the staging RAM goes with its code straight
# into the code RAM.  The booted program's output appears on the UART.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PROJ=$REPO/fpga/vc707-ethmin
ETH=$REPO/fpga/eth-rtl
OBJ=${OBJ:-$HOME/bytecode-work/vc707-nfs-sim-obj}
IMG=$(realpath -m "$1")
WORK=${WORK:-$HOME/bytecode-work/nfsboot}
"$REPO/tools/progimage.sh" "$REPO/io/netboot.ml" "$PROJ" > /dev/null
mkdir -p "$WORK/nfsroot"
cp "$IMG" "$WORK/nfsroot/vm.img"
printf 'nfs(0,0)vm.img\r' > "$WORK/boot.in"
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
  -I"$REPO" -I"$PROJ" -I"$REPO/fpga/sd-lowrisc" -CFLAGS -I"$REPO" -Mdir "$OBJ" \
  "$REPO/ocaml4142_vm_rtl.sv" "$OBJ.rom.v" "$HERE/unisim_sd_stubs.v" "$REPO/fpga/sd-lowrisc/sd_top.sv" "$REPO/fpga/sd-lowrisc/sd_data_serial_host.sv" "$REPO/fpga/sd-lowrisc/sd_cmd_serial_host.v" "$REPO/fpga/sd-lowrisc/sd_crc_7.v" "$REPO/fpga/sd-lowrisc/sd_crc_16.v" "$REPO/fpga/sd-lowrisc/sd_clock_divider.v" sd_wrap.v vm_trace.v tdp_ram32.v ethmin_vm_core.v "$REPO/fpga/fpu-rtl/fpu_hardfloat.v" "$REPO/fpga/fpu-rtl/recode64.v" "$REPO/fpga/fpu-rtl/hardfloat.v" "$ETH/eth_stream_dma.sv" "$ETH/simpleuart.v" \
  "$HERE/tb_netboot.cpp" "$REPO/ethmodel.c" > "$OBJ.log" 2>&1 || { tail -20 "$OBJ.log"; exit 1; }
ETHMODEL_NFS_ROOT=$WORK/nfsroot ETHMODEL_FAST_DHCP=1 TB_BOOT_INPUT=$WORK/boot.in "$OBJ/Vethmin_vm_core" "${SECONDS_LIMIT:-6}" \
  | grep -E '^(uart|tb):|eth: NFS (lookup|create)'
