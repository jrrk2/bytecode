# The `xc7vx485t/tilegrid.json` part of database-virtex7 `bdab7fe`

`database-virtex7-bdab7fe.patch` has the other three files of that commit (`FIXES.md`, `ppips_liob18.db`, `segbits_liob18.db`).  The commit is
one commit on top of `openXC7/database-virtex7` `main` (`cf39b5a`), published as the branch `ethmin-open-flow-fixes` (https://github.com/openXC7/database-virtex7/tree/ethmin-open-flow-fixes); this note and the patch are the same change in a form that does not need that repository.  `tilegrid.json` is a single
30 MB line, so its change is given here as the one tile that differs.

`bdab7fe` changes exactly one tile of `xc7vx485t/tilegrid.json`, `BRAM_L_X114Y0`, which had an empty `bits` and so no frame addresses:

    was:  "bits": {}
    now:  "bits": {"BLOCK_RAM": {"baseaddr": "0x00C20500", "frames": 128, "offset": 0, "words": 10},
                   "CLB_IO_CLK": {"baseaddr": "0x00423900", "frames": 28,  "offset": 0, "words": 10}}

Everything else in that tile is unchanged (`clock_region` X1Y0, `grid_x` 289, `grid_y` 363, `type` BRAM_L, the same three sites).
To apply it to a tilegrid you have:

    python3 -c "
    import json,sys; p='xc7vx485t/tilegrid.json'; d=json.load(open(p))
    d['BRAM_L_X114Y0']['bits']={'BLOCK_RAM':{'baseaddr':'0x00C20500','frames':128,'offset':0,'words':10},
                                'CLB_IO_CLK':{'baseaddr':'0x00423900','frames':28,'offset':0,'words':10}}
    json.dump(d,open(p,'w'),separators=(',',':'),sort_keys=True)"

(Re-serialising may change key order or spacing in the file; compare with `python3 -m json.tool` on both if you diff.)
