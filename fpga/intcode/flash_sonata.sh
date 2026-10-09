#!/bin/bash
# flash_sonata.sh prog.int : run a new INTCODE program on the Sonata with no synthesis, no FASM patch and no new bitstream.
# The design in $BASE (sonata_build.sh) reads its program from software slot 2 of the software flash at reset.  This assembles prog.int into the flash image (a
# software UF2, family 0x6CE29E60, address 0x10000000), copies it to the SONATA drive as software.uf2, then copies the same bitstream as fpga.uf2 to restart the
# FPGA, and syncs.  The file names are fixed so that the 15 MB drive does not fill up.  $DRIVE must be the drive mounted writable (default /mnt/sonata).
#   STDIN=NAME   the file in the flash file system the program reads as its standard input (default STDIN)
#   FS=dir       the files in this directory become the flash file system (intcode_fs.py), written with the program at UF2 address 0x10020000 in one UF2; without it the
#                files already in the flash stay, and the outputs written there (OCODE, INTCODE) are read by the next program
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=${BASE:-$HOME/bytecode-work/sonata/base}
DRIVE=${DRIVE:-/mnt/sonata}
W=${W:-/tmp/intcode_flash}; mkdir -p "$W"
mountpoint -q "$DRIVE" && [ -w "$DRIVE" ] || { echo "the SONATA drive is not mounted writable at $DRIVE (it re-enumerates: check lsblk)"; exit 1; }
python3 "$HERE/intcode_send.py" "$1" --uf2 "$W/software.uf2" --slot 2 ${STDIN:+--stdin "$STDIN"} | tail -1
if [ -n "$FS" ]; then
  # the Sonata takes one contiguous run of blocks: the program, ones up to 128 KiB (FS_AT), then the file system
  python3 "$HERE/intcode_fs.py" "$W/fs.bin" "$FS"/* | tail -1
  python3 - "$W" "$HERE" <<'PY'
import sys, struct
w, here = sys.argv[1], sys.argv[2]
sys.path.insert(0, here)
from intcode_fs import uf2_blocks
old = open(w + "/software.uf2", "rb").read()
prog = b"".join(old[i + 32:i + 32 + 256] for i in range(0, len(old), 512))      # the program's blocks' payloads, in order
prog = prog[:max(len(prog), 0)]
fs = open(w + "/fs.bin", "rb").read()
img = prog + b"\xff" * (0x20000 - len(prog)) + fs
open(w + "/software.uf2", "wb").write(uf2_blocks(img, 0x10000000))
print("%d blocks in software.uf2" % (len(img) // 256))
PY
fi
cp "$W/software.uf2" "$DRIVE/software.uf2" && sync
cp "$BASE/intcode_sonata.slot1.uf2" "$DRIVE/fpga.uf2" && sync
echo "copied software.uf2 and fpga.uf2 to $DRIVE; the program is running once the FPGA has restarted (a few seconds)"
