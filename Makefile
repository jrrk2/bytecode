all: obj_dir/Vocaml4142_vm_rtl

obj_dir/Vocaml4142_vm: bytecode.o prims.o obj_dir/Vocaml4142_vm.mk
	make -C obj_dir -f Vocaml4142_vm.mk

bytecode.o prims.o: ocaml-4.14.2/runtime/prims.c bytecode.c
	cc -c -g ocaml-4.14.2/runtime/prims.c bytecode.c -Iocaml-4.14.2/runtime

obj_dir/Vocaml4142_vm.mk: bytecode.o prims.o main.cpp ocaml4142_vm.sv ocaml_4142_opcodes.svh
	verilator -CFLAGS -g --exe --trace --Wno-widthtrunc --Wno-widthexpand --Wno-multidriven --Wno-BLKANDNBLK --cc -I. ocaml4142_vm.sv main.cpp ../bytecode.o ../prims.o ../ocaml-4.14.2/runtime/libcamlrund.a

obj_dir/Vocaml4142_vm_rtl: bytecode.o prims.o obj_dir/Vocaml4142_vm_rtl.mk
	make -C obj_dir -f Vocaml4142_vm_rtl.mk

obj_dir/Vocaml4142_vm_rtl.mk: bytecode.o prims.o main_rtl.cpp ocaml4142_vm_rtl.sv ocaml_4142_opcodes.svh rtl_instructions/acc0.svh rtl_instructions/acc1_7.svh rtl_instructions/acc1.svh rtl_instructions/apply1.svh rtl_instructions/apply23.svh rtl_instructions/appterm1.svh rtl_instructions/appterm2.svh rtl_instructions/appterm3.svh rtl_instructions/arithmetic_unchanged.svh rtl_instructions/assign.svh rtl_instructions/control_flow.svh rtl_instructions/envacc.svh rtl_instructions/getfield.svh rtl_instructions/globals.svh rtl_instructions/makeblock1.svh rtl_instructions/makeblock2.svh rtl_instructions/makeblock3.svh rtl_instructions/offsetclosure.svh rtl_instructions/offsetref.svh rtl_instructions/pop.svh rtl_instructions/push.svh rtl_instructions/pushacc.svh rtl_instructions/pushenvacc.svh rtl_instructions/pushoffsetclosure.svh rtl_instructions/return.svh rtl_instructions/rtl_state_handlers.svh rtl_instructions/setfield.svh
	verilator -CFLAGS -g --exe --trace --Wno-widthtrunc --Wno-widthexpand --Wno-multidriven --Wno-BLKANDNBLK --cc -I. -Irtl_instructions ocaml4142_vm_rtl.sv main_rtl.cpp ../bytecode.o ../prims.o ../ocaml-4.14.2/runtime/libcamlrund.a

