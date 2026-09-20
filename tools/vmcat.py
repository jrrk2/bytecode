#!/usr/bin/env python3
"""vmcat.py [host] [port] -- talk to the VM's network REPL (io/repl.ml) a line
at a time over UDP, like `nc -u` but line-based: each line typed (or piped in)
is sent as one datagram, and replies are printed whenever they arrive, however
long the evaluation takes.  Piped input waits for each reply before the next
line is sent, because the board keeps only one received frame while it is busy
evaluating.  Ctrl-D (or the end of piped input) quits; --wait N sets how many
seconds to wait for the last reply (default 30).
"""
import argparse, os, select, socket, sys, time

ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
ap.add_argument("host", nargs="?", default="192.168.1.233")
ap.add_argument("port", nargs="?", type=int, default=7777)
ap.add_argument("--wait", type=float, default=30.0, help="seconds to wait for a reply to piped input")
args = ap.parse_args()

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect((args.host, args.port))
interactive = sys.stdin.isatty()
if interactive:
    try:
        import readline  # noqa: F401  (line editing and history for input())
    except ImportError:
        pass

def show(data):
    sys.stdout.write(data.decode("latin-1").replace("\r\n", "\n"))
    sys.stdout.flush()

def drain(timeout):
    """Print replies until none arrives for `timeout` seconds."""
    got = False
    while select.select([s], [], [], timeout)[0]:
        try:
            show(s.recv(2048))
        except ConnectionRefusedError:  # ICMP port unreachable: nothing listening
            print("(port unreachable)")
        got = True
        timeout = 0.2  # the rest of a multi-datagram reply follows quickly
    return got

if interactive:
    # The REPL prints its own "# " prompt; print replies as they come, in the
    # background of input(), by polling between lines.
    print(f"vmcat: {args.host}:{args.port}, one line per datagram; Ctrl-D quits")
    while True:
        drain(0)
        try:
            line = input()
        except EOFError:
            break
        s.send((line + "\n").encode())
        if not drain(args.wait):
            print(f"(no reply in {args.wait:g} s)")
else:
    for line in sys.stdin:
        line = line.rstrip("\n")
        print(f">>> {line}")
        s.send((line + "\n").encode())
        t = time.time()
        if drain(args.wait):
            if os.environ.get("VMCAT_TIME"):
                print(f"({time.time() - t:.2f} s)")
        else:
            print(f"(no reply in {args.wait:g} s)")
