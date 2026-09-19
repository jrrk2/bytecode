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

(* SWITCH (on constant constructors and on block tags) and array writes. *)
external array_get : 'a array -> int -> 'a = "%array_safe_get"
external array_set : 'a array -> int -> 'a -> unit = "%array_safe_set"
external array_unsafe_set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"
external array_length : 'a array -> int = "%array_length"
type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"

type msg = Discover | Offer of int | Request of int * int | Ack of int | Nak | Release

let weight m = match m with
  | Discover -> 1
  | Offer ip -> 10 + ip
  | Request (ip, srv) -> 100 + ip + srv
  | Ack ip -> 1000 + ip
  | Nak -> 5
  | Release -> 7

let option_name code = match code with
  | 0 -> 3 | 1 -> 5 | 2 -> 7 | 3 -> 11 | 4 -> 13 | 5 -> 17 | 6 -> 19 | _ -> 23

let () =
  let a = [| 0; 0; 0; 0; 0; 0; 0 |] in
  let msgs = [| Discover; Offer 2; Request (3, 4); Ack 5; Nak; Release; Offer 6 |] in
  for i = 0 to array_length msgs - 1 do
    array_set a i (weight (array_get msgs i));
  done;
  array_unsafe_set a 6 (array_get a 6 + option_name 5);
  let t = ref 0 in
  for i = 0 to 6 do t := !t + array_get a i * option_name i done;
  print_int !t;
  output_char stdout '\n'; flush stdout
