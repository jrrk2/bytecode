# Turning INTCODE text into executables on the FPGA

Today the host does the last step: `intcode_send.py` (a Python port of icint's assembler) turns `.i` text into a program file with the `INTC`/`INTD` header, and the monitor runs
that file with `RUN`.  The proposal is to move that step onto the board, so that the whole tool chain is on the FPGA:

    source (.b) --ST--> OCODE --CG--> INTCODE (.i text) --ASM--> program file --RUN--> running

## ASM, a BCPL program

* A direct port of the assembler in `icint.c` (about 100 lines of BCPL; `icint.b` in the kit is a 16-bit EBCDIC version, so the C one is the model), 32-bit words, four characters
  to a word.  It is compiled by ST and CG like any other program, and shipped on the disk image as a program file, first built on the host.  Once it is on the board it can be
  rebuilt there from its own source (`ASM.B`): the toolchain then regenerates itself.
* It assembles into a vector (the store image from word 0, so labels and the global vector get their absolute addresses; the vector is about 12K words for the compiler and the
  program may be up to about 26K words, the rest of the 32K-word store being ASM itself, its stack and the library).  Then it writes one file: the five header words
  (`INTC`, N, C = 402, P, G = 1), optionally the six name words of `INTD`, and the N words, little-endian.  `findoutput` appends that record to the flash; `RUN` loads it.
* Input is a list of INTCODE files, concatenated in order, as the bootstrap does (`iclib.i`, `blib.i`, then the program's own `.i`).

## Arguments: the file ARGS

Programs have no command line, so use a convention the monitor can supply: `RUN name arg...` first writes the text of the arguments to a file `ARGS`, then execs `name`; a program
reads `ARGS` (one line) with `findinput` when it starts.  Then `RUN ASM HELLO ICLIB.I BLIB.I HELLO.I` writes the program file `HELLO`, `RUN HELLO` runs it, and
`RUN ST BLIB.B` / `RUN CG` replace the `COPY ... STDIN` step.  The monitor change is about 20 lines; `ARGS`, like `STDIN`, is an ordinary newest-record-wins file.

## Cost and checks

* Assembling the compiler's 60 KB of INTCODE is a few million instructions, well under a second at 25 MHz; the output record is about 40 KB of flash.
* Correctness check, which needs nothing new: ASM's output for each of the shipped `.i` files must equal `intcode_send.py --flash` byte for byte; and ASM assembling its own `.i`
  must give the file it was built from (a fixed point, as the bootstrap already shows for the compiler).
* Limits to state: 500 labels per section (as in the kit), 32K-word store, flash writes are append-only (a rebuilt program makes a new record; the old one is hidden, not freed;
  a host reflash starts the file system afresh).

## Alternatives considered

* Hardware assembler: costs LUTs and a second copy of the INTCODE syntax in Verilog, and can never be changed from the console.
* Loading the text directly, as `icint` does (assemble and interpret in one go): needs the assembler resident next to every program and wastes store; a program file runs at once.
* A longer-term option is a linker in the same style (several program files, one global vector) if programs ever outgrow one store.
