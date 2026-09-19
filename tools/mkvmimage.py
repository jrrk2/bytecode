#!/usr/bin/env python3
"""mkvmimage.py <dir> <out.img> : pack a program's images (tools/progimage.sh
output: program.hex, heap.hex, globals.hex) into one file for netboot.

Layout, 32-bit little-endian words:
  0  magic 0x4D56434F ("OCVM")      4  globals words
  1  format version (1)             5  primitive-table digest (CRC-32 of the
  2  code words                        primitive list the program was linked
  3  heap words                        against; 0 = the runtime's own)
  6  CRC-16-CCITT (0x1021, from 0xFFFF) of every byte after the header:
     16 bits, so the loader can check it in 31-bit OCaml ints
  7  reserved (0)
then the code, heap and globals words.
"""
import binascii
import os
import struct
import subprocess
import sys

MAGIC, VERSION = 0x4D56434F, 1


def hexwords(path):
    with open(path) as f:
        return [int(line, 16) for line in f if line.strip()]


def crc16_ccitt(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def prims_digest():
    """CRC-32 of the VM's primitive list: the runtime's, then vm_io_read/vm_io_write."""
    runtime = subprocess.run(["ocamlrun", "-p"], capture_output=True, text=True, check=True).stdout
    return binascii.crc32((runtime + "vm_io_read\nvm_io_write\n").encode()) & 0xFFFFFFFF


def main():
    src, out = sys.argv[1], sys.argv[2]
    code = hexwords(os.path.join(src, "program.hex"))
    heap = hexwords(os.path.join(src, "heap.hex"))
    glob = hexwords(os.path.join(src, "globals.hex"))
    body = struct.pack(f"<{len(code) + len(heap) + len(glob)}I", *(code + heap + glob))
    header = struct.pack("<8I", MAGIC, VERSION, len(code), len(heap), len(glob),
                         prims_digest(), crc16_ccitt(body), 0)
    with open(out, "wb") as f:
        f.write(header + body)
    print(f"{out}: {len(code)} code, {len(heap)} heap, {len(glob)} globals words, "
          f"{len(header) + len(body)} bytes, primitives digest {prims_digest():08x}")


if __name__ == "__main__":
    main()
