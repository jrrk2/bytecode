(* Step-by-step test of OCaml ref operations *)
(* Tests: ref creation, dereferencing (!), assignment (:=), incr, decr *)

type out_channel

external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"

external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"

external ( ~- ) : int -> int = "%negint"

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

let print_step msg =
  let rec print_chars i =
    if i >= 0 then begin
      print_char msg.[i];
      print_chars (i - 1)
    end
  in
  let len = String.length msg - 1 in
  let rec forward i =
    if i > len then ()
    else begin
      print_char msg.[i];
      forward (i + 1)
    end
  in
  forward 0

let () =
  (* Header *)
  print_step "REF TEST";
  print_newline ();
  print_newline ();
  
  (* Step 1: Create a ref with value 0 *)
  print_step "Step 1: Create ref with 0";
  print_newline ();
  let x = ref 0 in
  print_step "  x = ";
  print_int (!x);
  print_newline ();
  if !x = 0 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Step 2: Assign value 5 *)
  print_step "Step 2: Assign x := 5";
  print_newline ();
  x := 5;
  print_step "  x = ";
  print_int (!x);
  print_newline ();
  if !x = 5 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Step 3: Increment *)
  print_step "Step 3: incr x";
  print_newline ();
  incr x;
  print_step "  x = ";
  print_int (!x);
  print_newline ();
  if !x = 6 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Step 4: Increment again *)
  print_step "Step 4: incr x again";
  print_newline ();
  incr x;
  print_step "  x = ";
  print_int (!x);
  print_newline ();
  if !x = 7 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Step 5: Decrement *)
  print_step "Step 5: decr x";
  print_newline ();
  decr x;
  print_step "  x = ";
  print_int (!x);
  print_newline ();
  if !x = 6 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Step 6: Assign new value *)
  print_step "Step 6: Assign x := 42";
  print_newline ();
  x := 42;
  print_step "  x = ";
  print_int (!x);
  print_newline ();
  if !x = 42 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Step 7: Multiple refs *)
  print_step "Step 7: Create second ref y";
  print_newline ();
  let y = ref 10 in
  print_step "  x = ";
  print_int (!x);
  print_step ", y = ";
  print_int (!y);
  print_newline ();
  if !x = 42 && !y = 10 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Step 8: Modify both *)
  print_step "Step 8: x := x + y";
  print_newline ();
  x := !x + !y;
  print_step "  x = ";
  print_int (!x);
  print_newline ();
  if !x = 52 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Step 9: Swap *)
  print_step "Step 9: Swap x and y";
  print_newline ();
  let temp = !x in
  x := !y;
  y := temp;
  print_step "  x = ";
  print_int (!x);
  print_step ", y = ";
  print_int (!y);
  print_newline ();
  if !x = 10 && !y = 52 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Step 10: Counter pattern *)
  print_step "Step 10: Counter loop";
  print_newline ();
  let counter = ref 0 in
  incr counter;
  incr counter;
  incr counter;
  print_step "  counter = ";
  print_int (!counter);
  print_newline ();
  if !counter = 3 then print_step "  PASS" else print_step "  FAIL";
  print_newline ();
  print_newline ();
  
  (* Summary *)
  print_step "All ref operations tested!";
  print_newline ();
  
  flush stdout
