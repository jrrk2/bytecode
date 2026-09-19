(* repl: a read-eval-print loop for a small ML, on the UART.

     # let rec fact n = if n = 0 then 1 else n * fact (n - 1)
     val fact : <fun>
     # fact 10
     - = 3628800

   The language: integers and booleans; + - * / mod; = <> < > <= >=;
   if/then/else; let [rec] f x y = e [in e]; fun x y -> e; application by
   juxtaposition; parentheses.  Top-level lets extend the session.

   Written for the VM as it stands: no exceptions (errors are values), no
   polymorphic comparison on strings (caml_string_equal instead), and input
   from the UART through vm_io_read 0x1008 (-1 when nothing is waiting). *)

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
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
external not : bool -> bool = "%boolnot"
external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"
external string_length : string -> int = "%string_length"
external string_get : string -> int -> char = "%string_safe_get"
external string_equal : string -> string -> bool = "caml_string_equal"
external create_bytes : int -> bytes = "caml_create_bytes"
external bytes_set : bytes -> int -> char -> unit = "%bytes_unsafe_set"
external bytes_get : bytes -> int -> char = "%bytes_unsafe_get"
external bytes_to_string : bytes -> string = "%bytes_to_string"

type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"

external io_read : int -> int = "vm_io_read"
external io_write : int -> int -> unit = "vm_io_write"

let uart = 0x1005
let uart_rx = 0x1008

(* ---- output ---- *)
let putc c = io_write uart (int_of_char c)
let puts s = for i = 0 to string_length s - 1 do putc (string_get s i) done
let newline () = putc '\r'; putc '\n'
let rec put_nat n =
  if n >= 10 then put_nat (n / 10);
  io_write uart (48 + n mod 10)
let put_int n = if n < 0 then begin putc '-'; put_nat (- n) end else put_nat n

(* ---- input: a line into a buffer, echoed, with backspace ---- *)
let line_max = 120
let line = create_bytes line_max
let line_len = ref 0

let rec getc () = let c = io_read uart_rx in if c < 0 then getc () else c

let read_line () =
  line_len := 0;
  let fin = ref false in
  while not !fin do
    let c = getc () in
    if c = 13 || c = 10 then begin newline (); fin := true end
    else if c = 8 || c = 127 then begin
      if !line_len > 0 then begin
        line_len := !line_len - 1;
        putc '\b'; putc ' '; putc '\b'
      end
    end else if c >= 32 && !line_len < line_max then begin
      bytes_set line !line_len (char_of_int c);
      line_len := !line_len + 1;
      io_write uart c
    end
  done

(* ---- tokens ---- *)
type token = TInt of int | TId of string | TSym of string

let is_digit c = c >= 48 && c <= 57
let is_alpha c = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c = 95
let is_space c = c = 32 || c = 9
let char_at i = int_of_char (bytes_get line i)

let substring from upto =
  let b = create_bytes (upto - from) in
  for i = from to upto - 1 do bytes_set b (i - from) (bytes_get line i) done;
  bytes_to_string b

(* two-character operators first, then one *)
let symbol_len i =
  let c = char_at i in
  let d = if i + 1 < !line_len then char_at (i + 1) else 0 in
  if (c = 60 && (d = 61 || d = 62)) || (c = 62 && d = 61) || (c = 45 && d = 62) then 2
  else if c = 43 || c = 45 || c = 42 || c = 47 || c = 61 || c = 60 || c = 62
       || c = 40 || c = 41 then 1
  else 0

type 'a result = Ok of 'a | Err of string

let tokenize () =
  let rec go i acc =
    if i >= !line_len then Ok (rev acc [])
    else begin
      let c = char_at i in
      if is_space c then go (i + 1) acc
      else if is_digit c then begin
        let j = ref i and n = ref 0 in
        while !j < !line_len && is_digit (char_at !j) do
          n := !n * 10 + (char_at !j - 48); j := !j + 1
        done;
        go !j (TInt !n :: acc)
      end else if is_alpha c then begin
        let j = ref i in
        while !j < !line_len && (is_alpha (char_at !j) || is_digit (char_at !j)) do j := !j + 1 done;
        go !j (TId (substring i !j) :: acc)
      end else begin
        let n = symbol_len i in
        if n = 0 then Err "unexpected character"
        else go (i + n) (TSym (substring i (i + n)) :: acc)
      end
    end
  and rev l acc = match l with [] -> acc | x :: r -> rev r (x :: acc) in
  go 0 []

(* ---- syntax ---- *)
type expr =
  | Int of int
  | Bool of bool
  | Var of string
  | Binop of string * expr * expr
  | If of expr * expr * expr
  | Fun of string * expr
  | App of expr * expr
  | Let of bool * string * expr * expr    (* rec?, name, bound, body *)

