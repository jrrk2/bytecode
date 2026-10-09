#!/bin/bash
# flash_sonata.sh prog.int : run a new INTCODE program on the Sonata with no synthesis, no FASM patch and no new bitstream.
# The design in $BASE (sonata_build.sh) reads its program from software slot 2 of the software flash at reset.  This assembles prog.int into the flash image (a
# software UF2, family 0x6CE29E60, address 0x10000000), copies it to the SONATA drive as software.uf2, then copies the same bitstream as fpga.uf2 to restart the
# FPGA, and syncs.  The file names are fixed so that the 15 MB drive does not fill up.  $DRIVE must be the drive mounted writable (default /mnt/sonata).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=${BASE:-$HOME/bytecode-work/sonata/base}
DRIVE=${DRIVE:-/mnt/sonata}
W=${W:-/tmp/intcode_flash}; mkdir -p "$W"
mountpoint -q "$DRIVE" && [ -w "$DRIVE" ] || { echo "the SONATA drive is not mounted writable at $DRIVE (it re-enumerates: check lsblk)"; exit 1; }
python3 "$HERE/intcode_send.py" "$1" --uf2 "$W/software.uf2" --slot 2 | tail -1
cp "$W/software.uf2" "$DRIVE/software.uf2" && sync
cp "$BASE/intcode_sonata.slot1.uf2" "$DRIVE/fpga.uf2" && sync
echo "copied software.uf2 and fpga.uf2 to $DRIVE; the program is running once the FPGA has restarted (a few seconds)"
