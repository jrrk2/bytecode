#!/usr/bin/env python3
"""fasm_patch_mem.py : put a new program into the block-RAM store of an already routed INTCODE design, by rewriting its FASM.

    fasm_patch_mem.py base.fasm placement.json image.hex out.fasm

The design (intcode_sys.v) keeps its 32K-word store in RAMB36s, one per bit of the word, each 32K x 1: the cell named sys.mem.0.K holds bit K.  In the
FASM a RAMB36 appears as the two RAMB18 halves of its tile, RAMB18_Y0 holding the even addresses and RAMB18_Y1 the odd ones, 256 bits to an INIT_nn
line (nn = 00..3F), address 0 at the right-hand end of the 256-bit string.  (Derived by comparing the synthesized netlist's contents with the FASM for three
cells; the self-test below re-derives nothing but checks the result.)  image.hex is the whole store, 32768 words, one hex word a line, as intcode_send.py
--image or tb_intcode with INTCODE_DUMP write it.  Placement and routing are untouched, so the patched FASM converts to a bitstream in seconds."""
import json, re, sys

def main():
    fasm_in, place_in, hex_in, fasm_out = sys.argv[1:5]
    place = json.load(open(place_in))
    cells = {}                                       # tile -> bit
    for name, c in place.items():
        m = re.fullmatch(r"sys\.mem\.0\.(\d+)", name)
        if m and c.get("type", "").startswith("RAMB36"):
            cells[c["tile"]] = int(m.group(1))
    words = [int(l, 16) for l in open(hex_in) if l.strip()]
    if len(words) != 32768:
        sys.exit("%s has %d words, not 32768" % (hex_in, len(words)))
    nbits = max(cells.values()) + 1
    if sorted(cells.values()) != list(range(nbits)):
        sys.exit("memory cells do not cover bits 0..%d: %s" % (nbits - 1, sorted(cells.values())))
    # per tile, per half, the 64 INIT rows
    rows = {}
    for tile, bit in cells.items():
        plane = [(w >> bit) & 1 for w in words]
        for y, half in (("RAMB18_Y0", plane[0::2]), ("RAMB18_Y1", plane[1::2])):
            for nn in range(64):
                chunk = half[256 * nn:256 * nn + 256]
                rows[(tile, y, nn)] = "".join(str(b) for b in reversed(chunk))
    pat = re.compile(r"^(\S+)\.(RAMB18_Y[01])\.INIT_([0-9A-F]{2})\[255:0\] = 256'b[01]{256}$")
    n = 0
    with open(fasm_in) as f, open(fasm_out, "w") as out:
        for line in f:
            m = pat.match(line.rstrip("\n"))
            if m and (m.group(1), m.group(2), int(m.group(3), 16)) in rows:
                line = "%s.%s.INIT_%s[255:0] = 256'b%s\n" % (m.group(1), m.group(2), m.group(3), rows[(m.group(1), m.group(2), int(m.group(3), 16))])
                n += 1
            out.write(line)
    expect = len(cells) * 128
    if n != expect:
        sys.exit("rewrote %d INIT lines, expected %d (%d RAMs x 2 halves x 64 rows)" % (n, expect, len(cells)))
    print("%d memory bits (%d RAMs), %d INIT lines rewritten" % (nbits, len(cells), n))

main()
