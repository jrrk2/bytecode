#!/usr/bin/env python3
"""dhcp_mini.py SERVER_IP [CLIENT_IP] -- the smallest DHCP server that will do.

For a direct cable to the board: answers every DISCOVER with an OFFER and
every REQUEST with an ACK, hands out one address, names this host as the
TFTP server (siaddr) and "vm.img" as the file, and prints each step -- so
the question "does the board hear the reply?" is answered by whether a
REQUEST ever follows the OFFER.

    sudo python3 dhcp_mini.py 192.168.1.106            # this host's address
    sudo python3 dhcp_mini.py 192.168.1.106 192.168.1.233

Port 67 needs root.  No leases, no options beyond the ones the loader reads
(subnet mask, server id, lease time, siaddr/file), and no state: it answers
whatever asks.
"""
import socket, struct, sys, time

MAGIC = b'\x63\x82\x53\x63'


def parse(pkt):
    if len(pkt) < 240 or pkt[236:240] != MAGIC:
        return None
    op, htype, hlen, hops = pkt[0:4]
    xid = pkt[4:8]
    chaddr = pkt[28:28 + 6]
    opts, i, msgtype = {}, 240, None
    while i < len(pkt):
        t = pkt[i]
        if t == 255:
            break
        if t == 0:
            i += 1
            continue
        n = pkt[i + 1]
        opts[t] = pkt[i + 2:i + 2 + n]
        i += 2 + n
    return dict(xid=xid, mac=chaddr, type=opts.get(53, b'\0')[0], opts=opts)


def build(msgtype, xid, mac, yiaddr, server_ip, filename):
    p = bytearray(240)
    p[0:4] = bytes([2, 1, 6, 0])            # reply, ethernet, hlen 6
    p[4:8] = xid
    p[10:12] = b'\x80\x00'                  # broadcast flag: the client has no address yet
    p[16:20] = socket.inet_aton(yiaddr)
    p[20:24] = socket.inet_aton(server_ip)  # siaddr: where to fetch the file from
    p[28:34] = mac
    f = filename.encode()
    p[108:108 + len(f)] = f
    p[236:240] = MAGIC
    opts = bytes([53, 1, msgtype,
                  1, 4]) + socket.inet_aton('255.255.255.0') + \
           bytes([54, 4]) + socket.inet_aton(server_ip) + \
           bytes([51, 4]) + struct.pack('>I', 3600) + \
           bytes([255])
    return bytes(p) + opts


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    server_ip = sys.argv[1]
    client_ip = sys.argv[2] if len(sys.argv) > 2 else '192.168.1.233'
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(('', 67))
    print(f"dhcp_mini: serving {client_ip} to anyone, tftp from {server_ip}:vm.img")
    names = {1: 'DISCOVER', 2: 'OFFER', 3: 'REQUEST', 5: 'ACK', 7: 'RELEASE'}
    while True:
        pkt, (src, _) = s.recvfrom(1500)
        m = parse(pkt)
        if not m:
            continue
        mac = ':'.join(f'{b:02x}' for b in m['mac'])
        stamp = time.strftime('%H:%M:%S')
        kind = names.get(m['type'], str(m['type']))
        print(f"[{stamp}] {kind:8s} from {mac} xid {m['xid'].hex()}", flush=True)
        if m['type'] == 1:
            s.sendto(build(2, m['xid'], m['mac'], client_ip, server_ip, 'vm.img'), ('255.255.255.255', 68))
            print(f"[{stamp}]   -> OFFER {client_ip}", flush=True)
        elif m['type'] == 3:
            s.sendto(build(5, m['xid'], m['mac'], client_ip, server_ip, 'vm.img'), ('255.255.255.255', 68))
            print(f"[{stamp}]   -> ACK   {client_ip}", flush=True)


if __name__ == '__main__':
    main()
