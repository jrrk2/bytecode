#!/bin/bash
# open_build.sh : build this design with the open flow (yosys, openXC7's
# nextpnr, prjxray), the same route as xc7-bitstream-tools' "make
# vc707-ethmin" but with the VM in place of picorv32.  Vivado's build.tcl
# stays the reference; this one says whether the open tools can do it.
#
#   tools/progimage.sh io/netboot.ml fpga/vc707-ethmin   # the resident program
#   fpga/vc707-ethmin/open_build.sh                      # -> $OUT (a .bit)
#
# $YOSYS_DEFS passes defines to yosys, for a build that differs only by a
# macro: "-DSYS_DIV=13.375 -DCLK_HZ=74766355" builds this design at 74.77 MHz
# instead of 100, which is what the open flow can currently close.
#
# $SKIP_SYNTH=1 keeps the netlist from the last run: when only a nextpnr
# option has changed, synthesis has nothing to redo (it is the slower half).
#
# The VM is SystemVerilog, which yosys does not read, so sv2v converts it
# first.  vc707_rbtest_open.xdc is the constraints for this flow: the same
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
WORK=${WORK:-$HOME/bytecode-work/rbtest-open}
OUT=${OUT:-$WORK/vc707_rbtest.bit}
PART=${PART:-xc7vx485tffg1761-2}
TOP=vc707_rbtest
YOSYS=${YOSYS:-$XC7BT/yosys-install/bin/yosys}
NEXTPNR=${NEXTPNR:-$XC7BT/build/nextpnr-himbaechel}   # the Makefile's NEXTPNR_BUILD, with the xc7vx485t chipdb
PRJXRAY_DB=${PRJXRAY_DB:-$XC7BT/.deps/prjxray-db}
PYTHON=${PYTHON:-$XC7BT/.venv/bin/python}   # the flow's venv: fasm, and what convert.py imports
mkdir -p "$WORK"

# yosys and $readmemh both resolve paths against the working directory, and
# the program images live beside the RTL, so build from a copy of this
# directory with the converted VM added.
cp "$HERE"/*.v "$WORK/"   # no SystemVerilog here, so no sv2v step

SRCS="vc707_rbtest.v $ETH/clkgen_vc707.sv"

cd "$WORK"
if [ -n "${SKIP_SYNTH:-}" ] && [ -s "$TOP.json" ]; then
    echo "== yosys (skipped, keeping $TOP.json)"
else
    echo "== yosys"
    "$YOSYS" -q -l yosys.log -p \
      "read_verilog -sv -I. ${YOSYS_DEFS:-} $SRCS; synth_xilinx -flatten -abc9 -arch xc7 -top $TOP; write_json $TOP.json"
fi

echo "== nextpnr"
"$NEXTPNR" --device "$PART" -o xdc="$HERE/vc707_rbtest_open.xdc" \
  --json "$TOP.json" -o fasm="$TOP.fasm" -o placement="${TOP}_placement.json" \
  --router router2 --timing-allow-fail -o hold-fix ${NEXTPNR_FLAGS:-} 2>&1 | tee nextpnr.log | tail -20

echo "== fasm -> bitstream"
"$PYTHON" "$XC7BT/scripts/check_fasm_expressible.py" "$PRJXRAY_DB/virtex7" "$PART" "$TOP.fasm"
"$PYTHON" "$XC7BT/scripts/convert.py" --arch xilinx --family xc7 --part "$PART" \
  --db "$PRJXRAY_DB" --fasm "$TOP.fasm" --output "$OUT"
echo "built $OUT"
