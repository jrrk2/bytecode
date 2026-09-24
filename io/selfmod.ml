(* selfmod: the one risky part of an incremental compiler, on its own.
   A running program writes bytecode into its own code memory, finds the
   place it must patch by scanning for a constant it planted there at
   compile time, points a branch at what it wrote, and calls it.

   If this prints the generated character and comes back, then code memory
   is writable and readable while the VM runs, prog_words admits the new
   words to the fetch unit, the one-deep prefetch is invalidated by a
   write, and a compiled phrase can be entered by an ordinary call.  That
   is everything an incremental compiler needs from the machine. *)
external ( = ) : int -> int -> bool = "%equal"
external ( < ) : int -> int -> bool = "%lessthan"
external ( > ) : int -> int -> bool = "%greaterthan"
external ( >= ) : int -> int -> bool = "%greaterequal"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"
external ( lor ) : int -> int -> int = "%orint"
external ( land ) : int -> int -> int = "%andint"
external ( lsl ) : int -> int -> int = "%lslint"
external ( lsr ) : int -> int -> int = "%lsrint"
external string_length : string -> int = "%string_length"
external string_get : string -> int -> char = "%string_safe_get"
external int_of_char : char -> int = "%identity"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"
external io_read : int -> int = "vm_io_read"
external io_write : int -> int -> unit = "vm_io_write"

let uart = 0x1005
let code_win = 0x60000                (* code memory, a byte per address *)
let prog_words_reg = 0x100c           (* what the fetch unit will reach *)

let putc c = io_write uart c
let puts s = for i = 0 to string_length s - 1 do putc (int_of_char (string_get s i)) done
let rec dec n = if n >= 10 then dec (n / 10); putc (48 + n mod 10)
let line s = puts s; putc 10

(* the opcodes this needs, as the RTL numbers them *)
let op_branch = 84
let op_constint = 103
let op_push = 9
let op_ccall2 = 94
let op_return = 40
let prim_io_write = 404

let code_rd w =
  let a = code_win + w * 4 in
  io_read a lor (io_read (a + 1) lsl 8) lor (io_read (a + 2) lsl 16)

let code_wr w v =
  let a = code_win + w * 4 in
  io_write a (v land 0xFF);
  io_write (a + 1) ((v lsr 8) land 0xFF);
  io_write (a + 2) ((v lsr 16) land 0xFF);
  io_write (a + 3) 0

(* The doorway.  Its body is one constant, which is what makes it findable;
   the branch that replaces it sends the call wherever the compiler last
   put a phrase. *)
let marker = 0x5EED5E
(* the literal, not the name: a reference to the global would compile to a
   GETGLOBAL and leave nothing to find *)
let dispatch (_x : int) = 0x5EED5E

let () =
  line "selfmod: looking for the doorway";
  let p = ref 1 and found = ref (0 - 1) in
  while !found < 0 && !p < 8000 do
    if code_rd !p = marker && code_rd (!p - 1) = op_constint then found := !p - 1;
    p := !p + 1
  done;
  if !found < 0 then line "selfmod: FAIL -- the marker is not in code memory"
  else begin
    puts "selfmod: doorway at word "; dec !found; putc 10;
    (* the phrase: write a character, return 0 *)
    let t = 28000 in
    code_wr (t + 0) op_constint;   code_wr (t + 1) 71;       (* 'G' *)
    code_wr (t + 2) op_push;
    code_wr (t + 3) op_constint;   code_wr (t + 4) uart;
    code_wr (t + 5) op_ccall2;     code_wr (t + 6) prim_io_write;
    code_wr (t + 7) op_constint;   code_wr (t + 8) 0;
    code_wr (t + 9) op_return;     code_wr (t + 10) 1;
    io_write prog_words_reg (t + 16);
    (* and point the doorway at it: the operand is relative to itself *)
    code_wr !found op_branch;
    code_wr (!found + 1) (t - (!found + 1));
    (* read back what we wrote: reads are known to work, the scan used them *)
    puts "selfmod: word "; dec t; puts " reads "; dec (code_rd t);
    puts " (want "; dec op_constint; puts ")"; putc 10;
    puts "selfmod: doorway reads "; dec (code_rd !found);
    puts " (want "; dec op_branch; puts ")"; putc 10;
    puts "selfmod: offset reads "; dec (code_rd (!found + 1));
    puts " (want "; dec (t - (!found + 1)); puts ")"; putc 10;
    line "selfmod: calling the doorway";
    let r = dispatch 0 in
    puts "selfmod: returned "; dec r;
    line (if r = 0 then "  <- PASS" else "  <- FAIL, that is the old constant")
  end
