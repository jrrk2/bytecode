#!/usr/bin/env python3
"""intcode_send.py : assemble an INTCODE program and load it into the INTCODE machine over its UART loader (loader.int), then run it.

    intcode_send.py prog.int --port /dev/ttyUSB5            load, run, and show what it prints (Ctrl-C to leave; typed lines go to it)
    intcode_send.py prog.int --commands out.txt             write the loader's command stream to a file instead (for the simulation)
    intcode_send.py prog.int --hex out.hex                  write the assembled store (words 0 .. end) as 8-digit hex, one a line

The assembler is icint.c's, as it was in bcplkit: the same location counter from word 402, the same label chains, the same packing of characters (four
to a 32-bit word, first character in the high byte), a start-up stub at 402 (LIG1, K2, X22) -- so that the store it builds is word for word what icint
and tb_intcode build.  The loader's protocol is "W aaaaaaaa dddddddd" (store a word) and "G pppppppp" (P := p, jump to 402), all hex."""
import argparse, sys, time

IBIT, PBIT, GBIT, DBIT, ABITS, FSHIFT = 0o10000, 0o4000, 0o2000, 0o1000, 0o777, 13
LIG1, K2, X22 = 0o12001, 0o140002, 0o160026
MPROG, MGLOB = 402, 1

def assemble(text, base=MPROG):
    M = [0] * 65536
    P = base
    if base == MPROG:
        M[P] = LIG1; M[P + 1] = K2; M[P + 2] = X22; P += 3
    labv = [0] * 501
    pos = 0
    ch = 0
    cp = 0

    def rch():
        nonlocal pos, ch
        while True:
            ch = ord(text[pos]) if pos < len(text) else -1
            pos += 1
            if ch != 47:                       # '/' starts a comment to the end of the line
                return
            while True:
                ch = ord(text[pos]) if pos < len(text) else -1
                pos += 1
                if ch == 10 or ch == -1:
                    break

    def rdn():
        nonlocal ch
        a, neg = 0, False
        if ch == 45:
            neg = True; rch()
        while 48 <= ch <= 57:
            a = 10 * a + ch - 48; rch()
        return -a if neg else a

    def stw(w):
        nonlocal P, cp
        M[P] = w; P += 1; cp = 0

    def stc(c):
        nonlocal cp
        if cp == 0:
            stw(0); cp = 32
        cp -= 8
        M[P - 1] += c << cp

    def setlab(n):
        k = labv[n]
        if k < 0:
            print("L%d ALREADY SET TO %d AT P = %d" % (n, -k, P), file=sys.stderr)
        while k > 0:
            nxt = M[k]; M[k] = P; k = nxt
        labv[n] = -P

    def labref(n, a):
        k = labv[n]
        if k < 0: k = -k
        else: labv[n] = a
        M[a] += k

    rch()
    funcs = {'L': 0, 'S': 1, 'A': 2, 'J': 3, 'T': 4, 'F': 5, 'K': 6, 'X': 7}
    while True:
        if ch == -1:
            break
        c = chr(ch)
        if c.isdigit():
            setlab(rdn()); cp = 0; continue
        if c in '$ \n':
            rch(); continue
        if c == 'C':
            rch(); stc(rdn()); continue
        if c == 'D':
            rch()
            if ch == ord('L'):
                rch(); stw(0); labref(rdn(), P - 1)
            else:
                stw(rdn())
            continue
        if c == 'G':
            rch(); a = rdn() + MGLOB
            if ch == ord('L'): rch()
            M[a] = 0; labref(rdn(), a); continue
        if c == 'Z':
            for n in range(501):
                if labv[n] > 0: print("L%d UNSET" % n, file=sys.stderr)
            labv[:] = [0] * 501; cp = 0; rch(); continue
        if c not in funcs:
            print("BAD CH %r AT P = %d" % (c, P), file=sys.stderr); rch(); continue
        w = funcs[c] << FSHIFT
        rch()
        if ch == ord('I'): w += IBIT; rch()
        if ch == ord('P'): w += PBIT; rch()
        if ch == ord('G'): w += GBIT; rch()
        if ch == ord('L'):
            rch(); stw(w + DBIT); stw(0); labref(rdn(), P - 1)
        else:
            a = rdn()
            if (a & ABITS) == a: stw(w + a)
            else: stw(w + DBIT); stw(a)
    return [m & 0xFFFFFFFF for m in M[:P]], P

