#!/bin/bash
# sonata_build.sh prog.int [workdir] : the INTCODE system with prog.int in its store, through the open flow for the lowRISC Sonata ONE
# (Artix-7 xc7a50tcsg324-1, 25 MHz): assemble prog.int and dump the store (tb_intcode, ./run.sh builds it), yosys, nextpnr-himbaechel, prjxray -> a UF2.
#   ROUTER=router2 (default; the Sonata example's README says router1 is needed for the 25 MHz clock path, so ROUTER=router1 is the fallback)
#   SLOT=1|2|3     which of the board's configuration slots the UF2 is for (the UF2's address)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
X=${XC7BT:-$HOME/xc7-bitstream-tools}
RTL=${RTL:-$HOME/bytecode-work/intcode-obj/obj/Vintcode_core}
PROG=$(realpath "$1"); W=${2:-/tmp/intcode_sonata}; ROUTER=${ROUTER:-router2}; SLOT=${SLOT:-1}
mkdir -p "$W"; cd "$W"
cp "$PROG" prog.int
INTCODE_DUMP="$W" "$RTL" prog.int > /dev/null 2>&1 || true                 # writes image.hex and image.vh, then exits
cp "$HERE/intcode_sonata.xdc" .
"$X/yosys-install/bin/yosys" -q -l yosys.log -p "read_verilog -sv -DSYNTHESIS -I. $HERE/intcode_core.sv $HERE/intcode_sys.v $HERE/intcode_sonata.v $HERE/../eth-rtl/simpleuart.v; synth_xilinx -flatten -abc9 -arch xc7 -top intcode_sonata; write_json top.json"
"$X/build/nextpnr-himbaechel" --device xc7a50tcsg324-1 -o xdc=intcode_sonata.xdc --json top.json -o fasm=top.fasm -o placement=top_placement.json --router "$ROUTER" --timing-allow-fail > pnr.log 2>&1
grep "Max frequency" pnr.log | tail -1
# raw bitstream, then the board's UF2 writer with the slot's address (slot 1 at 0, slot 2 at 0x10000000, slot 3 at 0x20000000)
"$X/.venv/bin/python" "$X/scripts/convert.py" --arch xilinx --family xc7 --part xc7a50tcsg324-1 --db "$X/.deps/prjxray-db" --fasm top.fasm --output intcode_sonata.bit > conv.log 2>&1
"$X/.venv/bin/python" -c "
import sys; sys.path.insert(0, '$X')
from boards.sonata import write_uf2
write_uf2(open('intcode_sonata.bit', 'rb').read(), 'intcode_sonata.slot$SLOT.uf2', ($SLOT - 1) * 0x10000000)"
ls -l "intcode_sonata.slot$SLOT.uf2"
