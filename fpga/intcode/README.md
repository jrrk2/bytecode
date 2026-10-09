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
* Cost (before the serial multiply and divide, below): 25.6 M instructions per generation (syntax and translation 18.3 M, code generation 7.3 M, over the four files), 139.5 M clocks,
  so **5.45 clocks per instruction** with this simple state machine (a two-clock fetch from a synchronous store, then the address stage, then execute).
  At 100 MHz that is 18 MIPS and 1.4 s for a generation; at 62.5 MHz 2.2 s.  Overlapping the next fetch with the execute would bring it towards 3 clocks.

## The open flow: yosys, nextpnr, prjxray (2026-10-09)

Multiply, divide and remainder are serial (a bit a clock), since a combinational divider alone took hundreds of LUTs; that raises the clocks per instruction from
5.45 to 5.6 (the bootstrap is unchanged: still a fixed point, still the same instruction counts as the C interpreter).  `intcode_arty.v` wraps the core in a small
system for the Arty A7-35T (a 32K-word store in block RAM that starts holding an assembled program, a console on the UART; `intcode_arty.xdc`).  The store image is
`INTCODE_DUMP=dir tb_intcode prog.int` (`image.hex`, `image.vh`).  Flow, as in `xc7-bitstream-tools`' `arty-blinky`:

    yosys: read_verilog -sv intcode_core.sv intcode_arty.v ../eth-rtl/simpleuart.v; chparam -set WIDTH N intcode_arty;
           synth_xilinx -flatten -abc9 -arch xc7 -top intcode_arty
    nextpnr-himbaechel --device xc7a35tcsg324-1 -o xdc=intcode_arty.xdc --router router2 --freq 100 ...
    scripts/convert.py --arch xilinx --family xc7 --part xc7a35tcsg324-1 ...   -> a 2.2 MB .bit

| | yosys LUTs | FFs | CARRY4 | RAMB36 | nextpnr fmax (target 100 MHz) |
|---|---|---|---|---|---|
| core alone, WIDTH 32 | 1,986 | 376 | 146 | | |
| core alone, WIDTH 16 | 1,136 | 200 | 83 | | |
| system, WIDTH 32 | 2,070 | 452 | 169 | 32 | 113.6 MHz, passes |
| system, WIDTH 16 | 1,213 | 292 | 110 | 16 | 133.8 MHz, passes |

(nextpnr counts 3,191 and 1,980 LUT sites, which includes the sites the carry chains and route-throughs occupy.)  Both reach a bitstream.  They have not been run on a
board (there is no Arty here), and the system's console logic is untested beyond synthesis: only the core is simulated.  The 16-bit store image used for sizing is the 32-bit image
truncated, which does not run.

Where the 16-bit core's LUTs go (by removing each in turn): the two shifters 142, getbyte/putbyte 91, the six compares 34; the rest, about 870, is the adders and address
multiplexers of a plain state machine.  A microcoded design with one shared adder and a serial shifter would be well under half of this; that has not been tried.

## The Sonata ONE (lowRISC, Artix-7 xc7a50t) -- 2026-10-09

