#!/bin/bash
# open_build.sh : build this design with the open flow (yosys, openXC7's
# nextpnr, prjxray), the same route as xc7-bitstream-tools' "make
# vc707-ethmin" but with the VM in place of picorv32.  Vivado's build.tcl
# stays the reference; this one says whether the open tools can do it.
#
#   tools/progimage.sh io/netboot.ml fpga/vc707-ethmin   # the resident program
#   fpga/vc707-ethmin/open_build.sh                      # -> $OUT (a .bit)
#
# $SYNTH_OPTS passes options to synth_xilinx: "-nodsp" keeps the multiplier
# in fabric, which is how to ask whether the DSP48s are the problem.
#
# $YOSYS_DEFS passes defines to yosys, for a build that differs only by a
# macro: "-DSYS_DIV=13.375 -DCLK_HZ=74766355" builds this design at 74.77 MHz
# instead of 100, which is what the open flow can currently close.
#
# $SKIP_SYNTH=1 keeps the netlist from the last run: when only a nextpnr
# option has changed, synthesis has nothing to redo (it is the slower half).
#
# The VM is SystemVerilog, which yosys does not read, so sv2v converts it
# first.  vc707_ethmin_vm_open.xdc is the constraints for this flow: the same
# board as Vivado's, but placing the clocking primitives by hand, which the
# open flow needs.  --timing-allow-fail is the flow's standing exception
# for this design (see the Makefile), and -o hold-fix repairs the
# min-delay violations it would otherwise let through: the packet RAM's write
# data arrived too fast for the block RAM's hold time, and the frames the VM
# sent came out corrupt (a MAC address of ASCII text).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
XC7BT=${XC7BT:-$HOME/xc7-bitstream-tools}   # the tools only: yosys, nextpnr, prjxray, the venv
ETH=$REPO/fpga/eth-rtl
WORK=${WORK:-$HOME/bytecode-work/vc707-ethmin-open}
OUT=${OUT:-$WORK/vc707_ethmin_vm.bit}
PART=${PART:-xc7vx485tffg1761-2}
TOP=vc707_ethmin_vm
YOSYS=${YOSYS:-$XC7BT/yosys-install/bin/yosys}
NEXTPNR=${NEXTPNR:-$XC7BT/build/nextpnr-himbaechel}   # the Makefile's NEXTPNR_BUILD, with the xc7vx485t chipdb
# the working copy has the LIOB18 STEPDOWN fix (bit-free there); the copy under .deps is older and collides with INT_L PIPs
PRJXRAY_DB=${PRJXRAY_DB:-$( [ -d "$HOME/prjxray/database/virtex7" ] && echo "$HOME/prjxray/database" || echo "$XC7BT/.deps/prjxray-db")}
PYTHON=${PYTHON:-$XC7BT/.venv/bin/python}   # the flow's venv: fasm, and what convert.py imports
mkdir -p "$WORK"

