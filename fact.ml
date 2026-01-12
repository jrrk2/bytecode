type in_channel
type out_channel

external ( = ) : 'a -> 'a -> bool = "%equal"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external output_char : out_channel -> char -> unit = "caml_ml_output_char"
external open_descriptor_out : int -> out_channel = "caml_ml_open_descriptor_out"
external open_descriptor_in : int -> in_channel = "caml_ml_open_descriptor_in"
external string_length : string -> int = "%string_length"
external format_int : string -> int -> string = "caml_format_int"
external unsafe_output_string : out_channel -> string -> int -> int -> unit = "caml_ml_output"

let stdin = open_descriptor_in 0
let stdout = open_descriptor_out 1
let string_of_int n = format_int "%d" n
let print_char c = output_char stdout c
let output_string oc s = unsafe_output_string oc s 0 (string_length s)

let print_int i = output_string stdout (string_of_int i)

let fact n =
  let rec loop n acc =
    if n = 0 then acc
    else loop (n - 1) (acc * n)
  in
  loop n 1

let () = print_char '*'

let () =
  print_int (fact 5); output_char stdout '\n'
