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
external string_length : string -> int = "%string_length"
external string_get : string -> int -> char = "%string_safe_get"

let stdin = open_descriptor_in 0
let stdout = open_descriptor_out 1
let print_char c = output_char stdout c

let () =
let str = "Hello World\n" in
for i = 0 to 11 do print_char (string_get str i) done;
flush stdout
