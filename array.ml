type out_channel

external array_length : 'a array -> int = "%array_length"
external array_get : 'a array -> int -> 'a = "%array_safe_get"

external ( ~- ) : int -> int = "%negint"
external ( ~+ ) : int -> int = "%identity"
external succ : int -> int = "%succint"
external pred : int -> int = "%predint"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"

external output_char : out_channel -> char -> unit = "caml_ml_output_char"
external open_descriptor_out : int -> out_channel = "caml_ml_open_descriptor_out"
external flush : out_channel -> unit = "caml_ml_flush"

let stdout = open_descriptor_out 1
let print_char c = output_char stdout c
let print_newline () = output_char stdout '\n'; flush stdout

let print_chars chars =
  let len = array_length chars in
  for i = 0 to len - 1 do
    print_char (array_get chars i)
  done;
  print_newline ()

let main () =
  let hello = [| 'h'; 'e'; 'l'; 'l'; 'o' |] in
  let space = [| ' ' |] in
  let world = [| 'w'; 'o'; 'r'; 'l'; 'd' |] in

  print_chars hello;
  print_chars space;
  print_chars world

let () = main ()
