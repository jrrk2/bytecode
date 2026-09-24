(* repl: a read-eval-print loop for a small ML, on the UART and over UDP.

     # let rec fact n = if n = 0 then 1 else n * fact (n - 1)
     val fact = <fun>
     # fact 10
     - = 3628800

   The language: integers and booleans; + - * / mod; = <> < > <= >=;
   if/then/else; let [rec] f x y = e [in e]; fun x y -> e; try e with _ ->
   e (or "with m ->" to see the message); application by juxtaposition;
   parentheses.  Top-level lets extend the session.

   Two ways in, one session: typing at the UART (echo, backspace), and UDP
   datagrams to port 7777 -- `nc -u <address> 7777` -- whose lines are
   evaluated in turn, the output and a prompt going back to the sender.  The
   address comes from DHCP (as dhcp.ml, with the netboot loader's MAC, so the
   same lease); it answers ARP and ping too.  No authentication.

   Written for the VM as it stands: no exceptions (errors are values), no
   polymorphic comparison on strings (caml_string_equal instead); the UART
   and Ethernet through vm_io_read/vm_io_write (see io/dhcp.ml's I/O space,
   and 0x1008: the next received UART byte, or -1). *)

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
external ( land ) : int -> int -> int = "%andint"
external ( lor ) : int -> int -> int = "%orint"
external ( lxor ) : int -> int -> int = "%xorint"
external ( lsl ) : int -> int -> int = "%lslint"
external ( lsr ) : int -> int -> int = "%lsrint"
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
external array_get : 'a array -> int -> 'a = "%array_safe_get"
external array_set : 'a array -> int -> 'a -> unit = "%array_safe_set"

type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"

external io_read : int -> int = "vm_io_read"
external io_write : int -> int -> unit = "vm_io_write"

(* ---- I/O space ---- *)
let rx_base = 0x0000
let tx_base = 0x0800
let eth_status = 0x1000
let eth_rxlen = 0x1002
let eth_txlen = 0x1003
let leds = 0x1004
let uart = 0x1005
let timer_ms = 0x1006
let uart_rx = 0x1008
let eth_rx_valid = 1
let eth_tx_busy = 2

let rx i = io_read (rx_base + i)
let tx i v = io_write (tx_base + i) v
let tx_get i = io_read (tx_base + i)
let now () = io_read timer_ms

let my_mac = "\x02\x00\x00\x4d\x47\x33"  (* the netboot loader's: the same DHCP lease *)
let mac i = int_of_char (string_get my_mac i)

(* ---- output: to the UART, or into a UDP reply ---- *)
let net_max = 1400
let to_net = ref false
let net_out = create_bytes net_max
let net_len = ref 0

let putc c =
  if !to_net then begin
    if !net_len < net_max then begin bytes_set net_out !net_len c; net_len := !net_len + 1 end
  end else io_write uart (int_of_char c)
let puts s = for i = 0 to string_length s - 1 do putc (string_get s i) done
let newline () = if not !to_net then putc '\r'; putc '\n'
let rec put_nat n =
  if n >= 10 then put_nat (n / 10);
  putc (char_of_int (48 + n mod 10))
let put_int n = if n < 0 then begin putc '-'; put_nat (- n) end else put_nat n

(* The DHCP client's log (dhcp.ml's names), always to the UART. *)
let uart_putc c = io_write uart (int_of_char c)
let uart_puts s = for i = 0 to string_length s - 1 do uart_putc (string_get s i) done
let rec uart_dec n =
  if n >= 10 then uart_dec (n / 10);
  io_write uart (48 + n mod 10)
let uart_ip a =
  for i = 0 to 3 do
    uart_dec (array_get a i);
    if i < 3 then uart_putc '.'
  done

(* ---- the line being evaluated (the tokenizer reads it) ---- *)
let line_max = 120
let line = create_bytes line_max
let line_len = ref 0

(* ---- DHCP state ---- *)
type state = Init | Selecting | Requesting | Bound

let state = ref Init
let my_ip = [| 0; 0; 0; 0 |]        (* 0.0.0.0 until bound *)
let offered_ip = [| 0; 0; 0; 0 |]
let server_id = [| 0; 0; 0; 0 |]
let xid = [| 0x56; 0x4d; 0; 0 |]    (* "VM" and two bytes of the clock *)
let deadline = ref 0                 (* ms: retransmit or renew *)
let lease_s = ref 0

let bound () = !state = Bound
let ip i = array_get my_ip i

