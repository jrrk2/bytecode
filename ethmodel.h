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

#ifdef __cplusplus
}
#endif
