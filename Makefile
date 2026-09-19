all: obj_dir/Vocaml4142_vm_rtl

obj_dir/Vocaml4142_vm: bytecode.o prims.o obj_dir/Vocaml4142_vm.mk
	make -C obj_dir -f Vocaml4142_vm.mk

bytecode.o prims.o: ocaml-4.14.2/runtime/prims.c bytecode.c
	cc -c -g ocaml-4.14.2/runtime/prims.c bytecode.c -Iocaml-4.14.2/runtime

obj_dir/Vocaml4142_vm.mk: bytecode.o prims.o main.cpp ocaml4142_vm.sv ocaml_4142_opcodes.svh
	verilator -CFLAGS -g --exe --trace --Wno-widthtrunc --Wno-widthexpand --Wno-multidriven --Wno-BLKANDNBLK --cc -I. ocaml4142_vm.sv main.cpp ../bytecode.o ../prims.o ../ocaml-4.14.2/runtime/libcamlrund.a

obj_dir/Vocaml4142_vm_rtl: bytecode.o prims.o obj_dir/Vocaml4142_vm_rtl.mk
	make -C obj_dir -f Vocaml4142_vm_rtl.mk

obj_dir/Vocaml4142_vm_rtl.mk: bytecode.o prims.o main_rtl.cpp ethmodel.c ethmodel.h ocaml4142_vm_rtl.sv ocaml_4142_opcodes.svh state_rtl_complete.h
	verilator -CFLAGS -g --exe --trace --Wno-widthtrunc --Wno-widthexpand --Wno-multidriven --Wno-BLKANDNBLK --cc -I. -Irtl_instructions ocaml4142_vm_rtl.sv main_rtl.cpp ethmodel.c ../bytecode.o ../prims.o ../ocaml-4.14.2/runtime/libcamlrund.a

