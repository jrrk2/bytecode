#!/usr/bin/env python3
"""nfs_splice.py [--check] : put io/nfs.ml's text (between its ">>> io/nfs.ml" and "<<< io/nfs.ml" lines) into io/comp.ml
and io/netboot.ml, where the same two marker lines bracket the copy.  --check only reports whether the copies are current.
Neither program can call the other (see the head of io/nfs.ml), so the shared client is spliced in as text."""
import re, sys
root = __file__.rsplit("/tools/", 1)[0] if "/tools/" in __file__ else "."
pat = re.compile(r"(\(\* >>> io/nfs\.ml \*\)\n).*?(\(\* <<< io/nfs\.ml \*\)\n)", re.S)
src = open(root + "/io/nfs.ml").read()
m = pat.search(src)
if not m: sys.exit("io/nfs.ml has no marker lines")
body = m.group(0)
bad = 0
for f in ("io/comp.ml", "io/netboot.ml"):
    p = root + "/" + f
    text = open(p).read()
    if not pat.search(text):
        print(f + ": no marker lines"); bad += 1; continue
    new = pat.sub(lambda _: body, text, count=1)
    if new == text:
        print(f + ": current")
    elif "--check" in sys.argv:
        print(f + ": OUT OF DATE"); bad += 1
    else:
        open(p, "w").write(new); print(f + ": updated")
sys.exit(1 if bad else 0)
