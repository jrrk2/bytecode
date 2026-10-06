#!/usr/bin/env python3
"""img2bc.py in.img outdir : an OCVM image back into what the simulator runs: outdir/prog.bc (CODE + PRIM, an
ocamlc-style trailer), outdir/heap.hex, globals.hex and image.txt."""
import struct, sys, os
img = open(sys.argv[1], 'rb').read(); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
mg, ver, cw, hw, gw, dig, crc, _ = struct.unpack('<8I', img[:32])
assert mg == 0x4D56434F
w = struct.unpack('<%dI' % (cw + hw + gw), img[32:32 + 4 * (cw + hw + gw)])
code = img[32:32 + 4 * cw]
import subprocess
prims = (subprocess.run(['ocamlrun', '-p'], capture_output=True, text=True, check=True).stdout
          + 'vm_io_read\nvm_io_write\n').replace('\n', '\0').encode()
secs = [(b'CODE', code), (b'PRIM', prims), (b'DATA', struct.pack('>I', 0))]
body = b''.join(d for _, d in secs)
table = b''.join(n + struct.pack('>I', len(d)) for n, d in secs)
open(os.path.join(out, 'prog.bc'), 'wb').write(body + table + struct.pack('>I', len(secs)) + b'Caml1999X031')
open(os.path.join(out, 'heap.hex'), 'w').write(''.join('%08x\n' % x for x in w[cw:cw + hw]))
open(os.path.join(out, 'globals.hex'), 'w').write(''.join('%08x\n' % x for x in w[cw + hw:]))
open(os.path.join(out, 'image.txt'), 'w').write('heap_words %d\nglobals %d\n' % (hw, gw))
print("code %d heap %d globals %d" % (cw, hw, gw))
