(* replnet: a read-eval-print loop for a small ML -- on the UART, over UDP,
   and over TCP, so a telnet client gets the session with editing and echo.
   The TCP is io/telnet.ml's: one connection, handshake, in-order data with
   an immediate ACK, one segment in flight, FIN both ways.

   (repl.ml, unchanged, is the UART and UDP version.)


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

(* ==== HW ==== *)
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
let dip_sw = 0x1009
let buttons = 0x100b
let eth_rx_valid = 1
let eth_tx_busy = 2

let rx i = io_read (rx_base + i)
let tx i v = io_write (tx_base + i) v
let tx_get i = io_read (tx_base + i)
let now () = io_read timer_ms
(* ==== END HW ==== *)

let my_mac = "\x02\x00\x00\x4d\x47\x33"  (* the netboot loader's: the same DHCP lease *)
let mac i = int_of_char (string_get my_mac i)

(* ---- output: to the UART, or into a UDP reply ---- *)
let net_max = 1400
let to_net = ref false
let net_out = create_bytes net_max
let net_len = ref 0

(* to_tcp takes priority: a line evaluated for a telnet client goes into
   that connection's output buffer (tcp_out_char, defined with the TCP
   layer below and reached through this forward reference). *)
let to_tcp = ref false
let tcp_sink = ref (fun (_ : char) -> ())

let putc c =
  if !to_tcp then (!tcp_sink) c
  else if !to_net then begin
    if !net_len < net_max then begin bytes_set net_out !net_len c; net_len := !net_len + 1 end
  end else io_write uart (int_of_char c)
let puts s = for i = 0 to string_length s - 1 do putc (string_get s i) done
let newline () = if not !to_net || !to_tcp then putc '\r'; putc '\n'
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

(* The TCP checksum needs the sum on its own (the pseudo-header is added
   before the fold), so the sum and the fold are separate here; ip_checksum
   is the two together, as before. *)
let sum_tx start len =
  let s = ref 0 in
  let i = ref 0 in
  while !i + 1 < len do
    s := !s + ((tx_get (start + !i) lsl 8) lor tx_get (start + !i + 1));
    i := !i + 2
  done;
  if !i < len then s := !s + (tx_get (start + !i) lsl 8);
  !s

let fold s =
  let s = ref s in
  while !s lsr 16 <> 0 do s := (!s land 0xFFFF) + (!s lsr 16) done;
  lnot_16 !s

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
      if io_read dip_sw land 0xFF <> 0 then begin
        uart_puts " (dip "; uart_dec (io_read dip_sw land 0xFF); uart_putc ')'
      end;
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

(* ---- floating point ----
   The processor does these in hardware (fpga/fpu-rtl); here they are just
   the externals, since this file compiles without the standard library. *)
external ( +. ) : float -> float -> float = "caml_add_float" "%addfloat"
external ( -. ) : float -> float -> float = "caml_sub_float" "%subfloat"
external ( *. ) : float -> float -> float = "caml_mul_float" "%mulfloat"
external ( /. ) : float -> float -> float = "caml_div_float" "%divfloat"
external ( ~-. ) : float -> float = "caml_neg_float" "%negfloat"
external float_of_int : int -> float = "caml_float_of_int" "%floatofint"
external int_of_float : float -> int = "caml_int_of_float" "%intoffloat"
external flt_lt : float -> float -> bool = "caml_lt_float" "%lessthan"
external flt_le : float -> float -> bool = "caml_le_float" "%lessequal"
external flt_eq : float -> float -> bool = "caml_eq_float" "%equal"

(* ---- tokens ---- *)
type token = TInt of int | TFloat of float | TId of string | TSym of string

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
  (* +. -. *. /. are two characters, as are <= <> >= -> *)
  if (c = 60 && (d = 61 || d = 62)) || (c = 62 && d = 61) || (c = 45 && d = 62)
     || ((c = 43 || c = 45 || c = 42 || c = 47) && d = 46) then 2
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
        (* a point with a digit after it, or a point at the end as OCaml
           allows in "1.", makes this a float rather than an int *)
        if !j < !line_len && char_at !j = 46 then begin
          let whole = float_of_int !n in
          j := !j + 1;
          let frac = ref 0.0 and scale = ref 1.0 in
          while !j < !line_len && is_digit (char_at !j) do
            scale := !scale *. 10.0;
            frac := !frac *. 10.0 +. float_of_int (char_at !j - 48);
            j := !j + 1
          done;
          go !j (TFloat (whole +. (if flt_eq !scale 1.0 then 0.0 else !frac /. !scale)) :: acc)
        end else go !j (TInt !n :: acc)
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
  | Float of float
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
  | TSym op :: rest when string_equal op "+" || string_equal op "-"
                        || string_equal op "+." || string_equal op "-." ->
    (match parse_term rest with
     | Err e -> Err e
     | Ok (b, rest) -> arith_more (Binop (op, a, b)) rest)
  | _ -> Ok (a, toks)

and parse_term toks =
  match parse_app toks with
  | Err e -> Err e
  | Ok (a, rest) -> term_more a rest
and term_more a toks = match toks with
  | t :: rest when is_sym t "*" || is_sym t "/" || is_kw t "mod"
                   || is_sym t "*." || is_sym t "/." ->
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
  | TFloat _ :: _ -> true
  | TId x :: _ -> not (keyword x) || string_equal x "true" || string_equal x "false"
  | t :: _ -> is_sym t "("
  | [] -> false

and parse_atom toks = match toks with
  | TInt n :: rest -> Ok (Int n, rest)
  | TFloat f :: rest -> Ok (Float f, rest)
  | TId x :: rest when string_equal x "true" -> Ok (Bool true, rest)
  | TId x :: rest when string_equal x "false" -> Ok (Bool false, rest)
  | TId x :: rest when not (keyword x) -> Ok (Var x, rest)
  | TSym s :: TFloat f :: rest when string_equal s "-" -> Ok (Float (~-. f), rest)
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
  | VFloat of float
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

let float_arith op a b =
  if string_equal op "+." then Ok (VFloat (a +. b))
  else if string_equal op "-." then Ok (VFloat (a -. b))
  else if string_equal op "*." then Ok (VFloat (a *. b))
  else Ok (VFloat (a /. b))          (* division by zero gives an infinity,
                                        as it does in OCaml *)

(* The comparisons are the ones the hardware answers; the rest are built
   from them, as caml_gt_float and its siblings are. *)
let compare_floats op (a : float) (b : float) =
  VBool (if string_equal op "=" then flt_eq a b
         else if string_equal op "<>" then not (flt_eq a b)
         else if string_equal op "<" then flt_lt a b
         else if string_equal op ">" then flt_lt b a
         else if string_equal op "<=" then flt_le a b
         else flt_le b a)

let is_float_op op =
  string_equal op "+." || string_equal op "-." ||
  string_equal op "*." || string_equal op "/."


(* ---- types ----
   Hindley-Milner, so that "1 +. 2" is refused before it is run and a
   function's type is worked out rather than declared.  Type variables are
   mutable cells: unification points one at the type it turned out to be,
   and everything downstream follows the link.  Generalisation is the plain
   rule -- a let quantifies the variables its right-hand side left free that
   the environment does not also mention -- which is enough for a REPL and
   costs no levels to track. *)
type ty =
  | TInt
  | TBool
  | TFloat
  | TString
  | TArrow of ty * ty
  | TVar of tv ref
and tv = Unbound of int | Link of ty

let tvar_count = ref 0
let fresh_tv () =
  tvar_count := !tvar_count + 1;
  TVar (ref (Unbound !tvar_count))

let rec repr t = match t with
  | TVar r -> (match r.contents with Link u -> repr u | Unbound _ -> t)
  | _ -> t

let rec occurs id t = match repr t with
  | TVar r -> (match r.contents with Unbound i -> i = id | Link _ -> false)
  | TArrow (a, b) -> occurs id a || occurs id b
  | _ -> false

(* Type variables are numbered as they are created, so a type printed on its
   own would start at whatever the counter had reached: 'g for the first one
   the session happens to show.  Naming them in order of appearance instead
   gives 'a, 'b, ... per type, which is what OCaml prints and what anyone
   reading it expects. *)
let type_name t =
  let seen = ref [] and next = ref 0 in
  let rec index_of (i : int) l = match l with
    | [] ->
      let k = !next in
      next := k + 1;
      seen := (i, k) :: !seen;
      k
    | (j, k) :: r -> if i = j then k else index_of i r in
  let letter i =
    let b = create_bytes 1 in
    bytes_set b 0 (char_of_int (97 + i mod 26));
    bytes_to_string b in
  let rec go t = match repr t with
    | TInt -> "int"
    | TBool -> "bool"
    | TFloat -> "float"
    | TString -> "string"
    | TVar r -> (match r.contents with
                 | Unbound i -> "'" ^^ letter (index_of i !seen)
                 | Link u -> go u)
    | TArrow (a, b) ->
      (match repr a with
       | TArrow _ -> "(" ^^ go a ^^ ") -> " ^^ go b
       | _ -> go a ^^ " -> " ^^ go b) in
  go t

let rec unify a b =
  let ra = repr a and rb = repr b in
  match ra, rb with
  | TInt, TInt -> Ok ()
  | TBool, TBool -> Ok ()
  | TFloat, TFloat -> Ok ()
  | TString, TString -> Ok ()
  | TArrow (a1, a2), TArrow (b1, b2) ->
    (match unify a1 b1 with Err m -> Err m | Ok () -> unify a2 b2)
  | TVar r, _ ->
    (match r.contents with
     | Unbound i ->
       (* the same variable on both sides: every cell carries a distinct
          number, so the numbers answer this without physical equality *)
       let same = match rb with
         | TVar q -> (match q.contents with Unbound j -> i = j | Link _ -> false)
         | _ -> false in
       if same then Ok ()
       else if occurs i rb then Err "this would make a type that contains itself"
       else begin r.contents <- Link rb; Ok () end
     | Link u -> unify u rb)
  | _, TVar _ -> unify rb ra
  | _ ->
    Err ("this expression has type " ^^ type_name rb
         ^^ " but was expected to have type " ^^ type_name ra)

(* A scheme is a type with some of its variables quantified; instantiating
   gives each of them a fresh cell, which is what lets "let id x = x" serve
   an int in one place and a float in another. *)
type scheme = Forall of int list * ty

let rec mem_int (x : int) (l : int list) =
  match l with [] -> false | y :: r -> x = y || mem_int x r

let rec free_ty t acc = match repr t with
  | TVar r -> (match r.contents with
               | Unbound i -> if mem_int i acc then acc else i :: acc
               | Link u -> free_ty u acc)
  | TArrow (a, b) -> free_ty b (free_ty a acc)
  | _ -> acc

let rec free_env env acc = match env with
  | [] -> acc
  | (_, Forall (q, t)) :: rest ->
    let here = free_ty t [] in
    let rec keep l a = match l with
      | [] -> a
      | i :: r -> keep r (if mem_int i q || mem_int i a then a else i :: a) in
    free_env rest (keep here acc)

let generalize env t =
  let ft = free_ty t [] and fe = free_env env [] in
  let rec keep l a = match l with
    | [] -> a
    | i :: r -> keep r (if mem_int i fe then a else i :: a) in
  Forall (keep ft [], t)

let instantiate sc = match sc with
  | Forall ([], t) -> t
  | Forall (q, t) ->
    let subst = ref [] in
    let rec fresh_for (i : int) l = match l with
      | [] -> let v = fresh_tv () in subst := (i, v) :: !subst; v
      | (j, v) :: r -> if i = j then v else fresh_for i r in
    let rec go t = match repr t with
      | TVar r -> (match r.contents with
                   | Unbound i -> if mem_int i q then fresh_for i !subst else t
                   | Link u -> go u)
      | TArrow (a, b) -> TArrow (go a, go b)
      | u -> u in
    go t

let rec lookup_scheme env x = match env with
  | [] -> Err ("unbound " ^^ x)
  | (y, sc) :: rest -> if string_equal x y then Ok (instantiate sc) else lookup_scheme rest x

let int_op op =
  string_equal op "+" || string_equal op "-" || string_equal op "*"
  || string_equal op "/" || string_equal op "mod"

let rec infer env e = match e with
  | Int _ -> Ok TInt
  | Float _ -> Ok TFloat
  | Bool _ -> Ok TBool
  | Var x -> lookup_scheme env x
  | Fun (x, body) ->
    let a = fresh_tv () in
    (match infer ((x, Forall ([], a)) :: env) body with
     | Err m -> Err m
     | Ok b -> Ok (TArrow (a, b)))
  | App (Var f, _) when string_equal f "ms" -> Ok TInt
  | App (f, a) ->
    (match infer env f with
     | Err m -> Err m
     | Ok tf ->
       match infer env a with
       | Err m -> Err m
       | Ok ta ->
         let r = fresh_tv () in
         match unify tf (TArrow (ta, r)) with
         | Err m -> Err m
         | Ok () -> Ok r)
  | Binop (op, a, b) ->
    (match infer env a with
     | Err m -> Err m
     | Ok ta ->
       match infer env b with
       | Err m -> Err m
       | Ok tb ->
         if is_comparison op then
           (match unify ta tb with Err m -> Err m | Ok () -> Ok TBool)
         else begin
           let want = if int_op op then TInt else TFloat in
           match unify ta want with
           | Err m -> Err m
           | Ok () -> match unify tb want with Err m -> Err m | Ok () -> Ok want
         end)
  | If (c, a, b) ->
    (match infer env c with
     | Err m -> Err m
     | Ok tc ->
       match unify tc TBool with
       | Err _ -> Err "the condition of an if must be a bool"
       | Ok () ->
         match infer env a with
         | Err m -> Err m
         | Ok ta ->
           match infer env b with
           | Err m -> Err m
           | Ok tb -> match unify ta tb with Err m -> Err m | Ok () -> Ok ta)
  | Let (recursive, name, bound, body) ->
    let inner =
      if recursive then (name, Forall ([], fresh_tv ())) :: env else env in
    (match infer inner bound with
     | Err m -> Err m
     | Ok tb ->
       let check =
         if recursive then
           (match inner with
            | (_, Forall (_, a)) :: _ -> unify a tb
            | [] -> Ok ())
         else Ok () in
       match check with
       | Err m -> Err m
       | Ok () ->
         let sc = generalize env tb in
         infer ((name, sc) :: env) body)
  | Try (body, name, handler) ->
    (match infer env body with
     | Err m -> Err m
     | Ok tb ->
       let henv = if string_equal name "_" then env
                  else (name, Forall ([], TString)) :: env in
       match infer henv handler with
       | Err m -> Err m
       | Ok th -> match unify tb th with Err m -> Err m | Ok () -> Ok tb)

let rec eval env e = match e with
  | Int n -> Ok (VInt n)
  | Float f -> Ok (VFloat f)
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
         | VFloat x, VFloat y ->
           if is_comparison op then Ok (compare_floats op x y)
           else if is_float_op op then float_arith op x y
           else Err ("float needs " ^^ op ^^ ".")
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
(* Printing a double, without caml_format_float -- which this processor does
   not have, and which would be a page of C if it did.  Six digits after the
   point, the last one rounded, and a trailing zero kept so that a float
   always looks like one: 3. rather than 3.  Values too large for an int are
   printed as a mantissa and a power of ten, which is what they are. *)
let print_float (x : float) =
  if not (flt_eq x x) then puts "nan"
  else begin
    let neg = flt_lt x 0.0 in
    let a = if neg then ~-. x else x in
    if neg then putc '-';
    if flt_le 1e18 a then puts "inf"        (* anything this big, near enough *)
    else begin
      (* the whole part, digit by digit from the top, so that values beyond
         an int's range still print *)
      let rec scale_of p acc = if flt_lt a p then acc else scale_of (p *. 10.0) (acc + 1) in
      let digits = scale_of 1.0 0 in
      let rest = ref a in
      if digits = 0 then putc '0'
      else begin
        let p = ref 1.0 in
        for _ = 2 to digits do p := !p *. 10.0 done;
        for _ = 1 to digits do
          let d = int_of_float (!rest /. !p) in
          putc (char_of_int (48 + d));
          rest := !rest -. float_of_int d *. !p;
          p := !p /. 10.0
        done
      end;
      putc '.';
      (* Six places, rounded at the last, with trailing zeros dropped: OCaml
         prints 3.75 and 6., not 3.750000 and 6.000000. *)
      let f = !rest *. 1000000.0 +. 0.5 in
      let n = ref (int_of_float f) in
      if !n >= 1000000 then n := 999999;
      let keep = ref 6 in
      let m = ref !n in
      while !keep > 0 && !m mod 10 = 0 do m := !m / 10; keep := !keep - 1 done;
      let d = ref 1 in
      for _ = 2 to !keep do d := !d * 10 done;
      let r = ref !m in
      for _ = 1 to !keep do
        let k = !r / !d in
        putc (char_of_int (48 + k));
        r := !r - k * !d;
        d := !d / 10
      done
    end
  end

let print_value v = match v with
  | VInt n -> put_int n
  | VFloat f -> print_float f
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
  | Float _ -> Ok ()
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

(* The session's types, beside its values.  A top-level binding is parsed as
   "let x = e in x", so its scheme is generalised from the right-hand side
   and kept here; everything else is inferred against what is already bound. *)
let type_session : (string * scheme) list ref = ref []

let infer_line e = match e with
  | Let (recursive, name, bound, Var v) when string_equal v name ->
    let self = fresh_tv () in
    let inner = if recursive then (name, Forall ([], self)) :: !type_session
                else !type_session in
    (match infer inner bound with
     | Err m -> Err m
     | Ok tb ->
       let check = if recursive then unify self tb else Ok () in
       match check with
       | Err m -> Err m
       | Ok () -> Ok (name, generalize !type_session tb, tb))
  | _ -> (match infer !type_session e with
          | Err m -> Err m
          | Ok t -> Ok ("", Forall ([], t), t))

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
        match infer_line e with
        | Err m -> puts "error: "; puts m; newline ()
        | Ok (bound_name, sc, ty) ->
        let t0 = now () in
        match eval !session e with
        | Err m -> puts "error: "; puts m; newline ()
        | Ok v ->
          let elapsed = now () - t0 in
          (match top_let, e with
           | true, Let (_, name, _, Var _) ->
             session := (name, v) :: !session;
             type_session := (bound_name, sc) :: !type_session;
             puts "val "; puts name; puts " : "; puts (type_name ty); puts " = "
           | _ -> puts "- : "; puts (type_name ty); puts " = ");
          print_value v;
          (* what it cost on the board, with the network and the UART left
             out: the millisecond counter around eval alone *)
          if elapsed > 0 then begin
            puts "   ("; put_int elapsed; puts " ms)"
          end;
          newline ()
  end

(* ---- the UART: a line collected a byte at a time, echoed ---- *)
(* ---- 32-bit sequence numbers as two 16-bit halves ---- *)
let seq_set (a : int array) hi lo = array_set a 0 hi; array_set a 1 lo
let seq_copy (dst : int array) (src : int array) = seq_set dst (array_get src 0) (array_get src 1)

(* a + n, n >= 0 and small *)
let seq_add (a : int array) n =
  let lo = array_get a 1 + n in
  array_set a 1 (lo land 0xFFFF);
  array_set a 0 ((array_get a 0 + (lo lsr 16)) land 0xFFFF)

(* a - b as a signed distance, saturating outside +-32767: everything this
   code decides (is this the next byte? is this ack in flight?) is a
   comparison of numbers that are close together *)
let seq_diff (a : int array) (b : int array) =
  let dlo = array_get a 1 - array_get b 1 in
  let borrow = if dlo < 0 then 1 else 0 in
  let dhi = (array_get a 0 - array_get b 0 - borrow) land 0xFFFF in
  let dlo = dlo land 0xFFFF in
  if dhi = 0 then (if dlo < 32768 then dlo else 32767)
  else if dhi = 0xFFFF then (if dlo >= 32768 then dlo - 65536 else -32768)
  else if dhi land 0x8000 <> 0 then -32768
  else 32767

let seq_eq (a : int array) (b : int array) =
  array_get a 0 = array_get b 0 && array_get a 1 = array_get b 1

(* ---- TCP ---- *)
let tcp_port = 23
let mss = 536                      (* what we send; the peer's MSS is not needed *)
let out_max = 1024                 (* unsent + unacknowledged output *)
let win = 1024                     (* what we advertise: one RX window's worth *)

type tstate = Closed | SynRcvd | Estab | LastAck

let tcp_state = ref Closed
let peer_mac = [| 0; 0; 0; 0; 0; 0 |]
let peer_ip = [| 0; 0; 0; 0 |]
let peer_port = ref 0
let rcv_nxt = [| 0; 0 |]           (* the next byte we expect *)
let snd_una = [| 0; 0 |]           (* the oldest byte we have sent and not had acked *)
let snd_nxt = [| 0; 0 |]           (* the next byte we will send *)
let out = create_bytes out_max     (* snd_una .. snd_una + out_len *)
let out_len = ref 0
let rtx_at = ref 0                 (* ms: retransmit the unacked head then *)
let rtx_left = ref 0               (* retransmissions before the peer is declared gone *)
let knocked = ref false            (* someone was turned away: is the incumbent still there? *)
let idle_at = ref 0                (* ms: with nothing heard by then, the peer is gone *)
let idle_ms = 600000               (* ten minutes of silence ends a session: long
                                      enough to read what is on the screen, and a
                                      backstop only -- a peer that goes away while
                                      we have something to send is caught by the
                                      retransmission count, in seconds *)
let rtx_max = 8
let close_after = ref false        (* the application asked to hang up *)

let out_room () = out_max - !out_len

let out_char c =
  if !out_len < out_max then begin
    bytes_set out !out_len c;
    out_len := !out_len + 1
  end

let out_string s = for i = 0 to string_length s - 1 do out_char (string_get s i) done

let out_dec n =
  let rec go n = if n >= 10 then go (n / 10); out_char (char_of_int (48 + n mod 10)) in
  if n = 0 then out_char '0' else go n

(* The TCP header sits at 34 with a 20-byte IP header; data at 54. *)
let tcph = 34
let data_off = 54

(* flags: 0x01 FIN, 0x02 SYN, 0x04 RST, 0x08 PSH, 0x10 ACK *)
let send_segment flags seq data_len with_mss =
  let opt_len = if with_mss then 4 else 0 in
  let tcp_len = 20 + opt_len + data_len in
  let ip_len = 20 + tcp_len in
  for i = 0 to 5 do tx i (array_get peer_mac i); tx (6 + i) (mac i) done;
  tx 12 0x08; tx 13 0x00;
  tx 14 0x45; tx 15 0;
  tx 16 (ip_len lsr 8); tx 17 (ip_len land 0xFF);
  tx 18 0; tx 19 0; tx 20 0x40; tx 21 0;          (* id 0, don't fragment *)
  tx 22 64; tx 23 6;                               (* TTL, TCP *)
  tx 24 0; tx 25 0;
  for i = 0 to 3 do tx (26 + i) (ip i); tx (30 + i) (array_get peer_ip i) done;
  let s = ip_checksum 14 20 in
  tx 24 (s lsr 8); tx 25 (s land 0xFF);
  tx tcph (tcp_port lsr 8); tx (tcph + 1) (tcp_port land 0xFF);
  tx (tcph + 2) (!peer_port lsr 8); tx (tcph + 3) (!peer_port land 0xFF);
  tx (tcph + 4) (array_get seq 0 lsr 8); tx (tcph + 5) (array_get seq 0 land 0xFF);
  tx (tcph + 6) (array_get seq 1 lsr 8); tx (tcph + 7) (array_get seq 1 land 0xFF);
  tx (tcph + 8) (array_get rcv_nxt 0 lsr 8); tx (tcph + 9) (array_get rcv_nxt 0 land 0xFF);
  tx (tcph + 10) (array_get rcv_nxt 1 lsr 8); tx (tcph + 11) (array_get rcv_nxt 1 land 0xFF);
  tx (tcph + 12) (((20 + opt_len) / 4) lsl 4);
  tx (tcph + 13) flags;
  tx (tcph + 14) (win lsr 8); tx (tcph + 15) (win land 0xFF);
  tx (tcph + 16) 0; tx (tcph + 17) 0;              (* checksum, filled below *)
  tx (tcph + 18) 0; tx (tcph + 19) 0;              (* urgent pointer *)
  if with_mss then begin
    tx (tcph + 20) 2; tx (tcph + 21) 4;
    tx (tcph + 22) (mss lsr 8); tx (tcph + 23) (mss land 0xFF)
  end;
  (* pseudo-header: source and destination addresses, protocol, TCP length *)
  let ps = ref 0 in
  for i = 0 to 1 do
    ps := !ps + ((ip (2 * i) lsl 8) lor ip (2 * i + 1));
    ps := !ps + ((array_get peer_ip (2 * i) lsl 8) lor array_get peer_ip (2 * i + 1))
  done;
  ps := !ps + 6 + tcp_len;
  let s = fold (!ps + sum_tx tcph tcp_len) in
  tx (tcph + 16) (s lsr 8); tx (tcph + 17) (s land 0xFF);
  eth_send (14 + ip_len)

(* Put the unsent part of the output buffer on the wire, one segment. *)
let send_data () =
  let unsent = !out_len - seq_diff snd_nxt snd_una in
  if unsent > 0 then begin
    let n = if unsent > mss then mss else unsent in
    let from = seq_diff snd_nxt snd_una in
    for i = 0 to n - 1 do tx (data_off + i) (int_of_char (bytes_get out (from + i))) done;
    send_segment 0x18 snd_nxt n false;             (* PSH|ACK *)
    seq_add snd_nxt n;
    rtx_at := now () + 400
  end

let send_ack () = send_segment 0x10 snd_nxt 0 false

let send_rst_to seq_hi seq_lo =
  (* an RST for a segment we cannot place: our sequence is their ack *)
  let s = [| seq_hi; seq_lo |] in
  send_segment 0x04 s 0 false

let close_connection () =
  tcp_state := Closed;
  knocked := false;
  out_len := 0;
  close_after := false;
  rtx_left := 0;
  uart_puts "tcp: closed\n"

(* ---- the application behind the connection: the REPL ---- *)
let prompt () = out_string "# "

let banner () =
  out_string "\r\nOCaml processor: mini-ML over telnet.  ^C clears the line.\r\n";
  prompt ()

(* A line from the client: evaluate it with the REPL's own output going into
   this connection's buffer (to_tcp), then a prompt. *)
let run_line () =
  to_tcp := true;
  evaluate_line ();
  line_len := 0;
  prompt ();
  to_tcp := false

(* One received byte, after telnet's escapes have been removed: echo it and
   collect a line.  The client is in character-at-a-time mode, so the editing
   happens here. *)
let app_byte c =
  let v = int_of_char c in
  if v = 13 || v = 10 then begin
    out_string "\r\n";
    run_line ()
  end else if v = 8 || v = 127 then begin
    if !line_len > 0 then begin
      line_len := !line_len - 1;
      out_string "\b \b"
    end
  end else if v = 3 then begin
    line_len := 0;
    out_string "^C\r\n";
    prompt ()
  end else if v >= 32 && v < 127 then begin
    if !line_len < line_max then begin
      bytes_set line !line_len c;
      line_len := !line_len + 1;
      out_char c
    end
  end

(* telnet option negotiation: we say WILL ECHO and WILL SUPPRESS-GO-AHEAD so
   the client sends each keystroke, and refuse everything it offers. *)
let iac = 255
let telnet_state = ref 0                           (* 0 data, 1 after IAC, 2 after a verb *)
let telnet_verb = ref 0

let telnet_reply verb opt =
  out_char (char_of_int iac); out_char (char_of_int verb); out_char (char_of_int opt)

let telnet_hello () =
  telnet_reply 251 1;                              (* WILL ECHO *)
  telnet_reply 251 3                               (* WILL SUPPRESS-GO-AHEAD *)

let feed_byte v =
  if !telnet_state = 1 then begin
    if v = iac then begin telnet_state := 0; app_byte (char_of_int iac) end
    else if v >= 251 && v <= 254 then begin telnet_verb := v; telnet_state := 2 end
    else telnet_state := 0                          (* other commands: ignored *)
  end else if !telnet_state = 2 then begin
    (* DO x -> WONT x unless it is one of ours; WILL x -> DONT x *)
    (if !telnet_verb = 253 then                     (* DO *)
       (if v = 1 || v = 3 then () else telnet_reply 252 v)
     else if !telnet_verb = 251 then telnet_reply 254 v   (* WILL -> DONT *)
     else ());
    telnet_state := 0
  end else if v = iac then telnet_state := 1
  else if v = 0 then ()                             (* CR NUL: the NUL is padding *)
  else app_byte (char_of_int v)

(* A sequence number for a connection we refuse, made only of theirs: the
   same SYN always earns the same answer, so the second segment can check
   the ACK without having kept anything. *)
let cookie isn =
  [| ((array_get isn 0) lxor 0x5A3C) land 0xFFFF;
     ((array_get isn 1) + 0x1D7B) land 0xFFFF |]

let busy_msg =
  "\r\nbusy: this processor serves one session at a time, and another is connected.\r\nplease try again shortly.\r\n"

(* ---- the TCP input path ---- *)
let handle_tcp len ihl =
  let t = 14 + ihl in
  if bound () && ip_is_mine 30 && len >= t + 20 then begin
    let dport = (rx (t + 2) lsl 8) lor rx (t + 3) in
    let sport = (rx t lsl 8) lor rx (t + 1) in
    let doff = (rx (t + 12) lsr 4) * 4 in
    let flags = rx (t + 13) in
    let seg_seq = [| (rx (t + 4) lsl 8) lor rx (t + 5); (rx (t + 6) lsl 8) lor rx (t + 7) |] in
    let seg_ack = [| (rx (t + 8) lsl 8) lor rx (t + 9); (rx (t + 10) lsl 8) lor rx (t + 11) |] in
    let ip_total = (rx 16 lsl 8) lor rx 17 in
    let seg_len = ip_total - ihl - doff in
    let syn = flags land 0x02 <> 0 and ack = flags land 0x10 <> 0 in
    let fin = flags land 0x01 <> 0 and rst = flags land 0x04 <> 0 in
    let from_peer =
      !tcp_state <> Closed && sport = !peer_port
      && rx 26 = array_get peer_ip 0 && rx 27 = array_get peer_ip 1
      && rx 28 = array_get peer_ip 2 && rx 29 = array_get peer_ip 3 in
    if dport = tcp_port && seg_len >= 0 && t + doff + seg_len <= len then begin
      if rst then begin
        if from_peer then close_connection ()
      end else if syn && not ack && !tcp_state = Closed then begin
        (* passive open: take the connection *)
        for i = 0 to 5 do array_set peer_mac i (rx (6 + i)) done;
        for i = 0 to 3 do array_set peer_ip i (rx (26 + i)) done;
        peer_port := sport;
        seq_copy rcv_nxt seg_seq;
        seq_add rcv_nxt 1;
        let t0 = now () in
        seq_set snd_una ((t0 lsr 6) land 0xFFFF) ((t0 * 7) land 0xFFFF);   (* an ISN that moves *)
        seq_copy snd_nxt snd_una;
        out_len := 0;
        line_len := 0;
        telnet_state := 0;
        tcp_state := SynRcvd;
        idle_at := now () + idle_ms;
        rtx_left := rtx_max;
        uart_puts "tcp: syn from ";
        uart_ip peer_ip;
        uart_putc ':';
        uart_dec sport;
        uart_putc '\n';
        send_segment 0x12 snd_nxt 0 true;                          (* SYN|ACK with MSS *)
        seq_add snd_nxt 1;
        rtx_at := now () + 400
      end else if not from_peer && !tcp_state <> Closed then
        (* Someone else knocks while a session is in progress.  We have room
           for exactly one connection, so instead of a bare RST ("connection
           refused", which tells the person nothing) we answer the handshake
           and say why -- and we do it without a second connection block, by
           deriving our sequence number from theirs the way a SYN cookie
           does, so nothing is remembered between the two segments. *)
        (let saved_port = !peer_port and saved_mac = [| 0; 0; 0; 0; 0; 0 |]
         and saved_ip = [| 0; 0; 0; 0 |] and saved_rcv = [| 0; 0 |] in
         for i = 0 to 5 do array_set saved_mac i (array_get peer_mac i) done;
         for i = 0 to 3 do array_set saved_ip i (array_get peer_ip i) done;
         seq_copy saved_rcv rcv_nxt;
         for i = 0 to 5 do array_set peer_mac i (rx (6 + i)) done;
         for i = 0 to 3 do array_set peer_ip i (rx (26 + i)) done;
         peer_port := sport;
         (* The cookie is made from the byte after their SYN -- the number
            the SYN names and every later segment of theirs carries -- so
            both halves of this exchange arrive at it independently. *)
         seq_copy rcv_nxt seg_seq;
         if syn then seq_add rcv_nxt 1;
         let ck = cookie rcv_nxt in
         if syn && not ack then begin
           uart_puts "tcp: busy, turning away ";
           uart_ip peer_ip; uart_putc ':'; uart_dec sport; uart_putc '\n';
           knocked := true;   (* and ask the incumbent, once we are back on it,
                                 whether it is still listening: a frame lost in
                                 the one-frame receive window can leave us
                                 holding a session whose peer has gone home *)
           send_segment 0x12 ck 0 true                       (* SYN|ACK, our cookie *)
         end else if ack && seg_len = 0 && not fin then begin
           let want = [| array_get ck 0; array_get ck 1 |] in
           seq_add want 1;
           if seq_eq seg_ack want then begin
             (* their ACK of our SYN: the whole refusal in one segment *)
             let n = string_length busy_msg in
             for i = 0 to n - 1 do
               tx (data_off + i) (int_of_char (string_get busy_msg i))
             done;
             send_segment 0x19 want n false                  (* FIN|PSH|ACK *)
           end
         end else if fin then begin
           (* their half closing: acknowledge it and we are done with them *)
           seq_add rcv_nxt (seg_len + 1);
           let s = [| array_get ck 0; array_get ck 1 |] in
           seq_add s (string_length busy_msg + 2);
           send_segment 0x10 s 0 false
         end;
         for i = 0 to 5 do array_set peer_mac i (array_get saved_mac i) done;
         for i = 0 to 3 do array_set peer_ip i (array_get saved_ip i) done;
         seq_copy rcv_nxt saved_rcv;
         peer_port := saved_port)
      else if from_peer then begin
        idle_at := now () + idle_ms;
        (* acknowledgement first: drop what the peer has taken *)
        if ack then begin
          let acked = seq_diff seg_ack snd_una in
          if acked > 0 && acked <= !out_len + 2 then begin
            let drop = if acked > !out_len then !out_len else acked in
            for i = 0 to !out_len - drop - 1 do
              bytes_set out i (bytes_get out (i + drop))
            done;
            out_len := !out_len - drop;
            seq_copy snd_una seg_ack;
            if seq_eq snd_una snd_nxt then rtx_at := 0 else rtx_at := now () + 400
          end
        end;
        if !tcp_state = SynRcvd && ack then begin
          tcp_state := Estab;
          uart_puts "tcp: established\n";
          telnet_hello ();
          banner ()
        end;
        if !tcp_state = Estab || !tcp_state = SynRcvd then begin
          let d = seq_diff seg_seq rcv_nxt in
          if seg_len > 0 then begin
            if d = 0 then begin
              (* in order: give it to the application, byte by byte *)
              for i = 0 to seg_len - 1 do feed_byte (rx (t + doff + i)) done;
              seq_add rcv_nxt seg_len
            end;
            send_ack ()                                  (* also re-ACKs a duplicate *)
          end;
          if fin && (d = 0 || d = seg_len) then begin
            seq_add rcv_nxt 1;
            uart_puts "tcp: fin\n";
            send_segment 0x11 snd_nxt 0 false;           (* FIN|ACK *)
            seq_add snd_nxt 1;
            tcp_state := LastAck;
            rtx_at := now () + 400
          end
        end else if !tcp_state = LastAck && ack then close_connection ()
      end else if not syn then begin
        (* something for a connection we do not have *)
        if ack then send_rst_to (array_get seg_ack 0) (array_get seg_ack 1)
      end
    end
  end

(* Retransmission and the application's own output: called every pass. *)
let tcp_tick () =
  if !tcp_state = Estab || !tcp_state = SynRcvd || !tcp_state = LastAck then begin
    let in_flight = seq_diff snd_nxt snd_una in
    if now () > !idle_at then begin
      (* the peer stopped answering: a closed laptop, a pulled cable, a
         client that died.  Without this the session stays Established for
         ever and every later client is refused a connection it could have
         had. *)
      uart_puts "tcp: peer gone, session dropped\n";
      send_segment 0x04 snd_nxt 0 false;            (* RST: it may still be there *)
      close_connection ()
    end else if in_flight > 0 && !rtx_at <> 0 && now () > !rtx_at && !rtx_left = 0 then begin
      uart_puts "tcp: no answer, session dropped\n";
      send_segment 0x04 snd_nxt 0 false;
      close_connection ()
    end else if in_flight > 0 && !rtx_at <> 0 && now () > !rtx_at then begin
      rtx_left := !rtx_left - 1;
      (* the head of the window again: SYN, data or FIN, whichever it was *)
      if !tcp_state = SynRcvd then send_segment 0x12 snd_una 0 true
      else if !tcp_state = LastAck then send_segment 0x11 snd_una 0 false
      else begin
        seq_copy snd_nxt snd_una;
        send_data ()
      end;
      rtx_at := now () + 800
    end else if !knocked && !tcp_state = Estab && in_flight = 0 && !out_len = 0 then begin
      (* a bare ACK to the peer we are keeping the session for.  A peer that
         is still there ignores it; a peer that has gone answers with a reset
         (or nothing at all, and the silence is caught above), and the next
         caller gets the session instead of the same refusal for ever. *)
      knocked := false;
      send_ack ()
    end else if !tcp_state = Estab && in_flight = 0 && !out_len > 0 then
      send_data ()
    else if !tcp_state = Estab && !close_after && !out_len = 0 && in_flight = 0 then begin
      send_segment 0x11 snd_nxt 0 false;
      seq_add snd_nxt 1;
      tcp_state := LastAck;
      close_after := false;
      rtx_at := now () + 400
    end
  end

let () = tcp_sink := out_char

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

(* ---- one pass of the machine ---- *)
let packets = ref 0

let poll () =
  uart_poll ();
  dhcp_tick ();
  tcp_tick ();
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
      else if rx 23 = 6 then handle_tcp len ihl
    end;
    io_write eth_rxlen 0;
    packets := !packets + 1;
    io_write leds ((if bound () then 2 else 0) lor ((!packets land 0x3F) lsl 2))
  end

let build_id = 0x100a

(* "24d6527 open": the commit this bitstream was built from (with a + if the
   tree was dirty) and which flow built it, so a board on a bench says what
   it is running. *)
let uart_build () =
  (* the switches as the board sees them, so a switch that does nothing can
     be told from a switch read the wrong way round *)
  let digits = "0123456789abcdef" in
  let v = io_read build_id in
  if v = 0 then uart_puts "unstamped"
  else begin
    let digits = "0123456789abcdef" in
    for k = 6 downto 0 do uart_putc (string_get digits ((v lsr (4 * k)) land 0xF)) done;
    if v land 0x10000000 <> 0 then uart_putc '+';
    let flow = (v lsr 29) land 3 in   (* 30:29: bit 31 is past a 31-bit int *)
    if flow = 1 then uart_puts " open"
    else if flow = 2 then uart_puts " vivado"
    else uart_puts " ?"
  end;
  let d = io_read dip_sw land 0xFF in
  uart_puts " dip=";
  uart_putc (string_get digits ((d lsr 4) land 0xF));
  uart_putc (string_get digits (d land 0xF));
  uart_puts " btn=";
  uart_putc (string_get digits (io_read buttons land 0x1F))

(* ==== MAIN ==== *)
let () =
  io_write leds 1;
  puts "OCaml processor mini-ML (UART, UDP 7777, telnet 23) -- build ";
  uart_build ();
  newline ();
  puts "# ";
  while true do poll () done
(* ==== END MAIN ==== *)
