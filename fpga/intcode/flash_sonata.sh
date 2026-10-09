#!/bin/bash
# flash_sonata.sh prog.int : run a new INTCODE program on the Sonata with no synthesis, no FASM patch and no new bitstream.
# The design in $BASE (sonata_build.sh) reads its program from software slot 2 of the software flash at reset.  This assembles prog.int into the flash image (a
# software UF2, family 0x6CE29E60, address 0x10000000), copies it to the SONATA drive as software.uf2, then copies the same bitstream as fpga.uf2 to restart the
# FPGA, and syncs.  The file names are fixed so that the 15 MB drive does not fill up.  $DRIVE must be the drive mounted writable (default /mnt/sonata).
#   STDIN=NAME   the file in the flash file system the program reads as its standard input (default STDIN)
#   FS=dir       the files in this directory become the flash file system (intcode_fs.py), written with the program at UF2 address 0x10400000; without it the
#                files already in the flash stay, and the outputs written there (OCODE, INTCODE) are read by the next program
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=${BASE:-$HOME/bytecode-work/sonata/base}
DRIVE=${DRIVE:-/mnt/sonata}
W=${W:-/tmp/intcode_flash}; mkdir -p "$W"
mountpoint -q "$DRIVE" && [ -w "$DRIVE" ] || { echo "the SONATA drive is not mounted writable at $DRIVE (it re-enumerates: check lsblk)"; exit 1; }
python3 "$HERE/intcode_send.py" "$1" --uf2 "$W/software.uf2" --slot 2 ${STDIN:+--stdin "$STDIN"} | tail -1
if [ -n "$FS" ]; then
  python3 "$HERE/intcode_fs.py" "$W/fs.bin" "$FS"/* --uf2 "$W/fs.uf2" | tail -2
  python3 - "$W/software.uf2" "$W/fs.uf2" <<'PY'
import struct, sys
blocks = []
for f in sys.argv[1:]:
    d = open(f, "rb").read()
    blocks += [d[i:i + 512] for i in range(0, len(d), 512)]
out = b""
for n, b in enumerate(blocks):
    out += b[:20] + struct.pack("<II", n, len(blocks)) + b[28:]
open(sys.argv[1], "wb").write(out)
print("%d blocks in software.uf2" % len(blocks))
PY
fi
cp "$W/software.uf2" "$DRIVE/software.uf2" && sync
cp "$BASE/intcode_sonata.slot1.uf2" "$DRIVE/fpga.uf2" && sync
echo "copied software.uf2 and fpga.uf2 to $DRIVE; the program is running once the FPGA has restarted (a few seconds)"
