# Known-good open-flow build of vc707_ethmin_vm (2026-10-11)

A bitstream built through the open flow (yosys, nextpnr, prjxray) from the source at `a8fbc3e` booted on a VC707 with working Ethernet:
banner `a8fbc3e open`, DHCP, NFS, the self-compiled compiler (`stage2.img`, OCVM, 78477 code words) and `355. /. 113.` giving `3.141593`.
Vivado's build of the same tree meets timing too (WNS +2.2 ns at 50 MHz) and boots.

**The one thing that has to be right is the Eigen that nextpnr's HeAP placer was built against.**  It solves a sparse system, and the
version decides the placement.  The same netlist placed with Eigen 5.0.1 (what a miniconda on the search path gives) boots the CPU and
the UART and then never transmits on Ethernet, while every timing check nextpnr makes passes (`eth_tx_clk` 260 MHz against 125 required);
placed with the system Eigen 3.4.0 and `--placer-heap-timingweight 60` it works.  openXC7/nextpnr's `.github/workflows/demos.yml` records
the same finding for another SoC and builds Eigen 3.4.0 from its tag for that reason.  `open_build.sh` now defaults the timing weight, and
prints a warning if the nextpnr it is given was not built against 3.4.0.

| piece | version |
|---|---|
| this repository | `a8fbc3e` or later on this branch (the only source change after it is to `open_build.sh` and this file) |
| yosys | 0.63+173 (git 66306a8ca), from xc7-bitstream-tools `yosys-install`, built with g++ 11.5.0; the same commit in oss-cad-suite (clang++ 18.1.8) gives the same netlist |
| sv2v | v0.0.13-11-g6662fa5 |
| nextpnr-himbaechel | openXC7/nextpnr `e558304b` (branch `bram-cascade-cluster`; PR openXC7/nextpnr#87 is its upstreamable part), built for xc7vx485t only against **system Eigen 3.4.0**, its chipdb generated from the database below |
| prjxray database | openXC7/database-virtex7 `bdab7fe`, branch `ethmin-open-flow-fixes` (https://github.com/openXC7/database-virtex7/tree/ethmin-open-flow-fixes), checked out as `~/prjxray/database/virtex7`; one commit on top of that repo's `main` (`cf39b5a`) |
| prjxray tools / `convert.py` | xc7-bitstream-tools `61d60e4` |
| defines | `SYS_DIV=20.000 CLK_HZ=50000000` (50 MHz), `ROUTER=router2`, `-o hold-fix`, `--placer-heap-timingweight 60` |
| result | router2 15 iterations, `clk_sys` 51.01 MHz (passes at 50), `eth_tx_clk` 282 MHz |

## Rebuild

    # nextpnr: the source above, the system Eigen, the chipdb from the database above
    cmake -S <xc7-bitstream-tools>/nextpnr -B <build> -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF \
          -DHIMBAECHEL_XILINX_DEVICES="xc7vx485t" -DHIMBAECHEL_PRJXRAY_DB=<prjxray>/database \
          -DEigen3_DIR=/usr/share/eigen3/cmake -DCMAKE_IGNORE_PREFIX_PATH=$HOME/miniconda3
    cmake --build <build> --target nextpnr-himbaechel --parallel 8
    grep Eigen3_DIR <build>/CMakeCache.txt          # must say /usr/share/eigen3/cmake
    # the design.  The program images are generated and gitignored: a clean checkout needs this first.
    tools/progimage.sh io/netboot.ml fpga/vc707-ethmin
    NEXTPNR=<build>/nextpnr-himbaechel PRJXRAY_DB=<prjxray>/database YOSYS_DEFS="-DSYS_DIV=20.000 -DCLK_HZ=50000000" \
        WORK=<dir> fpga/vc707-ethmin/open_build.sh

`open_build.sh` writes `provenance.txt` into the work directory: tool versions, the Eigen the nextpnr binary was built against, the
database revision, the defines, and the sha256 of the netlist, FASM and bitstream.  Compare that before comparing anything else.
The bitstream that booted is kept at `~/bytecode-work/backup-open-bitstream-20261011-eigen34/` (sha256 `bff3627c72d27faf…`).

## What is and is not reproducible

* **yosys, nextpnr and sv2v are deterministic** for identical input: re-running yosys on the same inputs gives the same netlist (and
  the oss-cad-suite build of the same yosys commit gives it too), and nextpnr gives byte-identical FASM from the same netlist, binary and flags.
* **The 32-bit `BUILD_ID` constant changes the netlist.**  It is a constant in the synthesized logic, the commit id, and a different value
  re-maps thousands of cells across the design (3,668 cell kinds differ between two builds that differ only in it).  So every commit is a
  different netlist and a different placement.  With the setup above that has worked each time it was tried; with a different Eigen it is
  a lottery.  Stamping the build id into a ROM that is patched into the bitstream afterwards (as `tools/loader_update.py` patches the
  resident program) would keep the netlist stable across commits; not done.
* A bitstream built before this note, `backup-open-bitstream-20261010`, came from a nextpnr built against Eigen 5.0.1 and is a placement
  that happened to work.  Do not treat it as the reference.
* The nextpnr on current openXC7/nextpnr `main` (plus the two fixes of #87) has not been tried with Eigen 3.4.0.  An earlier attempt
  linked Eigen 5.0.1 and its router did not converge on the old netlist, which is no longer evidence about `main`.
