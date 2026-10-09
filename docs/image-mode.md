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

io/image2.input checks that the booted program sees the RAM disk (a file the compiling session wrote with write_file, read through the
directory at 0x100000) and the UART input the compiling session had not yet read.

Globals 0..11 of an image are the predefined exceptions (a block of tag 248, name and id), as in an ocamlc image: the machine
reads Division_by_zero from slot 5, Stack_overflow from 8 and Out_of_memory from 0 to raise them, so image_begin starts the
program's own globals at 12 and image_end puts the blocks in the heap.  `#image out.img src.ml` compiles a source file (multi-line
phrases, nested comments, strings and character literals in them) to an image; it works on the host runner too, which has a model of
the RAM disk (tools/mkdisk.py makes a disk with files on it; $ETHMODEL_DISK names it).

Not yet: float literals (image_end refuses), and everything comp.ml needs of the language to compile itself.

Testing in the simulator: run comp.ml's bytecode with `+disk=disk.bin` and `io/image.input` as the UART input, find
`t.img` in the disk (the filing system: 16-byte superblock, 32-byte entries, name[24] offset length), then
`tools/img2bc.py t.img dir` turns it into a bytecode file and heap/globals hex files the simulator runs:

    main_rtl model: prog.bc +notrace +heap=dir/heap.hex +globals=dir/globals.hex +heap_words=N

io/image.input builds t.img, boots it, and the new program prints "hello from the image" and "4".

## Building an image on a server, with no RAM disk

`image_begin "nfs(U,P)dir/out.img"` (or `#image nfs(U,P)dir/out.img src.ml`, the source also a device name) builds the image straight into a
file on an NFS server.  The file is created at once.  Code is written in order and patched only near its end, except words 0 and 1 (the branch to
`main`, patched last): words 0..255 are kept until the end, the later ones go through a ring of recent words (32768 words in the free part of the RAM
disk, not committed to any file; 16384 words in the heap if there is no RAM disk) and an older 256-word piece is sent, 1 KiB at a time, when the ring
is needed for newer words.  The heap and globals sections are built in memory and sent at the end; the CRC is taken by reading the code back from the
server once; the header goes last.  A patch that would reach back past the ring prints "image: a patch reaches back past the window".

`tools/selfhost_nodisk.sh` runs this on the host with no RAM disk at all (`ETHMODEL_NODISK=1`): `ethmodel.c` has an NFS server (portmap, mountd, nfsd:
GETPORT, MNT, LOOKUP, READ, CREATE, WRITE over the directory `$ETHMODEL_NFS_ROOT`), the compiler reads `comp.ml` from it and writes the image back, and
the result is compared with the conventional build: they are byte-for-byte the same.  `image_begin "stm:name"` is the test path for the same code with
a RAM-disk file as the sink.
