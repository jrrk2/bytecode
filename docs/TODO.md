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
* Later, with the 32-bit-integer layout, use the spare bits 35:34 as an advisory 2-bit hint on immediates (int / char / bool or
  unit / constructor), set by `comp.ml` for char and bool constants, so that a generic printer shows `'a'` and `true` and a debug
  mode can trap a type-confused `=`.  Preserved by whole-word moves, dropped by arithmetic, I/O and C primitives; comparison must
  mask it; never relied on for correctness.

## SD card
* CMD0/CMD8, then ACMD41, CMD2/3/7, CMD17 reads, 4-bit mode; ML block layer; a small FAT32 reader; `DISK.RFS` as the
  persistent RAM-disk volume, read and written in place; load from the card at power-on, fall back to the network.

## Compiler
* Tail calls (`APPTERM`) in `io/comp.ml`: deep tail recursion overflows the stack at about 4000 levels, and it would save
  code words.
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
