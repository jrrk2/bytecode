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

Not yet: float literals (image_end refuses), booting from the RAM disk (the loader reads the staging RAM, which is
too small for a compiler-sized image), and everything comp.ml needs of the language to compile itself.

Testing in the simulator: run comp.ml's bytecode with `+disk=disk.bin` and `io/image.input` as the UART input, find
`t.img` in the disk (the filing system: 16-byte superblock, 32-byte entries, name[24] offset length), then
`tools/img2bc.py t.img dir` turns it into a bytecode file and heap/globals hex files the simulator runs:

    main_rtl model: prog.bc +notrace +heap=dir/heap.hex +globals=dir/globals.hex +heap_words=N

io/image.input prints "hello from the image" and "4".
