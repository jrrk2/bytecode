# TODO

## 32-bit native integers
Make an OCaml `int` 32 bits instead of 31 (idea from the user, 2026-10-08): bit 0 the tag, the integer in bits 32:1, the
collector's bits 35:33, pointers still even words.  The VM word becomes 33 bits.
* `Int_val`/`Val_int` and every arithmetic path mask to 33 bits so tagged arithmetic wraps at 2^32.
* The code-pointer marker (bit 31 today) moves to bit 32; `gc_points_to_from`, `Make_codeptr` and every `v[31]` test follow.
* Audit every `[31:0]` slice that means "the value" (trapsp, the bounds-error string, hash/compare helpers).  Check each change
  in Vivado, not only in Verilator: the `OFFSETCLOSURE` sign-extension bug was a width construct the two tools read differently.
* Headers, strings, bytes and floats are raw 32-bit words and do not change.
* Then drop the 31-bit work-arounds: the 16-bit register halves of the SD host, the 24-bit RFS offsets, the float-literal
  accumulation in `comp.ml`'s tokenizer, `bc2image`'s "wraps to 31 bits" warning, the 30-bit millisecond timer.
* Needs the full regress, new reference traces where a test overflows 31 bits, and a bitstream.  Do it on a branch, after the
  SD card works.

## Polymorphic comparison, and type hints in the spare bits
* The core has no `caml_equal`, `caml_compare` or `caml_hash` (`tools/check_prims.py` flags them).  Headers carry enough to
  walk a value (string/bytes tag: compare raw words; double tag: compare as float; closure tag: not comparable; else field by
  field), so these need a microcoded walk with its own stack in the RTL, or an ML library linked into `comp.ml`.  Until then
  the compiler must not use `=` on tuples or other structured values (see `dispatch_shape`).
