#!/bin/bash
# gen.sh [program.ml | bytecode] : generate this apio project's sources.
#   vm_sv2v.v     the VM (../../ocaml4142_vm_rtl.sv) as Verilog-2005 for yosys
#   program.hex   the program's CODE section (bc2hex.py)
#   heap.hex, globals.hex   its DATA section in the VM's heap format (bc2image)
#   program.vh    their names and sizes, for vc707_vm_top.v
# A .ml is compiled with ocamlc -nopervasives.  Intermediate files go to $GEN,
# outside this directory: apio compiles every .v/.sv beneath its project.
set -e
[ -n "${1:-}" ] && PROG=$(readlink -f "$1")
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
PROG=${PROG:-$REPO/fact.ml}
GEN=${GEN:-$HOME/bytecode-work/vc707-gen}
SV2V=${SV2V:-sv2v}
OCAMLC=${OCAMLC:-ocamlc}
mkdir -p "$GEN"

case "$PROG" in
*.ml)
  name=$(basename "$PROG" .ml)
  cp "$PROG" "$GEN/"
  (cd "$GEN" && "$OCAMLC" -nopervasives "$name.ml" -o "$name")
  BC=$GEN/$name ;;
*)
  name=$(basename "$PROG")
  BC=$PROG ;;
esac

"$SV2V" -DSYNTHESIS -I"$REPO" "$REPO/ocaml4142_vm_rtl.sv" > vm_sv2v.v
python3 "$REPO/tools/bc2hex.py" "$BC" program.hex
[ "$GEN/bc2image" -nt "$REPO/tools/bc2image.ml" ] ||
  (cd "$GEN" && "$OCAMLC" -o bc2image "$REPO/tools/bc2image.ml")
"$GEN/bc2image" "$BC" . > /dev/null
words=$(wc -l < program.hex)
heap_words=$(awk '/heap_words/{print $2}' image.txt)
rm image.txt
cat > program.vh <<VH
\`define PROGRAM_HEX "program.hex"
\`define PROGRAM_WORDS $words
\`define PROGRAM_NAME "$name"
\`define HEAP_WORDS $heap_words
VH
echo "vm_sv2v.v; $name: program.hex ($words words), heap.hex ($heap_words words), globals.hex"
