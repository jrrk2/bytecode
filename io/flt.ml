(* flt: floating point on the processor.  Every answer is turned back into
   an int before it is printed, so the UART shows numbers a person can check
   and the regression can compare against ocamlrund's own run. *)
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( >= ) : int -> int -> bool = "%greaterequal"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"
external io_write : int -> int -> unit = "vm_io_write"

external ( +. ) : float -> float -> float = "caml_add_float" "%addfloat"
external ( -. ) : float -> float -> float = "caml_sub_float" "%subfloat"
external ( *. ) : float -> float -> float = "caml_mul_float" "%mulfloat"
external ( /. ) : float -> float -> float = "caml_div_float" "%divfloat"
external sqrt : float -> float = "caml_sqrt_float" "%sqrtfloat"
external abs_float : float -> float = "caml_abs_float" "%absfloat"
external ( ~-. ) : float -> float = "caml_neg_float" "%negfloat"
external float_of_int : int -> float = "caml_float_of_int" "%floatofint"
external int_of_float : float -> int = "caml_int_of_float" "%intoffloat"
external ( <. ) : float -> float -> bool = "caml_lt_float" "%lessthan"
external ( <=. ) : float -> float -> bool = "caml_le_float" "%lessequal"
external ( =. ) : float -> float -> bool = "caml_eq_float" "%equal"

let uart = 0x1005
let putc c = io_write uart c
let rec dec n = if n >= 10 then dec (n / 10); putc (48 + n mod 10)
let show n = if n >= 0 then dec n else (putc 45; dec (0 - n)); putc 32
let line () = putc 10
let yes b = putc (if b then 89 else 78); putc 32

let () =
  (* arithmetic, scaled up so the fractional part shows *)
  show (int_of_float (1.5 +. 2.25));            (* 3 *)
  show (int_of_float ((1.5 +. 2.25) *. 100.));  (* 375 *)
  show (int_of_float (10. -. 4.5));             (* 5 *)
  show (int_of_float (3. *. 7.));               (* 21 *)
  show (int_of_float (1. /. 8. *. 1000.));      (* 125 *)
  line ();

  (* square root, negation, absolute value *)
  show (int_of_float (sqrt 16.));               (* 4 *)
  show (int_of_float (sqrt 2. *. 1000000.));    (* 1414213 *)
  show (int_of_float (~-. 42.5));               (* -42 *)
  show (int_of_float (abs_float (~-. 42.5)));   (* 42 *)
  line ();

  (* conversion both ways, and a value too big for an int *)
  show (int_of_float (float_of_int 12345));     (* 12345 *)
  show (int_of_float (float_of_int (-7) /. 2. *. 100.));  (* -350 *)
  line ();

  (* comparisons *)
  yes (1.5 <. 2.5); yes (2.5 <. 1.5);
  yes (1.5 <=. 1.5); yes (2.5 <=. 1.5);
  yes (1.5 =. 1.5); yes (1.5 =. 2.5);
  line ();

  (* something with a loop, so the collector sees a few boxes go by *)
  let rec sum i acc = if i >= 1000 then acc else sum (i + 1) (acc +. float_of_int i) in
  show (int_of_float (sum 0 0.));               (* 499500 *)
  line ()
