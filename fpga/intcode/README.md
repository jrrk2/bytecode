# INTCODE machine in RTL, and the BCPL bootstrap on it (Verilator)

`intcode_core.sv` is M. Richards' INTCODE machine (registers A B C D P G, 16-bit instruction words F/I/P/G/D flags and a 9-bit address, eight functions,
operate codes 1..39), written after `bcplkit`'s `icint.c`.  The store is an external synchronous RAM; the stream operations are requests on a port.
`WIDTH` is the word size: 32 runs the kit's INTCODE as shipped (four characters to a word).  `tb_intcode.cpp` is the Verilator harness: it loads the
store with `icint.c`'s own assembler (the loader), keeps the RAM, and serves the stream operations with the kit's unchanged `blib.c`; it prints
icint's banner and its "EXECUTION CYCLES", so its output can be diffed against `icint`'s, and reports the clocks the RTL took.

    ./run.sh                           # builds ~/bytecode-work/intcode-obj/obj/Vintcode_core  (KIT=~/bcplkit-0.9.7/src)
    ./bootstrap.sh /tmp/ic_boot        # the bootstrap: GENS=2 generations on the RTL, about 40 s

## What was checked (WIDTH 32, 2026-10-09)

* Against the C interpreter, for `hello.int` and for both compiler phases on `blib.b` and `cg.b`: identical console output, identical `OCODE` and `INTCODE`
  files, and the same instruction count to the unit (294,752; 539,354 + 342,732; 3,687,850 + 1,541,879).
* The bootstrap (`bootstrap.sh`): generation 0 is the kit's `st.int`/`cg.int` compiling `blib.b syn.b trn.b cg.b` on the RTL; its INTCODE is assembled into a
  new `st` and `cg` (generation 1), which compile the four sources again, and those results into generation 2.  The INTCODE and OCODE of all four sources are
  identical in all three generations (63,657 bytes of INTCODE): a fixed point.  Three of the four equal the kit's own `blib.i syn.i trn.i`; `cg.i` differs only
  in the code generator's work-vector size, which is a manifest in `CGHDR` (8000 in the sources as shipped, 4000 in the kit's checked-in `cg.i`).
* Cost: 25.6 M instructions per generation (syntax and translation 21 M, code generation 9 M of the three-phase total across the four files), 139.5 M clocks,
  so **5.45 clocks per instruction** with this simple state machine (a two-clock fetch from a synchronous store, then the address stage, then execute).
  At 100 MHz that is 18 MIPS and 1.4 s for a generation; at 62.5 MHz 2.2 s.  Overlapping the next fetch with the execute would bring it towards 3 clocks.

## Not done

* WIDTH 16.  The shipped INTCODE has the 32-bit word baked in (four characters to a word in `C` constants and in the library's byte routines; `WORDSIZE 32`
  in the assembler), so a 16-bit core needs the compiler's libraries and the assembler changed to two characters a word, and the whole bootstrap redone at that
  width.  That is the real test of whether the compiler is 16-bit clean.
* An assembler in the machine (the host's assembler is the loader here), a real UART/storage in place of `blib.c`, FPGA synthesis for resource figures.
* Overlays: `st` (syntax and translation, 9,756 words) and `cg` (3,317 words) already run as two programs through the `OCODE` file; here each is simply loaded in turn.