* Tagged words as an early warning (the user's intent, 2026-10-08): give bits 35:34 a *kind* that the hardware checks on use, so a
  corrupted word traps at the instruction that used it: 00 integer (bit 0 set), 01 heap pointer, 10 code pointer, 11 invalid.
  Check at every dereference (base must be a heap pointer), at APPLY/RETURN/APPTERM/PUSHTRAP (code pointer), in integer
  arithmetic and comparisons (integer operands), and in the collector's scan.  A violation raises the bounds exception and
  freezes `vm_trace` at that record.  All producers are in the VM (allocation, closure creation, `Make_codeptr`, the
  collector's forwarding) plus the word-rebuilding places: `bc2image`, the loader's unmarshaller, I/O reads, C primitives.
  Make the full checks a mode (`#strict`), off for plain `ocamlc` programs that use `Obj.magic`; keep the kind-11 check always
  on.  It would have caught the `OFFSETCLOSURE` carry (a stray bit 34 on a closure pointer) at its first use.
* Separately, an advisory hint (as above, not the invariant check) could ride on the same bits; with the 32-bit-integer layout, use the spare bits 35:34 as an advisory 2-bit hint on immediates (int / char / bool or
  unit / constructor), set by `comp.ml` for char and bool constants, so that a generic printer shows `'a'` and `true` and a debug
  mode can trap a type-confused `=`.  Preserved by whole-word moves, dropped by arithmetic, I/O and C primitives; comparison must
  mask it; never relied on for correctness.

## Loader: safer unmarshalling (`io/netboot.ml` `strip_and_boot`, `tools/bc2image.ml`)
Today it checks the trailer and section table, bounds the staging space, rejects unsupported marshal codes and range-checks
shared-object references.  Missing:
* After unmarshalling, require that the read position equals the end of the DATA section and that the object count matches the
  header; reject otherwise.
* Record each block start as it is written, and check that every pointer value written (fields and globals) lands on one
  (including infix headers inside closure blocks); reject a pointer into the middle of a block.
* Integrity of the raw `.bc` path: the OCVM-image path has a CRC-16 and a primitive digest, the raw bytecode file has none, and
  TFTP over UDP gives no checksum (our client does not verify the UDP one).  Add a CRC-16 (or CRC-32) trailer from a small
  `tools/mkbc` step on the host, checked before stripping; also check the primitive table against the VM's.
* Once words carry kinds (see above), stamp heap pointers and code pointers as they are written, so a corrupted file fails in
  the loader and not minutes into a run.
* The same checks in `tools/bc2image.ml`, which writes the simulator's heap image.

## SD card
Done (`io/sd.ml`, `io/fat.ml`, `fpga/sd-lowrisc`): init, 4-bit mode at 15.6 MHz, multi-block read and write (CMD23 + CMD18/25), a FAT32
reader, `DISK.RFS` read and written in place, the loader's `sd(0,P)file` boot.  Remaining:
* Create files and grow them (`fat_store` only overwrites an existing file's clusters); long file names; subdirectories.
* The card as a first-class store for the channel functions: `sd(0,0)name` in `open_in` / `open_out` as `nfs(0,0)path` works.
* A faster copy between the card's block buffer and the RAM disk (the byte loop is now the limit, not the 15.6 MHz card), and
  trying a divisor of 0 (31 MHz is over the card's 25 MHz default speed; high-speed mode needs CMD6).
* Card detect at run time (hot swap), and a clear error when the card is absent or the volume is not FAT32.

## Network files
* `file_exists` for `nfs(U,P)` names; the calls wait inside the call and so only work in a UART session: make them work in a telnet
  or UDP session (a state machine resumed on the next poll, or a second TX window for the RPC traffic).
* Append and seek on a written NFS file (today `close_out` sends the whole scratch file); `nfs_write`-style directory operations
  (mkdir, remove, rename).
* NFS over TCP, and NFSv4, if a server ever refuses v3 over UDP.

## Code RAM: 128K words
**Why.**  The compiler compiled by itself no longer fits.  `io/comp.ml` self-compiled (host runner, `#image`) is 67,532 code
words against a code RAM of 65,535, and the REPL needs room above the image for the phrases it compiles.  By commit of `io/comp.ml`:
64,687 (a2a7f24) -> 65,126 (shared NFS client) -> 65,266 (`help`) -> 67,532 (NFS writes and `nfs(U,P)` names); ocamlc's own code for
the same source is about 46K.  Code density work (below) helps but is a long road; the part has block RAM to spare (853 of 1030 RAMB36
free before this).
**What.**  `fpga/vc707-ethmin/ethmin_vm_core.v`: `PROG_WORDS` 65536 -> 131072 (`prog_code` is 64 inferred x1 tiles, so 128: +64 RAMB36); the
fetch and second-port indexes `prog_code[fetch_pc[15:0]]` and `[pc_paddr]` to 17 bits; `prog_words` (17 bits, the 0x100c register, `set_pw_val`,
`fetch_in_range`) to 18; the sequencer's code load address and the lengths the loader gives it (0x1010..); the Verilator model in
`main_rtl.cpp`; `io/netboot.ml` `code_max` and its checks; `tools/mkvmimage.py`, `tools/progimage.sh` and the image header's limits;
`io/comp.ml`'s doorway and emission limits.  The resident code ROM stays 32K words.
**Check.**  Simulate an image with more than 64K words of code end to end (the stage-1 image from `#image` is the test), including the
out-of-range fetch exception at the new limit; then on the board the stage-1 compiler should boot from NFS/SD, and compile `io/comp.ml`
again (stage 2) with an identical image.  Watch timing: the code read mux gets one more level (see the next item).  The 512 KiB RAM disk
cannot hold the source and two 280 KB images at once for stage 3 either; the DDR3 disk or a bigger on-chip one is the way.

## 100 MHz
**State.**  The board builds run at 62.5 MHz (`VM_DEFS="SYS_DIV=16.000 CLK_HZ=62500000"`).  spec23: worst setup slack +1.10 ns on the 16 ns clock.
The worst path is block RAM to block RAM inside the heap: `core/vm/heap_mem_reg_4_20` to `heap_mem_reg_6_10/ADDRARDADDR[13]`, 14.4 ns of data
path of which 10.8 ns is routing (75%) and 3.7 ns logic; the heap is 288 tiles (8 depth blocks x 36 bits, `HEAP_AW` 18) spread over the part.
At 100 MHz (10 ns) spec10 (heap 256K words) missed by 1.7 ns; a 4x larger heap once cost 0.7 ns.  The heap has to stay 256K words (a
self-compile peaks near 100K live words in a 128K semi-space).
**Ideas, roughly in order.**
* Pipeline the heap: register the RAM outputs (and the address) and give the VM FSM the extra state where it waits for a read, since the
  routing, not the logic, is the cost.  Find how many states already wait a cycle for `heap_q`.
* Place the heap tiles together (a pblock over a few clock-region columns) or build the 64K x 1 depth-4 cascade from explicit `RAMB36E1`
  with `CASCADEOUT`/`CASCADEIN` (explicit instantiation is the rule for FPGA-only IP), so the depth mux is in the RAM column and not in fabric.
* The same for `prog_code` once it is 128 tiles, `stack_mem`, `disk_ram` and `stage_ram` (check what comes up after the heap path is fixed).
* A stepping stone: 80 MHz, to see what is next.  Vivado: `Performance_ExplorePostRoutePhysOpt`, `phys_opt_design -directive AggressiveExplore`.
* The clock is a constant in several places: `CLK_HZ` / `SYS_DIV`, the UART divisor, the millisecond timer (0x1006), the SD clock divider
  (`clk / (2 (div + 1))`: divisor 1 gives 25 MHz at 100 MHz, over the card's default-speed limit: use 2), the Ethernet clock crossing.  Re-check
  each and the generated-clock constraints (`sd_clk`) at the new frequency.
Target: a bitstream at 100 MHz with the heap at 256K words and the code RAM at 128K words, timing met, regression green.

## Compiler
* Tail calls (`APPTERM`) in `io/comp.ml`: deep tail recursion overflows the stack at about 4000 levels, and it would save
  code words.
* Code density: the self-compiled `comp.ml` is 67,532 words against ocamlc's ~46K (see Code RAM above).  Where it goes is unmeasured:
  count code words per top-level phrase in `#image` mode and look at the largest, and at closure creation and field access sequences.
* Move the NFS client out of the resident compiler into a library loaded with `run_file` (about 4K words), if the code RAM is not widened.
* Gate the `DEBUG_TRACE` letters (G D S O H P Q F a e h s g, X) off by default; they show in the console output.
* Stage 3: compile the board-built compiler with itself and compare, once the RAM disk can hold three 265 KB images.

## Memory
* DDR3 disk, phases 2 and 3 (`fpga/vc707-ddr3-serv`): the write-back cache is written but its simulation never finished.
* A hardwired-compiler bitstream (the compiler in the ROM, no loader, no network) as a regression check that starts from the
  same RAM state as the simulator.
* RFS: offsets are 24 bits (16 MB); widen for a 1 GB disk.

## Tooling
* `tools/regress.sh` at the board's sizes (stack 32K, heap 64K words) now that they are the RTL defaults.
* Commit the repository to a remote; there is none.
