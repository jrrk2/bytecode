(* Ultra-simple ref test - no strings *)
(* Each step prints: step_number value PASS/FAIL *)

type out_channel

external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"

external ( ~- ) : int -> int = "%negint"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"

external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"

external output_char : out_channel -> char -> unit = "caml_ml_output_char"
external open_descriptor_out : int -> out_channel = "caml_ml_open_descriptor_out"
external flush : out_channel -> unit = "caml_ml_flush"

(* Ref operations *)
type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"
external incr : int ref -> unit = "%incr"
external decr : int ref -> unit = "%decr"

let stdout = open_descriptor_out 1
let print_char c = output_char stdout c

let rec print_positive i = 
  if i > 9 then print_positive (i/10); 
  print_char (char_of_int (i mod 10 + int_of_char('0')))

let print_int i = 
  if i < 0 then begin 
    print_char '-'; 
    print_positive (-i); 
  end else 
    print_positive i

let print_newline () = print_char '\n'
let print_space () = print_char ' '
let print_pass () = print_char 'P'; print_char 'A'; print_char 'S'; print_char 'S'
let print_fail () = print_char 'F'; print_char 'A'; print_char 'I'; print_char 'L'

let test step_num expected actual =
  print_int step_num;
  print_char ':';
  print_space ();
  print_int actual;
  print_space ();
  if expected = actual then print_pass () else print_fail ();
  print_newline ()

let () =
  (* Header *)
  print_char 'R'; print_char 'E'; print_char 'F'; print_space ();
  print_char 'T'; print_char 'E'; print_char 'S'; print_char 'T';
  print_newline ();
  print_newline ();
  
  (* Test 1: Create ref with 0 *)
  let x = ref 0 in
  test 1 0 (!x);
  
  (* Test 2: Assign 5 *)
  x := 5;
  test 2 5 (!x);
  
  (* Test 3: Increment *)
  incr x;
  test 3 6 (!x);
  
  (* Test 4: Increment again *)
  incr x;
  test 4 7 (!x);
  
  (* Test 5: Decrement *)
  decr x;
  test 5 6 (!x);
  
  (* Test 6: Assign 42 *)
  x := 42;
  test 6 42 (!x);
  
  (* Test 7: Create second ref *)
  let y = ref 10 in
  test 7 10 (!y);
  
  (* Test 8: Verify x unchanged *)
  test 8 42 (!x);
  
  (* Test 9: Add refs *)
  let z = !x + !y in
  test 9 52 z;
  
  (* Test 10: Assign sum to x *)
  x := !x + !y;
  test 10 52 (!x);
  
  (* Test 11: Verify y unchanged *)
  test 11 10 (!y);
  
  (* Test 12: Assign x to y *)
  y := !x;
  test 12 52 (!y);
  
  (* Test 13: Both should be equal now *)
  test 13 52 (!x);
  
  (* Test 14: Swap - save x *)
  let temp = !x in
  test 14 52 temp;
  
  (* Test 15: Assign y to x *)
  x := !y;
  test 15 52 (!x);
  
  (* Test 16: Assign temp to y *)
  y := temp;
  test 16 52 (!y);
  
  (* Test 17: Multiple increments *)
  let counter = ref 0 in
  incr counter;
  incr counter;
  incr counter;
  test 17 3 (!counter);
  
  (* Test 18: Multiple decrements *)
  decr counter;
  decr counter;
  test 18 1 (!counter);
  
  (* Test 19: Assign negative *)
  x := -99;
  test 19 (-99) (!x);
  
  (* Test 20: Increment negative *)
  incr x;
  test 20 (-98) (!x);
  
  print_newline ();
  print_char 'D'; print_char 'O'; print_char 'N'; print_char 'E';
  print_newline ();
  
  flush stdout
