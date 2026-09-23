(* exc: exceptions on the processor: a division by zero caught, an exception
   raised and caught by hand, and a handler that is never needed. *)
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"
external raise : exn -> 'a = "%raise"
external io_write : int -> int -> unit = "vm_io_write"
let uart = 0x1005
let putc c = io_write uart c
let rec dec n = if n >= 10 then dec (n / 10); putc (48 + n mod 10)
let line n = dec n; putc 10

exception Mine of int

let () =
  (* the one the question asked for *)
  let x = try 0 / 0 with _ -> 7 in
  line x;
  (* a handler that is not needed: the value passes through *)
  let y = try 6 * 7 with _ -> 0 in
  line y;
  (* mod by zero raises too *)
  let z = try 5 mod 0 with _ -> 8 in
  line z;
  (* an exception of our own, with a payload, through two frames *)
  let w = try (try raise (Mine 9) with Not_found -> 0) with Mine k -> k in
  line w;
  (* the handler leaves the stack as it found it: arithmetic after it works *)
  line (x + y + z + w)
