#!/bin/bash
# run.sh : build the Verilator model of intcode_core (WIDTH=${WIDTH:-32}) with the harness and the kit's blib.c.
#   OBJ=dir   where it is built (default ~/bytecode-work/intcode-obj)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=${KIT:-$HOME/bcplkit-0.9.7/src}
OBJ=${OBJ:-$HOME/bytecode-work/intcode-obj}
mkdir -p "$OBJ"
cp "$KIT/blib.c" "$KIT/blib.h" "$OBJ/"
gcc -O2 -c "$OBJ/blib.c" -o "$OBJ/blib.o"
verilator --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-style --top-module intcode_core -GWIDTH=${WIDTH:-32} -CFLAGS -O2 \
  -Mdir "$OBJ/obj" "$HERE/intcode_core.sv" "$HERE/tb_intcode.cpp" "$OBJ/blib.o" > "$OBJ/build.log" 2>&1 || { tail -20 "$OBJ/build.log"; exit 1; }
echo "$OBJ/obj/Vintcode_core"
