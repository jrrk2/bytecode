obj_dir/Vocaml4142_vm: bytecode.o prims.o obj_dir/Vocaml4142_vm.mk
	make -C obj_dir -f Vocaml4142_vm.mk

bytecode.o prims.o: ocaml-4.14.2/runtime/prims.c bytecode.c
	cc -c -g ocaml-4.14.2/runtime/prims.c bytecode.c -Iocaml-4.14.2/runtime

obj_dir/Vocaml4142_vm.mk: bytecode.o prims.o main.cpp ocaml4142_vm.sv
	rm -rf obj_dir
	verilator -CFLAGS -g --exe --trace --Wno-widthtrunc --Wno-widthexpand --Wno-multidriven --Wno-BLKANDNBLK --cc -I. ocaml4142_vm.sv main.cpp ../bytecode.o ../prims.o ../ocaml-4.14.2/runtime/libcamlrund.a

