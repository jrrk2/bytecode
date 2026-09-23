#!/usr/bin/env python3
"""clockshare.py design.fasm -- does any wire carry two different clock nets?

The open flow routes a clock from an MMCM to its BUFG through the fabric,
and has been seen to give two clocks the same route-through LUT: the
bitstream then drives clk_sys and eth_rx_clk from one wire, the processor
runs on the wrong clock and the board is silent from reset with no other
sign.  The FASM says so plainly -- each net's routing is listed under its
own comment -- so this reads it back and fails the build rather than the
board.
"""
import re, sys, collections

fasm = sys.argv[1]
clocky = re.compile(r'clk|clock|drck|gclk', re.I)
net = None
owners = collections.defaultdict(set)      # wire -> the nets that drive it
for line in open(fasm):
    line = line.strip()
    m = re.match(r'# routing for net (.*)$', line)
    if m:
        net = m.group(1)
        continue
    if not net or not line or line.startswith('#'):
        continue
    parts = line.split('.')
    # a routing pip is TILE.DESTINATION.SOURCE; anything else (IN_USE, an
    # INIT, a mux setting) configures a site and is not a wire
    if len(parts) != 3 or '=' in line:
        continue
    # a pip touches two wires; a clock net that shares either of them with
    # another clock net is being carried on the same silicon as that one
    owners[parts[0] + '.' + parts[1]].add(net)
    owners[parts[0] + '.' + parts[2]].add(net)

def is_clock(n):
    return bool(clocky.search(n))
shared = {w: ns for w, ns in owners.items()
          if sum(1 for n in ns if is_clock(n)) > 1}
if not shared:
    print(f'clockshare: no wire carries two clock nets')
    sys.exit(0)
print(f'clockshare: {len(shared)} wire(s) carry more than one net, a clock among them:')
for w, ns in sorted(shared.items())[:10]:
    print(f'  {w}  <-  {sorted(ns)}')
print('\nThis is the open flow giving two clocks one route; the design will not\n'
      'run.  Build again with another --seed, or route the clocks by hand.')
sys.exit(1)
