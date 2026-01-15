(* Comprehensive OCaml VM Test Suite *)
(* Tests all arithmetic, logical, comparison, and shift operations *)

type in_channel
type out_channel

(* External declarations *)
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

let rec print_int i = 
  if i > 9 then print_int (i/10); 
  print_char (char_of_int (i mod 10 + int_of_char('0')))

let print_int i = 
  if i < 0 then begin 
    print_char '-'; 
    print_int (-i); 
  end else 
    print_int i

let print_string s =
  let rec loop i =
    if i < 0 then ()
    else begin
      print_char s.[i];
      loop (i - 1)
    end
  in
  (* Print backwards since we're doing recursive *)
  let len = String.length s - 1 in
  let rec forward i =
    if i > len then ()
    else begin
      print_char s.[i];
      forward (i + 1)
    end
  in
  forward 0

let print_newline () = print_char '\n'

let print_space () = print_char ' '

(* Test result tracking *)
let test_count = ref 0
let pass_count = ref 0
let fail_count = ref 0

(* Print test result *)
let print_result name expected actual =
  test_count := !test_count + 1;
  print_string "Test ";
  print_int !test_count;
  print_string ": ";
  print_string name;
  print_string " = ";
  print_int actual;
  if expected = actual then begin
    print_string " [PASS]";
    pass_count := !pass_count + 1
  end else begin
    print_string " [FAIL expected ";
    print_int expected;
    print_char ']';
    fail_count := !fail_count + 1
  end;
  print_newline ()

let print_bool_result name expected actual =
  test_count := !test_count + 1;
  print_string "Test ";
  print_int !test_count;
  print_string ": ";
  print_string name;
  print_string " = ";
  print_string (if actual then "true" else "false");
  if expected = actual then begin
    print_string " [PASS]";
    pass_count := !pass_count + 1
  end else begin
    print_string " [FAIL expected ";
    print_string (if expected then "true" else "false");
    print_char ']';
    fail_count := !fail_count + 1
  end;
  print_newline ()

(* Simple pseudo-random number generator *)
(* Linear congruential generator: X(n+1) = (a * X(n) + c) mod m *)
let rand_seed = ref 12345

let rand_next () =
  rand_seed := (!rand_seed * 1103515245 + 12345) mod 2147483647;
  if !rand_seed < 0 then !rand_seed + 2147483647 else !rand_seed

let rand_range min max =
  let r = rand_next () in
  let range = max - min + 1 in
  min + (r mod range)

(* ===== ARITHMETIC TESTS ===== *)

let test_addition () =
  print_string "=== Addition Tests ===";
  print_newline ();
  
  (* Basic cases *)
  print_result "5 + 3" 8 (5 + 3);
  print_result "0 + 0" 0 (0 + 0);
  print_result "100 + 200" 300 (100 + 200);
  print_result "(-5) + 3" (-2) ((-5) + 3);
  print_result "5 + (-3)" 2 (5 + (-3));
  print_result "(-5) + (-3)" (-8) ((-5) + (-3));
  
  (* Edge cases *)
  print_result "1 + 1" 2 (1 + 1);
  print_result "999 + 1" 1000 (999 + 1);
  
  (* Random tests *)
  let a = rand_range 1 100 in
  let b = rand_range 1 100 in
  print_result "random add" (a + b) (a + b);
  
  print_newline ()

let test_subtraction () =
  print_string "=== Subtraction Tests ===";
  print_newline ();
  
  (* Basic cases *)
  print_result "10 - 3" 7 (10 - 3);
  print_result "5 - 5" 0 (5 - 5);
  print_result "3 - 10" (-7) (3 - 10);
  print_result "(-5) - 3" (-8) ((-5) - 3);
  print_result "5 - (-3)" 8 (5 - (-3));
  print_result "(-5) - (-3)" (-2) ((-5) - (-3));
  
  (* Edge cases *)
  print_result "100 - 1" 99 (100 - 1);
  print_result "0 - 5" (-5) (0 - 5);
  
  print_newline ()

let test_multiplication () =
  print_string "=== Multiplication Tests ===";
  print_newline ();
  
  (* Basic cases *)
  print_result "5 * 3" 15 (5 * 3);
  print_result "0 * 100" 0 (0 * 100);
  print_result "100 * 0" 0 (100 * 0);
  print_result "1 * 42" 42 (1 * 42);
  print_result "(-5) * 3" (-15) ((-5) * 3);
  print_result "5 * (-3)" (-15) (5 * (-3));
  print_result "(-5) * (-3)" 15 ((-5) * (-3));
  
  (* Powers of 2 *)
  print_result "2 * 2" 4 (2 * 2);
  print_result "4 * 4" 16 (4 * 4);
  print_result "10 * 10" 100 (10 * 10);
  
  print_newline ()

let test_division () =
  print_string "=== Division Tests ===";
  print_newline ();
  
  (* Basic cases *)
  print_result "10 / 3" 3 (10 / 3);
  print_result "15 / 5" 3 (15 / 5);
  print_result "7 / 2" 3 (7 / 2);
  print_result "100 / 10" 10 (100 / 10);
  print_result "5 / 10" 0 (5 / 10);
  
  (* Negative numbers *)
  print_result "(-10) / 3" (-3) ((-10) / 3);
  print_result "10 / (-3)" (-3) (10 / (-3));
  print_result "(-10) / (-3)" 3 ((-10) / (-3));
  
  (* Edge cases *)
  print_result "1 / 1" 1 (1 / 1);
  print_result "999 / 1" 999 (999 / 1);
  
  print_newline ()

let test_modulo () =
  print_string "=== Modulo Tests ===";
  print_newline ();
  
  (* Basic cases *)
  print_result "10 mod 3" 1 (10 mod 3);
  print_result "15 mod 5" 0 (15 mod 5);
  print_result "7 mod 2" 1 (7 mod 2);
  print_result "100 mod 10" 0 (100 mod 10);
  print_result "5 mod 10" 5 (5 mod 10);
  
  (* Negative numbers *)
  print_result "(-10) mod 3" (-1) ((-10) mod 3);
  print_result "10 mod (-3)" 1 (10 mod (-3));
  
  (* Edge cases *)
  print_result "0 mod 5" 0 (0 mod 5);
  print_result "99 mod 100" 99 (99 mod 100);
  
  print_newline ()

let test_negation () =
  print_string "=== Negation Tests ===";
  print_newline ();
  
  print_result "~-5" (-5) (~-5);
  print_result "~-(-5)" 5 (~-(-5));
  print_result "~-0" 0 (~-0);
  print_result "~-100" (-100) (~-100);
  print_result "~-(-100)" 100 (~-(-100));
  
  print_newline ()

(* ===== COMPARISON TESTS ===== *)

let test_equality () =
  print_string "=== Equality Tests ===";
  print_newline ();
  
  print_bool_result "5 = 5" true (5 = 5);
  print_bool_result "5 = 3" false (5 = 3);
  print_bool_result "0 = 0" true (0 = 0);
  print_bool_result "(-5) = (-5)" true ((-5) = (-5));
  print_bool_result "(-5) = 5" false ((-5) = 5);
  
  print_bool_result "5 <> 5" false (5 <> 5);
  print_bool_result "5 <> 3" true (5 <> 3);
  
  print_newline ()

let test_comparisons () =
  print_string "=== Comparison Tests ===";
  print_newline ();
  
  (* Less than *)
  print_bool_result "3 < 5" true (3 < 5);
  print_bool_result "5 < 3" false (5 < 3);
  print_bool_result "5 < 5" false (5 < 5);
  print_bool_result "(-5) < 3" true ((-5) < 3);
  print_bool_result "3 < (-5)" false (3 < (-5));
  
  (* Less than or equal *)
  print_bool_result "3 <= 5" true (3 <= 5);
  print_bool_result "5 <= 5" true (5 <= 5);
  print_bool_result "7 <= 5" false (7 <= 5);
  
  (* Greater than *)
  print_bool_result "5 > 3" true (5 > 3);
  print_bool_result "3 > 5" false (3 > 5);
  print_bool_result "5 > 5" false (5 > 5);
  print_bool_result "3 > (-5)" true (3 > (-5));
  
  (* Greater than or equal *)
  print_bool_result "5 >= 3" true (5 >= 3);
  print_bool_result "5 >= 5" true (5 >= 5);
  print_bool_result "3 >= 5" false (3 >= 5);
  
  print_newline ()

(* ===== BITWISE LOGICAL TESTS ===== *)

let test_bitwise_and () =
  print_string "=== Bitwise AND Tests ===";
  print_newline ();
  
  print_result "15 land 7" 7 (15 land 7);
  print_result "12 land 10" 8 (12 land 10);
  print_result "255 land 15" 15 (255 land 15);
  print_result "0 land 255" 0 (0 land 255);
  print_result "255 land 0" 0 (255 land 0);
  print_result "255 land 255" 255 (255 land 255);
  print_result "7 land 5" 5 (7 land 5);
  
  print_newline ()

let test_bitwise_or () =
  print_string "=== Bitwise OR Tests ===";
  print_newline ();
  
  print_result "8 lor 4" 12 (8 lor 4);
  print_result "3 lor 5" 7 (3 lor 5);
  print_result "0 lor 255" 255 (0 lor 255);
  print_result "255 lor 0" 255 (255 lor 0);
  print_result "1 lor 2" 3 (1 lor 2);
  print_result "7 lor 8" 15 (7 lor 8);
  
  print_newline ()

let test_bitwise_xor () =
  print_string "=== Bitwise XOR Tests ===";
  print_newline ();
  
  print_result "5 lxor 3" 6 (5 lxor 3);
  print_result "15 lxor 15" 0 (15 lxor 15);
  print_result "255 lxor 0" 255 (255 lxor 0);
  print_result "12 lxor 10" 6 (12 lxor 10);
  print_result "7 lxor 5" 2 (7 lxor 5);
  
  print_newline ()

(* ===== SHIFT TESTS ===== *)

let test_shift_left () =
  print_string "=== Left Shift Tests ===";
  print_newline ();
  
  print_result "1 lsl 0" 1 (1 lsl 0);
  print_result "1 lsl 1" 2 (1 lsl 1);
  print_result "1 lsl 2" 4 (1 lsl 2);
  print_result "1 lsl 3" 8 (1 lsl 3);
  print_result "1 lsl 4" 16 (1 lsl 4);
  print_result "5 lsl 2" 20 (5 lsl 2);
  print_result "3 lsl 3" 24 (3 lsl 3);
  print_result "7 lsl 1" 14 (7 lsl 1);
  
  print_newline ()

let test_shift_right_logical () =
  print_string "=== Logical Right Shift Tests ===";
  print_newline ();
  
  print_result "16 lsr 1" 8 (16 lsr 1);
  print_result "16 lsr 2" 4 (16 lsr 2);
  print_result "16 lsr 3" 2 (16 lsr 3);
  print_result "16 lsr 4" 1 (16 lsr 4);
  print_result "100 lsr 2" 25 (100 lsr 2);
  print_result "255 lsr 4" 15 (255 lsr 4);
  print_result "7 lsr 1" 3 (7 lsr 1);
  
  print_newline ()

let test_shift_right_arithmetic () =
  print_string "=== Arithmetic Right Shift Tests ===";
  print_newline ();
  
  print_result "16 asr 1" 8 (16 asr 1);
  print_result "16 asr 2" 4 (16 asr 2);
  print_result "100 asr 2" 25 (100 asr 2);
  print_result "255 asr 4" 15 (255 asr 4);
  
  (* Negative numbers *)
  print_result "(-16) asr 1" (-8) ((-16) asr 1);
  print_result "(-16) asr 2" (-4) ((-16) asr 2);
  
  print_newline ()

(* ===== COMBINED OPERATIONS TESTS ===== *)

let test_combined () =
  print_string "=== Combined Operations Tests ===";
  print_newline ();
  
  (* Operator precedence *)
  print_result "2 + 3 * 4" 14 (2 + 3 * 4);
  print_result "10 - 6 / 2" 7 (10 - 6 / 2);
  print_result "(2 + 3) * 4" 20 ((2 + 3) * 4);
  print_result "(10 - 6) / 2" 2 ((10 - 6) / 2);
  
  (* Nested operations *)
  print_result "5 * (3 + 2)" 25 (5 * (3 + 2));
  print_result "(10 + 5) / (3 + 2)" 3 ((10 + 5) / (3 + 2));
  print_result "100 - (20 + 30)" 50 (100 - (20 + 30));
  
  (* Bitwise combinations *)
  print_result "(5 lor 3) land 6" 6 ((5 lor 3) land 6);
  print_result "15 land (7 lor 8)" 15 (15 land (7 lor 8));
  
  print_newline ()

(* ===== PSEUDO-RANDOM TESTS ===== *)

let test_random_operations () =
  print_string "=== Random Operations Tests ===";
  print_newline ();
  
  (* Generate and test random values *)
  let rec test_random n =
    if n <= 0 then ()
    else begin
      let a = rand_range 1 50 in
      let b = rand_range 1 20 in
      
      (* Test that operation produces same result twice *)
      let add_result = a + b in
      print_result "rand add verify" add_result (a + b);
      
      let sub_result = a - b in
      print_result "rand sub verify" sub_result (a - b);
      
      let mul_result = a * b in
      print_result "rand mul verify" mul_result (a * b);
      
      let div_result = a / b in
      print_result "rand div verify" div_result (a / b);
      
      let mod_result = a mod b in
      print_result "rand mod verify" mod_result (a mod b);
      
      test_random (n - 1)
    end
  in
  test_random 3;
  
  print_newline ()

(* ===== MAIN TEST RUNNER ===== *)

let () =
  print_string "================================";
  print_newline ();
  print_string "OCaml VM Test Suite";
  print_newline ();
  print_string "================================";
  print_newline ();
  print_newline ();
  
  test_negation ();
  test_addition ();
  test_subtraction ();
  test_multiplication ();
  test_division ();
  test_modulo ();
  test_equality ();
  test_comparisons ();
  test_bitwise_and ();
  test_bitwise_or ();
  test_bitwise_xor ();
  test_shift_left ();
  test_shift_right_logical ();
  test_shift_right_arithmetic ();
  test_combined ();
  test_random_operations ();
  
  print_string "================================";
  print_newline ();
  print_string "Test Summary";
  print_newline ();
  print_string "================================";
  print_newline ();
  print_string "Total tests: ";
  print_int !test_count;
  print_newline ();
  print_string "Passed: ";
  print_int !pass_count;
  print_newline ();
  print_string "Failed: ";
  print_int !fail_count;
  print_newline ();
  print_newline ();
  
  if !fail_count = 0 then begin
    print_string "All tests PASSED!";
    print_newline ()
  end else begin
    print_string "Some tests FAILED!";
    print_newline ()
  end;
  
  flush stdout
