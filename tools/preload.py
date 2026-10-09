#!/usr/bin/env python3
"""preload.py : put initial contents into inferred block RAMs of a built VC707 bitstream, with no rebuild.

    preload.py --bit in.bit --slices out/ram_slices.txt --out new.bit  stage=vm.bc disk=disk.img  [code=words.hex]

A RAM on the command line is named by what follows "core/" in its cells (stage = stage_ram, disk = disk_ram, code =
prog_code) and gets a file: raw bytes for stage and disk (byte i is lane i mod 4 of word i / 4, as the I/O space sees it),
the hex word list (as tools/progimage.sh's program.hex) for code.  The RAM must be x1 planes (one RAMB36 a bit and address
range), which the build's inference gives for the 32K-deep memories; out/ram_slices.txt says where each went (build.tcl
writes it; tools/ram_slices.tcl makes it from out/routed.dcp for an older build).  The rest of the bitstream is untouched.
What is loaded is what the RAM holds when the board starts, until something writes it."""
import argparse, os, re, subprocess, sys, tempfile

def die(m):
    sys.exit("preload: " + m)

NAMES = {"stage": "core/stage_ram", "disk": "core/disk_ram", "code": "core/prog_code"}

def mmi(tiles, proc, words, part):
    x = ['<?xml version="1.0" encoding="UTF-8"?>', '<MemInfo Version="1" Minor="0">',
         '  <Processor Endianness="Little" InstPath="%s">' % proc,
         '    <AddressSpace Name="%s" Begin="0" End="%d">' % (proc, words * 4 - 1)]
    for ab in sorted({t[3] for t in tiles}):
        x.append('      <BusBlock>')
        for loc, bit, a0, a1 in sorted(((t[0], t[1], t[3], t[4]) for t in tiles if t[3] == ab), key=lambda r: -r[1]):
            x += ['        <BitLane MemType="RAMB32" Placement="%s">' % loc.replace('RAMB36_', ''),
                  '          <DataWidth MSB="%d" LSB="%d"/>' % (bit, bit),
                  '          <AddressRange Begin="%d" End="%d"/>' % (a0, a1),
                  '          <Parity ON="false" NumBits="0"/>', '        </BitLane>']
        x.append('      </BusBlock>')
    x += ['    </AddressSpace>', '  </Processor>', '  <Config>', '    <Option Name="Part" Val="%s"/>' % part, '  </Config>', '</MemInfo>']
    return '\n'.join(x) + '\n'

def main():
    ap = argparse.ArgumentParser()
    for a in ('--bit', '--slices', '--out'):
        ap.add_argument(a, required=True)
    ap.add_argument('--updatemem', default='/opt/Xilinx/Vivado/2020.1/bin/updatemem')
    ap.add_argument('--part', default='xc7vx485tffg1761-2')
    ap.add_argument('what', nargs='+', help='stage=file disk=file code=file')
    a = ap.parse_args()
    rows = [r for r in (l.split() for l in open(a.slices)) if len(r) == 7]       # cells without a slice (a plain RAM) have no row
    cur = a.bit
    with tempfile.TemporaryDirectory() as t:
        for item in a.what:
            kind, _, path = item.partition('=')
            if kind not in NAMES or not path: die('give stage=file, disk=file or code=file')
            pre = NAMES[kind]
            tiles = []
            for name, loc, ref, sb, se, ab, ae in rows:
                if name.startswith(pre + '_reg') and ref == 'RAMB36E1':
                    if sb != se: die('%s is not a x1 plane (slice %s:%s)' % (name, sb, se))
                    tiles.append((loc, int(sb), int(se), int(ab), int(ae)))
            if not tiles: die('no cells for ' + pre)
            words = max(t[4] for t in tiles) + 1
            if kind == 'code':
                data = [int(l.split('//')[0], 16) for l in open(path) if l.split('//')[0].strip()]
            else:
                raw = open(path, 'rb').read()
                raw += b'\0' * (-len(raw) % 4)
                data = [int.from_bytes(raw[i:i + 4], 'little') for i in range(0, len(raw), 4)]
            if len(data) > words: die('%s is %d words; %s holds %d' % (path, len(data), pre, words))
            print('%s: %d of %d words' % (kind, len(data), words))
            data += [0] * (words - len(data))
            proc = kind + '_proc'
            mmif, memf, outf = (os.path.join(t, kind + e) for e in ('.mmi', '.mem', '.bit'))
            open(mmif, 'w').write(mmi(tiles, proc, words, a.part))
            open(memf, 'w').write('@00000000\n' + '\n'.join('%08x' % w for w in data) + '\n')
            r = subprocess.run([a.updatemem, '-meminfo', mmif, '-data', memf, '-bit', cur, '-proc', proc, '-out', outf, '-force'],
                               capture_output=True, text=True)
            if r.returncode or not os.path.exists(outf) or 'ERROR' in r.stdout:
                die('updatemem failed on %s:\n%s%s' % (kind, r.stdout[-800:], r.stderr[-400:]))
            cur = outf
        data = open(cur, 'rb').read()
    open(a.out, 'wb').write(data)
    print('wrote', a.out)

main()
