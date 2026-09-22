# A TCP small enough for this processor

*2026-09-22.*  `docs/tcpip-on-the-processor.md` measured what MirageOS's
`tcpip` would cost here: 9,830 bytecode instructions per KB per traversal,
109 C primitives the processor does not have, 436 KB of bytecode.  That is
the stack to aim at once the core and the memory system are upgraded.  For
*now* -- an interactive session with a telnet client -- the same idea fits
in one file.

`io/telnet.ml` is a complete, if minimal, TCP: DHCP, ARP and ICMP as
`io/dhcp.ml`, then one connection at a time on port 23 with a small command
shell behind it.

    $ telnet 10.10.10.60
    OCaml processor on an FPGA.  Type "help".
    > time
    1843 ms since reset
    > echo hello
    hello
    > quit

## What it implements

A passive open and the three-way handshake; in-order data with an
immediate ACK; one outstanding segment with a 400 ms retransmission timer;
FIN in both directions; RST for anything it cannot place (including a
second client while one is connected).  Telnet option negotiation is
three lines: WILL ECHO and WILL SUPPRESS-GO-AHEAD, so the client sends
each keystroke, and a refusal for everything it offers.

What it does not implement, deliberately: reassembly (an out-of-order
segment is dropped and re-ACKed, so the peer retransmits), window scaling,
timestamps, congestion control beyond one segment in flight, a second
connection, or an active open.  For a person typing at a terminal none of
these change anything.

**Sequence numbers.**  A sequence is 32 bits and this processor's `int` is
31, so a sequence is a two-element array of 16-bit halves and all the
arithmetic -- add, compare, difference -- is 16-bit.  `seq_diff`
saturates outside ±32767, which is exact for every comparison the code
makes (everything it decides is about numbers a window apart).

**Primitives.**  The whole program uses only the sixteen the processor
already implements in hardware: `caml_array_get_addr`/`set_addr`,
`caml_bytes_get`/`set`, `caml_create_bytes`, `caml_string_get`,
`caml_ml_string_length`, `caml_ml_bytes_length`, `caml_string_equal` and
the I/O traps.  No bigarrays, no `Int32`, no polymorphic compare, no
floats.

## Tested against another TCP

`io/test/telnet-harness` builds a **mirage-tcpip** stack and this code on
two ports of an in-memory network (mirage-vnetif), in one process: the
mirage side opens the connection, types lines and reads the answers, so
the handshake, the ACKs, the negotiation and the close are checked against
an implementation that did not come from the same head.  The session it
prints is the one above, including the `IAC WILL ECHO` bytes and a clean
FIN exchange.

## What it costs

Every frame of that session is recorded and replayed with nothing else
running, counted with `ocamlrund`'s instruction trace:

| | instructions |
|---|---|
| a telnet session (14 frames: open, four commands, close) | 71,516 |
| **per interactive packet** (60-100 bytes) | **≈ 5,100** |
| per byte of bulk data | ≈ 117 |

Per byte, split by what does the work (measured one byte at a time):

| instructions/byte | |
|---|---|
| 22.5 | the TCP checksum (a `vm_io_read` per byte, folded 16 bits at a time) |
| 63.3 | the telnet and echo path (per received character) |
| 26.0 | copying a byte into the transmit window |

At today's ~1 M instructions/s that is **5 ms to answer a keystroke** --
interactive by any standard -- and about 8 KB/s if someone pastes.  A core
at 10 clocks per instruction makes it 0.5 ms and 70 KB/s; the echo path
(63 instructions per character, for a bounds-checked append and an echo)
is the first thing to tighten if bulk matters, and the checksum is the
obvious thing for the MAC to do instead.

Against the measured `tcpip` figures: **5,100 instructions per packet
here, against 3,400 per packet per stack there** -- the same order, for a
stack that fits in 6,141 words of code (24 KB, in the 32 K-word ROM) and
needs no primitive the processor lacks.  What `tcpip` buys for its 436 KB
and its 109 primitives is everything this leaves out: reassembly, windows,
congestion control, IPv6, a real socket API -- and that is the right trade
once the memory system can hold it.

## On the board

*2026-09-22.*  `io/replnet.ml` -- repl.ml's mini-ML with this TCP behind it --
netbooted onto the VC707 through the open flow (yosys, nextpnr, prjxray):

    $ telnet 10.10.10.60
    OCaml processor: mini-ML over telnet.  ^C clears the line.
    # let rec f x = if x <= 0 then 1 else f (x-1) * x
    val f = <fun>
    # f 6
    - = 720

Character-at-a-time, the echo and the line editing done on the board, the
whole stack -- handshake, ACKs, retransmission, FIN -- in OCaml bytecode on
a processor whose native instruction set is OCaml bytecode.

## Running it

    tools/progimage.sh io/telnet.ml <outdir>      # for a bitstream's ROM
    python3 tools/mkvmimage.py <outdir> vm.img    # for netboot

The netboot loader fetches `vm.img` from the TFTP server the DHCP reply
names (or 10.10.10.10), stages it and starts it; the board then answers
ARP, ping and `telnet <its address>`.  The UART prints the DHCP lease and
each connection, and anything typed at the UART goes to the connected
client.
