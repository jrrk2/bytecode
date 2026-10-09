#!/bin/bash
# monitor_sonata.sh [file...] : put the INTCODE monitor, the BCPL compiler's two phases and all the sources into the Sonata's flash, and start it.
# The monitor (mon/mon.b, compiled here with the kit's own compiler) is the program in slot 2; it runs at reset and again whenever a program started with RUN halts.
# The file system after it (intcode_fs.py) holds ST and CG (the compiler's phases, as programs: ST reads the file STDIN and writes OCODE, CG reads OCODE and
# writes INTCODE), the compiler's headers and sources from the kit, and any files named on the command line.  Program and file system go out as one contiguous UF2.
# At the console (115200 8N1): DIR, CAT name, PUT name (then the text, ended with ^D), COPY a b, RUN name.  E.g.  COPY BLIB.B STDIN  RUN ST  RUN CG  CAT INTCODE
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=${KIT:-$HOME/bcplkit-0.9.7/src}
BASE=${BASE:-$HOME/bytecode-work/sonata/base}
DRIVE=${DRIVE:-/mnt/sonata}
W=${W:-/tmp/intcode_monitor}; mkdir -p "$W/files"
mountpoint -q "$DRIVE" && [ -w "$DRIVE" ] || { echo "the SONATA drive is not mounted writable at $DRIVE (it re-enumerates: check lsblk)"; exit 1; }
cd "$W"
cp "$KIT"/LIBHDR "$KIT"/st.int "$KIT"/cg.int "$KIT"/iclib.i "$KIT"/blib.i . ; cp "$HERE/mon/mon.b" "$HERE/mon/exec.i" .
"$KIT/icint" st.int < mon.b | grep -a -E "ERROR|COMPILATION" && exit 1 || true
"$KIT/icint" cg.int < OCODE > /dev/null
cat iclib.i exec.i blib.i INTCODE > mon.int
python3 "$HERE/intcode_send.py" mon.int --flash MON.prog --stdin "" | tail -1
python3 "$HERE/intcode_send.py" "$KIT/st.int" --flash files/ST --stdin STDIN | tail -1
python3 "$HERE/intcode_send.py" "$KIT/cg.int" --flash files/CG --stdin OCODE | tail -1
for f in LIBHDR SYNHDR TRNHDR CGHDR; do cp "$KIT/$f" files/$f; done
for f in blib syn trn cg; do cp "$KIT/$f.b" files/$(echo $f | tr a-z A-Z).B; done
for f in "$@"; do cp "$f" files/; done
python3 "$HERE/intcode_fs.py" fs.bin files/* | tail -1
HERE="$HERE" python3 - <<'PY'
import sys, os
sys.path.insert(0, os.environ["HERE"])
from intcode_fs import uf2_blocks
prog = open("MON.prog", "rb").read(); fs = open("fs.bin", "rb").read()
assert len(prog) < 0x20000
open("software.uf2", "wb").write(uf2_blocks(prog + b"\xff" * (0x20000 - len(prog)) + fs, 0x10000000))
print("%d bytes of flash image" % (0x20000 + len(fs)))
PY
cp software.uf2 "$DRIVE/software.uf2" && sync
cp "$BASE/intcode_sonata.slot1.uf2" "$DRIVE/fpga.uf2" && sync
echo "copied software.uf2 and fpga.uf2 to $DRIVE; open /dev/ttyUSB5 (115200) and type HELP once the FPGA has restarted"