let keyword s = string_equal s "let" || string_equal s "rec" || string_equal s "in"
                || string_equal s "if" || string_equal s "then" || string_equal s "else"
                || string_equal s "fun" || string_equal s "true" || string_equal s "false"
                || string_equal s "mod"

let is_sym t s = match t with TSym x -> string_equal x s | _ -> false
let is_kw t s = match t with TId x -> string_equal x s | _ -> false

let ( ^^ ) a b =
  let n = string_length a and m = string_length b in
  let r = create_bytes (n + m) in
  for i = 0 to n - 1 do bytes_set r i (string_get a i) done;
  for i = 0 to m - 1 do bytes_set r (n + i) (string_get b i) done;
  bytes_to_string r

let expect toks s = match toks with
  | t :: rest -> if is_sym t s || is_kw t s then Ok rest else Err ("expected " ^^ s)
  | [] -> Err ("expected " ^^ s)

(* parameters x y z, then a body: fun x -> fun y -> ... *)
let rec params toks acc = match toks with
  | TId x :: rest when not (keyword x) -> params rest (x :: acc)
  | _ -> (acc, toks)

let rec wrap_funs ps body = match ps with
  | [] -> body
  | p :: rest -> wrap_funs rest (Fun (p, body))

let rec parse_expr toks = match toks with
  | t :: rest when is_kw t "let" -> parse_let rest true
  | t :: rest when is_kw t "if" ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (c, rest) ->
       match expect rest "then" with
       | Err e -> Err e
       | Ok rest ->
         match parse_expr rest with
         | Err e -> Err e
         | Ok (a, rest) ->
           match expect rest "else" with
           | Err e -> Err e
           | Ok rest ->
             match parse_expr rest with
             | Err e -> Err e
             | Ok (b, rest) -> Ok (If (c, a, b), rest))
  | t :: rest when is_kw t "fun" ->
    let (ps, rest) = params rest [] in
    (match ps with
     | [] -> Err "fun needs a parameter"
     | _ ->
       match expect rest "->" with
       | Err e -> Err e
       | Ok rest ->
         match parse_expr rest with
         | Err e -> Err e
         | Ok (body, rest) -> Ok (wrap_funs ps body, rest))
  | _ -> parse_cmp toks

(* let [rec] f x y = e [in e]; with need_in false, "in" is optional (top level) *)
and parse_let toks need_in =
  let (recursive, toks) = match toks with
    | t :: rest when is_kw t "rec" -> (true, rest)
    | _ -> (false, toks) in
  match toks with
  | TId name :: rest when not (keyword name) ->
    let (ps, rest) = params rest [] in
    (match expect rest "=" with
     | Err e -> Err e
     | Ok rest ->
       match parse_expr rest with
       | Err e -> Err e
       | Ok (bound, rest) ->
         let bound = wrap_funs ps bound in
         match rest with
         | t :: rest when is_kw t "in" ->
           (match parse_expr rest with
            | Err e -> Err e
            | Ok (body, rest) -> Ok (Let (recursive, name, bound, body), rest))
         | _ -> if need_in then Err "expected in"
           else Ok (Let (recursive, name, bound, Var name), rest))
  | _ -> Err "expected a name after let"

and parse_cmp toks =
  match parse_arith toks with
  | Err e -> Err e
  | Ok (a, rest) ->
    match rest with
    | TSym op :: rest2 when string_equal op "=" || string_equal op "<>" || string_equal op "<"
                           || string_equal op ">" || string_equal op "<=" || string_equal op ">=" ->
      (match parse_arith rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (Binop (op, a, b), rest3))
    | _ -> Ok (a, rest)

and parse_arith toks =
  match parse_term toks with
  | Err e -> Err e
  | Ok (a, rest) -> arith_more a rest
and arith_more a toks = match toks with
  | TSym op :: rest when string_equal op "+" || string_equal op "-" ->
    (match parse_term rest with
     | Err e -> Err e
     | Ok (b, rest) -> arith_more (Binop (op, a, b)) rest)
  | _ -> Ok (a, toks)

and parse_term toks =
  match parse_app toks with
  | Err e -> Err e
  | Ok (a, rest) -> term_more a rest
and term_more a toks = match toks with
  | t :: rest when is_sym t "*" || is_sym t "/" || is_kw t "mod" ->
    let op = match t with TSym s -> s | _ -> "mod" in
    (match parse_app rest with
     | Err e -> Err e
     | Ok (b, rest) -> term_more (Binop (op, a, b)) rest)
  | _ -> Ok (a, toks)

and parse_app toks =
  match parse_atom toks with
  | Err e -> Err e
  | Ok (f, rest) -> app_more f rest
and app_more f toks =
  if starts_atom toks then
    match parse_atom toks with
    | Err e -> Err e
    | Ok (a, rest) -> app_more (App (f, a)) rest
  else Ok (f, toks)