(* ---- checksum over the TX window ---- *)
let lnot_16 s = s lxor 0xFFFF

let ip_checksum start len =
  let s = ref 0 in
  let i = ref 0 in
  while !i + 1 < len do
    s := !s + ((tx_get (start + !i) lsl 8) lor tx_get (start + !i + 1));
    i := !i + 2
  done;
  if !i < len then s := !s + (tx_get (start + !i) lsl 8);
  while !s lsr 16 <> 0 do s := (!s land 0xFFFF) + (!s lsr 16) done;
  lnot_16 !s

let eth_send len =
  while io_read eth_status land eth_tx_busy <> 0 do () done;
  let len =
    if len < 60 then begin           (* pad to the 60-byte minimum *)
      for i = len to 59 do tx i 0 done;
      60
    end else len in
  io_write eth_txlen len

let ip_is_mine off =
  rx off = ip 0 && rx (off + 1) = ip 1 && rx (off + 2) = ip 2 && rx (off + 3) = ip 3

(* ---- ARP and ICMP echo, as ethmin, once we have an address ---- *)
let handle_arp len =
  if bound () && len >= 42 && rx 20 = 0x00 && rx 21 = 0x01 && ip_is_mine 38 then begin
    for i = 0 to 5 do
      tx i (rx (6 + i));
      tx (6 + i) (mac i)
    done;
    tx 12 0x08; tx 13 0x06;
    tx 14 0x00; tx 15 0x01;
    tx 16 0x08; tx 17 0x00;
    tx 18 6; tx 19 4;
    tx 20 0x00; tx 21 0x02;
    for i = 0 to 5 do tx (22 + i) (mac i) done;
    for i = 0 to 3 do tx (28 + i) (ip i) done;
    for i = 0 to 5 do tx (32 + i) (rx (22 + i)) done;
    for i = 0 to 3 do tx (38 + i) (rx (28 + i)) done;
    eth_send 42
  end

let handle_icmp len ihl =
  if bound () && ip_is_mine 30 && rx (14 + ihl) = 8 then begin
    for i = 0 to len - 1 do tx i (rx i) done;
    for i = 0 to 5 do
      tx i (rx (6 + i));
      tx (6 + i) (mac i)
    done;
    for i = 0 to 3 do
      tx (26 + i) (ip i);
      tx (30 + i) (rx (26 + i))
    done;
    tx 24 0; tx 25 0;
    let s = ip_checksum 14 ihl in
    tx 24 (s lsr 8); tx 25 (s land 0xFF);
    tx (14 + ihl) 0;
    tx (14 + ihl + 2) 0; tx (14 + ihl + 3) 0;
    let s = ip_checksum (14 + ihl) (len - 14 - ihl) in
    tx (14 + ihl + 2) (s lsr 8); tx (14 + ihl + 3) (s land 0xFF);
    eth_send len
  end

(* ---- DHCP client ---- *)
(* Frame layout: Ethernet 0..13, IP 14..33, UDP 34..41, BOOTP from 42 (its
   options from 42 + 240 = 282), 300 bytes of BOOTP: a 342-byte frame. *)
let bootp = 42
let frame_len = 342

type dhcp_msg = Discover | Request

let dhcp_send msg =
  for i = 0 to frame_len - 1 do tx i 0 done;
  for i = 0 to 5 do tx i 0xff; tx (6 + i) (mac i) done;       (* broadcast *)
  tx 12 0x08; tx 13 0x00;
  tx 14 0x45; tx 16 ((frame_len - 14) lsr 8); tx 17 ((frame_len - 14) land 0xFF);
  tx 22 64; tx 23 17;                                           (* TTL, UDP *)
  for i = 0 to 3 do tx (30 + i) 0xff done;                      (* to 255.255.255.255, from 0.0.0.0 *)
  let s = ip_checksum 14 20 in
  tx 24 (s lsr 8); tx 25 (s land 0xFF);
  tx 35 68; tx 37 67;                                           (* ports 68 -> 67 *)
  tx 38 ((frame_len - 34) lsr 8); tx 39 ((frame_len - 34) land 0xFF);  (* UDP checksum 0: none *)
  tx bootp 1; tx (bootp + 1) 1; tx (bootp + 2) 6;               (* BOOTREQUEST, Ethernet *)
  for i = 0 to 3 do tx (bootp + 4 + i) (array_get xid i) done;
  tx (bootp + 10) 0x80;                                         (* broadcast replies *)
  for i = 0 to 5 do tx (bootp + 28 + i) (mac i) done;           (* chaddr *)
  tx (bootp + 236) 0x63; tx (bootp + 237) 0x82; tx (bootp + 238) 0x53; tx (bootp + 239) 0x63;
  let o = ref (bootp + 240) in
  let opt b = tx !o b; o := !o + 1 in
  opt 53; opt 1;
  (match msg with
   | Discover -> opt 1
   | Request ->
     opt 3;
     opt 50; opt 4; for i = 0 to 3 do opt (array_get offered_ip i) done;
     opt 54; opt 4; for i = 0 to 3 do opt (array_get server_id i) done);
  opt 55; opt 3; opt 1; opt 3; opt 6;                           (* subnet, router, DNS *)
  opt 255;
  eth_send frame_len

