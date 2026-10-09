# Files over NFS

The REPL (`io/comp.ml`) can fetch a file from an NFS server straight into
the RAM disk, where `run_file` compiles it into the running session.  That
is how a library gets onto the board without rebuilding the image: the
transcendental functions used to sit in the image, unreachable, and now
live on the server as source.

The client speaks ONC RPC over **UDP** and NFS **version 3**: portmap for
mountd, mount for the root handle, portmap for nfsd, look the name up in
the root, then read it in 1 KiB pieces.  Each piece is written to the disk
as it arrives, so nothing is buffered anywhere else and the file lands
where it will live.

## The commands

    nfs_server : string -> int        the server, as a dotted quad
    nfs_fetch  : string -> string -> int   export, then file name
    nfs_done   : int -> int           how the last fetch went

`nfs_server` returns 1 if the address parsed, 0 otherwise.  It is a string
rather than a number because a 31-bit int cannot hold every IPv4 address:
`172.16/12` has no representation at all and `192.168/16` only as a
negative one.

`nfs_fetch` returns 1 if a load started and 0 if it was refused -- no
address yet, no DHCP lease, a load already running, or a name longer than
24 characters.  It returns **immediately**: the replies arrive in later
polls, so ask `nfs_done` for the outcome.

`nfs_done` returns -1 while a load is running and before the first one, -2
if the last one failed, and otherwise the number of bytes it fetched.  It
holds that answer until the next `nfs_fetch` starts, so ask it before
fetching again rather than after.  A failure also
prints its reason on the UART: `no mountd`, `mount refused`, `bad handle`,
`no such file`, `read refused`, `disk full`, `no answer`.  Each step is
retried four times at 1.5 s before `no answer`.

The file then behaves as any other on the RAM disk:

    read_file  : string -> string
    run_file   : string -> int        compile it into this session
    files      : int -> int           list them; the argument is ignored

## A session

Typed at `nc -u 192.168.1.233 7777`, against `maths.ml` on the export:

    # nfs_server "192.168.1.224"
    - : int = 1
    # nfs_fetch "/srv/nfs/vc707" "maths.ml"
    - : int = 1
    # nfs_done 0
    - : int = 2028
    # files 0
    maths.ml  2028
    - : int = 1
    # run_file "maths.ml"
    val ln2 : float = 0.693147
    ...
    - : int = 32   (62 ms)
    # atan2 1.0 1.0
    - : float = 0.785398
    # pow 2.0 10.0
    - : float = 1024.

32 phrases compiled in 62 ms.  `exp 1.0` gives 2.718282, `log 10.0`
2.302585, `atan 2.0` 1.107149 and `tan 0.7853981` 0.999999.

## The server

The export must admit the board's address.  A line such as

    /srv/nfs/vc707 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)

is enough; `insecure` is not needed, because the client binds port 1010 and
an export without `insecure` insists on a privileged one.  Two things are
worth checking before blaming the board, because a server that refuses
looks much like one that is not there:

    rpcinfo -p localhost | grep udp     # 100003 3 udp 2049 must be listed

NFS over UDP is off by default in some distributions (`udp=y` in
`/etc/nfs.conf`), and this client has no TCP.  The address to give
`nfs_server` is the host's address *on the board's network*, which follows
whichever interface is up -- `ip -4 -brief addr` rather than memory.

## Limits

The RAM disk is 512 KiB of block RAM at 0x100000, holding at most 64 files
with names up to 24 characters.  It survives a chain load, because neither
the sequencer nor the VM's reset reaches it, but not power off.

A fetch owns the free space above the last file until it commits, so do not
`write_file` while one is in flight.  Nothing is reclaimed: rewriting a
file appends a second copy and the newest name wins.

Reading a large file back with `read_file` over UDP is cut to about 1400
bytes by the reply buffer -- the file on the disk is whole, and `files`
shows its real length.

## The loader boots over NFS

`io/netboot.ml` (the resident loader) fetches `vm.img` and, unless the RAM disk already holds a file system, `disk.img`
from the export `/srv/nfs/vc707` on the boot server (the DIP switches' host number, or the DHCP siaddr), in the directory
`bytecode/<mac>/` -- here `bytecode/02:00:00:4d:47:33/` -- and only if NFS gets no answer falls back to TFTP.  The client is the
same text as the REPL's: `io/nfs.ml`, spliced into both `io/comp.ml` and `io/netboot.ml` by `tools/nfs_splice.py` (run
it after editing `io/nfs.ml`; `--check` says whether the copies are current).  Neither program can call into the other:
the loader is a separate code bank and a loaded image replaces the heap and globals.  A path may have several components
(`dir/dir/file`), each looked up in turn.  Boot files are copied into the export, not linked (a symbolic link cannot be read).

## Booting with nothing on the network

`tools/preload.py` sets the initial contents of the staging RAM and the RAM disk in a built bitstream (no rebuild: Vivado's
`updatemem`, with the tile table `out/ram_slices.txt`).  The loader looks at the end of the staging RAM first: "PREL" at
0x3FFF0, then the image length in three bytes, and the image from offset 0; if they check out it boots that, before DHCP
or NFS (hold a button to skip it).  So

    python3 tools/loader_update.py --bit B.bit --cells out/ram_cells.txt --program program.hex --data data.hex --out L.bit
    python3 tools/preload.py --bit L.bit --slices out/ram_slices.txt --out P.bit stage=stage.bin disk=disk.img

gives a bitstream that starts the compiler, with its source files on the RAM disk, from power-up.

## NFS files by name

From a session on the UART the channel functions take `nfs(U,P)path` as a file name: `open_in`, `open_out`, `read_file`,
`write_file`, `run_file`.  U is the server's host number on the board's network (0: the address `nfs_server` set), P is
ignored, and the path is below the export `nfs_root` names (default `/srv/nfs/vc707`).

    nfs_server "192.168.1.106"
    write_file "nfs(0,0)bytecode/hello.txt" "hello from the board"
    read_file "nfs(0,0)bytecode/hello.txt"

Reading fetches the whole file into the RAM disk under its last component (at most 24 characters) and opens that, so the
file is a copy: a second `open_in` of the same name fetches it again.  Writing goes to a scratch file of that name on the
RAM disk and `close_out` creates the file on the server (mode 0644, an existing one is truncated) and sends it, in 1 KiB WRITEs,
FILE_SYNC; `flush` alone sends nothing.  The calls wait for the replies, which is only safe in a UART session (the TX window
holds a network session's reply and the receive window its command), so in a telnet or UDP session they raise `Sys_error`;
`nfs_fetch` still works there.  The writes are made as uid 0, so the export needs `no_root_squash` (or the directory to be
writable by whoever it maps root to).
