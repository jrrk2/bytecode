# mirage-tcpip on the OCaml processor: what it would cost

*Measured, 2026-09-22.*  Is `tcpip` (the MirageOS TCP/IP stack,
<https://ocaml.org/p/tcpip/6.4.0/>) a plausible network stack for an
upgraded version of this hardware?  This is not an estimate: the stack was
built for OCaml 4.14, run for real, and every number below comes from a
measurement of the bytecode it executes.

## The experiment

`~/bytecode-work/tcpip-survey` builds two complete stacks --
`Vnetif` → `Ethernet.Make` → static ARP → `Static_ipv4.Make` →
`Tcp.Flow.Make` -- inside one process on mirage-vnetif's in-memory
backend, opens a TCP connection between them, sends N KB, echoes it back
and closes.  It runs as **bytecode**, so the work is exactly what this
processor would execute.  `ocamlrund`'s instruction trace
(`OCAMLRUNPARAM=t=2`) counts every bytecode instruction and every C
primitive call; `Gc.stat` gives the allocation.

Payloads of 1-256 KB, fitted:

| quantity | measurement |
|---|---|
| connection + stack init + teardown | **304,000 instructions** (one-off) |
| per KB echoed (4 stack traversals: tx, rx, tx, rx) | **39,300 instructions** |
| per KB per stack traversal | **9,830 instructions** = 9.6 per byte |
| per Ethernet frame, marginal (1448 B payload) | **6,877** (3,439 per stack) |
| allocation | 5,046 words/KB echoed ≈ **5 KB per KB per traversal** |
| live heap after 256 KB | 80 KB; peak heap 500 KB |
| stack's bytecode | **436 KB** of CODE (+22 KB DATA), stdlib included |

Where the instructions go (16 KB echo, 946,402 instructions):

| share | kind |
|---|---|
| 52.4 % | stack and environment access (`ACC`, `PUSHACC`, `ENVACC`) |
| 18.9 % | calls, returns, closures (`APPLY`, `RETURN`, `GRAB`, `CLOSURE`) |
| 11.7 % | field and global access (`GETFIELD`, `GETGLOBALFIELD`) |
| 7.4 % | control flow |
| 5.8 % | integer and constant |
| 1.9 % | C primitives (18,199 calls) |
| 1.6 % | allocation (`MAKEBLOCK`) |

## What that means on this hardware

At today's ~1 M instructions/s (≈100 clocks per instruction at 100 MHz):

- **0.4 Mbit/s** through one stack doing receive and transmit, and a
  connection takes **0.3 s** to set up.  A telnet-like service or a
  low-rate UDP/TCP control channel is comfortable; bulk transfer is not.
- At **10 clocks/instruction** (pipelined fetch/decode, a register-cached
  top of stack -- the rework the LiteX survey already identifies):
  **4 Mbit/s**.  At 2 clocks/instruction: **20 Mbit/s**.

The profile says where the clocks go, and it is not the protocol: **71 %
of all instructions are stack/environment access and calls**.  That is the
OCaml calling convention, not TCP.  A core that makes `ACC`/`PUSHACC`
single-cycle from a register-cached stack top, and `APPLY`/`RETURN`/`GRAB`
cheap, wins on the whole workload at once.  Nothing in the profile argues
for protocol-specific hardware.

## Primitives: the real gate

The run calls **124 distinct C primitives, 18,199 times**; the processor
implements 15 of them.  By implementation tier:

| calls | primitives | tier |
|---|---|---|
| 11,869 | 38 | **hardware, a load/store or ALU op**: `caml_ba_get_1`/`set_1`, `caml_ba_uint8_get16/32`, `caml_ba_dim_1` (Cstruct's byte and word access), `caml_int32_*` (boxed Int32 arithmetic -- sequence numbers), `caml_bswap16`, `caml_int32_bswap`, `caml_string_compare`, `caml_int_compare` |
| 676 | 8 | **block moves**: `caml_blit_*`, `caml_fill_bigstring` -- microcode or a DMA-ish helper |
| 2,186 | 20 | **OCaml itself**: `caml_compare`, `caml_hash`, the polymorphic comparisons, `caml_obj_*`, `caml_alloc_dummy`/`update_dummy` -- expressible over `Obj.t`, no C needed |
| 110 | 2 | `mirage_tcpip_ones_complement_checksum[_list]` -- the stack's only own C |
| 72 | 18 | `caml_sys_*`, `caml_ml_*`, `caml_register_named_value` -- traps to the core services |

So: **roughly 40 primitives in the datapath, 8 block moves, 20 in OCaml,
20 as traps** and the stack runs.  Two observations decide the design:

- **Cstruct is a bigarray.**  Every header field read or written is a
  `caml_ba_*` call; 3,545 of the 18,199 calls are bigarray access.  A
  bigarray whose data lives in the memory the processor already addresses --
  a custom block with the data words inline -- turns each of these into a
  single load or store.  Without that, the stack is unusable, not slow.
- **The checksum must not be OCaml.**  Written in OCaml over a Cstruct it
  costs **23,552 instructions/KB** -- more than doubling the cost of a
  traversal that checksums once in each direction.  In hardware it is a
  few hundred clocks per packet; better still, the MAC already computes
  it, so the stub becomes "read the MAC's answer".

`Int32` is the other quiet expense: TCP sequence arithmetic is `Int32`,
every operation allocates a boxed value and calls a primitive (3,922
calls).  Unboxed `Int32` in the datapath (a 32-bit machine's natural
word) removes an entire class of work.

## Memory

436 KB of bytecode for the stack alone, against the 32 K-word (128 KB)
code ROM: **code must come from DDR through the cache** (the `ddr-cache`
branch), which the LiteX survey already puts first.  The data side is
mild: 80 KB live, 500 KB peak, and about 5 KB allocated per KB of traffic
per traversal -- a Cheney collector over a few MB of DDR copes, though a
generational one would keep the pauses off the wire.

## Versions

Measured against **tcpip 6.4.0** with OCaml 4.14.2 (cstruct 6.0.1,
ethernet 2.2.1, mirage-protocols 6.x).  tcpip 7.x/8.x drop
`mirage-protocols` for direct `mirage-net`/`Mirage_mtime` signatures and
move to newer cstruct; 9.0 is current.  Nothing in the measurements is
version-specific -- the profile is the OCaml calling convention and
Cstruct -- but a port should target whichever version the Mirage release
being used wants, and 6.4.0 is the last of the `mirage-protocols` line.

## Verdict

Suitable, with three prerequisites and one rework:

1. **Bigarray-backed Cstruct in the processor's memory** (custom blocks with
   inline data, `caml_ba_*` in the datapath).  Without it, no.
2. **Checksum in hardware or from the MAC.**
3. **Code out of ROM into DDR** -- 436 KB of bytecode.

Then ~40 datapath primitives, 20 written in OCaml and 20 traps bring the
stack up, and it will answer pings, serve a REPL, and move a few hundred
kbit/s.  The **core rework** (stack/environment access and calls, 71 % of
the profile) is what turns that into megabits; it is the same rework the
LiteX/Mirage survey identifies, and this measurement says exactly which
instructions to spend the silicon on.
