(* Every function in io/trig.ml against the host's libm, over a sweep.
   The processor's own regression proves the hardware runs this code as
   ocamlrund does; this proves the code itself is worth running. *)
let err name f g lo hi n =
  let worst = ref 0.0 and at = ref lo in
  for i = 0 to n do
    let x = lo +. (hi -. lo) *. float_of_int i /. float_of_int n in
    let a = f x and b = g x in
    let e = if b = 0.0 then abs_float (a -. b)
            else abs_float ((a -. b) /. b) in
    if e > !worst && not (Float.is_nan e) then begin worst := e; at := x end
  done;
  Printf.printf "  %-8s over [%g, %g]  worst relative error %.2e  at x = %g\n"
    name lo hi !worst !at;
  !worst

let () =
  print_endline "io/trig.ml against libm:";
  let w = ref 0.0 in
  let keep x = if x > !w then w := x in
  keep (err "sin"  Trigmath.sin  sin  (-6.28) 6.28 200000);
  keep (err "cos"  Trigmath.cos  cos  (-6.28) 6.28 200000);
  keep (err "sin"  Trigmath.sin  sin  (-1000.0) 1000.0 200000);
  keep (err "tan"  Trigmath.tan  tan  (-1.5) 1.5 200000);
  keep (err "exp"  Trigmath.exp  exp  (-700.0) 700.0 200000);
  keep (err "log"  Trigmath.log  log  1e-300 1e300 200000);
  keep (err "log"  Trigmath.log  log  0.5 2.0 200000);
  keep (err "atan" Trigmath.atan atan (-100.0) 100.0 200000);
  keep (err "asin" Trigmath.asin asin (-0.999999) 0.999999 200000);
  keep (err "acos" Trigmath.acos acos (-0.999) 0.999 200000);
  keep (err "pow2" (fun x -> Trigmath.pow 2.0 x) (fun x -> Float.pow 2.0 x) (-50.0) 50.0 100000);
  Printf.printf "\nworst of all: %.2e relative\n" !w;
  if !w > 1e-13 then (print_endline "TOO LOOSE"; exit 1)