let discover () =
  let t = now () in
  array_set xid 2 ((t lsr 8) land 0xFF);
  array_set xid 3 (t land 0xFF);
  uart_puts "dhcp: discover\r\n";
  dhcp_send Discover;
  state := Selecting;
  deadline := now () + 4000

let request () =
  uart_puts "dhcp: request ";
  uart_ip offered_ip;
  uart_puts "\r\n";
  dhcp_send Request;
  state := Requesting;
  deadline := now () + 4000

(* A BOOTREPLY to us: its message type (0 if it has none), with the
   offered address, server and lease noted on the way. *)
let dhcp_parse len =
  let msg = ref 0 in
  for i = 0 to 3 do array_set offered_ip i (rx (bootp + 16 + i)) done;
  let o = ref (bootp + 240) in
  while !o + 1 < len && rx !o <> 255 do
    let code = rx !o in
    if code = 0 then o := !o + 1
    else begin
      let n = rx (!o + 1) in
      (match code with
       | 53 -> msg := rx (!o + 2)
       | 54 -> for i = 0 to 3 do array_set server_id i (rx (!o + 2 + i)) done
       | 51 -> lease_s := (rx (!o + 2) lsl 24) lor (rx (!o + 3) lsl 16)
                          lor (rx (!o + 4) lsl 8) lor rx (!o + 5)
       | _ -> ());
      o := !o + 2 + n
    end
  done;
  !msg

let for_us () =
  rx bootp = 2
  && rx (bootp + 4) = array_get xid 0 && rx (bootp + 5) = array_get xid 1
  && rx (bootp + 6) = array_get xid 2 && rx (bootp + 7) = array_get xid 3
  && rx (bootp + 28) = mac 0 && rx (bootp + 29) = mac 1 && rx (bootp + 30) = mac 2
  && rx (bootp + 31) = mac 3 && rx (bootp + 32) = mac 4 && rx (bootp + 33) = mac 5
  && rx (bootp + 236) = 0x63 && rx (bootp + 237) = 0x82
  && rx (bootp + 238) = 0x53 && rx (bootp + 239) = 0x63

let handle_dhcp len =
  if len >= bootp + 240 && for_us () then begin
    let msg = dhcp_parse len in
    match !state, msg with
    | Selecting, 2 -> request ()                                (* OFFER *)
    | Requesting, 5 ->                                          (* ACK *)
      for i = 0 to 3 do array_set my_ip i (array_get offered_ip i) done;
      state := Bound;
      deadline := now () + !lease_s * 500;                      (* T1: half the lease, in ms *)
      uart_puts "dhcp: bound ";
      uart_ip my_ip;
      uart_puts " lease ";
      uart_dec !lease_s;
      uart_puts " s from ";
      uart_ip server_id;
      uart_puts "\r\n"
    | Requesting, 6 -> uart_puts "dhcp: nak\r\n"; state := Init  (* NAK *)
    | _ -> ()
  end

let dhcp_tick () =
  match !state with
  | Init -> discover ()
  | Selecting | Requesting -> if now () > !deadline then begin
      uart_puts "dhcp: timeout\r\n"; state := Init end
  | Bound -> if now () > !deadline then request ()             (* renew *)

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
  | Try of expr * string * expr           (* try e with x -> e: x names the message *)

