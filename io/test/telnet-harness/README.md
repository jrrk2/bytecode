# Testing io/telnet.ml against another TCP

`harness.ml` builds a mirage-tcpip stack and the device's own TCP
(`io/telnet.ml`, its hardware block replaced by `host_hw.ml`'s simulated
packet window) on two ports of a mirage-vnetif backend, then connects from
the mirage side to port 23, types lines and prints what came back.  An
independent implementation is the peer, so the handshake, the ACKs, the
telnet negotiation and the close are all checked against something that
did not come from the same head.

    opam switch 4.14.2         # tcpip 6.4.0, ethernet 2.2.1, mirage-vnetif
    ./prepare.py               # telnet_core.ml from ../../telnet.ml
    dune exec ./harness.exe    # the session; `harness.exe big` pastes long lines

It writes `session.frames`, every frame the peer sent.  `replay.bc` feeds
those to the device logic with nothing else running, so
`OCAMLRUNPARAM=t=2 ocamlrund _build/default/replay.bc` counts the bytecode
instructions one telnet session costs (see docs/minimal-tcp.md).
`bench.bc` does the same for the checksum, the echo path and the copy into
the transmit window, one byte at a time.
