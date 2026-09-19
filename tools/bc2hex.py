#!/usr/bin/env python3
"""bc2hex.py prog.bc out.hex : CODE section of an OCaml bytecode executable as $readmemh words."""
import struct, sys
data = open(sys.argv[1], 'rb').read()
nsec, magic = struct.unpack('>I12s', data[-16:])
assert magic.startswith(b'Caml1999X'), magic
descs = [struct.unpack('>4sI', data[-16 - 8 * (nsec - i):][:8]) for i in range(nsec)]
pos = len(data) - 16 - 8 * nsec - sum(n for _, n in descs)
for name, size in descs:
    if name == b'CODE':
        words = struct.unpack(f'<{size // 4}I', data[pos:pos + size])
        break
    pos += size
with open(sys.argv[2], 'w') as f:
    f.writelines(f'{w:08x}\n' for w in words)
print(f'{sys.argv[2]}: {len(words)} words')
