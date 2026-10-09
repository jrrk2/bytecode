#!/bin/bash
# selfhost_nodisk.sh : the compiler compiles io/comp.ml with no RAM disk at all, on the host.
# The source comes from, and the image goes to, ethmodel.c's NFS server (a directory), through the channel layer and the streaming
# image builder; then the same compile is made the conventional way, into the RAM disk, and the two images are compared.
# usage: tools/selfhost_nodisk.sh [workdir]      (default /tmp/selfhost_nodisk)
set -e
B=$(cd "$(dirname "$0")/.." && pwd); W=${1:-/tmp/selfhost_nodisk}
rm -rf "$W"; mkdir -p "$W/root"; cd "$W"
cp "$B/io/comp.ml" comp.ml; cp "$B/io/comp.ml" root/comp.ml
/usr/bin/ocamlc -nopervasives -custom -runtime-variant d -ccopt -I"$B" comp.ml "$B/io/io_stubs.c" "$B/ethmodel.c" -o comp.ref 2>/dev/null
# blank lines first: each is a poll, and the DHCP exchange has to finish before the NFS client has an address; #nfs names the server and the mount point (the host runner can't call nfs_server)
{ for i in $(seq 1 1500); do echo; done; echo '#nfs 192.168.1.106 /nfs'; echo '#image /nfs/stage2.img /nfs/comp.ml'; } > in.txt
ETHMODEL_NODISK=1 ETHMODEL_NFS_ROOT="$W/root" ETHMODEL_UART_INPUT=in.txt timeout 1800 ./comp.ref > run.log 2>&1 || true
grep "uart: image /nfs" run.log
DISK_KIB=4096 python3 "$B/tools/mkdisk.py" d.disk comp.ml=comp.ml > /dev/null
echo '#image a.img comp.ml' > in2.txt
ETHMODEL_DISK=d.disk ETHMODEL_UART_INPUT=in2.txt timeout 900 ./comp.ref 2>&1 | grep "uart: image a.img:"
python3 - <<'P'
import struct, sys
d = open('d.disk', 'rb').read(); n = struct.unpack('<I', d[4:8])[0]; a = None
for k in range(n):
    e = d[16 + k * 32:16 + k * 32 + 32]
    if e[:24].rstrip(b'\0') == b'a.img':
        off, ln = struct.unpack('<II', e[24:]); a = d[off:off + ln]
b = open('root/stage2.img', 'rb').read()
print("stage2.img (no RAM disk): %d bytes; a.img (RAM disk): %d bytes: %s" % (len(b), len(a or b''), "IDENTICAL" if a == b else "DIFFERENT"))
sys.exit(0 if a == b else 1)
P
