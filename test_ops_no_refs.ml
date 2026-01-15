(* Simplified OCaml VM Test Suite - No refs *)
(* Tests all arithmetic, logical, comparison, and shift operations *)

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

(* Test with direct counter passing - no refs *)
let test_result test_num pass_count fail_count expected actual =
  print_int test_num;
  print_char ':';
  print_space ();
  print_int actual;
  print_space ();
  if expected = actual then begin
    print_pass ();
    (test_num, pass_count + 1, fail_count)
  end else begin
    print_fail ();
    print_space ();
    print_char '(';
    print_int expected;
    print_char ')';
    (test_num, pass_count, fail_count + 1)
  end

let test_bool test_num pass_count fail_count expected actual =
  print_int test_num;
  print_char ':';
  print_space ();
  if actual then (print_char 'T') else (print_char 'F');
  print_space ();
  if expected = actual then begin
    print_pass ();
    (test_num, pass_count + 1, fail_count)
  end else begin
    print_fail ();
    print_space ();
    print_char '(';
    if expected then (print_char 'T') else (print_char 'F');
    print_char ')';
    (test_num, pass_count, fail_count + 1)
  end

(* Run all tests - returns (test_count, pass_count, fail_count) *)
let run_tests () =
  (* Print header *)
  print_char 'T'; print_char 'E'; print_char 'S'; print_char 'T'; 
  print_newline (); print_newline ();
  
  let n = 0 in
  let p = 0 in
  let f = 0 in
  
  (* NEGATION *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-5) (~-5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 5 (~-(-5)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (~-0) in (print_newline (); (n1, p1, f1))) in
  
  (* ADDITION *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 8 (5 + 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (0 + 0) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 300 (100 + 200) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-2) ((-5) + 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 2 (5 + (-3)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-8) ((-5) + (-3)) in (print_newline (); (n1, p1, f1))) in
  
  (* SUBTRACTION *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 7 (10 - 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (5 - 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-7) (3 - 10) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-8) ((-5) - 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 8 (5 - (-3)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-2) ((-5) - (-3)) in (print_newline (); (n1, p1, f1))) in
  
  (* MULTIPLICATION *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 15 (5 * 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (0 * 100) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (100 * 0) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 42 (1 * 42) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-15) ((-5) * 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-15) (5 * (-3)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 15 ((-5) * (-3)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 4 (2 * 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 100 (10 * 10) in (print_newline (); (n1, p1, f1))) in
  
  (* DIVISION *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 3 (10 / 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 3 (15 / 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 3 (7 / 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 10 (100 / 10) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (5 / 10) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-3) ((-10) / 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-3) (10 / (-3)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 3 ((-10) / (-3)) in (print_newline (); (n1, p1, f1))) in
  
  (* MODULO *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 1 (10 mod 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (15 mod 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 1 (7 mod 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (100 mod 10) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 5 (5 mod 10) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (0 mod 5) in (print_newline (); (n1, p1, f1))) in
  
  (* EQUALITY *)
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (5 = 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false (5 = 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (0 = 0) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true ((-5) = (-5)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false ((-5) = 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false (5 <> 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (5 <> 3) in (print_newline (); (n1, p1, f1))) in
  
  (* LESS THAN *)
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (3 < 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false (5 < 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false (5 < 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true ((-5) < 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false (3 < (-5)) in (print_newline (); (n1, p1, f1))) in
  
  (* LESS EQUAL *)
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (3 <= 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (5 <= 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false (7 <= 5) in (print_newline (); (n1, p1, f1))) in
  
  (* GREATER THAN *)
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (5 > 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false (3 > 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false (5 > 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (3 > (-5)) in (print_newline (); (n1, p1, f1))) in
  
  (* GREATER EQUAL *)
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (5 >= 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f true (5 >= 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_bool (n+1) p f false (3 >= 5) in (print_newline (); (n1, p1, f1))) in
  
  (* BITWISE AND *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 7 (15 land 7) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 8 (12 land 10) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 15 (255 land 15) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (0 land 255) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 255 (255 land 255) in (print_newline (); (n1, p1, f1))) in
  
  (* BITWISE OR *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 12 (8 lor 4) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 7 (3 lor 5) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 255 (0 lor 255) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 3 (1 lor 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 15 (7 lor 8) in (print_newline (); (n1, p1, f1))) in
  
  (* BITWISE XOR *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 6 (5 lxor 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 0 (15 lxor 15) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 255 (255 lxor 0) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 6 (12 lxor 10) in (print_newline (); (n1, p1, f1))) in
  
  (* LEFT SHIFT *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 1 (1 lsl 0) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 2 (1 lsl 1) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 4 (1 lsl 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 8 (1 lsl 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 16 (1 lsl 4) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 20 (5 lsl 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 24 (3 lsl 3) in (print_newline (); (n1, p1, f1))) in
  
  (* LOGICAL RIGHT SHIFT *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 8 (16 lsr 1) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 4 (16 lsr 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 2 (16 lsr 3) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 1 (16 lsr 4) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 25 (100 lsr 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 15 (255 lsr 4) in (print_newline (); (n1, p1, f1))) in
  
  (* ARITHMETIC RIGHT SHIFT *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 8 (16 asr 1) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 4 (16 asr 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 25 (100 asr 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-8) ((-16) asr 1) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f (-4) ((-16) asr 2) in (print_newline (); (n1, p1, f1))) in
  
  (* COMBINED OPERATIONS *)
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 14 (2 + 3 * 4) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 7 (10 - 6 / 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 20 ((2 + 3) * 4) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 2 ((10 - 6) / 2) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 25 (5 * (3 + 2)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 3 ((10 + 5) / (3 + 2)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 50 (100 - (20 + 30)) in (print_newline (); (n1, p1, f1))) in
  let (n, p, f) = (let (n1, p1, f1) = test_result (n+1) p f 6 ((5 lor 3) land 6) in (print_newline (); (n1, p1, f1))) in
  
  print_newline ();
  (n, p, f)

let () =
  let (total, passed, failed) = run_tests () in
  
  (* Summary *)
  print_char 'T'; print_char 'O'; print_char 'T'; print_char 'A'; print_char 'L'; 
  print_char ':'; print_space ();
  print_int total;
  print_newline ();
  
  print_pass (); print_char ':'; print_space ();
  print_int passed;
  print_newline ();
  
  print_fail (); print_char ':'; print_space ();
  print_int failed;
  print_newline ();
  print_newline ();
  
  if failed = 0 then begin
    print_char 'A'; print_char 'L'; print_char 'L'; print_space ();
    print_ok ();
    print_newline ()
  end;
  
  flush stdout
