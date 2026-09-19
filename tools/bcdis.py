#!/usr/bin/env python3
"""bcdis.py prog.bc [rtl.sv]: opcode histogram of an OCaml 4.14 bytecode
executable; with the VM's RTL, marks the opcodes it has no S_EXEC arm for."""
import re, struct, sys
import os
_h = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ocaml-4.14.2/runtime/caml/instruct.h')).read()
NAMES = re.sub(r'\s+', '', re.search(r'enum instructions \{(.*?)\};', _h, re.S).group(1)).split(',')
ONE = set("""ACC PUSHACC POP ASSIGN ENVACC PUSHENVACC PUSH_RETADDR APPLY APPTERM1 APPTERM2
APPTERM3 RETURN GRAB OFFSETCLOSURE PUSHOFFSETCLOSURE GETGLOBAL PUSHGETGLOBAL SETGLOBAL ATOM
PUSHATOM MAKEBLOCK1 MAKEBLOCK2 MAKEBLOCK3 MAKEFLOATBLOCK GETFIELD GETFLOATFIELD SETFIELD
SETFLOATFIELD BRANCH BRANCHIF BRANCHIFNOT PUSHTRAP C_CALL1 C_CALL2 C_CALL3 C_CALL4 C_CALL5
CONSTINT PUSHCONSTINT OFFSETINT OFFSETREF""".split())
TWO = set("""APPTERM CLOSURE GETGLOBALFIELD PUSHGETGLOBALFIELD MAKEBLOCK C_CALLN BEQ BNEQ
BLTINT BLEINT BGTINT BGEINT BULTINT BUGEINT GETPUBMET C_CALLN""".split())
data = open(sys.argv[1], 'rb').read()
nsec, _ = struct.unpack('>I12s', data[-16:])
descs = [struct.unpack('>4sI', data[-16 - 8 * (nsec - i):][:8]) for i in range(nsec)]
pos = len(data) - 16 - 8 * nsec - sum(n for _, n in descs)
sec = {}
for name, size in descs:
    sec[name.decode()] = data[pos:pos + size]; pos += size
code = struct.unpack(f'<{len(sec["CODE"]) // 4}I', sec["CODE"])
prims = sec["PRIM"].split(b'\0')
hist, ccalls, pc = {}, {}, 0
while pc < len(code):
    op = NAMES[code[pc]]; pc += 1
    hist[op] = hist.get(op, 0) + 1
    if op.startswith('C_CALL'):
        p = code[pc + (1 if op == 'C_CALLN' else 0)]
        ccalls[prims[p].decode()] = p
    if op in ONE: pc += 1
    elif op in TWO: pc += 2
    elif op == 'CLOSUREREC': nf = code[pc]; pc += 2 + nf
    elif op == 'SWITCH': sz = code[pc]; pc += 1 + (sz & 0xFFFF) + (sz >> 16)
implemented = set()
if len(sys.argv) > 2:
    rtl = open(sys.argv[2]).read()
    s_exec = rtl[rtl.index('S_EXEC: begin'):]
    implemented = set(re.findall(r'^\s*([A-Z][A-Z0-9_]*)\s*:', s_exec, re.M))
    implemented.discard('default')
    trapped = set(re.findall(r'^\s*([A-Z][A-Z0-9_]*):\s*begin\s*\n\s*\$display\("[A-Z_0-9]+ needs RTL', s_exec, re.M))
for op in sorted(hist, key=lambda o: NAMES.index(o)):
    mark = '' if not implemented else ('   ** stub: needs RTL' if op in trapped else ('' if op in implemented else '   ** MISSING'))
    print(f'{hist[op]:5d}  {op}{mark}')
print('C calls:', ', '.join(f'{n} (0x{p:x})' for n, p in sorted(ccalls.items(), key=lambda x: x[1])))
print('DATA section:', len(sec.get('DATA', b'')), 'bytes')
