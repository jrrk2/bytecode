#!/usr/bin/env python3
"""nfs_splice.py [--check] : put the shared text of io/nfs.ml, io/sd.ml and io/fat.ml (between each file's ">>> io/NAME" and
"<<< io/NAME" lines) into the programs that include it, where the same two marker lines bracket the copy.  --check only
reports whether the copies are current.  Neither the REPL (io/comp.ml) nor the loader (io/netboot.ml) can call the other
(see the head of io/nfs.ml), so shared code is spliced in as text.  io/sd.ml and io/fat.ml are also files the REPL runs
by itself with run_file; the loader takes the same text."""
import re, sys
root = __file__.rsplit("/tools/", 1)[0] if "/tools/" in __file__ else "."
USERS = {"io/nfs.ml": ["io/comp.ml", "io/netboot.ml"], "io/sd.ml": ["io/netboot.ml"], "io/fat.ml": ["io/netboot.ml"]}
bad = 0
for src, targets in USERS.items():
    pat = re.compile(r"(\(\* >>> " + re.escape(src) + r" \*\)\n).*?(\(\* <<< " + re.escape(src) + r" \*\)\n)", re.S)
    m = pat.search(open(root + "/" + src).read())
    if not m: sys.exit(src + " has no marker lines")
    body = m.group(0)
    for f in targets:
        p = root + "/" + f
        text = open(p).read()
        if not pat.search(text):
            print(f + " (" + src + "): no marker lines"); bad += 1; continue
        new = pat.sub(lambda _: body, text, count=1)
        if new == text:
            print(f + " (" + src + "): current")
        elif "--check" in sys.argv:
            print(f + " (" + src + "): OUT OF DATE"); bad += 1
        else:
            open(p, "w").write(new); print(f + " (" + src + "): updated")
sys.exit(1 if bad else 0)
