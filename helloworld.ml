type in_channel
type out_channel

(* Comparisons *)

external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external compare : 'a -> 'a -> int = "%compare"

external ( ~- ) : int -> int = "%negint"
external ( ~+ ) : int -> int = "%identity"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"

external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"

external output_char : out_channel -> char -> unit = "caml_ml_output_char"
external open_descriptor_out : int -> out_channel = "caml_ml_open_descriptor_out"
external open_descriptor_in : int -> in_channel = "caml_ml_open_descriptor_in"

external flush : out_channel -> unit = "caml_ml_flush"

let stdin = open_descriptor_in 0
let stdout = open_descriptor_out 1
let print_char c = output_char stdout c

let () =
print_char 'H';
print_char 'e';
print_char 'l';
print_char 'l';
print_char 'o';
print_char ' ';
print_char 'W';
print_char 'o';
print_char 'r';
print_char 'l';
print_char 'd';
print_char '\n';
flush stdout
