#!/usr/bin/env python3
"""mon_bootstrap.py : the BCPL bootstrap run on the FPGA, through the monitor on the serial port (flash it first with monitor_sonata.sh).
  stage 1: the kit-built ST and CG compile blib, syn, trn, cg (RUN ST x.b; RUN CG; COPY INTCODE x1.i)
  ASM    : RUN ASM ST1 ICLIB.I BLIB1.I SYN1.I TRN1.I  and  RUN ASM CG1 -OCODE ICLIB.I BLIB1.I CG1.I  make a compiler from what it has just compiled
  stage 2: ST1 and CG1 compile the four sources again; stage 1, stage 2 and the kit's compiler (the C interpreter on the host) must agree byte for byte."""
import time
from mon_serial import Mon, host_ref

m = Mon(); m.wake()
names = ['blib', 'syn', 'trn', 'cg']
t0 = time.time()
for stage, (st, cg) in enumerate([('st', 'cg'), ('st1', 'cg1')]):
    for n in names:
        a = m.run('run %s %s.b' % (st, n)); b = m.run('run ' + cg)
        assert 'OK' in m.run('copy intcode %s%d.i' % (n, stage + 1)), (n, a, b)
        print('stage %d  %-5s %s' % (stage + 1, n, a[:60]), flush=True)
    if stage == 0:
        print('asm st1:', m.run('run asm st1 iclib.i blib1.i syn1.i trn1.i')[-40:], flush=True)
        print('asm cg1:', m.run('run asm cg1 -OCODE iclib.i blib1.i cg1.i')[-40:], flush=True)
print('on-board bootstrap took %.0f s' % (time.time() - t0))
ok = True
for n in names:
    c1, c2, ref = m.cat(n + '1.i').strip(b'\n'), m.cat(n + '2.i').strip(b'\n'), host_ref(n).strip(b'\n')
    same = (c1 == ref, c2 == ref, c1 == c2); ok &= all(same)
    print('%-5s stage1 == C: %s   stage2 == C: %s   stage1 == stage2: %s   (%d bytes)' % (n, *same, len(ref)))
print('FIXED POINT REACHED ON THE FPGA' if ok else 'MISMATCH')
