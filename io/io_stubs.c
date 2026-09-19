// vm_io_read / vm_io_write for a -custom OCaml debug runtime, on the same device
// model as the Verilator testbench (the reference trace for ethmin.ml).
#include <caml/mlvalues.h>
#include <stdio.h>
#include <stdlib.h>
#include "ethmodel.h"
value vm_io_read(value a) {
  long v = ethmodel_read(Long_val(a));
  if (ethmodel_done()) { fflush(stdout); exit(0); }  // ethmin loops forever
  return Val_long(v);
}
value vm_io_write(value a, value d) { ethmodel_write(Long_val(a), Long_val(d)); return Val_unit; }