and starts_atom toks = match toks with
  | TInt _ :: _ -> true
  | TId x :: _ -> not (keyword x) || string_equal x "true" || string_equal x "false"
  | t :: _ -> is_sym t "("
  | [] -> false

and parse_atom toks = match toks with
  | TInt n :: rest -> Ok (Int n, rest)
  | TId x :: rest when string_equal x "true" -> Ok (Bool true, rest)
  | TId x :: rest when string_equal x "false" -> Ok (Bool false, rest)
  | TId x :: rest when not (keyword x) -> Ok (Var x, rest)
  | TSym s :: rest when string_equal s "-" ->
    (match parse_atom rest with
     | Err e -> Err e
     | Ok (a, rest) -> Ok (Binop ("-", Int 0, a), rest))
  | t :: rest when is_sym t "(" ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (e, rest) ->
       match expect rest ")" with
       | Err e -> Err e
       | Ok rest -> Ok (e, rest))
  | _ -> Err "syntax error"

(* ---- evaluation ---- *)
type value =
  | VInt of int
  | VBool of bool
  | VClosure of string * expr * env ref   (* the ref lets a let rec see itself *)
and env = (string * value) list

let rec lookup env x = match env with
  | [] -> Err ("unbound " ^^ x)
  | (y, v) :: rest -> if string_equal x y then Ok v else lookup rest x

let arith op a b =
  if string_equal op "+" then Ok (VInt (a + b))
  else if string_equal op "-" then Ok (VInt (a - b))
  else if string_equal op "*" then Ok (VInt (a * b))
  else if b = 0 then Err "division by zero"
  else if string_equal op "/" then Ok (VInt (a / b))
  else Ok (VInt (a mod b))

let compare_ints op (a : int) (b : int) =
  VBool (if string_equal op "=" then a = b
         else if string_equal op "<>" then a <> b
         else if string_equal op "<" then a < b
         else if string_equal op ">" then a > b
         else if string_equal op "<=" then a <= b
         else a >= b)

let is_comparison op =
  string_equal op "=" || string_equal op "<>" || string_equal op "<"
  || string_equal op ">" || string_equal op "<=" || string_equal op ">="

let rec eval env e = match e with
  | Int n -> Ok (VInt n)
  | Bool b -> Ok (VBool b)
  | Var x -> lookup env x
  | Fun (x, body) -> Ok (VClosure (x, body, ref env))
  | Binop (op, a, b) ->
    (match eval env a with
     | Err m -> Err m
     | Ok va ->
       match eval env b with
       | Err m -> Err m
       | Ok vb ->
         match va, vb with
         | VInt x, VInt y -> if is_comparison op then Ok (compare_ints op x y) else arith op x y
         | VBool x, VBool y when string_equal op "=" -> Ok (VBool (x = y))
         | VBool x, VBool y when string_equal op "<>" -> Ok (VBool (x <> y))
         | _ -> Err ("bad operands for " ^^ op))
  | If (c, a, b) ->
    (match eval env c with
     | Ok (VBool true) -> eval env a
     | Ok (VBool false) -> eval env b
     | Ok _ -> Err "if needs a bool"
     | Err m -> Err m)
  | App (f, a) ->
    (match eval env f with
     | Err m -> Err m
     | Ok (VClosure (x, body, cenv)) ->
       (match eval env a with
        | Err m -> Err m
        | Ok va -> eval ((x, va) :: !cenv) body)
     | Ok _ -> Err "not a function")
  | Let (recursive, name, bound, body) ->
    (match eval env bound with
     | Err m -> Err m
     | Ok v ->
       (match recursive, v with
        | true, VClosure (_, _, cenv) -> cenv := (name, v) :: !cenv
        | _ -> ());
       eval ((name, v) :: env) body)

(* ---- the loop ---- *)
let print_value v = match v with
  | VInt n -> put_int n
  | VBool b -> puts (if b then "true" else "false")
  | VClosure _ -> puts "<fun>"

let session = ref []

let () =
  puts "OCaml VM mini-ML"; newline ();
  while true do
    puts "# ";
    read_line ();
    if !line_len > 0 then begin
      match tokenize () with
      | Err m -> puts "error: "; puts m; newline ()
      | Ok toks ->
        let top_let = match toks with t :: _ -> is_kw t "let" | [] -> false in
        let parsed = match toks with
          | t :: rest when is_kw t "let" -> parse_let rest false
          | _ -> parse_expr toks in
        match parsed with
        | Err m -> puts "error: "; puts m; newline ()
        | Ok (_, _ :: _) -> puts "error: unexpected input at the end"; newline ()
        | Ok (e, []) ->
          match eval !session e with
          | Err m -> puts "error: "; puts m; newline ()
          | Ok v ->
            (match top_let, e with
             | true, Let (_, name, _, Var _) ->
               session := (name, v) :: !session;
               puts "val "; puts name; puts " = "
             | _ -> puts "- = ");
            print_value v; newline ()
    end
  done
