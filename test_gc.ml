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

(* regress: +semispace=400
   The GC under pressure: 60 iterations each allocate short lists and a
   closure (about 130 words) in 400-word semi-spaces, while `keep` must
   survive every collection.  map and sum recurse without tail calls, so
   collections also happen with live pointers in stack frames. *)
let rec build n acc = if n = 0 then acc else build (n - 1) (n :: acc)
let rec sum l = match l with [] -> 0 | x :: r -> x + sum r
let rec len l = match l with [] -> 0 | _ :: r -> 1 + len r
let rec map f l = match l with [] -> [] | x :: r -> f x :: map f r

let keep = build 30 []

let rec loop i acc =
  if i = 0 then acc
  else begin
    let m = map (fun x -> x * i) (build 20 []) in
    let (a, b) = (sum m, len keep) in
    loop (i - 1) (acc + a + b + sum keep)
  end

let () =
  print_int (loop 60 0 mod 100000);
  output_char stdout '\n'; flush stdout