# yosys and $readmemh both resolve paths against the working directory, and
# the program images live beside the RTL, so build from a copy of this
# directory with the converted VM added.
cp "$HERE"/*.v "$HERE"/*.vh "$HERE"/*.hex "$WORK/"
"${SV2V:-sv2v}" -DSYNTHESIS -I"$REPO" "$REPO/ocaml4142_vm_rtl.sv" > "$WORK/vm_sv2v.v"

# Who built this bitstream, for the banner: the commit, a dirty bit, and the
# flow (bits 30:29, 1 = this one; bit 31 would be past the processor's
# 31-bit int and could not be printed).  0x100a reads it back.
commit=$(git -C "$REPO" rev-parse --short=7 HEAD 2>/dev/null || echo 0000000)
dirty=0; git -C "$REPO" diff --quiet HEAD -- 2>/dev/null || dirty=1
build_id="32'h$(printf '%x' $(( (1 << 29) | (dirty << 28) | 0x$commit )))"
YOSYS_DEFS="${YOSYS_DEFS:-} -DBUILD_ID=$build_id"
echo "== build id $build_id (commit $commit, dirty $dirty, open flow)"

FPU=$REPO/fpga/fpu-rtl
SDL=$REPO/fpga/sd-lowrisc
SRCS="vm_sv2v.v program_bram.v data_bram.v vm_trace.v tdp_ram32.v ethmin_vm_core.v vc707_ethmin_vm.v sd_wrap.v \
  $SDL/sd_top.sv $SDL/sd_data_serial_host.sv $SDL/sd_cmd_serial_host.v $SDL/sd_crc_7.v $SDL/sd_crc_16.v $SDL/sd_clock_divider.v \
  $FPU/fpu_hardfloat.v $FPU/recode64.v $FPU/hardfloat.v \
  $ETH/simpleuart.v $ETH/liteeth_sgmii_phy.v $ETH/eth_mac_1g.sv \
  $ETH/axis_gmii_rx.sv $ETH/axis_gmii_tx.sv $ETH/rgmii_lfsr.sv \
  $ETH/eth_lutram_fifo.sv $ETH/eth_stream_dma.sv $ETH/eth_gmii_retime256.sv \
  $ETH/eth_pkt_buf256.sv $ETH/sgmii_soc_liteeth.sv $ETH/clkgen_vc707.sv"

cd "$WORK"
if [ -n "${SKIP_SYNTH:-}" ] && [ -s "$TOP.json" ]; then
    echo "== yosys (skipped, keeping $TOP.json)"
else
    echo "== yosys"
    "$YOSYS" -q -l yosys.log -p \
      "read_verilog -sv -I. -I$SDL ${YOSYS_DEFS:-} $SRCS; synth_xilinx -flatten -abc9 -arch xc7 ${SYNTH_OPTS:-} -top $TOP; write_json $TOP.json"
fi

echo "== nextpnr"
"$NEXTPNR" --device "$PART" -o xdc="$HERE/vc707_ethmin_vm_open.xdc" \
  --json "$TOP.json" -o fasm="$TOP.fasm" -o placement="${TOP}_placement.json" \
  --router router2 --timing-allow-fail -o hold-fix ${NEXTPNR_FLAGS:-} 2>&1 | tee nextpnr.log | tail -20

echo "== fasm -> bitstream"
"$PYTHON" "$XC7BT/scripts/check_fasm_expressible.py" "$PRJXRAY_DB/virtex7" "$PART" "$TOP.fasm"
"$PYTHON" "$XC7BT/scripts/convert.py" --arch xilinx --family xc7 --part "$PART" \
  --db "$PRJXRAY_DB" --fasm "$TOP.fasm" --output "$OUT"
echo "built $OUT"

# What went into this bitstream, so two builds can be compared without remembering: tool versions (and the compiler yosys was built
# with, and the Eigen nextpnr's placer was built against, both of which change the result), the database, the defines, and the hashes
# of the netlist, FASM and bitstream.
{
  echo "built:      $(date -u +%FT%TZ)"
  echo "repo:       $(git -C "$REPO" rev-parse --short=12 HEAD 2>/dev/null) dirty=$dirty build_id=$build_id"
  echo "defines:    ${YOSYS_DEFS:-}  SYNTH_OPTS=${SYNTH_OPTS:-}  NEXTPNR_FLAGS=${NEXTPNR_FLAGS:-}"
  echo "yosys:      $YOSYS: $("$YOSYS" -V 2>&1 | head -1)"
  echo "sv2v:       $(command -v "${SV2V:-sv2v}"): $("${SV2V:-sv2v}" --version 2>&1 | head -1)"
  nb=$(dirname "$NEXTPNR")
  echo "nextpnr:    $NEXTPNR sha256=$(sha256sum "$NEXTPNR" | cut -c1-16)"
  echo "  source:   $(grep -m1 CMAKE_HOME_DIRECTORY "$nb/CMakeCache.txt" 2>/dev/null | cut -d= -f2) @ $(git -C "$(grep -m1 CMAKE_HOME_DIRECTORY "$nb/CMakeCache.txt" 2>/dev/null | cut -d= -f2)" rev-parse --short=8 HEAD 2>/dev/null)"
  ed=$(grep -m1 '^Eigen3_DIR' "$nb/CMakeCache.txt" 2>/dev/null | cut -d= -f2)
  echo "  eigen:    $ed version $(grep -h 'set(PACKAGE_VERSION ' "$ed/Eigen3ConfigVersion.cmake" 2>/dev/null | head -1 | cut -d'"' -f2)"
  echo "  chipdb:   $(grep -m1 HIMBAECHEL_PRJXRAY_DB "$nb/CMakeCache.txt" 2>/dev/null | cut -d= -f2)"
  echo "database:   $PRJXRAY_DB/virtex7 @ $(git -C "$PRJXRAY_DB/virtex7" rev-parse --short=8 HEAD 2>/dev/null)"
  echo "netlist:    sha256=$(sha256sum "$TOP.json" | cut -c1-16)"
  echo "fasm:       sha256=$(sha256sum "$TOP.fasm" | cut -c1-16)"
  echo "bitstream:  sha256=$(sha256sum "$OUT" | cut -c1-16)"
} > "$WORK/provenance.txt"
cat "$WORK/provenance.txt"
