// ethmodel: the ethmin I/O space as the VM reaches it through vm_io_read /
// vm_io_write (see ethmin.ml for the map), fed with canned frames.  Linked
// into the Verilator testbench (the trap port) and into a -custom OCaml debug
// runtime (C stubs), so both run the program against the same device.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

long ethmodel_read(long addr);
void ethmodel_write(long addr, long data);
// True once every canned frame has been taken and the program has polled an
// idle status a few times: ethmin never halts on its own.
int ethmodel_done(void);
// Canned frame i (0-based) into buf; its length, or 0 past the last one.
// For testbenches that drive the hardware's MAC stream with the same frames.
int ethmodel_frame(int i, unsigned char *buf);

// Frame-level use, for a testbench driving the hardware's MAC streams: a
// frame the hardware sent (answered by the model's DHCP, ARP and TFTP
// servers), and the next frame for it to receive (length, or 0 if none).
// $ETHMODEL_FAST_DHCP answers the first DISCOVER too, as simulated real
// time is too slow for the client's 4 s retransmission.
void ethmodel_tx_frame(const unsigned char *buf, int len);
int ethmodel_rx_frame(unsigned char *buf);

#ifdef __cplusplus
}
#endif
