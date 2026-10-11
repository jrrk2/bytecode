# Known-good open-flow build of vc707_ethmin_vm (2026-10-10)

The nextpnr (open flow) bitstream built from this tree booted on a VC707: banner `d249787+ open` (the commit id in the banner is the
tree's HEAD at build time), DHCP, NFS, the self-compiled compiler (`stage2.img`, OCVM, 78477 code words) booting and running.  Its
`clk_sys` is 44.26 MHz at a 50 MHz request in nextpnr's estimate (the build allows that, `--timing-allow-fail`), router2 converged in 15
iterations.  Vivado's build of the same tree met timing (WNS +2.2 ns) and boots too.  Everything that went into it:

| piece | version |
|---|---|
| this repository | `e499e9b` (the SD and code/staging RAM changes) |
| yosys | 0.63+173 (git 66306a8ca), from xc7-bitstream-tools `yosys-install` |
| sv2v | v0.0.13-11-g6662fa5 |
| nextpnr-himbaechel | openXC7/nextpnr `e558304b` (branch `bram-cascade-cluster`; PR openXC7/nextpnr#87 is its upstreamable part), built for xc7vx485t only, its chipdb generated from the database below |
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
the design is the same; compare FASM with that in mind.  A build from a newer nextpnr (current openXC7/nextpnr `main` plus the two
fixes of #87) did NOT converge on this netlist: router2 was at iteration 493 with about 1000 overused wires and rising, where this
combination finished in 15.  Do not move nextpnr or the database without checking that, and booting, again.

SHA-256 of the bitstream that booted: `2d0e0849e1661a0bbe57c4960936688fec64ab3856bfe619c600d8c768dc6484`
(kept at `~/bytecode-work/backup-open-bitstream-20261010/`).
