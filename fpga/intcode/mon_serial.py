"""mon_serial.py : talk to the INTCODE monitor on the Sonata's UART (/dev/ttyUSB5, 115200 8N1) from the host, and build reference results with the kit's own compiler."""
import os, shutil, subprocess, tempfile, time
import serial

KIT = os.environ.get('KIT', os.path.expanduser('~/bcplkit-0.9.7/src'))


class Mon:
    def __init__(self, port='/dev/ttyUSB5'):
        self.s = serial.Serial(port, 115200, timeout=0.2)

    def read_until(self, pat, timeout):
        buf = b''; t = time.time()
        while time.time() - t < timeout:
            d = self.s.read(4096)
            if d: buf += d
            if pat in buf[-len(pat) - 8:]:
                time.sleep(0.15); buf += self.s.read(4096)
                return buf
        return buf

    def cmd(self, line, timeout=60, prompt=b'\n>'):
        """type a line (the monitor echoes it), return everything up to the next prompt; the board's ENQ flow-control bytes are removed"""
        self.s.reset_input_buffer()
        for ch in line.encode() + b'\n':
            self.s.write(bytes([ch])); self.s.flush(); time.sleep(0.004)
        return self.read_until(prompt, timeout).replace(b'\x05', b'')

    def wake(self):
        self.s.write(b'\n'); time.sleep(0.5); self.s.reset_input_buffer()

    def run(self, line, timeout=60):
        return ' '.join(self.cmd(line, timeout).decode('latin-1').replace('\r', '').split())

    def cat(self, name, timeout=120):
        out = self.cmd('cat ' + name, timeout).decode('latin-1').replace('\r', '')
        body = out.split('\n', 1)[1]
        return body[:body.rfind('\n>')].encode('latin-1')


def host_ref(name):
    """what the kit's compiler (the C interpreter running st.int and cg.int) makes of the kit's NAME.b"""
    d = tempfile.mkdtemp()
    for f in ('LIBHDR', 'SYNHDR', 'TRNHDR', 'CGHDR', 'st.int', 'cg.int', name + '.b'): shutil.copy(os.path.join(KIT, f), d)
    subprocess.run([KIT + '/icint', 'st.int'], stdin=open(d + '/' + name + '.b'), cwd=d, stdout=subprocess.DEVNULL, check=True)
    subprocess.run([KIT + '/icint', 'cg.int'], stdin=open(d + '/OCODE'), cwd=d, stdout=subprocess.DEVNULL, check=True)
    r = open(d + '/INTCODE', 'rb').read(); shutil.rmtree(d); return r
