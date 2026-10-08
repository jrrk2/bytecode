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
