#!/usr/bin/env python3
"""check_prims.py prog.bc [rtl.sv] : every C primitive the program calls,
against the ones the processor implements.

An unimplemented primitive is not a compile error and not a link error: the
program runs until it reaches one, and then the machine does whatever a
`unique case` with no matching arm does -- on the board, nothing good.  This
turns that into a build failure.  The RTL's arms are read from the case
labels beside each primitive's opcode, and the trap primitives (vm_io_*) are
always allowed.
"""
import os, re, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
prog = sys.argv[1]
rtl = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, '..', 'ocaml4142_vm_rtl.sv')

dis = subprocess.run([sys.executable, os.path.join(here, 'bcdis.py'), prog],
                     capture_output=True, text=True).stdout
line = [l for l in dis.split('\n') if l.startswith('C calls:')]
if not line:
    print('check_prims: no C calls line from bcdis.py'); sys.exit(2)
used = dict((m.group(1), int(m.group(2), 16))
            for m in re.finditer(r'([a-z_0-9]+) \(0x([0-9a-f]+)\)', line[0]))

src = open(rtl).read()
have = set()
for m in re.finditer(r"16'h([0-9a-fA-F]{3})", src):
    have.add(int(m.group(1), 16))
for m in re.finditer(r"imm == 16'h([0-9a-fA-F]{3})", src):
    have.add(int(m.group(1), 16))

missing = {n: o for n, o in used.items() if o not in have}
for n, o in sorted(used.items()):
    print(f'  {"ok " if o not in missing else "MISSING"} {n} (0x{o:03x})')
if missing:
    print(f'\n{os.path.basename(prog)} calls {len(missing)} primitive(s) this processor does not implement:')
    for n, o in sorted(missing.items()):
        print(f'  {n} (0x{o:03x})')
    print('\nEither avoid them in the program (a polymorphic helper often means\n'
          'caml_array_get or caml_equal: annotate it with int array), or add an\n'
          'arm to the RTL.')
    sys.exit(1)
print(f'{os.path.basename(prog)}: all {len(used)} primitives are implemented')
