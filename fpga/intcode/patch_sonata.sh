#!/bin/bash
# patch_sonata.sh prog.int : put a new INTCODE program into the Sonata design without synthesis or routing.
# The base design (sonata_build.sh: top.fasm, top_placement.json) is kept in $BASE; this assembles prog.int into the 32K-word store image, rewrites
# the block-RAM INIT lines in a copy of the base FASM (fasm_patch_mem.py), converts it to a UF2 (a few seconds) and copies it to the SONATA drive if that is
# mounted writable at $DRIVE (default /mnt/sonata), then syncs.  Slot 1 (address 0).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
X=${XC7BT:-$HOME/xc7-bitstream-tools}
BASE=${BASE:-$HOME/bytecode-work/sonata/base}
DRIVE=${DRIVE:-/mnt/sonata}
PROG=$(realpath "$1"); NAME=$(basename "$PROG" .int)
W=${W:-/tmp/intcode_patch}; mkdir -p "$W"
python3 "$HERE/intcode_send.py" "$PROG" --image "$W/image.hex"
python3 "$HERE/fasm_patch_mem.py" "$BASE/top.fasm" "$BASE/top_placement.json" "$W/image.hex" "$W/top.fasm"
"$X/.venv/bin/python" "$X/scripts/convert.py" --arch xilinx --family xc7 --board sonata --part xc7a50tcsg324-1 --db "$X/.deps/prjxray-db" \
    --fasm "$W/top.fasm" --output "$W/$NAME.slot1.uf2" > "$W/convert.log" 2>&1
ls -l "$W/$NAME.slot1.uf2" | awk '{print $5, $9}'
if mountpoint -q "$DRIVE" && [ -w "$DRIVE" ]; then
    cp "$W/$NAME.slot1.uf2" "$DRIVE/" && sync && echo "copied to $DRIVE and synced"
else
    echo "the SONATA drive is not mounted writable at $DRIVE: copy $W/$NAME.slot1.uf2 to it"
fi
