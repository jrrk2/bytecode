#!/usr/bin/env python3
"""bcpl_console.py : drive a BCPL compiler phase (st.int or cg.int) running on the INTCODE system through its console.

    bcpl_console.py expand  src.b  [--hdrdir DIR]         the text to send for st: src.b with each GET "X" followed by the text of X and an EOT, and an EOT at the end
    bcpl_console.py ocode   src.b  --port P [--hdrdir D]  send that to the board (running st) and write the OCODE it produces to OCODE.board
    bcpl_console.py split   captured.bin                   print the file text (between STX and ETX) from a capture, and the messages separately

Protocol (intcode_sys.v): the program's input is the UART; byte 0x04 is end of stream; findinput/findoutput give streams 3/4, both the UART, and while stream 4 is
selected the output is bracketed by 0x02 and 0x03."""
import re, sys, time, argparse

EOT, STX, ETX = b"\x04", b"\x02", b"\x03"

def check_ascii(text, name):
    """The console carries 7-bit text and reserves 0x02, 0x03 and 0x04 (STX, ETX, EOT) for the file protocol, so a source with other bytes -- EBCDIC from the
    original IBM kit, say, where ordinary letters have codes above 0x80 -- would be sent wrongly or confuse the protocol.  Say so rather than send it."""
    bad = sorted({c for c in text if ord(c) >= 0x80 or ord(c) in (2, 3, 4) or (ord(c) < 32 and c not in "\t\n\r\f")})
    if bad:
        sys.exit("%s has characters the console cannot carry: %s -- if it is EBCDIC, convert it with --ebcdic" % (name, " ".join("0x%02x" % ord(c) for c in bad[:12])))

def read_text(path, ebcdic):
    raw = open(path, "rb").read()
    text = raw.decode("cp037") if ebcdic else raw.decode("latin-1")     # cp037: EBCDIC US/Canada, the IBM 370's code
    check_ascii(text, path)
    return text

def expand(src, hdrdir, ebcdic=False, top=True):
    # A GET line is followed by the file's text, itself expanded (SYNHDR gets LIBHDR), then EOT; the main text ends with EOT as well.
    out = []
    for line in src.splitlines(keepends=True):
        out.append(line)
        m = re.match(r'\s*GET\s+"([^"]+)"', line)
        if m:
            out.append(expand(read_text("%s/%s" % (hdrdir, m.group(1)), ebcdic), hdrdir, ebcdic, False).decode("latin-1"))
    out.append("\x04")
    return "".join(out).encode("latin-1")


def split(data):
    files, msgs, cur, infile = [], bytearray(), bytearray(), False
    for b in data:
        if b == 2: infile = True; cur = bytearray()
        elif b == 3 and infile: files.append(bytes(cur)); infile = False
        elif infile: cur.append(b)
        else: msgs.append(b)
    return files, bytes(msgs)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["expand", "ocode", "intcode", "split"], help="ocode: run st on a BCPL source; intcode: run cg on an OCODE file")
    ap.add_argument("file", nargs="+", help="one file, or several for ocode/intcode: each is a job, and the program is started afresh for each (a program loaded from the flash restarts when it halts)")
    ap.add_argument("--ebcdic", action="store_true", help="the input files are EBCDIC (code page 037): convert to ASCII before sending")
    ap.add_argument("--hdrdir", default="."); ap.add_argument("--port"); ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out"); ap.add_argument("--wait", type=float, default=20)
    ap.add_argument("--flash", help="an .int program to flash first (flash_sonata.sh); the port is opened before, so what the program prints at start-up is not lost")
    ap.add_argument("--chunk", type=int, default=32, help="bytes sent at a time"); ap.add_argument("--quiet", type=float, default=0.012, help="seconds of silence from the board before the next chunk")
    ap.add_argument("--maxwait", type=float, default=300, help="most seconds to wait after the last byte is sent")
    ap.add_argument("--final", type=float, default=25, help="seconds of silence that end a job")
    ap.add_argument("--settle", type=float, default=8.0, help="seconds to wait after flashing for the FPGA to restart")
    a = ap.parse_args()
    if a.cmd == "expand":
        sys.stdout.buffer.write(expand(read_text(a.file[0], a.ebcdic), a.hdrdir, a.ebcdic)); return
    if a.cmd == "split":
        files, msgs = split(open(a.file[0], "rb").read())
        for i, f in enumerate(files): print("file %d: %d bytes" % (i, len(f)))
        print("messages: %r" % msgs[:300]); return
    import serial
    s = serial.Serial(a.port, a.baud, timeout=0.2)
    s.reset_input_buffer()
    t0 = time.time(); first = True
    if a.flash:
        import subprocess, os
        got = bytearray()
        subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), "flash_sonata.sh"), a.flash], check=True, stdout=subprocess.DEVNULL)
        end = time.time() + a.settle
        while time.time() < end: got += s.read(256)             # what the program says as it starts
    for name in a.file:
        data = expand(read_text(name, a.ebcdic), a.hdrdir, a.ebcdic) if a.cmd == "ocode" else read_text(name, a.ebcdic).encode("latin-1") + b"\x04"
        t1 = time.time(); got = bytearray()
        # The 128-byte receive FIFO cannot absorb what the program has no time to read (it is busy parsing or writing at 115200).  The board gives credit:
        # 96 bytes to start and 32 more for each ENQ (0x05) it sends, so never more is in flight than the FIFO holds.  ENQs are removed from the output.
        credit, k = 96, 0
        while k < len(data):
            if credit > 0:
                n = min(credit, a.chunk, len(data) - k); s.write(data[k:k + n]); s.flush(); k += n; credit -= n
            d = s.read(256 if credit > 0 else 4096)
            if d:
                credit += 32 * d.count(b"\x05"); got += d.replace(b"\x05", b"")
        last = tsent = time.time()
        while time.time() - last < a.final and time.time() - tsent < a.maxwait:    # until the program has been quiet for --final seconds (the last section is translated before any of it is written)
            d = s.read(256)
            if d: got += d.replace(b"\x05", b""); last = time.time()
        files, msgs = split(bytes(got))
        ext = ".ocode" if a.cmd == "ocode" else ".i"
        outname = name.rsplit(".", 1)[0] + ext + ".board"
        if files: open(outname, "wb").write(b"".join(files))        # one file per section (each ends the output stream)
        print("%s: %d bytes in, %d bytes out%s, %.1f s   %s" % (name, len(data), sum(len(f) for f in files), "" if files else " (NO FILE)", time.time() - t1, msgs.decode("latin-1").strip().replace("\n", " | ")[:60]), flush=True)
        time.sleep(1.0)                                         # the program restarts from the flash

main()
