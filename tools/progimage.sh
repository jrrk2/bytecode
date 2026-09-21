#!/bin/bash
# progimage.sh <program.ml | bytecode> <outdir> : a program's ROM and memory
# images for the FPGA builds.
#   program.hex           its CODE section (bc2hex.py)
#   heap.hex, globals.hex its DATA section in the VM's heap format (bc2image)
#   program.vh            PROGRAM_HEX, PROGRAM_WORDS, PROGRAM_NAME, HEAP_WORDS,
#                         GLOBALS_WORDS
# A .ml is compiled with ocamlc -nopervasives, and with the VM's primitive
# list (the runtime's, plus vm_io_read/vm_io_write) if it uses vm_io_*.
# Intermediate files go to $GEN (default ~/bytecode-work/progimage).
set -e
PROG=$(realpath -m "$1"); OUT=$(realpath -m "$2")
REPO=$(cd "$(dirname "$0")/.." && pwd)
GEN=${GEN:-$HOME/bytecode-work/progimage}
OCAMLC=${OCAMLC:-ocamlc}
mkdir -p "$GEN" "$OUT"

case "$PROG" in
*.ml)
  name=$(basename "$PROG" .ml)
  cp "$PROG" "$GEN/"
  prims=()
  if grep -q '"vm_io_' "$PROG"; then
    { "${OCAMLRUN:-ocamlrun}" -p; printf 'vm_io_read\nvm_io_write\n'; } > "$GEN/vm.prims"
    prims=(-use-prims vm.prims)
  fi
  (cd "$GEN" && "$OCAMLC" -nopervasives "${prims[@]}" "$name.ml" -o "$name")
  BC=$GEN/$name ;;
*)
  name=$(basename "$PROG")
  BC=$PROG ;;
esac

python3 "$REPO/tools/bc2hex.py" "$BC" "$OUT/program.hex" > /dev/null
[ "$GEN/bc2image" -nt "$REPO/tools/bc2image.ml" ] ||
  (cd "$GEN" && "$OCAMLC" -o bc2image "$REPO/tools/bc2image.ml")
"$GEN/bc2image" "$BC" "$OUT" > /dev/null
words=$(wc -l < "$OUT/program.hex")
# ...and the same code as explicit x1 block RAMs, which is what the design
# instantiates: inference picks x9, and the open flow gets x9 wrong.
python3 "$REPO/tools/gen_rom_bram.py" "$OUT/program.hex" "$OUT/program_bram.v" code_rom_bram > /dev/null
heap_words=$(awk '/heap_words/{print $2}' "$OUT/image.txt")
globals_words=$(awk '/^globals/{print $2}' "$OUT/image.txt")
rm "$OUT/image.txt"
cat > "$OUT/program.vh" <<VH
\`define PROGRAM_HEX "program.hex"
\`define PROGRAM_WORDS $words
\`define PROGRAM_NAME "$name"
\`define HEAP_WORDS $heap_words
\`define GLOBALS_WORDS $globals_words
VH
echo "$name: program.hex ($words words), heap.hex ($heap_words words), globals.hex -> $OUT"
