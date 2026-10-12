# VC707 `vc707-ocaml` design: Ethernet transmit is dead in some nextpnr placements

Everything here was measured on one VC707 (xc7vx485tffg1761-2) with scripted serial capture; see `PR-table.md` for the results table
and `captures/` for the raw console output of each run.

## The design and the test

`vc707_ethmin_vm.json.gz` is the yosys netlist (yosys 0.63+173, `synth_xilinx -flatten -abc9`, `SYS_DIV=20.000 CLK_HZ=50000000`) of the
OCaml bytecode processor in this repository (`ocaml4142_vm_rtl.sv` and `fpga/vc707-ethmin`) with SGMII Ethernet, SD host and an FPU.  It is
the netlist behind every row of the table except the one marked "fresh netlist".  The constraints are `../vc707_ethmin_vm_open.xdc`.
After configuration the resident loader prints a banner on the UART, leases an address by DHCP over the SGMII link, fetches a
327988-byte image by NFS, starts the REPL in it, and the harness types `355. /. 113.`.  PASS needs all of that.  FAIL is
`dhcp: discover` / `dhcp: timeout` forever (the PHY never receives a frame: the board's TX light never flashes).

## What the table shows, in short

* The `.IN` fix (openXC7/nextpnr, branch `hp-input-in-both-halves`) is needed on this board: without it CPU_RESET and a push button share
  `LIOB18_X81Y128`, the receive buffer is disabled, reset reads constant high, and there is **no serial output at all**.  The
  `vc707-ocaml` artifact built by nextpnr's own CI (Sep 23, before the fix) has no `.IN` feature on that tile and shows the same.
* The placer's Eigen version decides the placement.  The same netlist placed by a nextpnr linked against Eigen 5.0.1 boots the CPU
  and never transmits; against 3.4.0 with `--placer-heap-timingweight 60` (what nextpnr's CI uses) it works.  Every nextpnr timing
  check passes in both.
* With Eigen 3.4.0, `e558304b` (openXC7/nextpnr `bram-cascade-cluster`) passed 5 of 5 placements and `main` + the `.IN` fix 2 of 4.
  That is not a significant difference (one-sided Fisher exact p = 0.17).
* Each bitstream behaves the same on every reload (3 of 3 each for a failing and a passing one), so pass or fail belongs to the placed and
  routed bitstream.
* `main` at its default seed (FAIL) and `main` with upstream `a17bd29c` reverted (PASS) have the *same placement* (0 of 36,699 cells moved)
  and differ only in routing; 52 of the ~300,000 differing FASM features are clock-network features (the PHY MMCM outputs go through
  `BUFHCE_X1Y1`/`X1Y3` in the failing routing and `X1Y7`/`X1Y9` in the passing one).  Across all ten runs the `BUFHCE` lane alone does not separate
  pass from fail, so this is a lead, not a cause.  One pair is also one sample each; treat it as that.

## Reproduce

nextpnr must be linked against the system Eigen 3.4.0 (check `grep Eigen3_DIR CMakeCache.txt`; a conda Eigen on the prefix path is picked up
silently), and its chipdb generated from prjxray-db `bdab7fe` (openXC7/database-virtex7, branch `ethmin-open-flow-fixes`: https://github.com/openXC7/database-virtex7/tree/ethmin-open-flow-fixes).

    cmake -S nextpnr -B build -DARCH=himbaechel -DHIMBAECHEL_UARCH=xilinx -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF \
          -DHIMBAECHEL_XILINX_DEVICES=xc7vx485t -DHIMBAECHEL_PRJXRAY_DB=<db> -DEigen3_DIR=/usr/share/eigen3/cmake
    cmake --build build --target nextpnr-himbaechel --parallel 8
    gunzip -k vc707_ethmin_vm.json.gz
    build/nextpnr-himbaechel --device xc7vx485tffg1761-2 -o xdc=../vc707_ethmin_vm_open.xdc --json vc707_ethmin_vm.json \
          -o fasm=out.fasm -o placement=out_placement.json --router router2 --timing-allow-fail -o hold-fix \
          --placer-heap-timingweight 60 --seed 1
    # then prjxray fasm2frames/xc7frames2bit (xc7-bitstream-tools/scripts/convert.py does both), and load over JTAG

`main` + `.IN` at `--seed 1` and `--seed 4` fail on the board; `--seed 2` and `--seed 3` pass.  The database is one commit on `openXC7/database-virtex7`, branch `ethmin-open-flow-fixes` (also here as `database-virtex7-bdab7fe.patch`, plus `database-virtex7-bdab7fe-tilegrid.md` for its one `tilegrid.json` tile).  `HASHES.txt` has the sha256 of each bitstream
and FASM that was tested, so a run of yours can be compared with ours.  `sweep.py` is the loader and classifier (it needs `openFPGALoader`
and a serial port; its paths are this machine's).  The repository's `open_build.sh` runs yosys and nextpnr end to end and writes a
`provenance.txt` with tool versions, the Eigen version, and the hashes.
