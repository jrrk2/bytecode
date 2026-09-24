(* trig: the transcendental functions on top of the hardware FPU.
   
   The processor answers add, subtract, multiply, divide, square root, the
   comparisons and the integer conversions in silicon (fpga/fpu-rtl).
   Everything below is built from those: range reduction to bring an
   argument into a small interval, then a series that converges quickly
   there.  That is the usual division of labour -- IEEE requires the
   algebraic operations to be correctly rounded and says nothing about the
   transcendental ones, so the hardware does the first and this does the
   second.

   Accuracy is about 1e-15 relative over the ranges the checker sweeps
   (io/test/trig/check.ml compares every function against the host's libm).
   The limit on argument size is the reduction: sin and friends multiply by
   2/pi and round to an int, and this processor's ints are 31 bits, so
   arguments beyond about 1e9 lose their reduction and with it their
   meaning.  A payload-carrying reduction (Payne-Hanek) would lift that;
   for a demonstration the ordinary one is honest enough. *)

external ( = ) : 'a -> 'a -> bool = "%equal"
external ( >= ) : int -> int -> bool = "%greaterequal"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"
external io_write : int -> int -> unit = "vm_io_write"

(* no standard library here, so the mutable cell the series loops use is
   declared like everything else *)
type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"

(* ==== MATH ==== *)
external ( +. ) : float -> float -> float = "caml_add_float" "%addfloat"
external ( -. ) : float -> float -> float = "caml_sub_float" "%subfloat"
external ( *. ) : float -> float -> float = "caml_mul_float" "%mulfloat"
external ( /. ) : float -> float -> float = "caml_div_float" "%divfloat"
external ( ~-. ) : float -> float = "caml_neg_float" "%negfloat"
external sqrt : float -> float = "caml_sqrt_float" "%sqrtfloat"
external abs_float : float -> float = "caml_abs_float" "%absfloat"
external float_of_int : int -> float = "caml_float_of_int" "%floatofint"
external int_of_float : float -> int = "caml_int_of_float" "%intoffloat"
external ( <. ) : float -> float -> bool = "caml_lt_float" "%lessthan"
external ( <=. ) : float -> float -> bool = "caml_le_float" "%lessequal"
external ( =. ) : float -> float -> bool = "caml_eq_float" "%equal"

let pi      = 3.14159265358979312
let pio2    = 1.57079632679489656
let pio6    = 0.523598775598298927
let sqrt3   = 1.73205080756887730
(* pi/2 and ln 2 in two pieces: subtracting k * pi/2 from a large argument
   loses the low bits of pi/2 to rounding, so the high part is kept short
   enough to multiply exactly and the remainder is taken off afterwards. *)
let pio2_hi = 1.57079632673412562
let pio2_lo = 6.07710050650619225e-11
let ln2_hi  = 0.693147180369123816
let ln2_lo  = 1.90821492927058770e-10
let ln2     = 0.693147180559945286
let two_over_pi = 0.636619772367581343

(* 2^n, by squaring rather than n multiplications *)
let pow2 n =
  let rec go b e acc =
    if e = 0 then acc
    else go (b *. b) (e / 2) (if e mod 2 = 1 then acc *. b else acc) in
  if n >= 0 then go 2.0 n 1.0 else 1.0 /. go 2.0 (0 - n) 1.0

(* nearest integer, as an int: the reduction needs round-to-nearest and
   int_of_float truncates *)
let round_to_int x = int_of_float (if x <. 0.0 then x -. 0.5 else x +. 0.5)

(* ---- exp and log ---- *)

let exp x =
  if x <. -745.0 then 0.0
  else if 709.8 <. x then 1.0 /. 0.0
  else begin
    let k = round_to_int (x /. ln2) in
    let kf = float_of_int k in
    let r = x -. kf *. ln2_hi -. kf *. ln2_lo in
    (* Taylor about zero on |r| <= ln2/2; the term after the last is about
       1e-19 of the sum *)
    let sum = ref 1.0 and term = ref 1.0 in
    for i = 1 to 14 do
      term := !term *. r /. float_of_int i;
      sum := !sum +. !term
    done;
    !sum *. pow2 k
  end

let log x =
  if x <. 0.0 then 0.0 /. 0.0
  else if x =. 0.0 then ~-. (1.0 /. 0.0)
  else begin
    (* x = m * 2^e with m in [sqrt(1/2), sqrt(2)), coarsely first so that a
       huge argument does not take a thousand halvings *)
    let e = ref 0 and m = ref x in
    while 65536.0 <=. !m do m := !m /. 65536.0; e := !e + 16 done;
    while !m <. 1.52587890625e-05 do m := !m *. 65536.0; e := !e - 16 done;
    while 1.41421356237309515 <=. !m do m := !m /. 2.0; e := !e + 1 done;
    while !m <. 0.707106781186547524 do m := !m *. 2.0; e := !e - 1 done;
    (* log m = 2 atanh s, s = (m-1)/(m+1), |s| <= 0.1716 *)
    let s = (!m -. 1.0) /. (!m +. 1.0) in
    let s2 = s *. s in
    let acc = ref 0.0 and t = ref s in
    for i = 0 to 12 do
      acc := !acc +. !t /. float_of_int (2 * i + 1);
      t := !t *. s2
    done;
    2.0 *. !acc +. float_of_int !e *. ln2
  end

(* ---- sine, cosine, tangent ---- *)

let sin_small r =
  let r2 = r *. r in
  let term = ref r and sum = ref r in
  for n = 1 to 10 do
    term := ~-. (!term *. r2 /. float_of_int ((2 * n) * (2 * n + 1)));
    sum := !sum +. !term
  done;
  !sum

let cos_small r =
  let r2 = r *. r in
  let term = ref 1.0 and sum = ref 1.0 in
  for n = 1 to 10 do
    term := ~-. (!term *. r2 /. float_of_int ((2 * n - 1) * (2 * n)));
    sum := !sum +. !term
  done;
  !sum

(* x = k * pi/2 + r with |r| <= pi/4; which of sine and cosine to use, and
   with which sign, follows k around the circle *)
let quadrant x =
  let k = round_to_int (x *. two_over_pi) in
  let kf = float_of_int k in
  let r = x -. kf *. pio2_hi -. kf *. pio2_lo in
  (((k mod 4) + 4) mod 4, r)

let sin x =
  let (q, r) = quadrant x in
  if q = 0 then sin_small r
  else if q = 1 then cos_small r
  else if q = 2 then ~-. (sin_small r)
  else ~-. (cos_small r)

let cos x =
  let (q, r) = quadrant x in
  if q = 0 then cos_small r
  else if q = 1 then ~-. (sin_small r)
  else if q = 2 then ~-. (cos_small r)
  else sin_small r

let tan x = sin x /. cos x

(* ---- the inverses ---- *)

let atan_small t =
  let t2 = t *. t in
  let p = ref t and sum = ref t in
  for n = 1 to 16 do
    p := ~-. (!p *. t2);
    sum := !sum +. !p /. float_of_int (2 * n + 1)
  done;
  !sum

(* 0 <= a: fold a > 1 through atan a = pi/2 - atan (1/a), then the rest
   through atan a = pi/6 + atan ((a sqrt3 - 1)/(sqrt3 + a)), which leaves
   |t| <= tan(pi/12) = 0.268 and a series that falls by 14 each term *)
let atan_pos a =
  let reduce b =
    if 0.267949192431122706 <. b then
      pio6 +. atan_small ((b *. sqrt3 -. 1.0) /. (sqrt3 +. b))
    else atan_small b in
  if 1.0 <. a then pio2 -. reduce (1.0 /. a) else reduce a

let atan x = if x <. 0.0 then ~-. (atan_pos (~-. x)) else atan_pos x

let atan2 y x =
  if 0.0 <. x then atan (y /. x)
  else if x <. 0.0 then
    (if y <. 0.0 then atan (y /. x) -. pi else atan (y /. x) +. pi)
  else if 0.0 <. y then pio2
  else if y <. 0.0 then ~-. pio2
  else 0.0

(* asin a = atan (a / sqrt (1 - a^2)) loses its footing as a nears one,
   where the square root is the difference of two close numbers; the half
   angle moves the work back to the middle of the range *)
let rec asin_pos a =
  if a <=. 0.7 then atan (a /. sqrt (1.0 -. a *. a))
  else if 1.0 <. a then 0.0 /. 0.0
  else pio2 -. 2.0 *. asin_pos (sqrt ((1.0 -. a) /. 2.0))

let asin x = if x <. 0.0 then ~-. (asin_pos (~-. x)) else asin_pos x
let acos x = pio2 -. asin x

let pow x y = exp (y *. log x)
(* ==== END MATH ==== *)

(* ---- what it prints ----
   Each answer is scaled by a million and truncated, so the UART shows
   six decimal places of a number a person can check, and the regression
   can compare the line against ocamlrund's own run. *)
let uart = 0x1005
let putc c = io_write uart c
let rec dec n = if n >= 10 then dec (n / 10); putc (48 + n mod 10)
let show x =
  let scaled = int_of_float (if x <. 0.0 then x *. 1000000.0 -. 0.5
                             else x *. 1000000.0 +. 0.5) in
  if scaled >= 0 then dec scaled else (putc 45; dec (0 - scaled));
  putc 32
let line () = putc 10

let () =
  show (sin 0.5); show (cos 0.5); show (tan 0.5);        line ();
  show (sin 1.0); show (cos 1.0); show (tan 1.0);        line ();
  show (sin 3.0); show (cos 3.0);                        line ();
  show (sin 100.0); show (cos 100.0);                    line ();
  show (exp 1.0); show (exp 0.5); show (exp (~-. 2.0));  line ();
  show (log 2.0); show (log 10.0); show (log 0.5);       line ();
  show (exp (log 7.0));                                  line ();
  show (atan 1.0); show (atan 0.5); show (atan 10.0);    line ();
  show (asin 0.5); show (acos 0.5); show (asin 0.99);    line ();
  show (atan2 1.0 1.0); show (atan2 1.0 (~-. 1.0));      line ();
  show (pow 2.0 10.0); show (pow 2.0 0.5);               line ()
