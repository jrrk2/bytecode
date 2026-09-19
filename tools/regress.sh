#!/bin/bash
# regress.sh <label> [rtl.sv] -- build a Verilator model of <rtl.sv> (default:
# this repo's ocaml4142_vm_rtl.sv) and run every test program through it,
# comparing each against an ocamlrund -t -t reference trace.  Work files and
# filtered logs (cycle-count independent) go to $BYTECODE_WORK (default
# ~/bytecode-work): results/<label>/<test>.log.
set -uo pipefail
B=$(cd "$(dirname "$0")/.." && pwd)
LABEL=$1; RTL=$(readlink -f "${2:-$B/ocaml4142_vm_rtl.sv}")
W=${BYTECODE_WORK:-$HOME/bytecode-work}; OC=$B/ocaml-4.14.2
T=$W/tests; M=$W/models/$LABEL; R=$W/results/$LABEL
mkdir -p "$T" "$M" "$R"

# test programs: bytecode + reference trace (once)
for ml in "$B"/*.ml; do
    n=$(basename "$ml" .ml)
    [ -s "$T/$n.trace" ] && [ "$T/$n" -nt "$ml" ] && continue
    ( cd "$T" && cp "$ml" . && /usr/bin/ocamlc -nopervasives "$n.ml" -o "$n" 2>"$n.comp.err" \
        && /usr/bin/ocamlrund -t -t "$n" > "$n.trace" 2>/dev/null ) || echo "  (could not compile/trace $n)"
done

# I/O test programs (vm_io_read/vm_io_write, io/*.ml): the VM runs a
# -use-prims build; the reference trace and device output come from a -custom
# debug runtime linked with io_stubs.c and the same device model (ethmodel.c).
{ /usr/bin/ocamlrun -p; printf 'vm_io_read\nvm_io_write\n'; } > "$T/vm.prims"
# A "(* regress-tftp: prog.ml" line makes the model serve prog.ml's netboot
# image (tools/progimage.sh + mkvmimage.py) as $ETHMODEL_TFTP_FILE.
tftp_image() {  # io test name -> the image file, built if needed ("" if none)
    local src; src=$(sed -n 's/^(\* regress-tftp: \([^ ]*\).*$/\1/p' "$B/io/$1.ml" 2>/dev/null | head -1)
    [ -z "$src" ] && return
    if [ ! -s "$T/$1.tftp.img" ] || [ "$B/$src" -nt "$T/$1.tftp.img" ]; then
        "$B/tools/progimage.sh" "$B/$src" "$T/$1.tftp" > /dev/null && "$B/tools/mkvmimage.py" "$T/$1.tftp" "$T/$1.tftp.img" > /dev/null
    fi
    echo "$T/$1.tftp.img"
}
for ml in "$B"/io/*.ml; do
    n=$(basename "$ml" .ml)
    export ETHMODEL_TFTP_FILE=$(tftp_image "$n")
    [ -s "$T/$n.trace" ] && [ "$T/$n.trace" -nt "$ml" ] && [ "$T/$n.trace" -nt "$B/ethmodel.c" ] && continue
    ( cd "$T" && cp "$ml" . && /usr/bin/ocamlc -nopervasives -use-prims vm.prims "$n.ml" -o "$n" 2>"$n.comp.err" \
        && /usr/bin/ocamlc -nopervasives -custom -runtime-variant d -ccopt -I"$B" "$n.ml" "$B/io/io_stubs.c" \
             "$B/ethmodel.c" -o "$n.ref" 2>>"$n.comp.err" \
        && OCAMLRUNPARAM=t=2 "./$n.ref" 2>/dev/null | grep -vE '^(eth|uart): ' > "$n.trace" \
        && "./$n.ref" 2>/dev/null | grep -E '^(eth|uart): ' > "$n.io" ) || echo "  (could not compile/trace $n)"
done

# heap/globals images of each program's DATA section (bc2image)
BC2IMAGE=$W/bin/bc2image
[ "$BC2IMAGE" -nt "$B/tools/bc2image.ml" ] ||
    ( mkdir -p "$W/bin" && cd "$W/bin" && /usr/bin/ocamlc -o bc2image "$B/tools/bc2image.ml" ) || exit 1
for tr in "$T"/*.trace; do
    n=$(basename "$tr" .trace)
    [ -s "$T/$n.img/image.txt" ] && [ "$T/$n.img/image.txt" -nt "$T/$n" ] && [ "$T/$n.img/image.txt" -nt "$BC2IMAGE" ] && continue
    mkdir -p "$T/$n.img" && "$BC2IMAGE" "$T/$n" "$T/$n.img" > /dev/null || echo "  (no image for $n)"
done

# runtime objects (once)
if [ ! -s "$W/bytecode.o" ]; then
    ( cd "$W" && cc -c -g "$OC/runtime/prims.c" "$B/bytecode.c" -I"$OC/runtime" ) || exit 1
fi

# model
cp "$RTL" "$M/ocaml4142_vm_rtl.sv"
cp "$B"/*.svh "$B"/*.h "$M/"
( cd "$M" && verilator -CFLAGS -g -CFLAGS -I"$B" --exe --trace --Wno-widthtrunc --Wno-widthexpand --Wno-multidriven \
    --Wno-BLKANDNBLK --cc -I. --Mdir obj ocaml4142_vm_rtl.sv "$B/main_rtl.cpp" \
    "$B/ethmodel.c" "$W/bytecode.o" "$W/prims.o" "$OC/runtime/libcamlrund.a" > verilate.log 2>&1 \
  && make -s -j8 -C obj -f Vocaml4142_vm_rtl.mk > make.log 2>&1 ) || { echo "BUILD FAILED ($M)"; tail -15 "$M/verilate.log" "$M/make.log"; exit 1; }

for tr in "$T"/*.trace; do
    n=$(basename "$tr" .trace); d=$R/run-$n; mkdir -p "$d"
    img=$T/$n.img
    # a test can ask for simulation plusargs with a "(* regress: +name=value ... *)" line
    extra=$(sed -n 's/^(\* regress: \(.*\)$/\1/p' "$T/$n.ml" 2>/dev/null | head -1)
    [ -f "$B/io/$n.ml" ] && export ETHMODEL_TFTP_FILE=$(tftp_image "$n")
    ( cd "$d" && timeout 600 "$M/obj/Vocaml4142_vm_rtl" "$T/$n" "$tr" +heap="$img/heap.hex" +globals="$img/globals.hex" \
        +heap_words="$(awk '/heap_words/{print $2}' "$img/image.txt")" $extra > full.log 2>&1; echo "exit $?" >> full.log; rm -f trace.vcd )
    gcs=$(grep -c '^GC [0-9]*:' "$d/full.log"); gcbad=$(grep -c 'HEAP CHECK FAILED\|GC: out of memory' "$d/full.log")
    grep -E '^(Fetch |Trace |ACCU mismatch|SP mismatch|Stopped|Trace mismatch|Terminating|HALT|Timeout|caml_|exit |eth: |uart: |GC )' "$d/full.log" > "$R/$n.log"
    io=""
    if [ -s "$T/$n.io" ]; then
        cmp -s "$T/$n.io" <(grep -E '^(eth|uart): ' "$d/full.log") && io="  device output matches" || io="  device output DIFFERS"
    fi
    cyc=$(grep -cE '^[0-9a-f]{8} ' "$d/full.log")
    printf '%-20s %6d fetches %8d cycles  %s\n' "$n" "$(grep -c '^Fetch ' "$R/$n.log")" "$cyc" \
        "$(grep -qE 'Stopped|Trace mismatch|Terminating|Timeout' "$R/$n.log" && echo STOPPED || (grep -q '^HALT' "$R/$n.log" && echo HALT || echo '?'))$io$( [ "$gcs" != 0 ] && echo "  $gcs GCs" )$( [ "$gcbad" != 0 ] && echo "  GC FAILURES $gcbad" )"
done
