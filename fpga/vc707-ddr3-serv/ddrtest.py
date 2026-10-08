#!/usr/bin/env python3
"""ddrtest.py [lines] : run the hardware DDR3 test over the BIOS console (the SERV's UART).

Reads the tester's CSR addresses from the build's csr.csv, writes `limit` and `start` with the BIOS's
mem_write, polls `status` with mem_read until done, and prints the errors and throughput.  lines 0 (default):
the whole 1 GiB (2^24 lines of 64 bytes).
usage: ddrtest.py [lines] [--port /dev/ttyUSB0] [--csv build/serv-ddr3/csr.csv]
"""
import argparse, re, sys, time
import serial

ap = argparse.ArgumentParser()
ap.add_argument("lines", nargs="?", type=lambda v: int(v, 0), default=0)
ap.add_argument("--port", default="/dev/ttyUSB0")
ap.add_argument("--csv", default="build/serv-ddr3/csr.csv")
ap.add_argument("--timeout", type=float, default=600)
a = ap.parse_args()

csr = {}
for line in open(a.csv):
    f = line.strip().split(",")
    if f[0] == "csr_register" and f[1].startswith("ddr_test_"):
        csr[f[1][len("ddr_test_"):]] = int(f[2], 0)

s = serial.Serial(a.port, 115200, timeout=0.5)

def cmd(text, wait=0.4):
    s.reset_input_buffer()
    s.write(text.encode() + b"\r")
    time.sleep(wait)
    out = b""
    t0 = time.time()
    while time.time() - t0 < 3:
        d = s.read(256)
        if not d: break
        out += d
    return out.decode(errors="replace")

def rd(name):
    out = cmd("mem_read 0x%x 4" % csr[name])
    m = re.findall(r"0x([0-9a-fA-F]{8})\s*[:|]?\s*0x([0-9a-fA-F]{8})", out) or re.findall(r":\s*([0-9a-fA-F]{8})", out)
    for g in m:
        if isinstance(g, tuple) and int(g[0], 16) == csr[name]:
            return int(g[1], 16)
    nums = re.findall(r"\b([0-9a-fA-F]{8})\b", out)
    if len(nums) >= 2:
        return int(nums[1], 16)
    raise RuntimeError("cannot read %s from: %r" % (name, out))

def wr(name, v):
    cmd("mem_write 0x%x 0x%x" % (csr[name], v))

lines = rd("nlines")
print("memory: %d lines x 64 bytes = %.1f MiB" % (lines, lines * 64 / 2**20))
wr("limit", a.lines)
wr("start", 1)
t0 = time.time()
while time.time() - t0 < a.timeout:
    st = rd("status")
    if st & 1:
        break
    time.sleep(0.5)
else:
    sys.exit("timed out, status %x" % st)
errors, first = rd("errors"), rd("first_err")
cw, cr = rd("cycles_w"), rd("cycles_r")
n = a.lines or lines
print("tested %d lines (%.1f MiB): %d errors%s" % (n, n * 64 / 2**20, errors, ", first at line %d (0x%x)" % (first, first * 64) if errors else ""))
for nm, c in (("write", cw), ("read", cr)):
    if c:
        print("%s pass: %d cycles, %.2f bytes/cycle, %.0f MB/s at 100 MHz" % (nm, c, n * 64 / c, n * 64 / c * 100))
