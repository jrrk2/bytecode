#!/usr/bin/env python3
"""decode_trace.py [file] : name the states and opcodes in a vm_trace dump (18 hex digits a line: state, opcode, pc,
sp, accu low 16 bits).  The names come from the VM's own enumerations (state_rtl_complete.h, ocaml4142_vm_rtl.sv)."""
import re, sys, os
here = os.path.dirname(os.path.abspath(__file__)) + "/.."
states = re.findall(r"\b(S_[A-Z0-9_]+)\b", re.sub(r"//.*", "", open(here + "/state_rtl_complete.h").read()))
src = open(here + "/ocaml4142_vm_rtl.sv").read()
m = re.search(r"typedef enum logic \[7:0\] \{(.*?)\}\s*opcode_t", src, re.S)
ops = re.findall(r"\b([A-Z][A-Z0-9_]*)\b", re.sub(r"//.*", "", m.group(1))) if m else []
for line in (open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin):
    t = re.sub(r"^uart:\s*", "", line.strip())
    if not re.fullmatch(r"[0-9A-Fa-f]{37}", t):
        continue
    v = int(t, 16)
    st, op, pc, sp = (v >> 140) & 0x7F, (v >> 132) & 0xFF, (v >> 108) & 0xFFFFFF, (v >> 92) & 0x7FFF
    acc, env, hp = (v >> 56) & 0xFFFFFFFFF, (v >> 20) & 0xFFFFFFFFF, v & 0xFFFFF
    print("%-24s %-14s pc=%-7d sp=%-6d accu=%09x env=%09x hp=%d" % (states[st] if st < len(states) else st, ops[op] if op < len(ops) else op, pc, sp, acc, env, hp))
