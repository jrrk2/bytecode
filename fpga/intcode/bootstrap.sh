#!/bin/bash
# bootstrap.sh : the BCPL bootstrap, with the compiler running on the INTCODE core in RTL (Verilator).
#   gen 0: the kit's st.int + cg.int (the INTCODE compiler as shipped) compile the compiler's own sources syn, trn, cg, blib
#   gen 1: what that produced is assembled into a new st and cg, which compile the sources again
#   gen 2: likewise -- a fixed point when gen 1 and gen 2 produce the same INTCODE (and the same as the kit's own .i files)
# Every compile is two programs on the core: st (syntax and translation) reads BCPL on stdin and writes OCODE, cg reads OCODE and
# writes INTCODE.  Needs the model built by run.sh.
set -e
KIT=${KIT:-$HOME/bcplkit-0.9.7/src}
RTL=${RTL:-$HOME/bytecode-work/intcode-obj/obj/Vintcode_core}
W=${1:-/tmp/intcode_bootstrap}
GENS=${GENS:-2}
rm -rf "$W"; mkdir -p "$W"; cd "$W"
cp "$KIT"/*HDR "$KIT"/syn.b "$KIT"/trn.b "$KIT"/cg.b "$KIT"/blib.b "$KIT"/iclib.i "$KIT"/st.int "$KIT"/cg.int .
cp st.int st0.int; cp cg.int cg0.int
total_clocks=0; total_instr=0
run() {   # program, input -> output file is the program's own (OCODE / INTCODE); count clocks
  local out; out=$( { "$RTL" "$1" < "$2" > /dev/null; } 2>&1 | tail -1 )
  local c i; c=$(echo "$out" | sed 's/RTL: \([0-9]*\) clocks.*/\1/'); i=$(echo "$out" | sed 's/.*clocks, \([0-9]*\) instructions.*/\1/')
  total_clocks=$((total_clocks + c)); total_instr=$((total_instr + i))
}
for g in $(seq 0 $GENS); do
  mkdir -p gen$g
  for f in blib syn trn cg; do
    run st$g.int $f.b; cp OCODE gen$g/$f.ocode
    run cg$g.int OCODE; cp INTCODE gen$g/$f.i
  done
  echo "generation $g compiled blib syn trn cg: $(cat gen$g/*.i | wc -c) bytes of INTCODE   (so far $total_instr instructions, $total_clocks clocks)"
  next=$((g + 1))
  cat iclib.i gen$g/blib.i gen$g/syn.i gen$g/trn.i > st$next.int
  cat iclib.i gen$g/blib.i gen$g/cg.i > cg$next.int
done
echo
for g in $(seq 1 $GENS); do
  p=$((g - 1)); same=yes
  for f in blib syn trn cg; do cmp -s gen$p/$f.i gen$g/$f.i || same=no; cmp -s gen$p/$f.ocode gen$g/$f.ocode || same=no; done
  echo "generation $p and $g: INTCODE and OCODE for all four sources identical: $same"
done
same=yes; for f in blib syn trn cg; do cmp -s gen0/$f.i "$KIT/$f.i" || same=no; done
echo "generation 0 equals the kit's own $(echo blib.i syn.i trn.i cg.i): $same"
echo "total: $total_instr instructions, $total_clocks clocks"
