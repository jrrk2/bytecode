#!/usr/bin/env python3
"""board.py : drive the VC707's console (the compiler's REPL on the UART) from a script.

    board.py [--port /dev/ttyUSB2] boot                      wait for the banner and a prompt
    board.py run 'line' [--until REGEX] [--timeout S]        type a line, collect the output until REGEX (or quiet)
    board.py dump OUT.txt                                    send Ctrl-T, save the trace dump (vm_trace.v) to OUT.txt
    board.py script FILE [--until REGEX] [--timeout S]       type each line of FILE, waiting for the next prompt

Everything read goes to --log as well as the terminal.  The REPL's line limit and echo apply: one phrase a line.
"""
import argparse, re, sys, time
import serial

def open_port(a):
    s = serial.Serial(a.port, 115200, timeout=0.2)
    s.reset_input_buffer()
    return s

def drain(s, until=None, timeout=60.0, quiet=None, log=None, echo=True):
    """read until the regex matches, the line has been quiet for `quiet` seconds, or the timeout"""
    buf = b""
    t0 = last = time.time()
    while time.time() - t0 < timeout:
        d = s.read(4096)
        if d:
            last = time.time()
            buf += d
            if log: log.write(d); log.flush()
            if echo: sys.stdout.write(d.decode("latin-1")); sys.stdout.flush()
            if until and re.search(until, buf.decode("latin-1")): break
        elif quiet is not None and time.time() - last > quiet:
            break
    return buf.decode("latin-1")

def send_line(s, text):
    for ch in text.encode() + b"\r":           # a character at a time: the UART FIFO is 256 bytes and the REPL echoes
        s.write(bytes([ch])); s.flush(); time.sleep(0.004)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyUSB2")
    ap.add_argument("--log", default="/tmp/bc/board.log")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("boot")
    r = sub.add_parser("run"); r.add_argument("line"); r.add_argument("--until"); r.add_argument("--timeout", type=float, default=120)
    d = sub.add_parser("dump"); d.add_argument("out")
    sc = sub.add_parser("script"); sc.add_argument("file"); sc.add_argument("--until"); sc.add_argument("--timeout", type=float, default=120)
    a = ap.parse_args()
    s = open_port(a)
    log = open(a.log, "ab")
    if a.cmd == "boot":
        out = drain(s, until=r"OCaml processor mini-ML[^\n]*\n(?:.|\n)*# ", timeout=300, log=log)
        sys.exit(0 if "mini-ML" in out else 1)
    elif a.cmd == "run":
        send_line(s, a.line)
        drain(s, until=a.until, timeout=a.timeout, quiet=None if a.until else 3, log=log)
    elif a.cmd == "script":
        for line in open(a.file).read().splitlines():
            if not line.strip(): continue
            send_line(s, line)
            drain(s, until=a.until or r"\n# ?$", timeout=a.timeout, quiet=5, log=log)
    elif a.cmd == "dump":
        s.write(b"\x14"); s.flush()
        got = drain(s, timeout=60, quiet=4, log=log, echo=False)
        lines = [l.strip() for l in got.splitlines() if re.fullmatch(r"[0-9A-Fa-f]{18}", l.strip())]
        open(a.out, "w").write("\n".join(lines) + "\n")
        print("%d trace records -> %s" % (len(lines), a.out))

main()
