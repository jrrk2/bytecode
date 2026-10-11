# Known-good open-flow build of vc707_ethmin_vm (2026-10-10)

A bitstream built through the open flow (yosys, nextpnr, prjxray) booted on a VC707 from the netlist described below: banner
`d249787+ open`, DHCP, NFS, the self-compiled compiler (`stage2.img`, OCVM, 78477 code words) booting and running.  Vivado's build
of the same tree met timing (WNS +2.2 ns) and boots too.

**This branch does not by itself reproduce that bitstream.**  A fresh synthesis at this commit gives a bitstream whose Ethernet
transmit never works (the UART and CPU are fine).  The only input that differs between the two syntheses is the 32-bit `BUILD_ID`
(the commit id), yet the yosys netlists differ in hundreds of LUT mappings.  The working one came from the netlist file
`ethmin-open-50/vc707_ethmin_vm.json` (sha256 `903d8425...`, BUILD_ID `32'h3d249787`) put through nextpnr with `SKIP_SYNTH=1`; the
failing one is netlist `1f3cd55a...` (BUILD_ID `32'h2a8fbc3e`).  Both used the same yosys, nextpnr binary, Eigen and database below.
Until that is understood, treat the netlist, not the source, as the artifact worth keeping.  `open_build.sh` now writes
`provenance.txt` into the work directory (tool versions, the compiler yosys was built with, the Eigen nextpnr was built against,
database revision, defines, and sha256 of netlist, FASM and bitstream) so builds can be compared.

| piece | version |
|---|---|
| this repository | `e499e9b` (the SD and code/staging RAM changes) |
| yosys | 0.63+173 (git 66306a8ca), from xc7-bitstream-tools `yosys-install`, built with g++ 11.5.0 (the same commit in oss-cad-suite is built with clang++ 18.1.8) |
| sv2v | v0.0.13-11-g6662fa5 |
| nextpnr-himbaechel | openXC7/nextpnr `e558304b` (branch `bram-cascade-cluster`; PR openXC7/nextpnr#87 is its upstreamable part), built for xc7vx485t only, its chipdb generated from the database below; the binary that was used linked **Eigen 5.0.1** (miniconda), not the system Eigen 3.4.0 that `xc7-bitstream-tools` uses, and Eigen changes the placer's result |
| prjxray database | openXC7/database-virtex7 `bdab7fe`, as `~/prjxray/database/virtex7` (not on a remote branch when this was written) |
| prjxray tools / `convert.py` | xc7-bitstream-tools `61d60e4` |
| defines | `SYS_DIV=20.000 CLK_HZ=50000000` (50 MHz), `ROUTER=router2`, `-o hold-fix` |

## Rebuild

    # nextpnr: the source above, the chipdb from the database above
    cmake -S <xc7-bitstream-tools>/nextpnr -B <build> -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF \
          -DHIMBAECHEL_XILINX_DEVICES="xc7vx485t" -DHIMBAECHEL_PRJXRAY_DB=<prjxray>/database
    cmake --build <build> --target nextpnr-himbaechel --parallel 8
    # the design
    tools/progimage.sh io/netboot.ml fpga/vc707-ethmin
    NEXTPNR=<build>/nextpnr-himbaechel PRJXRAY_DB=<prjxray>/database YOSYS_DEFS="-DSYS_DIV=20.000 -DCLK_HZ=50000000" \
        WORK=<dir> fpga/vc707-ethmin/open_build.sh

The bitstream embeds `BUILD_ID` (the commit and a dirty bit), so two builds of different commits differ in those bits even when
the design is the same; compare FASM with that in mind.  A build from a newer nextpnr (current openXC7/nextpnr `main` plus the fixes of #87) did not converge on the old netlist (router2 was at
iteration 493 with about 1000 overused wires, rising, where the working build finished in 15).  That build also linked Eigen 5.0.1,
so it is not evidence about `main`; it has not been repeated with Eigen 3.4.0.

SHA-256 of the bitstream that booted: `2d0e0849e1661a0bbe57c4960936688fec64ab3856bfe619c600d8c768dc6484`
(kept at `~/bytecode-work/backup-open-bitstream-20261010/`).
