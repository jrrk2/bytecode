# Proving the FPU against the host's own doubles.
#
#   make            both tests
#   make roundtrip  recode64/derecode64 alone, by round trip
#   make fpu        every operation against C's doubles, bit for bit
#
# The recoding is the only part of this FPU not taken from HardFloat, so it
# is tested twice: alone, and through every operation.
RTL := ../fpu_hardfloat.v ../recode64.v ../hardfloat.v
VFLAGS := --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME

all: roundtrip fpu

roundtrip:
	verilator $(VFLAGS) roundtrip.v ../recode64.v tb_roundtrip.cpp -o tb_roundtrip --top-module roundtrip
	./obj_dir/tb_roundtrip

fpu:
	verilator $(VFLAGS) $(RTL) tb_fpu.cpp -o tb_fpu --top-module fpu_hardfloat
	./obj_dir/tb_fpu

clean:
	rm -rf obj_dir
.PHONY: all roundtrip fpu clean
