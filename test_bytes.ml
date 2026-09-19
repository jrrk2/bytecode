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

(* Bytes and string equality: create, unsafe/safe get and set, length,
   caml_string_equal/notequal on built and literal strings. *)
external create_bytes : int -> bytes = "caml_create_bytes"
external bytes_length : bytes -> int = "%bytes_length"
external bytes_unsafe_get : bytes -> int -> char = "%bytes_unsafe_get"
external bytes_unsafe_set : bytes -> int -> char -> unit = "%bytes_unsafe_set"
external bytes_get : bytes -> int -> char = "%bytes_safe_get"
external bytes_set : bytes -> int -> char -> unit = "%bytes_safe_set"
external unsafe_to_string : bytes -> string = "%bytes_to_string"
external string_equal : string -> string -> bool = "caml_string_equal"
external string_notequal : string -> string -> bool = "caml_string_notequal"
external string_length : string -> int = "%string_length"
external string_unsafe_get : string -> int -> char = "%string_unsafe_get"

type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"

let of_chars a b c d e =
  let s = create_bytes 5 in
  bytes_unsafe_set s 0 a; bytes_unsafe_set s 1 b; bytes_set s 2 c;
  bytes_unsafe_set s 3 d; bytes_set s 4 e;
  unsafe_to_string s

let b2i b = if b then 1 else 0

let () =
  let hello = of_chars 'h' 'e' 'l' 'l' 'o' in
  let help = of_chars 'h' 'e' 'l' 'p' 'o' in
  let t = create_bytes 9 in
  for i = 0 to 8 do bytes_set t i (char_of_int (int_of_char 'a' + i)) done;
  let n = ref 0 in
  n := !n + b2i (string_equal hello "hello");            (* 1 *)
  n := !n + 2 * b2i (string_equal help "hello");         (* 0 *)
  n := !n + 4 * b2i (string_notequal help "hello");      (* 4 *)
  n := !n + 8 * b2i (string_equal hello "hell");         (* 0 *)
  n := !n + 16 * b2i (string_equal (unsafe_to_string t) "abcdefghi");   (* 16 *)
  n := !n + 100 * (bytes_length t + string_length hello);  (* 1400 *)
  n := !n + int_of_char (bytes_get t 8) + int_of_char (bytes_unsafe_get t 0)
       + int_of_char (string_unsafe_get hello 4);          (* 105 + 97 + 111 *)
  print_int !n; output_char stdout '\n';
  for i = 0 to 4 do output_char stdout (string_unsafe_get hello i) done;
  output_char stdout '\n'; flush stdout
