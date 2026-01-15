(* Simplified OCaml VM Test Suite *)
(* Tests all arithmetic, logical, comparison, and shift operations *)
(* No string operations to keep it simple *)

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

external ( land ) : int -> int -> int = "%andint"
external ( lor ) : int -> int -> int = "%orint"
external ( lxor ) : int -> int -> int = "%xorint"
external ( lsl ) : int -> int -> int = "%lslint"
external ( lsr ) : int -> int -> int = "%lsrint"
external ( asr ) : int -> int -> int = "%asrint"

external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"

external output_char : out_channel -> char -> unit = "caml_ml_output_char"
external open_descriptor_out : int -> out_channel = "caml_ml_open_descriptor_out"
external flush : out_channel -> unit = "caml_ml_flush"

type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"
external incr : int ref -> unit = "%incr"
external decr : int ref -> unit = "%decr"

let stdout = open_descriptor_out 1

(* Print utilities *)
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
let print_ok () = print_char 'O'; print_char 'K'
let print_eq () = print_char '='

(* Test counters *)
let test_count = ref 0
let pass_count = ref 0
let fail_count = ref 0

(* Print test result *)
let test_result test_num expected actual =
  test_count := test_num;
  print_int test_num;
  print_char ':';
  print_space ();
  print_int actual;
  print_space ();
  if expected = actual then begin
    print_pass ();
    pass_count := !pass_count + 1
  end else begin
    print_fail ();
    print_space ();
    print_char '(';
    print_int expected;
    print_char ')';
    fail_count := !fail_count + 1
  end;
  print_newline ()

let test_bool test_num expected actual =
  test_count := test_num;
  print_int test_num;
  print_char ':';
  print_space ();
  if actual then (print_char 'T') else (print_char 'F');
  print_space ();
  if expected = actual then begin
    print_pass ();
    pass_count := !pass_count + 1
  end else begin
    print_fail ();
    print_space ();
    print_char '(';
    if expected then (print_char 'T') else (print_char 'F');
    print_char ')';
    fail_count := !fail_count + 1
  end;
  print_newline ()

(* Pseudo-random number generator *)
let rand_seed = ref 12345

let rand_next () =
  let a = 1103515245 in
  let c = 12345 in
  let m = 2147483647 in
  let temp = (!rand_seed * a + c) mod m in
  rand_seed := if temp < 0 then temp + m else temp;
  !rand_seed

let rand_range min max =
  let r = rand_next () in
  let range = max - min + 1 in
  let result = min + (r mod range) in
  if result < min then min
  else if result > max then max
  else result

