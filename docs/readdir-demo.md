# Sys.readdir and the standard names: a demo

Step 1 of the plan in `docs/TODO.md` ("Standard library names"), with a first piece of step 2.  What is new:

* **Qualified names.**  The lexer reads `Upper.lower` (and `Upper.Upper.lower`) as one identifier, and such a name is a value, not a constructor.  The compiler
  predefines three of them at start-up as externals: `String.length`, `Array.length` (the new primitive `%array_length`, the VM's VECTLENGTH) and `Array.get`.
* **`Sys.readdir : string -> string array`**, a builtin.  `"."` is the RAM disk's files, `"/"` the mount points, `"/sd"` the root directory of the card (8.3 names as
  `name.ext`, lower case).  A directory on the NFS server (`"/nfs"`, `"/nfs/dir"`) is read with READDIR3 (not yet run on the board).
* **The type `string array`** (`'a array` existed, for `[| a; b |]`), and **printing** of arrays and lists in the REPL's results: `[|"a"; "b"|]`, `[1; 2; 3]`.
* `[||]` and `[| |]` parse, but compile to an error: see below.

A session in the self-compiled compiler on the VM simulator (three files on the RAM disk):

    # Sys.readdir "."
    - : string array = [|"a.ml"; "b.txt"; "notes.txt"|]
    # Sys.readdir "/"
    - : string array = [|"sd"; "nfs"|]
    # Array.length (Sys.readdir ".")
    - : int = 3
    # Array.get (Sys.readdir ".") 1
    - : string = "b.txt"
    # String.length "hello"
    - : int = 5
    # String.length (Array.get (Sys.readdir ".") 2)
    - : int = 9
    # [| "a"; "b" |]
    - : string array = [|"a"; "b"|]
    # [1; 2; 3]
    - : int list = [1; 2; 3]

On the board (spec24, the card in the slot, stage10 image):

    # Sys.readdir "/sd"
    - : string array = [|"disk.rfs"; "comp.bc"|]   (83 ms)

The card's root directory holds `DISK.RFS` and `COMP.BC` (and the volume label, which is skipped).  `/` and `.` were checked in the simulator only; `.` has
nothing to list on spec24, which has no RAM disk.

NFS directories (the server model in `ethmodel.c`, READDIR3 in the shared client `io/nfs.ml`, in the VM simulator):

    # nfs_server "192.168.1.106" "/nfs"
    # Sys.readdir "/nfs"
    - : string array = [|"alpha.txt"; "beta.ml"; "gamma.img"; "sub"|]   (100 ms)
    # Sys.readdir "/nfs/sub"
    - : string array = [|"inner.txt"; "other.ml"|]   (120 ms)
    # Sys.readdir "/nfs/nosuchdir"
    error: exception Sys_error "nosuchdir: No such file or directory"

## What it exposed

* **No `Array.make`.**  The VM has no `caml_make_vect`, so an array whose length is known only at run time cannot be built.  `Sys.readdir` picks a literal array of
  the right length from a ladder (`mk_str_array`, 1 to 64 entries) and fills it, and cuts a directory at 64 names.  The proper fix is the primitive in the VM (or a
  MAKEBLOCK with a run-time count); with it `Array.make`, `Array.sub`, `Array.of_list` and a real `Sys.readdir` follow.
* **No empty array.**  `ATOM0` is a no-op in the VM, so `[||]` has no value to give: it is a compile error, and `Sys.readdir` of an empty directory raises
  `Sys_error`.  The fix is a shared zero-size block (a header word in the heap image, a global that holds its pointer, `ATOM0` compiled as a load of it).
* **The compiler's own parser** (which compiles `comp.ml` itself) does not accept a string literal in a pattern, `(expr : type)`, or a record-style `when`
  without care: the code uses `when string_equal ...` and a helper with an annotated parameter, as the rest of the file does.
