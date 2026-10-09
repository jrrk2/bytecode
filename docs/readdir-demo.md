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

## What it exposed (and what was done about it)

* **No `Array.make`; no empty array.**  Both are now in the VM (spec25): `caml_make_vect len init` (primitive 0x0f1; a length outside 0..65535 raises `Invalid_argument`,
  as the header's size field is 16 bits) and `ATOM0`/`ATOM`/`PUSHATOM0`/`PUSHATOM` (an empty block).  The OCaml runtime's `Atom(0)` is one shared static block; here it is a
  fresh one-word header each time, and the collector copies an empty block each time it is reached rather than marking it forwarded (there is no field to hold the forward
  pointer, and a header marked forwarded would send a second reference to the next block's header).  `[||]` now compiles; `Array.make n x` is predefined; `Sys.readdir` uses it,
  with no cap and an empty array for an empty directory.  Tested in the VM simulator (`/tmp/bc/mv/mv.ml`: 15 collections with empty arrays and a vector of them alive) and in the
  self-compiled compiler.  Latent bug fixed on the way: the emitter's operand table (`nops`) counted an operand for ATOM0 and none for PUSHATOM.
* **NFS directories** are read (READDIR3); see above.
* **The compiler's own parser** (which compiles `comp.ml` itself) does not accept a string literal in a pattern, `(expr : type)`, or a record-style `when`
  without care: the code uses `when string_equal ...` and a helper with an annotated parameter, as the rest of the file does.
