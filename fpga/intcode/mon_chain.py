#!/usr/bin/env python3
"""mon_chain.py : drive the INTCODE monitor on the Sonata over the serial port and compile the four compiler sources end to end (COPY x.b STDIN; RUN ST; RUN CG;
CAT INTCODE), comparing each INTCODE with what the kit's own compiler (the C interpreter running st.int and cg.int, in $KIT) makes of the same source."""
import time
from mon_serial import Mon, host_ref

m = Mon(); m.wake()
allok = True
for name in ['blib', 'syn', 'trn', 'cg']:
    t0 = time.time()
    assert 'OK' in m.run('copy %s.b stdin' % name, 30)
    st = m.run('run st'); cg = m.run('run cg')
    t1 = time.time()
    body = m.cat('intcode')
    ok = body.strip(b'\n') == host_ref(name).strip(b'\n')
    allok &= ok
    print('%-5s st: %s | %.1fs compile, INTCODE %d bytes, %s' % (name, st[:50], t1 - t0, len(body), 'IDENTICAL to the C compiler' if ok else 'DIFFERENT'))
print('ALL IDENTICAL' if allok else 'MISMATCH')
