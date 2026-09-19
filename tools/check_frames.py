#!/usr/bin/env python3
"""check_frames.py log: validate the ARP and ICMP replies ethmin sent ('eth: TX' lines)."""
import sys
def csum(b):
    s = sum((b[i] << 8) | (b[i + 1] if i + 1 < len(b) else 0) for i in range(0, len(b), 2))
    while s >> 16: s = (s & 0xFFFF) + (s >> 16)
    return s  # 0xFFFF when the embedded checksum is right
VM_MAC, VM_IP = bytes.fromhex('02 00 00 4d 47 31'), bytes([192, 168, 1, 42])
HOST_MAC, HOST_IP = bytes.fromhex('10 e2 d5 00 00 01'), bytes([192, 168, 1, 106])
ok, n = True, 0
for line in open(sys.argv[1]):
    if not line.startswith('eth: TX'): continue
    f = bytes.fromhex(''.join(line.split()[3:])); n += 1
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
