#!/bin/bash
# gen.sh [program.ml | bytecode] : generate this apio project's sources: the
# VM as Verilog-2005 for yosys (vm_sv2v.v, via sv2v) and the program's images
# (tools/progimage.sh: program.hex, heap.hex, globals.hex, program.vh).
# Default program ../../fact.ml.  Intermediate files stay outside this
# directory: apio compiles every .v/.sv beneath its project.
set -e
[ -n "${1:-}" ] && PROG=$(readlink -f "$1")
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
"${SV2V:-sv2v}" -DSYNTHESIS -I"$REPO" "$REPO/ocaml4142_vm_rtl.sv" > vm_sv2v.v
"$REPO/tools/progimage.sh" "${PROG:-$REPO/fact.ml}" .