def commands(words, pend):
    out = []
    for a, w in enumerate(words):
        out.append("W%08x%08x\n" % (a, w))
    out.append("G%08x\n" % pend)
    return "".join(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prog")
    ap.add_argument("--port"); ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--commands"); ap.add_argument("--hex")
    ap.add_argument("--flash", help="the program as the software-flash image intcode_sys reads at reset: magic INTC, word count, C, P, G, then the words (little-endian)")
    ap.add_argument("--uf2", help="the same as a software UF2 for the Sonata's RP2040 (family 0x6CE29E60, address by --slot)")
    ap.add_argument("--slot", type=int, default=2, help="software slot for --uf2 (1, 2 or 3; the design reads slot 2, at 10 MiB, by default)")
    ap.add_argument("--stdin", help="the file (in the flash file system) the program reads as its standard input; default STDIN")
    ap.add_argument("--image", help="the whole 32K-word store as hex, one word a line, with the start registers in its top three words (for patch_sonata.sh)")
    ap.add_argument("--listen", type=float, default=0, help="after loading, show output for this many seconds and leave (default: until Ctrl-C)")
    a = ap.parse_args()
    words, pend = assemble(open(a.prog).read())
    if a.flash or a.uf2:
        import struct
        body = b"".join(struct.pack("<I", w) for w in words)
        if a.stdin is not None:           # magic INTD: six words of the name, as BCPL packs a string, follow G
            from intcode_fs import pack_name
            blob = struct.pack("<5I", 0x494E5444, len(words), MPROG, pend, MGLOB) + pack_name(a.stdin) + body
        else:
            blob = struct.pack("<5I", 0x494E5443, len(words), MPROG, pend, MGLOB) + body
        if a.flash:
            open(a.flash, "wb").write(blob); print("%d bytes (%d words) to %s" % (len(blob), len(words), a.flash))
        if a.uf2:
            base = (a.slot - 1) * 0x10000000
            nblk = (len(blob) + 255) // 256
            with open(a.uf2, "wb") as f:
                for n in range(nblk):
                    payload = blob[n * 256:(n + 1) * 256]
                    payload += bytes(476 - len(payload))
                    f.write(struct.pack("<8I", 0x0A324655, 0x9E5D5157, 0x2000, base + n * 256, 256, n, nblk, 0x6CE29E60) + payload + struct.pack("<I", 0x0AB16F30))
            print("%d blocks to %s (slot %d, address 0x%x)" % (nblk, a.uf2, a.slot, base))
        return
    if a.image:
        store = words + [0] * (32768 - len(words)); store[32765], store[32766], store[32767] = MPROG, pend, MGLOB
        open(a.image, "w").write("".join("%08x\n" % w for w in store)); print("%d words (+ start registers) to %s" % (len(words), a.image)); return
    if a.hex:
        open(a.hex, "w").write("".join("%08x\n" % w for w in words)); print("%d words to %s" % (len(words), a.hex)); return
    text = commands(words, pend)
    if a.commands:
        open(a.commands, "w").write(text); print("%d words, %d characters to %s" % (len(words), len(text), a.commands)); return
    import serial, select
    s = serial.Serial(a.port, a.baud, timeout=0.1)
    s.reset_input_buffer()
    t0 = time.time()
    b = text.encode()
    for k in range(0, len(b), 256):
        s.write(b[k:k + 256]); s.flush()
        if k % 16384 == 0: print("\r%d/%d" % (k, len(b)), end="", file=sys.stderr, flush=True)
    print("\rloaded %d words in %.1f s" % (len(words), time.time() - t0), file=sys.stderr)
    end = time.time() + a.listen if a.listen else None
    try:
        while end is None or time.time() < end:
            d = s.read(256)
            if d: sys.stdout.write(d.decode("latin-1")); sys.stdout.flush()
            if sys.stdin.isatty() and select.select([sys.stdin], [], [], 0)[0]:
                s.write(sys.stdin.readline().replace("\n", "\r").encode())
    except KeyboardInterrupt:
        pass

main()
