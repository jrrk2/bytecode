# The OCaml bytecode VM as a LiteX CPU, and MirageOS on it

*Survey, 2026-09-21.*  Could the hardware OCaml 4.14 bytecode interpreter
(`ocaml4142_vm_rtl.sv`) become a CPU choice in a LiteX SoC, and could that
SoC boot a MirageOS unikernel?  Yes to both, as a staged programme; this
records what the block is, what LiteX and Mirage need from it, and the
order the work would go in.

## What the block is today

- A 32-bit OCaml 4.14 bytecode interpreter (`VALUEW = 32`): two-port
  memories, two-phase reads, a Cheney copying GC over a block-RAM heap.
- Memories in block RAM: 32K-word code ROM, 32K-word heap and stack, 8K
  globals.  The `ddr-cache` branch has a 4-way write-back cache and a
  DRAM model but nothing behind the VM yet.
- 16 runtime primitives in hardware (`caml_string_*`, `caml_bytes_*`,
  `caml_array_*_addr`, `caml_obj_dup`, the `caml_ml_output_char` and
  descriptor stubs) and a **trap interface** (`trap_valid`, `trap_prim`,
  `trap_arg0..1`, `trap_result`) the surrounding core services -- today
  for `vm_io_read`/`vm_io_write` only.  Programs link against the full
  405-entry primitive table (`ocamlrun -p`); anything outside the 16 plus
  traps is unimplemented.
- Throughput: `fib 18` in 249 ms at 100 MHz, about 1 M bytecode
  instructions/s, ~100 clocks per instruction -- some 200x slower than
  `ocamlrun` on a desktop.
- I/O: UART, a 1 GbE MAC with DMA and a 4 KB packet window, driven by
  OCaml (`io/netboot.ml` does DHCP, ARP and TFTP; `io/repl.ml` a UDP REPL).

## As a LiteX CPU choice

Mechanically possible; the interesting parts are where LiteX's assumptions
do not hold.

1. **Bus master.**  LiteX CPUs are Wishbone/AXI masters over a flat
   address space.  The VM's memories are dedicated ports.  Needed: heap,
   code and stack behind one cached Wishbone master (a unikernel's
   bytecode is megabytes, so code must leave the ROM), and the I/O trap
   translated to Wishbone/CSR accesses so LiteX peripherals (UART, timer,
   LiteEth, SD, LiteDRAM's own controller) are reachable.  The trap
   already has the shape of a bus transaction.
2. **The software flow.**  LiteX assumes a C toolchain: `gcc_triple`, a
   BIOS in C (memtest, netboot, `boot.json`), `linker.ld`, `crt0`.  There
   is no C compiler for OCaml bytecode, so the CPU class declares no
   toolchain and supplies its own BIOS: the OCaml loader, which already
   netboots; memtest and `boot.json` are small additions.  LiteX has
   precedent for CPUs whose software is built elsewhere (`CPUNone`, the
   hard-CPU wrappers): a `CPU` subclass with `gcc_triple = None`, a
   `software` step that runs `tools/progimage.sh`, and `mem_map` entries
   pointing at the OCaml images.  `litex_sim` works once the bus wrapper
   exists.
3. **Interrupts and timers.**  The VM has none; everything is polled.
   Mirage's scheduler is content with polling plus a monotonic clock (the
   `ms` counter exists; a 64-bit cycle counter is trivial); LiteX's
   `timer0` and `uart` can be polled over CSR.  A real interrupt line can
   come later, as a trap raised between instructions.
4. **Effort.**  Bus wrapper, cache integration, the CPU class and the
   OCaml BIOS: weeks of engineering with no unknowns.  The DDR branch is
   the critical path.

## Booting MirageOS

Mirage 4 supports OCaml 4.14, so the bytecode format matches.  What a
unikernel needs beyond what the VM has:

- **Runtime primitives.**  Mirage code leans on `caml_compare` and
  `caml_hash` (polymorphic compare and hash, large C functions),
  `caml_alloc_dummy`/`caml_update_dummy` (recursive definitions),
  `caml_make_vect`, `caml_blit_*`, floats (boxed; every operation is a
  primitive and the VM has no float unit), boxed `Int32`/`Int64`,
  `caml_obj_*`, `caml_sys_*`, and -- the largest -- **bigarrays**
  (`caml_ba_*`), on which `cstruct` and therefore `tcpip`, `ethernet` and
  `mirage-net` are built.  Some 60-80 primitives, implementable in three
  tiers: in hardware, as the 16 today; in OCaml itself running on the VM
  (compare, hash, blit and most of `Obj` are expressible over `Obj.t` --
  an OCaml-in-OCaml runtime); or as traps to a small helper (a picorv32
  beside the VM servicing traps is the pragmatic escape hatch, and LiteX
  makes it easy).  Bigarrays need the memory-mapped heap first: a custom
  block whose data lives in DDR.
- **A Mirage target.**  Mirage runs on a target that provides console,
  clock, network and block devices through a thin OS layer (`hvt`, `spt`,
  `xen`, `unix`).  Ours would be `ocamlvm`: console over UART traps, clock
  over the cycle counter, `mirage-net` over the DMA packet window
  (memory-mapped: length, frame, ack -- the loader does this in about a
  hundred lines), block over LiteX SD or a RAM disk.  Registering a target
  in `mirage`/`functoria` is well trodden.  The OCaml-side libraries suit
  a bytecode-only world better than most: `mirage-tcpip` is pure OCaml
  apart from a checksum stub, `checkseum` and `digestif` have pure-OCaml
  variants, `lwt`'s core is pure.  `mirage-crypto` and TLS are C and out
  of reach; plain HTTP is not.
- **Memory.**  A minimal network unikernel wants 8-32 MB of heap; 32-bit
  OCaml over 1 GB of DDR is fine.  The GC should become generational or
  incremental to avoid multi-second Cheney copies over DDR -- or the
  pauses are accepted at first.
- **Speed.**  At ~1 M instructions/s, boot (module initialisers, ~1e8
  instructions) is minutes, and pure-OCaml TCP/IP is tens of kbit/s.  A
  demonstration, not an appliance, unless the interpreter is reworked to
  ~10 clocks/instruction: pipelined fetch/decode, single-cycle stack
  operations, a register-cached top of stack.  That rework is where most
  of the engineering interest lies, and the DDR cache makes it matter
  more, not less.

## Stages

1. DDR-backed heap, code and stack behind a Wishbone master (the
   `ddr-cache` branch).
2. A LiteX CPU class with the OCaml loader as BIOS: a LiteX SoC that
   netboots OCaml programs.
3. Primitives in three tiers, bigarrays last: the VM runs ordinary OCaml
   libraries.
4. An `ocamlvm` Mirage target with net, console and clock.
5. A hello-world unikernel, then `mirage-tcpip` answering a ping.

Interpreter performance work runs alongside.  Each stage is independently
useful, and none depends on the open-flow Ethernet fault: that decides
only whether the SoC's Ethernet comes from the open flow or from Vivado in
the meantime.