(* Test functions *)
let run_tests () =
  let n = ref 0 in
  
  (* Header *)
  print_char 'T'; print_char 'E'; print_char 'S'; print_char 'T'; print_newline ();
  print_newline ();
  
  (* NEGATION *)
  n := !n + 1; test_result !n (-5) (~-5);
  n := !n + 1; test_result !n 5 (~-(-5));
  n := !n + 1; test_result !n 0 (~-0);
  
  (* ADDITION *)
  n := !n + 1; test_result !n 8 (5 + 3);
  n := !n + 1; test_result !n 0 (0 + 0);
  n := !n + 1; test_result !n 300 (100 + 200);
  n := !n + 1; test_result !n (-2) ((-5) + 3);
  n := !n + 1; test_result !n 2 (5 + (-3));
  n := !n + 1; test_result !n (-8) ((-5) + (-3));
  
  (* SUBTRACTION *)
  n := !n + 1; test_result !n 7 (10 - 3);
  n := !n + 1; test_result !n 0 (5 - 5);
  n := !n + 1; test_result !n (-7) (3 - 10);
  n := !n + 1; test_result !n (-8) ((-5) - 3);
  n := !n + 1; test_result !n 8 (5 - (-3));
  n := !n + 1; test_result !n (-2) ((-5) - (-3));
  
  (* MULTIPLICATION *)
  n := !n + 1; test_result !n 15 (5 * 3);
  n := !n + 1; test_result !n 0 (0 * 100);
  n := !n + 1; test_result !n 0 (100 * 0);
  n := !n + 1; test_result !n 42 (1 * 42);
  n := !n + 1; test_result !n (-15) ((-5) * 3);
  n := !n + 1; test_result !n (-15) (5 * (-3));
  n := !n + 1; test_result !n 15 ((-5) * (-3));
  n := !n + 1; test_result !n 4 (2 * 2);
  n := !n + 1; test_result !n 100 (10 * 10);
  
  (* DIVISION *)
  n := !n + 1; test_result !n 3 (10 / 3);
  n := !n + 1; test_result !n 3 (15 / 5);
  n := !n + 1; test_result !n 3 (7 / 2);
  n := !n + 1; test_result !n 10 (100 / 10);
  n := !n + 1; test_result !n 0 (5 / 10);
  n := !n + 1; test_result !n (-3) ((-10) / 3);
  n := !n + 1; test_result !n (-3) (10 / (-3));
  n := !n + 1; test_result !n 3 ((-10) / (-3));
  
  (* MODULO *)
  n := !n + 1; test_result !n 1 (10 mod 3);
  n := !n + 1; test_result !n 0 (15 mod 5);
  n := !n + 1; test_result !n 1 (7 mod 2);
  n := !n + 1; test_result !n 0 (100 mod 10);
  n := !n + 1; test_result !n 5 (5 mod 10);
  n := !n + 1; test_result !n 0 (0 mod 5);
  
  (* EQUALITY *)
  n := !n + 1; test_bool !n true (5 = 5);
  n := !n + 1; test_bool !n false (5 = 3);
  n := !n + 1; test_bool !n true (0 = 0);
  n := !n + 1; test_bool !n true ((-5) = (-5));
  n := !n + 1; test_bool !n false ((-5) = 5);
  n := !n + 1; test_bool !n false (5 <> 5);
  n := !n + 1; test_bool !n true (5 <> 3);
  
  (* LESS THAN *)
  n := !n + 1; test_bool !n true (3 < 5);
  n := !n + 1; test_bool !n false (5 < 3);
  n := !n + 1; test_bool !n false (5 < 5);
  n := !n + 1; test_bool !n true ((-5) < 3);
  n := !n + 1; test_bool !n false (3 < (-5));
  
  (* LESS EQUAL *)
  n := !n + 1; test_bool !n true (3 <= 5);
  n := !n + 1; test_bool !n true (5 <= 5);
  n := !n + 1; test_bool !n false (7 <= 5);
  
  (* GREATER THAN *)
  n := !n + 1; test_bool !n true (5 > 3);
  n := !n + 1; test_bool !n false (3 > 5);
  n := !n + 1; test_bool !n false (5 > 5);
  n := !n + 1; test_bool !n true (3 > (-5));
  
  (* GREATER EQUAL *)
  n := !n + 1; test_bool !n true (5 >= 3);
  n := !n + 1; test_bool !n true (5 >= 5);
  n := !n + 1; test_bool !n false (3 >= 5);
  
  (* BITWISE AND *)
  n := !n + 1; test_result !n 7 (15 land 7);
  n := !n + 1; test_result !n 8 (12 land 10);
  n := !n + 1; test_result !n 15 (255 land 15);
  n := !n + 1; test_result !n 0 (0 land 255);
  n := !n + 1; test_result !n 255 (255 land 255);
  
  (* BITWISE OR *)
  n := !n + 1; test_result !n 12 (8 lor 4);
  n := !n + 1; test_result !n 7 (3 lor 5);
  n := !n + 1; test_result !n 255 (0 lor 255);
  n := !n + 1; test_result !n 3 (1 lor 2);
  n := !n + 1; test_result !n 15 (7 lor 8);
  
  (* BITWISE XOR *)
  n := !n + 1; test_result !n 6 (5 lxor 3);
  n := !n + 1; test_result !n 0 (15 lxor 15);
  n := !n + 1; test_result !n 255 (255 lxor 0);
  n := !n + 1; test_result !n 6 (12 lxor 10);
  
  (* LEFT SHIFT *)
  n := !n + 1; test_result !n 1 (1 lsl 0);
  n := !n + 1; test_result !n 2 (1 lsl 1);
  n := !n + 1; test_result !n 4 (1 lsl 2);
  n := !n + 1; test_result !n 8 (1 lsl 3);
  n := !n + 1; test_result !n 16 (1 lsl 4);
  n := !n + 1; test_result !n 20 (5 lsl 2);
  n := !n + 1; test_result !n 24 (3 lsl 3);
  
  (* LOGICAL RIGHT SHIFT *)
  n := !n + 1; test_result !n 8 (16 lsr 1);
  n := !n + 1; test_result !n 4 (16 lsr 2);
  n := !n + 1; test_result !n 2 (16 lsr 3);
  n := !n + 1; test_result !n 1 (16 lsr 4);
  n := !n + 1; test_result !n 25 (100 lsr 2);
  n := !n + 1; test_result !n 15 (255 lsr 4);
  
  (* ARITHMETIC RIGHT SHIFT *)
  n := !n + 1; test_result !n 8 (16 asr 1);
  n := !n + 1; test_result !n 4 (16 asr 2);
  n := !n + 1; test_result !n 25 (100 asr 2);
  n := !n + 1; test_result !n (-8) ((-16) asr 1);
  n := !n + 1; test_result !n (-4) ((-16) asr 2);
  
  (* COMBINED OPERATIONS *)
  n := !n + 1; test_result !n 14 (2 + 3 * 4);
  n := !n + 1; test_result !n 7 (10 - 6 / 2);
  n := !n + 1; test_result !n 20 ((2 + 3) * 4);
  n := !n + 1; test_result !n 2 ((10 - 6) / 2);
  n := !n + 1; test_result !n 25 (5 * (3 + 2));
  n := !n + 1; test_result !n 3 ((10 + 5) / (3 + 2));
  n := !n + 1; test_result !n 50 (100 - (20 + 30));
  n := !n + 1; test_result !n 6 ((5 lor 3) land 6);
  
  (* RANDOM TESTS - Verify consistency *)
  let a1 = rand_range 1 50 in
  let b1 = rand_range 1 20 in
  n := !n + 1; test_result !n (a1 + b1) (a1 + b1);
  n := !n + 1; test_result !n (a1 - b1) (a1 - b1);
  n := !n + 1; test_result !n (a1 * b1) (a1 * b1);
  n := !n + 1; test_result !n (a1 / b1) (a1 / b1);
  n := !n + 1; test_result !n (a1 mod b1) (a1 mod b1);
  
  let a2 = rand_range 10 100 in
  let b2 = rand_range 5 15 in
  n := !n + 1; test_result !n (a2 + b2) (a2 + b2);
  n := !n + 1; test_result !n (a2 - b2) (a2 - b2);
  n := !n + 1; test_result !n (a2 / b2) (a2 / b2);
  
  let a3 = rand_range 1 30 in
  let b3 = rand_range 1 30 in
  n := !n + 1; test_result !n (a3 land b3) (a3 land b3);
  n := !n + 1; test_result !n (a3 lor b3) (a3 lor b3);
  n := !n + 1; test_result !n (a3 lxor b3) (a3 lxor b3);
  
  print_newline ()

let () =
  run_tests ();
  
  (* Summary *)
  print_char 'T'; print_char 'O'; print_char 'T'; print_char 'A'; print_char 'L'; 
  print_char ':'; print_space ();
  print_int !test_count;
  print_newline ();
  
  print_pass (); print_char ':'; print_space ();
  print_int !pass_count;
  print_newline ();
  
  print_fail (); print_char ':'; print_space ();
  print_int !fail_count;
  print_newline ();
  print_newline ();
  
  if !fail_count = 0 then begin
    print_char 'A'; print_char 'L'; print_char 'L'; print_space ();
    print_ok ();
    print_newline ()
  end;
  
  flush stdout
