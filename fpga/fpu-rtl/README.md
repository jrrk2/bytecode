# A double-precision FPU for the OCaml bytecode processor

OCaml's doubles are IEEE-754 binary64, boxed on the heap, and in bytecode
every float operation arrives as a C primitive. So the natural shape is a
peripheral behind the processor's trap port: hand it two doubles and an
operation, take the result back. Latency does not matter — the processor
runs about a million bytecode instructions a second, so even the sequential
divider's tens of cycles are lost in the noise — and nothing here is
pipelined for that reason.

    hardfloat.v       Berkeley HardFloat's cores (BSD), lifted whole from
                      Rocket's generated Verilog by tools/extract_modules.py:
                      the fused multiply-add, the divider and square root,
                      and the comparator, all double precision
    recode64.v        IEEE-754 <-> HardFloat's recoded format, written here
    fpu_hardfloat.v   the peripheral: op, two doubles, start -> result, done

Add, subtract and multiply come from the fused multiply-add; divide and
square root from the sequential divider; comparisons and sign operations
cost nothing. Everything transcendental — sin, exp, log, pow — belongs in
OCaml, built on these.

## What is trusted, and what is proved

The cores are Berkeley's, verified against Berkeley SoftFloat and shipped
in Rocket, which this flow already builds. The recoding is mine, so it is
proved twice: `test/` round-trips every corner case and 250,000 values
through recode and back, then runs **every operation against the host's own
doubles, bit for bit** — 82,250 cases including all 225 corner pairs
(zeros, subnormals, min and max normal, infinities, NaN) and values of
matched magnitude where cancellation bites. Zero differences.

Two mistakes that test caught, both invisible to a round trip: the format's
exponent bias is 1025, not 1024 (a consistent error cancels in a round
trip, and showed up as every result being exactly half), and the top *two*
exponent bits mark a special value while the third tells NaN from infinity.

## Cost

    12 DSP48E1, ~4600 LUTs, 532 flip-flops, 210 CARRY4

## Still to do

The processor side: the trap port carries two 32-bit arguments, so a double
takes two exchanges each way, and the processor does the heap reads and the
boxing since it is the one with the memories. The C primitives to route are
`caml_add_float` and its siblings, `caml_float_of_int`, `caml_int_of_float`
and the comparisons.
