#!/usr/bin/env python3
"""mkdisk.py out.disk name=path ... : a RAM-disk image (io/comp.ml's filing system) holding the given files.
Layout: 16-byte superblock (magic "RFS", file count, first free byte), 64 entries of 32 bytes (name[24], offset,
length), data from byte 2064.  For +disk= in the simulator or $ETHMODEL_DISK on the host."""
import struct, sys
SIZE, DIR, ENT, DATA = int(__import__("os").environ.get("DISK_KIB", "512")) * 1024, 16, 32, 16 + 64 * 32
disk = bytearray(SIZE); free = DATA; files = sys.argv[2:]
for k, spec in enumerate(files):
    name, path = spec.split('=', 1); d = open(path, 'rb').read()
    assert len(name) <= 24 and free + len(d) <= SIZE, spec
    disk[DIR + k * ENT:DIR + k * ENT + 24] = name.encode().ljust(24, b'\0')
    disk[DIR + k * ENT + 24:DIR + k * ENT + 32] = struct.pack('<II', free, len(d))
    disk[free:free + len(d)] = d; free += len(d)
disk[0:12] = struct.pack('<III', 0x534652, len(files), free)
open(sys.argv[1], 'wb').write(disk)
print("%s: %d files, %d bytes used" % (sys.argv[1], len(files), free))
