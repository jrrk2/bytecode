#!/usr/bin/env python3
"""check_frames.py log [replies] [vm_ip] [vm_mac]: validate the frames ethmin/dhcp sent
('eth: TX' lines): ARP and ICMP replies (counted: expect `replies`, default 3) from
vm_ip (default 192.168.1.42) and vm_mac (default 02:00:00:4d:47:31), and DHCP
DISCOVER/REQUEST broadcasts."""
import sys
def csum(b):
    s = sum((b[i] << 8) | (b[i + 1] if i + 1 < len(b) else 0) for i in range(0, len(b), 2))
    while s >> 16: s = (s & 0xFFFF) + (s >> 16)
    return s  # 0xFFFF when the embedded checksum is right
VM_MAC = bytes.fromhex((sys.argv[4] if len(sys.argv) > 4 else '02:00:00:4d:47:31').replace(':', ''))
VM_IP = bytes(int(x) for x in (sys.argv[3] if len(sys.argv) > 3 else '192.168.1.42').split('.'))
HOST_MAC, HOST_IP = bytes.fromhex('10 e2 d5 00 00 01'), bytes([192, 168, 1, 106])
ok, n = True, 0
for line in open(sys.argv[1]):
    if not line.startswith('eth: TX'): continue
    f = bytes.fromhex(''.join(line.split()[3:]))
    if f[12:14] == b'\x08\x00' and f[23] == 17:          # UDP: a DHCP client broadcast
        ip = f[14:34]; udp = f[34:42]; bootp = f[42:]
        opts = bootp[240:]; msg = None; i = 0
        while i < len(opts) and opts[i] != 255:
            if opts[i] == 0: i += 1; continue
            if opts[i] == 53: msg = opts[i + 2]
            i += 2 + opts[i + 1]
        good = (f[0:6] == b'\xff' * 6 and f[6:12] == VM_MAC and csum(ip) == 0xFFFF
                and ip[12:16] == bytes(4) and ip[16:20] == b'\xff' * 4
                and udp[0:4] == bytes([0, 68, 0, 67]) and bootp[0] == 1
                and bootp[28:34] == VM_MAC and bootp[236:240] == bytes([0x63, 0x82, 0x53, 0x63])
                and msg in (1, 3))
        print(f'  dhcp {"DISCOVER" if msg == 1 else "REQUEST" if msg == 3 else msg}: {"ok  " if good else "FAIL"}')
        ok &= good
        continue
    n += 1
    def check(cond, what):
        global ok
        print(f'  frame {n}: {"ok  " if cond else "FAIL"} {what}'); ok &= cond
    check(f[0:6] == HOST_MAC and f[6:12] == VM_MAC, 'addressed host <- vm')
    if f[12:14] == b'\x08\x06':
        check(f[20:22] == b'\x00\x02' and f[22:28] == VM_MAC and f[28:32] == VM_IP
              and f[32:38] == HOST_MAC and f[38:42] == HOST_IP, 'ARP reply fields')
    else:
        ihl = (f[14] & 15) * 4; ip = f[14:14 + ihl]; total = (f[16] << 8) | f[17]
        check(csum(ip) == 0xFFFF, 'IP header checksum')
        check(ip[12:16] == VM_IP and ip[16:20] == HOST_IP, 'IP addresses swapped')
        icmp = f[14 + ihl:14 + total]
        check(icmp[0] == 0 and csum(icmp) == 0xFFFF, 'ICMP echo reply + checksum')
want = int(sys.argv[2]) if len(sys.argv) > 2 else 3
print('frames:', n, 'PASS' if ok and n == want else 'FAIL (want %d)' % want)
sys.exit(0 if ok and n == want else 1)
