#!/usr/bin/env python3
"""loader_update.py : replace the resident program (the loader) inside a built VC707 bitstream, with no rebuild.

    loader_update.py --bit in.bit --cells out/ram_cells.txt --program program.hex --data data.hex --out new.bit

The resident program lives in explicit block RAMs: its code in core/code_rom_i/b0..b31 (one bit each, 32K deep)
and its heap and globals images in core/data_rom_i/b0..b31 (tools/gen_rom_bram.py, tools/progimage.sh make the
files).  build.tcl lists where each went in out/ram_cells.txt; this writes a memory-info file for each ROM from
that and runs Vivado's updatemem to put new contents in.  The new program and data must fit the ROMs the
bitstream was built with (32768 words), and the core RTL must be the same one the bitstream has: only the
program changes.
"""
import argparse, os, re, subprocess, sys, tempfile

def die(m):
    sys.exit("loader_update: " + m)

def mmi(planes, name, depth, part):
    x = ['<?xml version="1.0" encoding="UTF-8"?>', '<MemInfo Version="1" Minor="0">',
         '  <Processor Endianness="Little" InstPath="%s">' % name,
         '    <AddressSpace Name="%s" Begin="0" End="%d">' % (name, depth * 4 - 1), '      <BusBlock>']
    for bit, loc in sorted(planes.items(), reverse=True):
        x += ['        <BitLane MemType="RAMB32" Placement="%s">' % loc.replace('RAMB36_', ''),
              '          <DataWidth MSB="%d" LSB="%d"/>' % (bit, bit),
              '          <AddressRange Begin="0" End="%d"/>' % (depth - 1),
              '          <Parity ON="false" NumBits="0"/>', '        </BitLane>']
    x += ['      </BusBlock>', '    </AddressSpace>', '  </Processor>', '  <Config>',
          '    <Option Name="Part" Val="%s"/>' % part, '  </Config>', '</MemInfo>']
    return '\n'.join(x) + '\n'

def main():
    ap = argparse.ArgumentParser()
    for a in ('--bit', '--cells', '--program', '--data', '--out'):
        ap.add_argument(a, required=True)
    ap.add_argument('--updatemem', default='/opt/Xilinx/Vivado/2020.1/bin/updatemem')
    ap.add_argument('--part', default='xc7vx485tffg1761-2')
    a = ap.parse_args()
    cells = [l.split() for l in open(a.cells) if l.strip()]
    roms = {}
    for n, loc, width, ref in cells:
        m = re.search(r'/(code_rom_i|data_rom_i)/b(\d+)$', n)
        if m and ref == 'RAMB36E1':
            if int(width) != 1: die('%s is not a x1 plane' % n)
            roms.setdefault(m.group(1), {})[int(m.group(2))] = loc
    for need in ('code_rom_i', 'data_rom_i'):
        if len(roms.get(need, {})) != 32: die('the cell list has %d planes of %s, not 32' % (len(roms.get(need, {})), need))
    cur = a.bit
    with tempfile.TemporaryDirectory() as t:
        for rom, hexf, label in (('code_rom_i', a.program, 'program'), ('data_rom_i', a.data, 'data')):
            depth = 32768
            words = [int(l.split('//')[0], 16) for l in open(hexf) if l.split('//')[0].strip()]
            if len(words) > depth: die('%s is %d words; the ROM holds %d' % (label, len(words), depth))
            print('%s: %d of %d words' % (label, len(words), depth))
            words += [0] * (depth - len(words))
            mmif, memf, outf = (os.path.join(t, label + e) for e in ('.mmi', '.mem', '.bit'))
            open(mmif, 'w').write(mmi(roms[rom], label + '_proc', depth, a.part))
            open(memf, 'w').write('@00000000\n' + '\n'.join('%08x' % w for w in words) + '\n')
            r = subprocess.run([a.updatemem, '-meminfo', mmif, '-data', memf, '-bit', cur, '-proc', label + '_proc',
                                '-out', outf, '-force'], capture_output=True, text=True)
            if r.returncode or not os.path.exists(outf) or 'ERROR' in r.stdout:
                die('updatemem failed on the %s:\n%s%s' % (label, r.stdout[-800:], r.stderr[-400:]))
            cur = outf
        data = open(cur, 'rb').read()
    open(a.out, 'wb').write(data)
    print('wrote', a.out)

main()
