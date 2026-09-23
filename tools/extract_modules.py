#!/usr/bin/env python3
"""extract_modules.py <source.v> <out.v> <top>... -- a module and all it instantiates.

Chisel writes one flat file per configuration; the HardFloat cores inside it
are ordinary Verilog modules with ordinary instantiations, so a module and
its transitive dependencies can be lifted out whole.
"""
import re, sys

src, out = sys.argv[1], sys.argv[2]
wanted = sys.argv[3:]

text = open(src).read()
# split into modules: "module NAME(...);  ... endmodule"
bodies = {}
for m in re.finditer(r'^module\s+([A-Za-z_][A-Za-z0-9_$]*)\s*\(.*?^endmodule', text, re.S | re.M):
    bodies[m.group(1)] = m.group(0)
print(f"{len(bodies)} modules in {src}", file=sys.stderr)

inst_re = re.compile(r'^\s{2,}([A-Za-z_][A-Za-z0-9_$]*)\s+([A-Za-z_][A-Za-z0-9_$]*)\s*\(\s*(?://.*)?$', re.M)
seen, order = set(), []
def visit(name):
    if name in seen: return
    if name not in bodies:
        print(f"  (missing: {name})", file=sys.stderr); return
    seen.add(name)
    for mod, _inst in inst_re.findall(bodies[name]):
        if mod in bodies and mod != name:
            visit(mod)
    order.append(name)

for w in wanted: visit(w)
with open(out, 'w') as f:
    f.write("// Extracted from Rocket's generated Verilog by tools/extract_modules.py.\n"
            "// These are Berkeley HardFloat cores (BSD), as Chisel emitted them.\n\n")
    for name in order:
        f.write(bodies[name] + "\n\n")
print(f"wrote {len(order)} module(s) to {out}: {', '.join(order)}", file=sys.stderr)