`intcode_sys.v` is the whole system (core, 32K-word block-RAM store holding an assembled program, console on the UART with PicoSoC's `simpleuart`);
`intcode_arty.v` and `intcode_sonata.v` are board tops (100 MHz / 25 MHz clocks, UART divider 868 / 217, four / eight LEDs); `intcode_sonata.xdc` has the pins
(25 MHz oscillator P15, the UART header C17 tx and D18 rx, eight LEDs, as in litex-boards' `lowrisc_sonata.py`).  LEDs on the Sonata: 0 running, 1 halted,
2 result not zero, 3 a character received, 4 heartbeat (about 1 Hz), 5, 6, 7 toggle at each stream request, character received, character sent.
Stream operations are the console only: `rdch` and `wrch` are the UART, `input()` and `output()` are streams 1 and 2, `findinput` and `findoutput` return the
console (so a program that opens files, such as the compiler, does not run here yet).

* Simulated (`tb_sys.cpp`, a UART model on the pins; build with `-GDIV=217`): `msg.int` prints `Hello STA 5 START` exactly as `icint` does, and an echo program
  compiled with the kit's own compiler (`echo.b`) turns `hello sonata` typed at the console into `HELLO SONATA`.  Two bugs found there, not in the core: simpleuart
  holds the bus (`wait`) while it is busy, so the write strobe has to be held until accepted, not pulsed; and its bit period is the divider plus 2 clocks.
* Open flow: `sonata_build.sh prog.int` (yosys, nextpnr-himbaechel, prjxray, the UF2 writer): 32-bit system 2,070 LUTs, 476 flip-flops, 176 CARRY4, 32 RAMB36 of 75;
  `router2` routes it and meets 25 MHz (105.9 MHz post-route).  (The Sonata example's README says the 25 MHz clock path needs `router1`; with this build
  `router2` places the clock buffer on its dedicated routing and the design runs, so that note does not apply here.)  The UF2 for slot 1 is 4.4 MB (8,564 blocks);
  other slots are the same bits at 0x10000000 and 0x20000000.
* **On the board** (2026-10-09, UF2 copied to the SONATA drive, address 0): the heartbeat LED blinks, and a line typed at UART 0 (`/dev/ttyUSB5` here: the third
  interface of the board's FTDI bridge, C17/D18 are `ser0` in the Sonata pin file, 115200 8N1) comes back in capitals: `hello sonata` -> `HELLO SONATA`.  The echo program
  halts after one line, so it needs a reset (or a UF2 copy) for another.
* At 25 MHz and 5.6 clocks an instruction the machine does about 4.5 MIPS; the bootstrap's 25.6 M instructions would take about 6 s a generation.

## Changing the program without a rebuild (2026-10-09)

The store is the initial contents of 32 RAMB36s, so a new program is a rewrite of their `INIT_nn` lines in the routed design's FASM; placement and routing are
untouched.  `fasm_patch_mem.py base.fasm placement.json image.hex out.fasm` does it.  The mapping was derived from the netlist and checked against the FASM for three
cells: the RAM `sys.mem.0.K` holds bit K of the 32K-word store; its tile's `RAMB18_Y0` holds the even addresses and `RAMB18_Y1` the odd ones, 64 `INIT` rows of 256
bits each, address 0 at the right-hand end of the string.  Self-test: patching the base with its own image reproduces its FASM byte for byte.  The start registers C, P and
G are no longer constants in the logic: with `boot_store` the core reads them at reset from the top three words of the store (32765..32767), so they patch with the rest.

    fpga/intcode/sonata_build.sh prog.int ~/bytecode-work/sonata/base      # once: synthesis, place and route (about 70 s)
    fpga/intcode/patch_sonata.sh other.int                                 # any later program: assemble, patch, convert, copy to /mnt/sonata, sync (about 26 s)

`intcode_send.py` is a Python port of icint's assembler (checked word for word against the C one on five programs, including the 10,158-word compiler front end) and
also writes the store image.  Checked on the board: the base held an echo that prints a banner on start; `patch_sonata.sh echo3.int` replaced it with a program that waits
for a key and then prints `PATCHED VIA FASM`, and typed text came back in capitals.  The convert step dominates the 26 s (the UF2 is the whole 4.4 MB bitstream).

Reading the program from the software SPI flash at reset (`intcode_sys.v`, the `spi_*` ports; Sonata pins D10 cs, A8 clk, C11/C10 data, A10/A9 held high): after the flash's
reset command (0x66, 0x99) it READs (0x03) from slot 2 (10 MiB, `FLASH_AT`) a header of five little-endian words -- magic `INTC`, N, C, P, G -- and N words, into the store, holding the core;
without the magic the bitstream's own program runs.  `intcode_send.py prog.int --uf2 out.uf2 --slot 2` makes the software UF2 (family 0x6CE29E60; the slot is chosen by the target address, 0 / 0x10000000 /
0x20000000, as in the Sonata release procedure) and `--flash` the raw image.  Simulated (`tb_sys` with an SPI flash slave): a blank flash runs the built-in program; with a flash image the design
reads exactly the 4,312 bytes of the image and runs that instead.  **Not yet confirmed on the board** (2026-10-09): the first attempt got no UART reply from the new design, nor from the previously working
FASM-patched image copied back afterwards -- see the notes in the commit.  (The SONATA drive is 15 MB: each 4.4 MB UF2 left on it has to be deleted before the next.)

Two other routes, not built: `loader.int` is a 121-word UART loader (assembled at 26000, `W aaaaaaaa dddddddd` and `G pppppppp` commands) with `intcode_send.py --port`
as the sender, tested in the assembler but not yet in the system simulation; 

## The monitor and the flash file system (2026-10-09)

All of this runs on the Sonata, with no files crossing the serial line while a compile runs.

* **File system** (`intcode_sys.v`, `intcode_fs.py`): from `FS_AT` (flash 0xA20000, 128 KiB into slot 2, so that program and files go out as one contiguous UF2 -- the
  Sonata ignores a UF2 with a gap) the flash holds a chain of records: a 32-byte header (name as BCPL packs a string, length, flags) and the data.  The newest record of a name
  wins.  `findinput` reads a record, `findoutput` appends one (page program through a 256-byte buffer, sector erase when the chain first reaches a sector, the length written at
  `endwrite` or when the program halts).  A file `STDIN` is a program's standard input, or the file its header names (magic `INTD`, six name words after G).
  `$FLASH` reads the whole file system as one file.  A missing file reads as not found.
* **Monitor** (`mon/mon.b`, built by `monitor_sonata.sh`): slot 2's program, run at reset and after any program started with `RUN` halts.  `DIR`, `CAT n`, `PUT n` (text up
  to ^D), `COPY a b`, `RUN n args` (the arguments go to the file `ARGS`).  `RUN` is `exec` (operate code 48): load the named program file and restart the machine with it.
* **Toolchain on the board**: `ST` (syntax + translation) reads `STDIN` and writes `OCODE`; `CG` reads `OCODE` and writes `INTCODE`; `ASM` (`mon/asm.b`, a BCPL port of
  icint's assembler) turns INTCODE text into a program file: `RUN ASM out [-STDINNAME] iclib.i blib.i prog.i`.  `COPY blib.b stdin`, `RUN ST`, `RUN CG`, `CAT INTCODE`.
* **Results on the board**: blib/syn/trn/cg compile in 2-6 s each (over serial it was 12-320 s), all identical to the kit compiler (`mon_chain.py`); `mon_bootstrap.py` does the
  whole bootstrap on the FPGA in 48 s -- compile, assemble ST1/CG1 from the result, compile again -- and stage 1, stage 2 and the C-hosted compiler agree byte for byte.
  The kit's own `cg.i` is stale (it was built from a `cg.b` with `VEC 4000`; the source has 8000), so references are made by running the kit compiler on the sources.
* Build and flash: `sonata_build.sh mon.int` once (the bitstream), then `monitor_sonata.sh [extra files]` (about 20 s); `IMAGE=dir monitor_sonata.sh` writes the disk image
  (monitor, programs, all compiler sources and headers) without touching the board.  The file-system area is append-only: a host reflash starts it afresh.

## Not done

* WIDTH 16.  The shipped INTCODE has the 32-bit word baked in (four characters to a word in `C` constants and in the library's byte routines; `WORDSIZE 32`
  in the assembler), so a 16-bit core needs the compiler's libraries and the assembler changed to two characters a word, and the whole bootstrap redone at that
  width.  That is the real test of whether the compiler is 16-bit clean.
* An assembler in the machine (the host's assembler is the loader here), a real UART/storage in place of `blib.c`, running on a board, a smaller core.
* Overlays: `st` (syntax and translation, 9,756 words) and `cg` (3,317 words) already run as two programs through the `OCODE` file; here each is simply loaded in turn.
