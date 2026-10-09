# Putting the bytecode image in the VC707's configuration flash

The board's BPI flash held the HP2000 image (`~/hp2000`, `make flash`); it now holds the bytecode machine's bitstream, so the
board starts it by itself when it configures.  Writing it replaces whatever was there.

    # a bitstream with the loader and preloaded RAM (tools/loader_update.py, tools/preload.py), or a plain build's out/*.bit
    vivado -nojournal -mode batch -source ~/hp2000/scripts/write_cfgmem_vc707.tcl -tclargs image.mcs image.bit
    vivado -nojournal -mode batch -source ~/hp2000/scripts/flash_vc707.tcl -tclargs image.mcs     # about 4 minutes

Run both from a scratch directory, not from `~/hp2000` (write_cfgmem leaves a `.prm` beside the `.mcs`).  Wait for "Flash
programming completed successfully" in the log before doing anything to the board: the erase and the write both take minutes,
and the first lines of the log mention `PROGRAM.VERIFY` before any verifying has happened.

The flash is read when the FPGA configures itself, with the boot mode switches (SW11 M[2:0]) on BPI = 010.  Until then the FPGA
runs whatever was last loaded over JTAG, which is the flash programmer's helper design right after the write.  When it
configures from flash is the operator's business: the person at the board decides it and does it; a program or an agent
working on this should report that the flash is written and stop there.

To get the HP2000 back: `make flash` in `~/hp2000`, which uses `bitstreams/hp2000_vc707.bit` from that repository.

For development the flash is not needed: `openFPGALoader --cable digilent --freq 15000000 X.bit` loads the FPGA's SRAM (use the
full path to the file; a relative path that does not exist leaves the previous design running and prints only "Open file FAIL").
