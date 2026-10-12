### Board results: VC707 `vc707-ocaml` (ethmin) design, placed by nextpnr with different seeds

Every row is one bitstream, loaded over JTAG into a VC707 and its serial console captured by script (no manual observation).
**PASS** = the loader got a DHCP lease over the SGMII link, fetched its 327988-byte image over NFS, started the REPL, and the REPL
evaluated `355. /. 113.` to `3.141593`.  **FAIL** = the board prints `dhcp: discover` / `dhcp: timeout` forever and never sends a
request (Ethernet transmit dead).  A board with no serial output at all has its CPU held in reset (see the `.IN` bullet below).

Fixed for all rows: netlist `903d8425` (yosys 0.63+173, g++), the `vc707_ethmin_vm.xdc` constraints, `--placer-heap-timingweight 60`,
`-o hold-fix`, `--router router2`, prjxray-db `bdab7fe`, Eigen **3.4.0** (system), 50 MHz target.  The row marked "fresh netlist" used
netlist `1f3cd55a` (same RTL, different `BUILD_ID`).  The placer's Eigen version matters: the same netlist placed with Eigen 5.0.1
boots the CPU and never transmits.

| nextpnr | Eigen | seed | router iters | `clk_sys` (MHz) | DHCP bound | NFS image | REPL + `355. /. 113.` | result |
|---|---|---|---|---|---|---|---|---|
| e558304b | 3.4.0 | 1 (default) | 11 | 51.59 | yes | yes | yes | **PASS** |
| e558304b | 3.4.0 | 2 | 13 | 54.12 | yes | yes | yes | **PASS** |
| e558304b | 3.4.0 | 3 | 36 | 54.11 | yes | yes | yes | **PASS** |
| e558304b | 3.4.0 | 4 | 14 | 51.74 | yes | yes | yes | **PASS** |
| main + .IN fix | 3.4.0 | 1 (default) | 20 | 54.97 | no | no | no | **FAIL** |
| main + .IN fix | 3.4.0 | 2 | 16 | 56.03 | yes | yes | yes | **PASS** |
| main + .IN fix | 3.4.0 | 3 | 12 | 55.20 | yes | yes | yes | **PASS** |
| main + .IN fix | 3.4.0 | 4 | 17 | 52.74 | no | no | no | **FAIL** |
| main + .IN fix, a17bd29c reverted | 3.4.0 | 1 (default) | 13 | 54.15 | yes | yes | yes | **PASS** |
| main + .IN fix, old MMCM bits patched into the FASM | 3.4.0 | 1 (default) | 20 | 54.97 | no | no | no | **FAIL** (same placement as the default-seed row; only 7 MMCM lines edited) |
| e558304b, fresh netlist `1f3cd55a` | 3.4.0 | 1 (default) | 15 | 51.01 | yes | yes | yes | **PASS** |

**Is the result repeatable per bitstream?**  Yes: reloading `main-s1` and `main-s4` three times each failed all six times, and
`main-s2` passed all three times.  So pass or fail is a property of the placed and routed bitstream, not of boot timing.

**What this shows**
* `.IN` fix: without it the board gives no serial output at all (the CPU_RESET and a push button share `LIOB18_X81Y128` and its
  receive buffer is left disabled, so reset reads constant high); with it the same netlist runs.  The CI artifact for this design
  (`vc707-ocaml`, built before the fix) shows the same stuck reset.
* On `main` (+ the `.IN` fix) 2 of 4 seeds transmit; on `e558304b`'s tree 5 of 5 do (four seeds and a second netlist).  With n this small
  that is not a significant difference (one-sided Fisher exact p = 0.17), so nothing here says `main` is systematically worse.
* The failing placements are not distinguishable by nextpnr's own report: they close `clk_sys` and every `eth_*` clock with margin
  (`eth_tx_clk` 220 to 282 MHz against 125 required) and show no hold violations.
* Patching the MMCM loop-filter/power registers back to their older values (upstream `0057171d`) in a failing bitstream does not revive it.
* `main` default seed (FAIL) and `main` with upstream `a17bd29c` reverted (PASS) have an **identical placement** (0 of 36,699 cells moved) and
  differ only in routing (about 300,000 FASM features).  Fifty-two of those are clock-network features: the failing routing carries the
  PHY MMCM outputs through `BUFHCE_X1Y1`/`X1Y3` in `CLK_HROW_TOP_R_X192Y338` (`HCLK_CMT_MUX_CLK_2`/`_6`), the passing one through
  `X1Y7`/`X1Y9` (`MUX_CLK_7`/`_8`), and picks different `CLK_BUFG_IMUX` inputs for `BUFGCTRL1` and `BUFGCTRL8`.  Across all ten runs the
  `BUFHCE` lanes alone do not separate pass from fail (two passes use `Y1/Y3` too), so this is a lead about regional-clock routing
  data for this part, not an established cause.
