# Compiling to an image

`io/comp.ml` normally compiles each phrase into the running machine's code RAM and runs it.  For a chain load
(and eventually for compiling itself) it can instead build an image on the RAM disk:

    image_begin "t.img"        # phrases from here on are compiled into the image, not run
    ...                        # (externals, definitions, expressions: each phrase's code is a fragment)
    image_end 0                # a main that calls the fragments in order, the string literals as heap
                               # blocks, the globals, the header with its CRC, and a directory entry

The file has the layout of `tools/mkvmimage.py` (`OCVM`, version 1, code/heap/globals word counts, a primitive
digest of 0, CRC-16 of the body), so the boot sequencer can load it.  Output from a program in an image goes through
`external io_write : int -> int -> unit = "vm_io_write"` (the UART is address 0x1005): there is no REPL in it.

## Booting it

    boot_file "t.img"          # chain load the image: returns -1 if there is no such file

writes the byte offset of the image's header in the RAM disk to 0x100e.  The boot sequencer is to replace the program with
the image (code, heap, globals) and restart the machine, leaving the RAM disk as it is.  In the simulator (main_rtl.cpp) the
machine is the process, so BOOT starts the process again: the disk goes back to its backing file (+disk=), the image
is written out as a bytecode file (the running program's PRIM section plus the image's code) and heap/globals hex, and
$ETHMODEL_UART_SKIP carries the UART input on from where the old program stopped reading.  It checks the header and CRC
first and needs +notrace.  The hardware's side, ethmin_vm_core.v's sequencer reading its image from the RAM disk, is not
done.

Not yet: float literals (image_end refuses), and everything comp.ml needs of the language to compile itself.

Testing in the simulator: run comp.ml's bytecode with `+disk=disk.bin` and `io/image.input` as the UART input, find
`t.img` in the disk (the filing system: 16-byte superblock, 32-byte entries, name[24] offset length), then
`tools/img2bc.py t.img dir` turns it into a bytecode file and heap/globals hex files the simulator runs:

    main_rtl model: prog.bc +notrace +heap=dir/heap.hex +globals=dir/globals.hex +heap_words=N

io/image.input builds t.img, boots it, and the new program prints "hello from the image" and "4".
