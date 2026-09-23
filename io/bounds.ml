(* bounds: the checks a type-safe machine owes its programs.  An index
   outside an array or a string raises Invalid_argument rather than reading
   or writing whatever happens to be next in the heap. *)
external ( = ) : int -> int -> bool = "%equal"
external ( >= ) : int -> int -> bool = "%greaterequal"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"
external io_write : int -> int -> unit = "vm_io_write"
external array_get : int array -> int -> int = "%array_safe_get"
external array_set : int array -> int -> int -> unit = "%array_safe_set"
external string_get : string -> int -> char = "%string_safe_get"
external int_of_char : char -> int = "%identity"

let uart = 0x1005
let putc c = io_write uart c
let rec dec n = if n >= 10 then dec (n / 10); putc (48 + n mod 10)
let line n = dec n; putc 10

let a = [| 10; 20; 30 |]
let s = "abc"

let () =
  (* in range, read and write *)
  line (array_get a 1);
  array_set a 1 99;
  line (array_get a 1);
  line (int_of_char (string_get s 2));
  (* past the end, and before the start: Int_val leaves a negative index
     as a very large one, so the same unsigned test catches both *)
  line (try array_get a 3 with Invalid_argument _ -> 7);
  line (try array_get a (0 - 1) with Invalid_argument _ -> 8);
  line (try (array_set a 5 0; 0) with Invalid_argument _ -> 9);
  line (try int_of_char (string_get s 3) with Invalid_argument _ -> 6);
  (* the last byte is in range; the padding after it is not *)
  line (int_of_char (string_get s 0));
  (* and the array is unharmed by the attempts *)
  line (array_get a 2)
