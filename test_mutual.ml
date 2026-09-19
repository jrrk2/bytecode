type in_channel
type out_channel

external ( = ) : 'a -> 'a -> bool = "%equal"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( ~- ) : int -> int = "%negint"
external output_char : out_channel -> char -> unit = "caml_ml_output_char"
external open_descriptor_out : int -> out_channel = "caml_ml_open_descriptor_out"
external open_descriptor_in : int -> in_channel = "caml_ml_open_descriptor_in"
external flush : out_channel -> unit = "caml_ml_flush"

external string_length : string -> int = "%string_length"
external format_int : string -> int -> string = "caml_format_int"
external unsafe_output_string : out_channel -> string -> int -> int -> unit = "caml_ml_output"

external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"

let stdin = open_descriptor_in 0
let stdout = open_descriptor_out 1
let string_of_int n = format_int "%d" n
let print_char c = output_char stdout c

let print_int_100000 i = print_char (char_of_int (i mod 10 + int_of_char('0')))
let print_int_10000 i = print_int_100000 (i/10); print_char (char_of_int (i mod 10 + int_of_char('0')))
let print_int_1000 i = print_int_10000 (i/10); print_char (char_of_int (i mod 10 + int_of_char('0')))
let print_int_100 i = print_int_1000 (i/10); print_char (char_of_int (i mod 10 + int_of_char('0')))
let print_int_10 i = print_int_100 (i/10); print_char (char_of_int (i mod 10 + int_of_char('0')))
let print_int i = if i < 0 then begin print_char '-'; print_int_10 (-i); end else print_int_10 i

(* regress: +semispace=300
   let rec ... and ...: CLOSUREREC with several functions (infix closures),
   sibling calls through OFFSETCLOSURE, shared free variables, and the GC
   moving blocks that are held through infix pointers. *)
type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"

let rec even n = if n = 0 then true else odd (n - 1)
and odd n = if n = 0 then false else even (n - 1)

let rec build n acc = if n = 0 then acc else build (n - 1) (n :: acc)

let make base =
  (* three mutually recursive functions sharing two free variables *)
  let scale = base * 2 in
  let rec a n = if n = 0 then base else b (n - 1) + scale
  and b n = if n = 0 then scale else c (n - 1) + base
  and c n = if n = 0 then 1 else a (n - 1) + 1 in
  (a, c)

let rec sum l = match l with [] -> 0 | x :: r -> x + sum r

let () =
  let t = ref 0 in
  for i = 1 to 40 do
    let (a, c) = make i in                      (* infix pointers kept live *)
    let garbage = build 30 [] in                 (* forces collections *)
    t := !t + a 7 + c 4 + sum garbage + (if even i then 1 else 0) + (if odd (i + 3) then 10 else 0)
  done;
  print_int (!t mod 100000);
  output_char stdout '\n'; flush stdout