let keyword s = string_equal s "try" || string_equal s "with"
                || string_equal s "let" || string_equal s "rec" || string_equal s "in"
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
  (* try e with _ -> e2, or "with x -> e2" to bind the failure's message:
     an error anywhere in e -- division by zero, an unbound name, a bad
     operand -- gives e2 instead.  The machine's own exceptions are what
     this is built on: see io/exc.ml. *)
  | t :: rest when is_kw t "try" ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (body, rest) ->
       match expect rest "with" with
       | Err e -> Err e
       | Ok rest ->
         let (name, rest) = match rest with
           | TId x :: r when not (keyword x) -> (x, r)
           | TSym x :: r when string_equal x "_" -> ("_", r)
           | _ -> ("_", rest) in
         match expect rest "->" with
         | Err e -> Err e
         | Ok rest ->
           match parse_expr rest with
           | Err e -> Err e
           | Ok (handler, rest) -> Ok (Try (body, name, handler), rest))
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
  (* () is the argument of a niladic builtin such as ms (); the language has
     no unit, so it is 0 *)
  | t :: t2 :: rest when is_sym t "(" && is_sym t2 ")" -> Ok (Int 0, rest)
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
  | VStr of string                        (* a caught failure's message *)
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
  (* ms (): milliseconds since reset, straight from the hardware counter,
     so a program can time itself: let t = ms () in ... ms () - t *)
  | App (Var f, _) when string_equal f "ms" -> Ok (VInt (now ()))
  | App (f, a) ->
    (match eval env f with
     | Err m -> Err m
     | Ok (VClosure (x, body, cenv)) ->
       (match eval env a with
        | Err m -> Err m
        | Ok va -> eval ((x, va) :: !cenv) body)
     | Ok _ -> Err "not a function")
  | Try (body, name, handler) ->
    (match eval env body with
     | Ok v -> Ok v
     | Err m ->
       (* the handler sees the message as a string value if it asked for a
          name; "_" discards it *)
       if string_equal name "_" then eval env handler
       else eval ((name, VStr m) :: env) handler)
  | Let (recursive, name, bound, body) ->
    (match eval env bound with
     | Err m -> Err m
     | Ok v ->
       (match recursive, v with
        | true, VClosure (_, _, cenv) -> cenv := (name, v) :: !cenv
        | _ -> ());
       eval ((name, v) :: env) body)

(* ---- evaluating a line, whichever way it came ---- *)
let print_value v = match v with
  | VInt n -> put_int n
  | VBool b -> puts (if b then "true" else "false")
  | VStr s -> putc '"'; puts s; putc '"'
  | VClosure _ -> puts "<fun>"

let session = ref []


(* A name used but never bound is an error in the definition, not in the
   call that finds out: OCaml says so when the let is typed, and a mini-ML
   that waits until the closure runs gives "unbound fact" to someone who
   has just seen "val fact = <fun>".  This walks an expression for the
   first free name, with the session's own bindings counted as bound. *)
let rec bound_in names x = match names with
  | [] -> false
  | y :: rest -> if string_equal x y then true else bound_in rest x

let rec free_name names e = match e with
  | Int _ -> Ok ()
  | Bool _ -> Ok ()
  | Var x -> if bound_in names x then Ok () else Err x
  | Fun (p, body) -> free_name (p :: names) body
  | App (f, a) ->
    (match free_name names f with Err m -> Err m | Ok () -> free_name names a)
  | Binop (_, a, b) ->
    (match free_name names a with Err m -> Err m | Ok () -> free_name names b)
  | If (c, a, b) ->
    (match free_name names c with
     | Err m -> Err m
     | Ok () -> match free_name names a with Err m -> Err m | Ok () -> free_name names b)
  | Try (body, x, handler) ->
    (match free_name names body with Err m -> Err m | Ok () -> free_name (x :: names) handler)
  | Let (recursive, name, bound, body) ->
    let inner = if recursive then name :: names else names in
    (match free_name inner bound with
     | Err m -> Err m
     | Ok () -> free_name (name :: names) body)

let session_names () =
  let rec go env acc = match env with
    | [] -> acc
    | (n, _) :: rest -> go rest (n :: acc) in
  go !session []

(* "ms" is the one name the evaluator answers for without a binding *)
let scope_check e = free_name ("ms" :: session_names ()) e

let evaluate_line () =
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
        match scope_check e with
        | Err x ->
          puts "error: unbound "; puts x;
          (* the usual cause: a function that calls itself, written without
             rec, which binds nothing for its own body *)
          (match e with
           | Let (false, name, _, _) when string_equal name x ->
             puts " (did you mean \"let rec\"?)"
           | _ -> ());
          newline ()
        | Ok () ->
        let t0 = now () in
        match eval !session e with
        | Err m -> puts "error: "; puts m; newline ()
        | Ok v ->
          let elapsed = now () - t0 in
          (match top_let, e with
           | true, Let (_, name, _, Var _) ->
             session := (name, v) :: !session;
             puts "val "; puts name; puts " = "
           | _ -> puts "- = ");
          print_value v;
          (* what it cost on the board, with the network and the UART left
             out: the millisecond counter around eval alone *)
          if elapsed > 0 then begin
            puts "   ("; put_int elapsed; puts " ms)"
          end;
          newline ()
  end

(* ---- the UART: a line collected a byte at a time, echoed ---- *)
let uart_line = create_bytes line_max
let uart_len = ref 0

let uart_poll () =
  let c = io_read uart_rx in
  if c >= 0 then begin
    if c = 13 || c = 10 then begin
      newline ();
      for i = 0 to !uart_len - 1 do bytes_set line i (bytes_get uart_line i) done;
      line_len := !uart_len;
      uart_len := 0;
      evaluate_line ();
      puts "# "
    end else if c = 8 || c = 127 then begin
      if !uart_len > 0 then begin
        uart_len := !uart_len - 1;
        putc '\b'; putc ' '; putc '\b'
      end
    end else if c >= 32 && !uart_len < line_max then begin
      bytes_set uart_line !uart_len (char_of_int c);
      uart_len := !uart_len + 1;
      io_write uart c
    end
  end

(* ---- UDP port 7777: each line of a datagram, the output sent back ---- *)
let repl_port = 7777

let udp_reply () =
  let len = 42 + !net_len in
  for i = 0 to 5 do
    tx i (rx (6 + i));                                         (* to the sender *)
    tx (6 + i) (mac i)
  done;
  tx 12 0x08; tx 13 0x00;
  tx 14 0x45; tx 15 0; tx 16 ((len - 14) lsr 8); tx 17 ((len - 14) land 0xFF);
  for i = 18 to 21 do tx i 0 done;
  tx 22 64; tx 23 17; tx 24 0; tx 25 0;
  for i = 0 to 3 do
    tx (26 + i) (ip i);
    tx (30 + i) (rx (26 + i))
  done;
  let s = ip_checksum 14 20 in
  tx 24 (s lsr 8); tx 25 (s land 0xFF);
  tx 34 (repl_port lsr 8); tx 35 (repl_port land 0xFF);
  tx 36 (rx 34); tx 37 (rx 35);                                (* back to its port *)
  tx 38 ((8 + !net_len) lsr 8); tx 39 ((8 + !net_len) land 0xFF);
  tx 40 0; tx 41 0;                                            (* no UDP checksum *)
  for i = 0 to !net_len - 1 do tx (42 + i) (int_of_char (bytes_get net_out i)) done;
  eth_send len

let handle_repl len ihl =
  let udp = 14 + ihl in
  let n = ((rx (udp + 4) lsl 8) lor rx (udp + 5)) - 8 in
  if bound () && ip_is_mine 30 && n >= 0 && udp + 8 + n <= len then begin
    to_net := true;
    net_len := 0;
    line_len := 0;
    for i = 0 to n - 1 do
      let c = rx (udp + 8 + i) in
      if c = 10 then begin evaluate_line (); line_len := 0 end
      else if c >= 32 && !line_len < line_max then begin
        bytes_set line !line_len (char_of_int c);
        line_len := !line_len + 1
      end
    done;
    evaluate_line ();                                          (* a last line without a newline *)
    puts "# ";
    udp_reply ();
    to_net := false
  end

let () =
  io_write leds 1;
  puts "OCaml VM mini-ML (UART, and UDP port 7777 once DHCP has an address)"; newline ();
  puts "# ";
  let pkts = ref 0 in
  while true do
    uart_poll ();
    dhcp_tick ();
    let st = io_read eth_status in
    if st land eth_rx_valid <> 0 then begin
      let len = io_read eth_rxlen land 0x7FF in
      if rx 12 = 0x08 && rx 13 = 0x06 then handle_arp len
      else if rx 12 = 0x08 && rx 13 = 0x00 && len >= 42 then begin
        let ihl = (rx 14 land 0x0F) * 4 in
        let dport = (rx (14 + ihl + 2) lsl 8) lor rx (14 + ihl + 3) in
        if rx 23 = 1 then handle_icmp len ihl
        else if rx 23 = 17 && dport = 68 then handle_dhcp len
        else if rx 23 = 17 && dport = repl_port then handle_repl len ihl
      end;
      io_write eth_rxlen 0;
      pkts := !pkts + 1;
      io_write leds ((if bound () then 2 else 0) lor ((!pkts land 0x3F) lsl 2))
    end
  done
