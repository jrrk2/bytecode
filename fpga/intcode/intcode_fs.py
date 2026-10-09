#!/usr/bin/env python3
"""intcode_fs.py : build, list and unpack the file system the INTCODE system keeps in the software flash (intcode_sys.v, FS_AT).

    intcode_fs.py image.bin file...                 a raw image of the files
    intcode_fs.py image.bin file... --uf2 fs.uf2    also a software UF2 (family 0x6CE29E60) at UF2 address 0x10020000 = slot 2 plus 128 KiB, which is the default FS_AT
    intcode_fs.py --list image.bin                  the records in an image (or a dump of the flash from FS_AT)
    intcode_fs.py --extract image.bin dir           write the newest version of each file into dir

Layout (all words little-endian): a chain of records.  A record is a header of 32 bytes -- the file's name as BCPL packs a string (a length byte, then the characters,
four to a word, the first in the high byte of the first word: six words, so up to 23 characters), the length of the data in bytes, and a word of flags (ones) --
then the data, padded to a multiple of 4; the next record follows at once.  A blank header (word 0 all ones or zero) ends the chain, and so does a record whose
length is all ones, a file that was open for writing and never closed.  A later record hides an earlier one with the same name: the board appends files with
`findoutput` (whatever a program writes to OCODE or INTCODE becomes a record) and reads the newest.  A file called STDIN is the program's standard input.
Names are the file's basename in capitals, as BCPL source says them (GET "LIBHDR"); --keepcase keeps them as they are.  The image ends with a sector of ones so that the
chain stops even where the flash held something else before.
"""
import argparse, os, struct, sys

HDR = 32
UF2_FAMILY = 0x6CE29E60


def pack_name(name):
    b = name.encode("latin-1")
    if len(b) > 23: raise SystemExit("name too long (23 characters): " + name)
    b = bytes([len(b)]) + b
    b += bytes(24 - len(b))
    # the first character of the string is the high byte of the word, so the word is big-endian-packed, stored as a little-endian word
    return b"".join(struct.pack("<I", struct.unpack(">I", b[i:i + 4])[0]) for i in range(0, 24, 4))


def build(paths, keepcase=False):
    out = b""
    for p in paths:
        d = open(p, "rb").read()
        n = os.path.basename(p)
        out += pack_name(n if keepcase else n.upper()) + struct.pack("<II", len(d), 0xFFFFFFFF) + d + bytes((-len(d)) % 4)
    out += b"\xff" * ((-len(out)) % 4096 + 4096)
    return out


def uf2_blocks(blob, base):
    nblk = (len(blob) + 255) // 256
    out = b""
    for n in range(nblk):
        payload = blob[n * 256:(n + 1) * 256]
        payload += bytes(476 - len(payload))
        out += struct.pack("<8I", 0x0A324655, 0x9E5D5157, 0x2000, base + n * 256, 256, n, nblk, UF2_FAMILY) + payload + struct.pack("<I", 0x0AB16F30)
    return out


def records(blob):
    pos = 0
    while pos + HDR <= len(blob):
        w0 = struct.unpack("<I", blob[pos:pos + 4])[0]
        if w0 in (0, 0xFFFFFFFF): return
        ln = struct.unpack("<I", blob[pos + 24:pos + 28])[0]
        if ln == 0xFFFFFFFF: return
        nm = b"".join(struct.pack(">I", struct.unpack("<I", blob[pos + k:pos + k + 4])[0]) for k in range(0, 24, 4))
        yield nm[1:1 + nm[0]].decode("latin-1"), pos + HDR, ln
        pos += HDR + ln + (-ln) % 4


def listing(blob):
    for name, off, ln in records(blob): print("%-24s offset %8d length %8d" % (name, off, ln))


def extract(blob, d):
    os.makedirs(d, exist_ok=True)
    for name, off, ln in records(blob): open(os.path.join(d, name), "wb").write(blob[off:off + ln])      # the newest wins


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image"); ap.add_argument("files", nargs="*")
    ap.add_argument("--uf2"); ap.add_argument("--address", type=lambda x: int(x, 0), default=0x10020000)
    ap.add_argument("--keepcase", action="store_true"); ap.add_argument("--list", action="store_true"); ap.add_argument("--extract", action="store_true")
    a = ap.parse_args()
    if a.list: listing(open(a.image, "rb").read()); return
    if a.extract: extract(open(a.image, "rb").read(), a.files[0]); return
    blob = build(a.files, a.keepcase)
    open(a.image, "wb").write(blob)
    print("%d files, %d bytes to %s" % (len(a.files), len(blob), a.image))
    if a.uf2:
        open(a.uf2, "wb").write(uf2_blocks(blob, a.address)); print("UF2 to %s (address 0x%x)" % (a.uf2, a.address))


if __name__ == "__main__":
    main()
