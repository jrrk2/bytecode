#!/usr/bin/env python3
"""mon_chain.py : drive the INTCODE monitor on the Sonata over the serial port and compile the four compiler sources end to end (COPY x.b STDIN; RUN ST; RUN CG; CAT INTCODE),
comparing each INTCODE with what the kit's own compiler (the C interpreter running st.int and cg.int, in $KIT) makes of the same source."""
import subprocess, tempfile, shutil
import os
KIT = os.environ.get('KIT', os.path.expanduser('~/bcplkit-0.9.7/src'))
import serial, time, sys

def host_ref(name):
    d = tempfile.mkdtemp()
    for f in ('LIBHDR', 'SYNHDR', 'TRNHDR', 'CGHDR', 'st.int', 'cg.int', name + '.b'): shutil.copy(os.path.join(KIT, f), d)
    subprocess.run([os.path.join(KIT, 'icint'), 'st.int'], stdin=open(os.path.join(d, name + '.b')), cwd=d, stdout=subprocess.DEVNULL, check=True)
    subprocess.run([os.path.join(KIT, 'icint'), 'cg.int'], stdin=open(os.path.join(d, 'OCODE')), cwd=d, stdout=subprocess.DEVNULL, check=True)
    r = open(os.path.join(d, 'INTCODE'), 'rb').read().decode('latin-1'); shutil.rmtree(d); return r

class Mon:
    def __init__(s, port='/dev/ttyUSB5'):
        s.s = serial.Serial(port, 115200, timeout=0.2)
    def read_until(s, pat, timeout):
        buf = b''; t = time.time()
        while time.time() - t < timeout:
            d = s.s.read(4096)
            if d: buf += d; t = time.time() if False else t
            if pat in buf[-len(pat) - 8:] and True:
                # wait a moment for trailing output
                time.sleep(0.15); buf += s.s.read(4096)
                return buf
        return buf
    def cmd(s, line, timeout=60, prompt=b'\n>'):
        s.s.reset_input_buffer()
        for ch in line.encode() + b'\n':
            s.s.write(bytes([ch])); s.s.flush(); time.sleep(0.004)
        return s.read_until(prompt, timeout)
m = Mon()
m.s.write(b'\n'); time.sleep(0.3); m.s.reset_input_buffer()
allok = True
for name in ['blib', 'syn', 'trn', 'cg']:
    t0 = time.time()
    out = m.cmd('copy %s.b stdin' % name, 30).decode('latin-1')
    assert 'OK' in out, out
    st = m.cmd('run st', 60).decode('latin-1').replace('\r', '')
    cg = m.cmd('run cg', 60).decode('latin-1').replace('\r', '')
    t1 = time.time()
    cat = m.cmd('cat intcode', 120, prompt=b'\n>').decode('latin-1').replace('\r', '')
    body = cat.split('\n', 1)[1] if cat.startswith('cat') else cat
    body = body[:body.rfind('\n>')] if '\n>' in body else body
    ref = host_ref(name)
    ok = body.strip('\n') == ref.strip('\n')
    allok &= ok
    print('%-5s st: %s | cg: %s | %.1fs compile, INTCODE %d bytes, %s' % (name, ' '.join(st.split())[:60], ' '.join(cg.split())[-40:], t1 - t0, len(body), 'IDENTICAL to the C compiler' if ok else 'DIFFERENT'))
    if not ok:
        k = next((i for i in range(min(len(body), len(ref))) if body[i] != ref[i]), None)
        print('  first difference at', k, repr(body[k-30:k+30]) if k else '', repr(ref[k-30:k+30]) if k else '')
print('ALL IDENTICAL' if allok else 'MISMATCH')
