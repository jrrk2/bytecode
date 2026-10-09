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
external magic : 'a -> 'b = "%identity"
external raise : exn -> 'a = "%raise"
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
let line_max = 1000
(* the line being compiled: 120 bytes from the UART, a larger buffer while a source file is read *)
let line = ref (create_bytes line_max)
let line_len = ref 0

(* ---- DHCP state ---- *)
type state = Init | Selecting | Requesting | Bound

let state = ref Init
let my_ip = [| 0; 0; 0; 0 |]        (* 0.0.0.0 until bound *)
let offered_ip = [| 0; 0; 0; 0 |]
let server_id = [| 0; 0; 0; 0 |]
let server_ip = [| 10; 10; 10; 10 |]   (* where an image is fetched from *)
let server_mac = [| 0; 0; 0; 0; 0; 0 |]
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
  (* siaddr: the host the netboot loader was told to fetch from *)
  if rx (bootp + 20) <> 0 then
    for i = 0 to 3 do array_set server_ip i (rx (bootp + 20 + i)) done;
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
      (* the switches name the host, as they do for the loader *)
      let dip = io_read dip_sw land 0xFF in
      if dip <> 0 then begin
        for i = 0 to 2 do array_set server_ip i (array_get my_ip i) done;
        array_set server_ip 3 dip
      end;
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

(* ---- the transcendental functions ----
   Built on what the FPU answers -- add, multiply, divide, square root and
   the comparisons -- by range reduction and a series, and kept identical
   to io/trig.ml, whose accuracy io/test/trig measures against libm: a few
   parts in 1e16 for sine, cosine, exponential and logarithm. *)
external sqrt : float -> float = "caml_sqrt_float" "%sqrtfloat"
external abs_float : float -> float = "caml_abs_float" "%absfloat"
let ( <. ) (a : float) (b : float) = flt_lt a b
let ( <=. ) (a : float) (b : float) = flt_le a b
let ( =. ) (a : float) (b : float) = flt_eq a b


(* ---- tokens ---- *)
type token = TInt of int | TFloat of float | TId of string | TSym of string
            | TStr of string

let is_digit c = c >= 48 && c <= 57
let is_hex c = (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
let hex_val c = if c <= 57 then c - 48 else if c >= 97 then c - 87 else c - 55
let is_alpha c = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c = 95
let is_space c = c = 32 || c = 9
let char_at i = int_of_char (bytes_get !line i)

let substring from upto =
  let b = create_bytes (upto - from) in
  for i = from to upto - 1 do bytes_set b (i - from) (bytes_get !line i) done;
  bytes_to_string b

(* two-character operators first, then one *)
(* An operator is a run of operator characters, as in OCaml: <=. and ^^ and :=
   are each one token, and a user may define any of them.  A lone . is field
   selection, so a point cannot start one; ( ) , [ ] ; { } stand alone. *)
let is_opchar c =
  c = 33 || c = 36 || c = 37 || c = 38 || c = 42 || c = 43 || c = 45 || c = 46 || c = 47
  || c = 58 || c = 60 || c = 61 || c = 62 || c = 63 || c = 64 || c = 94 || c = 124 || c = 126

let symbol_len i =
  let c = char_at i in
  if is_opchar c && c <> 46 then begin
    let j = ref (i + 1) in
    while !j < !line_len && is_opchar (char_at !j) do j := !j + 1 done;
    !j - i
  end
  else if c = 40 || c = 41 || c = 44 || c = 91 || c = 93 || c = 59 || c = 123 || c = 125 || c = 46 then 1
  else 0

type 'a result = Ok of 'a | Err of string

let tokenize () =
  let rec go i acc =
    if i >= !line_len then Ok (rev acc [])
    else begin
      let c = char_at i in
      if is_space c then go (i + 1) acc
      else if c = 59 && i + 1 < !line_len && char_at (i + 1) = 59 then go (i + 2) acc      (* ;; ends a phrase: here it is nothing *)
      (* 0x1F: hexadecimal *)
      else if c = 48 && i + 2 < !line_len && char_at (i + 1) = 120 && is_hex (char_at (i + 2)) then begin
        let j = ref (i + 2) and n = ref 0 in
        while !j < !line_len && is_hex (char_at !j) do
          n := !n * 16 + hex_val (char_at !j); j := !j + 1
        done;
        go !j (TInt !n :: acc)
      end
      else if is_digit c then begin
        let j = ref i and n = ref 0 and big = ref 0.0 in
        while !j < !line_len && is_digit (char_at !j) do
          n := !n * 10 + (char_at !j - 48);
          big := !big *. 10.0 +. float_of_int (char_at !j - 48);   (* the same digits as a float: an int is 31 bits here *)
          j := !j + 1
        done;
        (* a point with a digit after it, or a point at the end as OCaml
           allows in "1.", makes this a float rather than an int; so does an exponent, 1e18 *)
        let is_float = ref false and mant = ref !big in
        (if !j < !line_len && char_at !j = 46 then begin
           is_float := true;
           j := !j + 1;
           let frac = ref 0.0 and scale = ref 1.0 in
           while !j < !line_len && is_digit (char_at !j) do
             scale := !scale *. 10.0;
             frac := !frac *. 10.0 +. float_of_int (char_at !j - 48);
             j := !j + 1
           done;
           mant := !mant +. (if flt_eq !scale 1.0 then 0.0 else !frac /. !scale)
         end);
        (if !j + 1 < !line_len && (char_at !j = 101 || char_at !j = 69)
            && (is_digit (char_at (!j + 1))
                || ((char_at (!j + 1) = 45 || char_at (!j + 1) = 43) && !j + 2 < !line_len && is_digit (char_at (!j + 2)))) then begin
           is_float := true;
           j := !j + 1;
           let neg = char_at !j = 45 in
           (if char_at !j = 45 || char_at !j = 43 then j := !j + 1);
           let ex = ref 0 in
           while !j < !line_len && is_digit (char_at !j) do ex := !ex * 10 + (char_at !j - 48); j := !j + 1 done;
           for _i = 1 to !ex do mant := (if neg then !mant /. 10.0 else !mant *. 10.0) done
         end);
        if !is_float then go !j (TFloat !mant :: acc) else go !j (TInt !n :: acc)
      end else if is_alpha c then begin
        let j = ref i in
        while !j < !line_len && (is_alpha (char_at !j) || is_digit (char_at !j)) do j := !j + 1 done;
        go !j (TId (substring i !j) :: acc)
      end else if c = 34 then begin
        (* a string literal.  A backslash escapes the next character, with
           n, r and t meaning newline, return and tab; anything else after
           one stands for itself, which covers the quote and the backslash.
           Escapes change the length, so it is built in a buffer rather
           than cut out of the line. *)
        let b = create_bytes (!line_len + 1) and n = ref 0 and j = ref (i + 1) in
        while !j < !line_len && char_at !j <> 34 do
          let ch = char_at !j in
          if ch = 92 && !j + 1 < !line_len then begin
            let e = char_at (!j + 1) in
            if e = 120 && !j + 3 < !line_len && is_hex (char_at (!j + 2)) && is_hex (char_at (!j + 3)) then begin
              (* \xHH *)
              bytes_set b !n (char_of_int (hex_val (char_at (!j + 2)) * 16 + hex_val (char_at (!j + 3))));
              n := !n + 1; j := !j + 4
            end else begin
              let v = if e = 110 then 10 else if e = 114 then 13
                      else if e = 116 then 9 else e in
              bytes_set b !n (char_of_int v); n := !n + 1; j := !j + 2
            end
          end else begin
            bytes_set b !n (char_of_int ch); n := !n + 1; j := !j + 1
          end
        done;
        if !j >= !line_len then Err "unterminated string"
        else begin
          let r = create_bytes !n in
          for k = 0 to !n - 1 do bytes_set r k (bytes_get b k) done;
          go (!j + 1) (TStr (bytes_to_string r) :: acc)
        end
      end else if c = 39 && i + 2 < !line_len && char_at (i + 1) <> 92 && char_at (i + 2) = 39 then begin
        go (i + 3) (TInt (char_at (i + 1)) :: acc)
      end else if c = 39 && i + 3 < !line_len && char_at (i + 1) = 92 && char_at (i + 3) = 39 then begin
        let e = char_at (i + 2) in
        let v = if e = 110 then 10 else if e = 114 then 13 else if e = 116 then 9
                else if e = 48 then 0 else e in
        go (i + 4) (TInt v :: acc)
      end else if c = 39 && i + 1 < !line_len && is_alpha (char_at (i + 1)) then begin
        let j = ref (i + 1) in
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
  | Str of string
  | Bool of bool
  | Var of string
  | Binop of string * expr * expr
  | If of expr * expr * expr
  | Fun of string * expr
  | App of expr * expr
  | Let of bool * string * expr * expr    (* rec?, name, bound, body *)
  | Try of expr * string * expr           (* try e with x -> e: x names the message *)
  | Tuple of expr list
  (* a constructor and its arguments: [] and :: are the list ones, which the
     parser writes for [] and for x :: xs and [a; b; c] *)
  | Con of string * expr list
  | Match of expr * (pat * expr) list
  | Record of (string * expr) list
  | With of expr * (string * expr) list   (* { e with f = v } *)
  | Field of expr * string
  | SetField of expr * string * expr      (* e.f <- v, and r := v is r.contents <- v *)
  | Prim of int * int * expr list         (* an external, applied to all its arguments: kind, code, arguments *)
  | While of expr * expr                  (* while c do b done *)
  | ArrLit of expr list                   (* [| a; b; c |] *)
  | Guard of expr * expr                  (* the body of a match arm that has a when: guard, body *)
  | LetRecs of (string * expr) list * expr   (* let rec f = ... and g = ... in body *)
  | ExnIs of string * expr                (* is this exception that predefined one: Stack_overflow, Not_found, ... *)
  | ExnVal of string                      (* a predefined exception as a value: the global that holds it *)
  | ExnArg of expr                        (* the argument of an exception that carries one *)
  | Reraise of expr
  | For of string * expr * expr * bool * expr   (* for x = lo to hi do b done: up?, or downto *)
and pat =
  | PWild
  | PVar of string
  | PInt of int
  | PBool of bool
  | PTuple of pat list
  | PCon of string * pat list
  | PRec of (string * pat) list

(* A type as it is written in a declaration, before it becomes a ty: the
   declaration is read once and its argument types instantiated afresh at
   every use, so the parameters stay names until then. *)
type tyexp =
  | TEVar of string
  | TECon of string * tyexp list
  | TEArrow of tyexp * tyexp
  | TETuple of tyexp list

(* how many arguments each constructor takes, kept here as well as in the type tables below
   because the parser needs it: Ok (a, b, c) is one argument that is a tuple, where a constructor
   declared with C of a * b * c takes three *)
let ctor_arities : (string * int) list ref = ref [("[]", 0); ("::", 2); ("None", 0); ("Some", 1)]

let rec early_arity c l = match l with
  | [] -> 0 - 1
  | (n, a) :: r -> if string_equal n c then a else early_arity c r

let rec wilds n = if n <= 0 then [] else PWild :: wilds (n - 1)

let rec mem_name (x : string) l = match l with
  | [] -> false
  | y :: r -> string_equal x y || mem_name x r

let keywords = ["try"; "with"; "match"; "type"; "of"; "let"; "rec"; "in"; "if"; "then"; "else"; "fun"; "true"; "false"; "mod"; "begin"; "end"; "land"; "lor"; "lxor"; "lsl"; "lsr"; "while"; "do"; "done"; "for"; "to"; "downto"; "and"; "when"]

let keyword s = mem_name s keywords

let is_sym t s = match t with TSym x -> string_equal x s | _ -> false
let is_kw t s = match t with TId x -> string_equal x s | _ -> false

let rec rev_acc l acc = match l with [] -> acc | x :: r -> rev_acc r (x :: acc)
let rec count_list l = match l with [] -> 0 | _ :: r -> 1 + count_list r
let rec apps f l = match l with [] -> f | a :: r -> apps (App (f, a)) r
(* a constructor starts with a capital, a type variable with a quote *)
let is_ctor s =
  string_length s > 0 && (let c = int_of_char (string_get s 0) in c >= 65 && c <= 90)
let is_tyvar s = string_length s > 0 && int_of_char (string_get s 0) = 39

let ( ^^ ) a b =
  let n = string_length a and m = string_length b in
  let r = create_bytes (n + m) in
  for i = 0 to n - 1 do bytes_set r i (string_get a i) done;
  for i = 0 to m - 1 do bytes_set r (n + i) (string_get b i) done;
  bytes_to_string r

(* what the parser is looking at, for a message: "expected ) but found then" *)
let tok_str t = match t with
  | TInt _ -> "a number"
  | TFloat _ -> "a number"
  | TStr _ -> "a string"
  | TId x -> x
  | TSym x -> x

let found toks = match toks with
  | t :: r ->
    (* the token it stopped at, and the next few, so a long phrase can be located *)
    let rec more l n = match l with
      | x :: rest when n > 0 -> " " ^^ tok_str x ^^ more rest (n - 1)
      | _ -> "" in
    " but found " ^^ tok_str t ^^ more r 4
  | [] -> " but the line ended"

let expect toks s = match toks with
  | t :: rest -> if is_sym t s || is_kw t s then Ok rest else Err ("expected " ^^ s ^^ found toks)
  | [] -> Err ("expected " ^^ s ^^ found toks)

(* an operator that parses as a comparison but is not one of the six built in *)
let user_cmp_op op =
  string_length op > 1
  && (let c = int_of_char (string_get op 0) in c = 60 || c = 62 || c = 61)
  && not (string_equal op "<>" || string_equal op "<=" || string_equal op ">=" || string_equal op "<-")

let is_op_name toks = match toks with
  | t :: TSym _ :: t2 :: _ -> is_sym t "(" && is_sym t2 ")"
  | _ -> false

(* skip a type written after a colon, up to the parenthesis that closes
   its group: "(x : int -> int)" and "(f : (int -> int) list)" *)
let rec skip_ty toks depth = match toks with
  | [] -> None
  | t :: rest ->
    if is_sym t "(" then skip_ty rest (depth + 1)
    else if is_sym t ")" then (if depth = 1 then Some rest else skip_ty rest (depth - 1))
    else skip_ty rest depth

(* parameters x y z, then a body: fun x -> fun y -> ...  A () parameter is a
   name nothing uses (there is no unit: it is the 0 that a call passes), and
   a type annotation on a parameter, (x : t), is read and dropped. *)
let rec params toks acc = match toks with
  | TId x :: rest when not (keyword x) -> params rest (x :: acc)
  | t :: t2 :: rest when is_sym t "(" && is_sym t2 ")" -> params rest ("_u" :: acc)
  | t :: TId x :: t3 :: rest when is_sym t "(" && is_sym t3 ":" && not (keyword x) ->
    (match skip_ty rest 1 with
     | Some r -> params r (x :: acc)
     | None -> (acc, toks))
  | _ -> (acc, toks)

let rec wrap_funs ps body = match ps with
  | [] -> body
  | p :: rest -> wrap_funs rest (Fun (p, body))

let rec parse_pat toks =
  match parse_pat_app toks with
  | Err e -> Err e
  | Ok (p, rest) ->
    match rest with
    | t :: rest2 when is_sym t "::" ->
      (match parse_pat rest2 with
       | Err e -> Err e
       | Ok (q, rest3) -> Ok (PCon ("::", [p; q]), rest3))
    | _ -> Ok (p, rest)

and parse_pat_app toks = match toks with
  | TId c :: rest when is_ctor c ->
    if starts_pat rest then
      (match parse_pat_atom rest with
       | Err e -> Err e
       | Ok (a, rest2) ->
         Ok (PCon (c, (match a with
                       | PTuple l when early_arity c !ctor_arities <> 1 -> l
                       | PWild when early_arity c !ctor_arities > 1 -> wilds (early_arity c !ctor_arities)
                       | _ -> [a])), rest2))
    else Ok (PCon (c, []), rest)
  | _ -> parse_pat_atom toks

and starts_pat toks = match toks with
  | TInt _ :: _ -> true
  | TId x :: _ -> not (keyword x) || string_equal x "true" || string_equal x "false"
  | t :: _ -> is_sym t "(" || is_sym t "[" || is_sym t "{"
  | [] -> false

and parse_pat_atom toks = match toks with
  | TInt n :: rest -> Ok (PInt n, rest)
  | TId x :: rest when string_equal x "true" -> Ok (PBool true, rest)
  | TId x :: rest when string_equal x "false" -> Ok (PBool false, rest)
  | TId x :: rest when string_equal x "_" -> Ok (PWild, rest)
  | TId c :: rest when is_ctor c -> Ok (PCon (c, []), rest)
  | TId x :: rest when not (keyword x) -> Ok (PVar x, rest)
  | t :: t2 :: rest when is_sym t "[" && is_sym t2 "]" -> Ok (PCon ("[]", []), rest)
  | t :: rest when is_sym t "[" -> parse_pat_list rest
  | t :: rest when is_sym t "{" -> parse_pat_rec rest []
  | t :: t2 :: rest when is_sym t "(" && is_sym t2 ")" -> Ok (PWild, rest)
  | t :: rest when is_sym t "(" ->
    (match parse_pat rest with
     | Err e -> Err e
     | Ok (q, rest2) -> parse_pat_tuple [q] rest2)
  | _ -> Err "syntax error in a pattern"

and parse_pat_tuple acc toks = match toks with
  | t :: rest when is_sym t "," ->
    (match parse_pat rest with
     | Err e -> Err e
     | Ok (q, rest2) -> parse_pat_tuple (q :: acc) rest2)
  | t :: rest when is_sym t ")" ->
    Ok ((match acc with [q] -> q | _ -> PTuple (rev_acc acc [])), rest)
  | _ -> Err "expected , or ) in a pattern"

and parse_pat_rec toks acc = match toks with
  | TId f :: (t :: rest) when not (keyword f) && is_sym t "=" ->
    (match parse_pat rest with
     | Err e -> Err e
     | Ok (q, rest2) ->
       match rest2 with
       | t2 :: rest3 when is_sym t2 ";" -> parse_pat_rec rest3 ((f, q) :: acc)
       | t2 :: rest3 when is_sym t2 "}" -> Ok (PRec (rev_acc ((f, q) :: acc) []), rest3)
       | _ -> Err "expected ; or } in a record pattern")
  (* { x } is shorthand for { x = x } *)
  | TId f :: (t :: rest) when not (keyword f) && is_sym t ";" ->
    parse_pat_rec rest ((f, PVar f) :: acc)
  | TId f :: (t :: rest) when not (keyword f) && is_sym t "}" ->
    Ok (PRec (rev_acc ((f, PVar f) :: acc) []), rest)
  | _ -> Err "expected a field name in a record pattern"

and parse_pat_list toks =
  match parse_pat toks with
  | Err e -> Err e
  | Ok (q, rest) ->
    match rest with
    | t :: rest2 when is_sym t ";" ->
      (match parse_pat_list rest2 with
       | Err e -> Err e
       | Ok (tl, rest3) -> Ok (PCon ("::", [q; tl]), rest3))
    | t :: rest2 when is_sym t "]" -> Ok (PCon ("::", [q; PCon ("[]", [])]), rest2)
    | _ -> Err "expected ; or ] in a list pattern"

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
           (* "if c then e" with no else is the 0 that stands for unit *)
           match rest with
           | t2 :: rest2 when is_kw t2 "else" ->
             (match parse_expr rest2 with
              | Err e -> Err e
              | Ok (b, rest3) -> Ok (If (c, a, b), rest3))
           | _ -> Ok (If (c, a, Int 0), rest))
  (* try e with _ -> e2, or "with x -> e2" to bind the failure's message:
     an error anywhere in e -- division by zero, an unbound name, a bad
     operand -- gives e2 instead.  The machine's own exceptions are what
     this is built on: see io/exc.ml. *)
  | t :: rest when is_kw t "try" ->
    (match parse_seq rest with
     | Err e -> Err e
     | Ok (body, rest) ->
       match expect rest "with" with
       | Err e -> Err e
       | Ok rest ->
         let rest = match rest with t2 :: r when is_sym t2 "|" -> r | _ -> rest in
         match rest with
         | TId c :: _ when is_ctor c ->
           (* try e with | Not_found -> a | Invalid_argument _ -> b: the handler tests the
              exception against the predefined ones in turn and raises it again if none is it *)
           (match parse_exn_arms rest with
            | Err e -> Err e
            | Ok (chain, rest) -> Ok (Try (body, "_exn", chain), rest))
         | _ ->
         let (name, rest) = match rest with
           | TId x :: r when not (keyword x) -> (x, r)
           | TSym x :: r when string_equal x "_" -> ("_", r)
           | _ -> ("_", rest) in
         match expect rest "->" with
         | Err e -> Err e
         | Ok rest ->
           match parse_seq rest with
           | Err e -> Err e
           | Ok (handler, rest) -> Ok (Try (body, name, handler), rest))
  | t :: rest when is_kw t "match" ->
    (match parse_scrut rest with
     | Err e -> Err e
     | Ok (scrut, rest) ->
       match expect rest "with" with
       | Err e -> Err e
       | Ok rest ->
         let rest = match rest with t2 :: r when is_sym t2 "|" -> r | _ -> rest in
         match parse_arms rest [] with
         | Err e -> Err e
         | Ok (arms, rest) -> Ok (Match (scrut, arms), rest))
  | t :: rest when is_kw t "while" ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (c, rest) ->
       match expect rest "do" with
       | Err e -> Err e
       | Ok rest ->
         match parse_seq rest with
         | Err e -> Err e
         | Ok (b, rest) ->
           match expect rest "done" with
           | Err e -> Err e
           | Ok rest -> Ok (While (c, b), rest))
  | t :: TId x :: t2 :: rest when is_kw t "for" && not (keyword x) && is_sym t2 "=" ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (lo, rest) ->
       let (up, rest) = match rest with
         | d :: r when is_kw d "downto" -> (false, r)
         | d :: r when is_kw d "to" -> (true, r)
         | _ -> (true, []) in
       match parse_expr rest with
       | Err e -> Err e
       | Ok (hi, rest) ->
         match expect rest "do" with
         | Err e -> Err e
         | Ok rest ->
           match parse_seq rest with
           | Err e -> Err e
           | Ok (b, rest) ->
             match expect rest "done" with
             | Err e -> Err e
             | Ok rest -> Ok (For (x, lo, hi, up, b), rest))
  | t :: rest when is_kw t "fun" ->
    let (ps, rest) = params rest [] in
    (match ps with
     | [] -> Err "fun needs a parameter"
     | _ ->
       match expect rest "->" with
       | Err e -> Err e
       | Ok rest ->
         match parse_seq rest with
         | Err e -> Err e
         | Ok (body, rest) -> Ok (wrap_funs ps body, rest))
  | _ ->
    match parse_or toks with
    | Err e -> Err e
    | Ok (lhs, rest) ->
      match rest with
      | t :: rest2 when is_sym t ":=" ->
        (match parse_expr rest2 with
         | Err e -> Err e
         | Ok (rhs, rest3) -> Ok (SetField (lhs, "contents", rhs), rest3))
      | t :: rest2 when is_sym t "<-" ->
        (match lhs with
         | Field (b, f) ->
           (match parse_expr rest2 with
            | Err e -> Err e
            | Ok (rhs, rest3) -> Ok (SetField (b, f, rhs), rest3))
         | _ -> Err "the left of <- must be a field")
      | _ -> Ok (lhs, rest)

(* e1; e2 -- a sequence is a let whose name nothing uses.  It sits below
   everything else, as in OCaml: "if c then a; b" is (if c then a); b, while the
   bodies of let, fun, match arms and try, and what is in parentheses or
   begin..end, take the whole sequence.  A ; before a closing token is allowed. *)
and parse_seq toks =
  match parse_expr toks with
  | Err e -> Err e
  | Ok (e, rest) ->
    match rest with
    | t :: rest2 when is_sym t ";" ->
      (match rest2 with
       | [] -> Ok (e, rest2)
       | t2 :: _ when is_kw t2 "end" || is_kw t2 "in" || is_sym t2 ")" || is_sym t2 "|" -> Ok (e, rest2)
       | _ ->
         match parse_seq rest2 with
         | Err m -> Err m
         | Ok (e2, rest3) -> Ok (Let (false, "_", e, e2), rest3))
    | _ -> Ok (e, rest)

(* let [rec] f x y = e [in e]; with need_in false, "in" is optional (top level) *)
and parse_let toks need_in =
  let (recursive, toks) = match toks with
    | t :: rest when is_kw t "rec" -> (true, rest)
    | _ -> (false, toks) in
  match toks with
  | t :: _ when is_sym t "(" && not (is_op_name toks) ->
    (* let (a, b) = e in body: a match with the one arm.  let () = e at the top level is e. *)
    (match parse_pat toks with
     | Err e -> Err e
     | Ok (pat, rest) ->
       match expect rest "=" with
       | Err e -> Err e
       | Ok rest ->
         match parse_seq rest with
         | Err e -> Err e
         | Ok (e1, rest) ->
           match rest with
           | t2 :: r when is_kw t2 "in" ->
             (match parse_seq r with
              | Err e -> Err e
              | Ok (body, rest) -> Ok (Match (e1, [(pat, body)]), rest))
           | _ -> if need_in then Err ("expected in" ^^ found rest) else Ok (e1, rest))
  | _ ->
  match parse_binding toks with
  | Err e -> Err e
  | Ok (name, bound, rest) ->
    match rest with
    | t :: rest2 when is_kw t "and" ->
      (* let a = e1 and b = e2 in body: the bindings do not see each other, so these are
         taken in turn; a mutually recursive let rec is not compiled yet *)
      if recursive then
        (match parse_and_bindings rest2 [] with
         | Err e -> Err e
         | Ok (more, rest3) ->
           let group = (name, bound) :: more in
           match rest3 with
           | t3 :: rest4 when is_kw t3 "in" ->
             (match parse_seq rest4 with
              | Err e -> Err e
              | Ok (body, rest5) -> Ok (LetRecs (group, body), rest5))
           | _ -> if need_in then Err ("expected in" ^^ found rest3) else Ok (LetRecs (group, Var name), rest3))
      else
        (match parse_and_bindings rest2 [] with
         | Err e -> Err e
         | Ok (more, rest3) ->
           match rest3 with
           | t3 :: rest4 when is_kw t3 "in" ->
             (match parse_seq rest4 with
              | Err e -> Err e
              | Ok (body, rest5) ->
                let rec nest l = match l with
                  | [] -> body
                  | (n, b) :: r -> Let (false, n, b, nest r) in
                Ok (nest ((name, bound) :: more), rest5))
           | _ -> Err "expected in after let ... and")
    | t :: rest when is_kw t "in" ->
      (match parse_seq rest with
       | Err e -> Err e
       | Ok (body, rest) -> Ok (Let (recursive, name, bound, body), rest))
    | _ -> if need_in then Err ("expected in" ^^ found rest)
      else Ok (Let (recursive, name, bound, Var name), rest)

(* name params [: type] = expression.  The name may be an operator in parentheses. *)
and parse_binding toks =
  let (name, rest) = match toks with
    | t :: TSym op :: t2 :: rest when is_sym t "(" && is_sym t2 ")" -> (op, rest)
    | TId n :: rest when not (keyword n) -> (n, rest)
    | _ -> ("", toks) in
  if string_equal name "" then Err ("expected a name after let" ^^ found toks)
  else begin
    let (ps, rest) = params rest [] in
    (* a type after the parameters, let x : t = e, is read and dropped *)
    let rec skip_to_eq r depth = match r with
      | [] -> []
      | t :: rest2 ->
        if is_sym t "(" then skip_to_eq rest2 (depth + 1)
        else if is_sym t ")" then skip_to_eq rest2 (depth - 1)
        else if depth = 0 && is_sym t "=" then r
        else skip_to_eq rest2 depth in
    let rest = match rest with
      | t :: r when is_sym t ":" -> skip_to_eq r 0
      | _ -> rest in
    match expect rest "=" with
    | Err e -> Err e
    | Ok rest ->
      match parse_seq rest with
      | Err e -> Err e
      | Ok (bound, rest) -> Ok (name, wrap_funs ps bound, rest)
  end

and parse_and_bindings toks acc =
  match parse_binding toks with
  | Err e -> Err e
  | Ok (n, b, rest) ->
    match rest with
    | t :: rest2 when is_kw t "and" -> parse_and_bindings rest2 ((n, b) :: acc)
    | _ -> Ok (rev_acc ((n, b) :: acc) [], rest)

and parse_exn_arms toks =
  match toks with
  | TId c :: rest when is_ctor c ->
    let (arg, rest) = match rest with
      | TId a :: r when not (keyword a) && not (is_ctor a) -> (Some a, r)
      | TSym a :: r when string_equal a "_" -> (None, r)
      | _ -> (None, rest) in
    (match expect rest "->" with
     | Err e -> Err e
     | Ok rest ->
       match parse_seq rest with
       | Err e -> Err e
       | Ok (h, rest) ->
         let h = match arg with Some v -> Let (false, v, ExnArg (Var "_exn"), h) | None -> h in
         match rest with
         | t :: more when is_sym t "|" ->
           (match parse_exn_arms more with
            | Err e -> Err e
            | Ok (tail, rest2) -> Ok (If (ExnIs (c, Var "_exn"), h, tail), rest2))
         | _ -> Ok (If (ExnIs (c, Var "_exn"), h, Reraise (Var "_exn")), rest))
  | _ ->
    (* a last arm that takes anything: _ -> e, or a name -> e *)
    (match toks with
     | TId _ :: r -> (match expect r "->" with Err e -> Err e | Ok rest -> parse_seq rest)
     | TSym _ :: r -> (match expect r "->" with Err e -> Err e | Ok rest -> parse_seq rest)
     | _ -> Err ("expected an exception pattern" ^^ found toks))

(* match a, b with: the scrutinee is a tuple without its parentheses *)
and parse_scrut toks =
  match parse_expr toks with
  | Err e -> Err e
  | Ok (e, rest) ->
    match rest with
    | t :: _ when is_sym t "," ->
      let rec more acc r = match r with
        | t2 :: r2 when is_sym t2 "," ->
          (match parse_expr r2 with
           | Err m -> Err m
           | Ok (e2, r3) -> more (e2 :: acc) r3)
        | _ -> Ok (Tuple (rev_acc acc []), r) in
      more [e] rest
    | _ -> Ok (e, rest)

(* a pattern, and any , patterns after it: | Ok a, Err b -> ... *)
and parse_pat_tup toks =
  match parse_pat toks with
  | Err e -> Err e
  | Ok (q, rest) ->
    match rest with
    | t :: _ when is_sym t "," ->
      let rec more acc r = match r with
        | t2 :: r2 when is_sym t2 "," ->
          (match parse_pat r2 with
           | Err m -> Err m
           | Ok (q2, r3) -> more (q2 :: acc) r3)
        | _ -> Ok (PTuple (rev_acc acc []), r) in
      more [q] rest
    | _ -> Ok (q, rest)

and parse_arms toks acc =
  match parse_pat_tup toks with
  | Err e -> Err e
  | Ok (q, rest) ->
    (* A | B -> e: alternatives that share a body are one arm each, with the body repeated *)
    let rec alts rest ps = match rest with
      | t :: more when is_sym t "|" ->
        (match parse_pat more with
         | Err e -> Err e
         | Ok (q2, r2) -> alts r2 (q2 :: ps))
      | _ -> Ok (ps, rest) in
    match alts rest [q] with
    | Err e -> Err e
    | Ok (ps, rest) ->
      (* p when guard -> e *)
      let guarded = match rest with
        | t :: g when is_kw t "when" ->
          (match parse_expr g with
           | Err e -> Err e
           | Ok (ge, r) -> Ok (Some ge, r))
        | _ -> Ok (None, rest) in
      match guarded with
      | Err e -> Err e
      | Ok (guard, rest) ->
        match expect rest "->" with
        | Err e -> Err e
        | Ok rest ->
          match parse_seq rest with
          | Err e -> Err e
          | Ok (body, rest) ->
            let body = match guard with Some g -> Guard (g, body) | None -> body in
            let rec add l acc = match l with [] -> acc | p :: r -> add r ((p, body) :: acc) in
            let acc = add (rev_acc ps []) acc in
            match rest with
            | t :: rest2 when is_sym t "|" -> parse_arms rest2 acc
            | _ -> Ok (rev_acc acc [], rest)

(* a && b and a || b are if a then b else false and if a then true else b *)
and parse_or toks =
  match parse_and toks with
  | Err e -> Err e
  | Ok (a, rest) ->
    match rest with
    | t :: rest2 when is_sym t "||" ->
      (match parse_or rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (If (a, Bool true, b), rest3))
    | _ -> Ok (a, rest)

and parse_and toks =
  match parse_cmp toks with
  | Err e -> Err e
  | Ok (a, rest) ->
    match rest with
    | t :: rest2 when is_sym t "&&" ->
      (match parse_and rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (If (a, b, Bool false), rest3))
    | _ -> Ok (a, rest)

and parse_cmp toks =
  match parse_concat toks with
  | Err e -> Err e
  | Ok (a, rest) ->
    match rest with
    | TSym op :: rest2 when string_equal op "=" || string_equal op "<>" || string_equal op "<"
                           || string_equal op ">" || string_equal op "<=" || string_equal op ">=" ->
      (match parse_concat rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (Binop (op, a, b), rest3))
    (* an operator of the program's own that starts like a comparison: <. <=. =. *)
    | TSym op :: rest2 when user_cmp_op op ->
      (match parse_concat rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (App (App (Var op, a), b), rest3))
    | _ -> Ok (a, rest)

(* @ and ^ and what starts with them: right-associative, looser than ::, tighter
   than a comparison.  The operator is a function the program defines. *)
and parse_concat toks =
  match parse_cons toks with
  | Err e -> Err e
  | Ok (a, rest) ->
    match rest with
    | TSym op :: rest2 when string_length op > 0 && (string_get op 0 = '@' || string_get op 0 = '^') ->
      (match parse_concat rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (App (App (Var op, a), b), rest3))
    | _ -> Ok (a, rest)

(* :: binds tighter than a comparison and looser than +, and associates to
   the right, so 1 :: 2 :: xs is 1 :: (2 :: xs) *)
and parse_cons toks =
  match parse_arith toks with
  | Err e -> Err e
  | Ok (a, rest) ->
    match rest with
    | t :: rest2 when is_sym t "::" ->
      (match parse_cons rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (Con ("::", [a; b]), rest3))
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
  match parse_shift toks with
  | Err e -> Err e
  | Ok (a, rest) -> term_more a rest
and term_more a toks = match toks with
  | t :: rest when is_sym t "*" || is_sym t "/" || is_kw t "mod"
                   || is_sym t "*." || is_sym t "/."
                   || is_kw t "land" || is_kw t "lor" || is_kw t "lxor" ->
    let op = match t with TSym s -> s | TId s -> s | _ -> "mod" in
    (match parse_shift rest with
     | Err e -> Err e
     | Ok (b, rest) -> term_more (Binop (op, a, b)) rest)
  | _ -> Ok (a, toks)

(* lsl and lsr bind tighter than * and associate to the right *)
and parse_shift toks =
  match parse_app toks with
  | Err e -> Err e
  | Ok (a, rest) ->
    match rest with
    | t :: rest2 when is_kw t "lsl" || is_kw t "lsr" ->
      let op = match t with TId s -> s | _ -> "lsl" in
      (match parse_shift rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (Binop (op, a, b), rest3))
    | _ -> Ok (a, rest)

and parse_app toks =
  match parse_sel toks with
  | Err e -> Err e
  | Ok (f, rest) -> app_more f rest

(* an atom and any field selections after it: f p.x is f (p.x) *)
and parse_sel toks =
  match parse_atom toks with
  | Err e -> Err e
  | Ok (a, rest) -> sel_more a rest
and sel_more a toks = match toks with
  | t :: (TId f :: rest) when is_sym t "." && not (keyword f) ->
    sel_more (Field (a, f)) rest
  | _ -> Ok (a, toks)

and app_more f toks =
  if starts_atom toks then
    match parse_sel toks with
    | Err e -> Err e
    | Ok (a, rest) ->
      let applied = match f with
        | Con (c, []) -> Con (c, (match a with
                                  | Tuple l when early_arity c !ctor_arities <> 1 -> l
                                  | _ -> [a]))
        | _ -> App (f, a) in
      app_more applied rest
  else Ok (f, toks)
and starts_atom toks = match toks with
  | TInt _ :: _ -> true
  | TFloat _ :: _ -> true
  | TStr _ :: _ -> true
  | TId x :: _ -> not (keyword x) || string_equal x "true" || string_equal x "false"
  | t :: _ -> is_sym t "(" || is_sym t "[" || is_sym t "{" || is_sym t "!"
  | [] -> false

and parse_atom toks = match toks with
  | TInt n :: rest -> Ok (Int n, rest)
  | TFloat f :: rest -> Ok (Float f, rest)
  | TStr s :: rest -> Ok (Str s, rest)
  | TId x :: rest when string_equal x "true" -> Ok (Bool true, rest)
  | TId x :: rest when string_equal x "false" -> Ok (Bool false, rest)
  | TId c :: rest when is_ctor c -> Ok (Con (c, []), rest)
  (* ref e is { contents = e }, !r is r.contents and r := e is r.contents <- e:
     the references of OCaml are a one-field record, and so they are here *)
  | TId x :: rest when string_equal x "ref" -> Ok (Fun ("_r", Record [("contents", Var "_r")]), rest)
  | TSym x :: rest when string_equal x "!" ->
    (match parse_atom rest with
     | Err e -> Err e
     | Ok (a, rest) -> Ok (Field (a, "contents"), rest))
  | TId x :: rest when not (keyword x) -> Ok (Var x, rest)
  | t :: t2 :: rest when is_sym t "[" && is_sym t2 "|" -> parse_arr_lit rest []
  | t :: t2 :: rest when is_sym t "[" && is_sym t2 "]" -> Ok (Con ("[]", []), rest)
  | t :: rest when is_sym t "[" -> parse_list_lit rest
  (* a field list starts "name =", anything else is the record to update *)
  | t :: (TId f :: (t2 :: rest)) when is_sym t "{" && not (keyword f) && is_sym t2 "=" ->
    parse_rec_lit (TId f :: (t2 :: rest)) []
  | t :: rest when is_sym t "{" ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (base, rest2) ->
       match expect rest2 "with" with
       | Err _ -> Err "expected = or with in a record"
       | Ok rest3 ->
         match parse_rec_lit rest3 [] with
         | Err e -> Err e
         | Ok (r, rest4) ->
           match r with
           | Record fs -> Ok (With (base, fs), rest4)
           | _ -> Err "expected fields after with")
  | TSym x :: rest when string_equal x "~-." ->
    (match parse_atom rest with
     | Err e -> Err e
     | Ok (a, rest) -> Ok (Binop ("-.", Float 0.0, a), rest))
  | TSym x :: rest when string_equal x "~-" ->
    (match parse_atom rest with
     | Err e -> Err e
     | Ok (a, rest) -> Ok (Binop ("-", Int 0, a), rest))
  | TSym s :: TFloat f :: rest when string_equal s "-" -> Ok (Float (~-. f), rest)
  | TSym s :: rest when string_equal s "-" ->
    (match parse_atom rest with
     | Err e -> Err e
     | Ok (a, rest) -> Ok (Binop ("-", Int 0, a), rest))
  (* () is the argument of a niladic builtin such as ms (); the language has
     no unit, so it is 0 *)
  | t :: t2 :: rest when is_sym t "(" && is_sym t2 ")" -> Ok (Int 0, rest)
  | t :: rest when is_kw t "begin" ->
    (match parse_seq rest with
     | Err e -> Err e
     | Ok (e, rest2) ->
       match rest2 with
       | t2 :: rest3 when is_kw t2 "end" -> Ok (e, rest3)
       | _ -> Err "expected end")
  | t :: rest when is_sym t "(" ->
    (match parse_seq rest with
     | Err e -> Err e
     | Ok (e, rest) -> parse_tuple_rest [e] rest)
  | _ -> Err ("syntax error" ^^ found toks)

and parse_tuple_rest acc toks = match toks with
  | t :: rest when is_sym t "," ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (e, rest) -> parse_tuple_rest (e :: acc) rest)
  | t :: rest when is_sym t ")" ->
    Ok ((match acc with [e] -> e | _ -> Tuple (rev_acc acc [])), rest)
  | _ -> Err ("expected , or )" ^^ found toks)

and parse_rec_lit toks acc = match toks with
  | TId f :: (t :: rest) when not (keyword f) && is_sym t "=" ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (v, rest2) ->
       match rest2 with
       | t2 :: rest3 when is_sym t2 ";" -> parse_rec_lit rest3 ((f, v) :: acc)
       | t2 :: rest3 when is_sym t2 "}" -> Ok (Record (rev_acc ((f, v) :: acc) []), rest3)
       | _ -> Err "expected ; or } in a record")
  | TId f :: (t :: rest) when not (keyword f) && is_sym t ";" ->
    parse_rec_lit rest ((f, Var f) :: acc)
  | TId f :: (t :: rest) when not (keyword f) && is_sym t "}" ->
    Ok (Record (rev_acc ((f, Var f) :: acc) []), rest)
  | _ -> Err "expected a field name in a record"

and parse_arr_lit toks acc =
  match parse_expr toks with
  | Err e -> Err e
  | Ok (e, rest) ->
    match rest with
    | t :: rest2 when is_sym t ";" -> parse_arr_lit rest2 (e :: acc)
    | t :: t2 :: rest2 when is_sym t "|" && is_sym t2 "]" -> Ok (ArrLit (rev_acc (e :: acc) []), rest2)
    | _ -> Err ("expected ; or |] in an array" ^^ found rest)

and parse_list_lit toks =
  match parse_expr toks with
  | Err e -> Err e
  | Ok (e, rest) ->
    match rest with
    | t :: rest2 when is_sym t ";" ->
      (match parse_list_lit rest2 with
       | Err e -> Err e
       | Ok (tl, rest3) -> Ok (Con ("::", [e; tl]), rest3))
    | t :: rest2 when is_sym t "]" -> Ok (Con ("::", [e; Con ("[]", [])]), rest2)
    | _ -> Err "expected ; or ] in a list"

(* ---- the types written in a declaration ---- *)
let rec parse_tyexp toks =
  match parse_ty_tuple toks with
  | Err e -> Err e
  | Ok (a, rest) ->
    match rest with
    | t :: rest2 when is_sym t "->" ->
      (match parse_tyexp rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (TEArrow (a, b), rest3))
    | _ -> Ok (a, rest)

and parse_ty_tuple toks =
  match parse_ty_app toks with
  | Err e -> Err e
  | Ok (a, rest) -> ty_tuple_more [a] rest
and ty_tuple_more acc toks = match toks with
  | t :: rest when is_sym t "*" ->
    (match parse_ty_app rest with
     | Err e -> Err e
     | Ok (a, rest2) -> ty_tuple_more (a :: acc) rest2)
  | _ -> Ok ((match acc with [a] -> a | _ -> TETuple (rev_acc acc [])), toks)

(* the argument comes first and can repeat: int list, int list list *)
and parse_ty_app toks =
  match parse_ty_atom toks with
  | Err e -> Err e
  | Ok (a, rest) -> ty_app_more a rest
and ty_app_more a toks = match toks with
  | TId n :: rest when not (keyword n) && not (is_tyvar n) -> ty_app_more (TECon (n, [a])) rest
  | _ -> Ok (a, toks)

and parse_ty_atom toks = match toks with
  | TId v :: rest when is_tyvar v -> Ok (TEVar v, rest)
  | TId n :: rest when not (keyword n) -> Ok (TECon (n, []), rest)
  | t :: rest when is_sym t "(" ->
    (match parse_tyexp rest with
     | Err e -> Err e
     | Ok (a, rest2) -> ty_paren [a] rest2)
  | _ -> Err "syntax error in a type"
and ty_paren acc toks = match toks with
  | t :: rest when is_sym t "," ->
    (match parse_tyexp rest with
     | Err e -> Err e
     | Ok (a, rest2) -> ty_paren (a :: acc) rest2)
  | t :: rest when is_sym t ")" ->
    (match acc with
     | [a] -> Ok (a, rest)
     (* several arguments are written before the name: (int, string) table *)
     | _ ->
       match rest with
       | TId n :: rest2 when not (keyword n) && not (is_tyvar n) ->
         Ok (TECon (n, rev_acc acc []), rest2)
       | _ -> Err "expected a type name after (...)")
  | _ -> Err "expected , or ) in a type"

(* type 'a option = None | Some of 'a  -- the name, its parameters, and a
   constructor list, each with the types of its arguments *)
(* type t = <a type expression>: an abbreviation, which is expanded where it is used *)
let aliases : (string * (string list * tyexp)) list ref = ref []

let parse_typedecl toks =
  let (ps, toks) = match toks with
    | TId v :: rest when is_tyvar v -> ([v], rest)
    | t :: rest when is_sym t "(" ->
      let rec go toks acc = match toks with
        | TId v :: (t2 :: r) when is_tyvar v && is_sym t2 "," -> go r (v :: acc)
        | TId v :: (t2 :: r) when is_tyvar v && is_sym t2 ")" -> (rev_acc (v :: acc) [], r)
        | _ -> ([], toks) in
      go rest []
    | _ -> ([], toks) in
  match toks with
  | TId name :: rest when not (keyword name) && not (is_tyvar name) ->
    (match expect rest "=" with
     | Err e -> Err e
     | Ok rest ->
       match rest with
       | TId first :: _ when not (is_ctor first) && not (keyword first) ->
         (* an abbreviation, type t = int list *)
         (match parse_tyexp rest with
          | Err e -> Err e
          | Ok (te, rest2) ->
            aliases := (name, (ps, te)) :: !aliases;
            Ok (name, ps, [], [], rest2))
       | t0 :: _ when is_sym t0 "(" ->
         (match parse_tyexp rest with
          | Err e -> Err e
          | Ok (te, rest2) ->
            aliases := (name, (ps, te)) :: !aliases;
            Ok (name, ps, [], [], rest2))
       | t :: rest1 when is_sym t "{" ->
         (* a record: fields and their types, rather than constructors *)
         let rec flds toks acc =
           let toks = match toks with TId m :: r when string_equal m "mutable" -> r | _ -> toks in
           match toks with
           | TId f :: (t2 :: rest2) when not (keyword f) && is_sym t2 ":" ->
             (match parse_tyexp rest2 with
              | Err e -> Err e
              | Ok (te, rest3) ->
                match rest3 with
                | t3 :: rest4 when is_sym t3 ";" -> flds rest4 ((f, te) :: acc)
                | t3 :: rest4 when is_sym t3 "}" ->
                  Ok (name, ps, [], rev_acc ((f, te) :: acc) [], rest4)
                | _ -> Err "expected ; or } in a record type")
           | _ -> Err "expected a field name and its type" in
         flds rest1 []
       | _ ->
       let rest = match rest with t :: r when is_sym t "|" -> r | _ -> rest in
       let rec arms toks acc = match toks with
         | TId c :: (t :: rest2) when is_ctor c && is_kw t "of" ->
           (match parse_tyexp rest2 with
            | Err e -> Err e
            | Ok (te, rest3) ->
              (* C of a * b takes two arguments, not one pair *)
              let l = match te with TETuple parts -> parts | _ -> [te] in
              more ((c, l) :: acc) rest3)
         | TId c :: rest2 when is_ctor c -> more ((c, []) :: acc) rest2
         (* the usual slip: false, true, or any other ordinary name, which
            the parser tells apart from a constructor by its first letter *)
         | TId x :: _ when not (is_tyvar x) ->
           Err (x ^^ " cannot be a constructor: they start with a capital letter")
         | _ -> Err "expected a constructor name"
       and more acc toks = match toks with
         | t :: rest2 when is_sym t "|" -> arms rest2 acc
         | _ -> Ok (name, ps, rev_acc acc [], [], toks) in
       arms rest [])
  | _ -> Err "expected a type name"

(* external name : type = "primitive" ["native name"]; name may be an operator in
   parentheses, which is skipped to the closing one and answered with "" *)
let rec skip_strs l = match l with TStr _ :: r -> skip_strs r | _ -> l

let parse_external toks =
  let (name, rest) = match toks with
    | t :: rest when is_sym t "(" ->
      let rec skip r = match r with
        | [] -> ("", [])
        | t2 :: r2 -> if is_sym t2 ")" then ("", r2) else skip r2 in
      skip rest
    | TId x :: rest when not (keyword x) -> (x, rest)
    | _ -> ("?", toks) in
  if string_equal name "?" then Err "expected a name after external"
  else
    match expect rest ":" with
    | Err e -> Err e
    | Ok rest ->
      match parse_tyexp rest with
      | Err e -> Err e
      | Ok (te, rest) ->
        match expect rest "=" with
        | Err e -> Err e
        | Ok rest ->
          match rest with
          | TStr p :: more -> Ok (name, te, p, skip_strs more)
          | _ -> Err "expected the primitive's name in quotes"

let not_b (a : bool) = if a then false else true

(* ---- evaluation ---- *)
type value =
  | VInt of int
  | VFloat of float
  (* name, how many arguments it wants, and the ones it has been given:
     a builtin is an ordinary value, so "let sin x = x" shadows it and
     "atan2 1." is a function waiting for its second argument *)
  | VBuiltin of string * int * value list
  | VBool of bool
  | VStr of string                        (* a caught failure's message *)
  | VClosure of string * expr * env ref   (* the ref lets a let rec see itself *)
  | VTuple of value list
  | VCon of string * value list
  | VRec of (string * value) list
and env = (string * value) list


(* The ones the FPU makes worth having.  Everything here is either a float
   function or a conversion; the types are seeded into the session below so
   that inference knows them without a declaration. *)
(* Set once the loader below is in scope.  boot returns only if it could
   not start; a successful one never comes back, because the machine it
   would return to has been replaced. *)

(* set once the disk and the evaluator are both in scope *)
let fs_put = ref (fun (_ : string) (_ : string) -> 0)
let fs_get = ref (fun (_ : string) -> Err "no filing system")
let fs_run = ref (fun (_ : string) -> 0)
let fs_ls = ref (fun (_ : int) -> 0)


let is_comparison op =
  string_equal op "=" || string_equal op "<>" || string_equal op "<"
  || string_equal op ">" || string_equal op "<=" || string_equal op ">="


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
  (* a declared type and its arguments: int list is TCon ("list", [TInt]) *)
  | TCon of string * ty list
  | TTuple of ty list
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
  | TCon (_, l) -> occurs_list id l
  | TTuple l -> occurs_list id l
  | _ -> false
and occurs_list id l = match l with
  | [] -> false
  | x :: r -> occurs id x || occurs_list id r

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
      let l = (match repr a with TArrow _ -> "(" ^^ go a ^^ ")" | _ -> go a) in
      let r = go b in
      l ^^ " -> " ^^ r
    (* int list, (int, string) table, and a tuple or an arrow argument
       parenthesised so that (int -> int) list does not read as int -> int list *)
    | TCon (n, []) -> n
    | TCon (n, [a]) -> let l = atom a in l ^^ " " ^^ n
    | TCon (n, l) -> "(" ^^ commas l ^^ ") " ^^ n
    | TTuple l -> stars l
  and atom t = match repr t with
    | TArrow _ -> "(" ^^ go t ^^ ")"
    | TTuple _ -> "(" ^^ go t ^^ ")"
    | _ -> go t
  and commas l = match l with
    | [] -> ""
    | [a] -> go a
    | a :: r -> let h = go a in h ^^ ", " ^^ commas r
  and stars l = match l with
    | [] -> ""
    | [a] -> atom a
    | a :: r -> let h = atom a in h ^^ " * " ^^ stars r in
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
  | TCon (n1, l1), TCon (n2, l2) when string_equal n1 n2 ->
    unify_list l1 l2 ra rb
  | TTuple l1, TTuple l2 -> unify_list l1 l2 ra rb
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
and unify_list l1 l2 ra rb = match l1, l2 with
  | [], [] -> Ok ()
  | a :: r1, b :: r2 ->
    (match unify a b with Err m -> Err m | Ok () -> unify_list r1 r2 ra rb)
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
  | TCon (_, l) -> free_tys l acc
  | TTuple l -> free_tys l acc
  | _ -> acc
and free_tys l acc = match l with
  | [] -> acc
  | t :: r -> free_tys r (free_ty t acc)

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
      | TCon (n, l) -> TCon (n, go_list l)
      | TTuple l -> TTuple (go_list l)
      | u -> u
    and go_list l = match l with [] -> [] | t :: r -> go t :: go_list r in
    go t

let rec lookup_scheme env x = match env with
  | [] -> Err ("unbound " ^^ x)
  | (y, sc) :: rest -> if string_equal x y then Ok (instantiate sc) else lookup_scheme rest x

(* ---- declared constructors ----
   Each one records the type it builds, that type's parameters, and the
   types of its arguments as they were written.  A use instantiates them:
   every parameter gets a fresh variable, so "Some 1" and "Some 1.0" are
   both fine and neither fixes the other.  [] and :: are the list type,
   declared here rather than built into the checker. *)
let constructors : (string * (string * string list * tyexp list)) list ref =
  ref [ ("[]", ("list", ["'a"], []));
        ("::", ("list", ["'a"], [TEVar "'a"; TECon ("list", [TEVar "'a"])]));
        ("None", ("option", ["'a"], []));
        ("Some", ("option", ["'a"], [TEVar "'a"])) ]

(* field name -> the record type it belongs to, that type's parameters, and
   the field's own type.  A field is looked up by name alone, so the last
   declaration of a name wins, as it does in OCaml. *)
let fields : (string * (string * string list * tyexp)) list ref = ref [("contents", ("ref", ["'a"], TEVar "'a"))]
(* record type name -> its fields in declaration order, for printing *)
let rec_order : (string * string list) list ref = ref [("ref", ["contents"])]
(* a type's constructors in the order they were declared, which is what
   decides their tags: the constant ones are numbered among themselves and
   the others among themselves *)
let type_ctors : (string * string list) list ref = ref [("list", ["[]"; "::"]); ("option", ["None"; "Some"])]

let rec find_rec_order l n = match l with
  | [] -> Err ("unknown record type " ^^ n)
  | (m, fs) :: r -> if string_equal m n then Ok fs else find_rec_order r n

let rec mem_field f l = match l with
  | [] -> false
  | (g, _) :: r -> string_equal f g || mem_field f r

let rec all_present want fs = match want with
  | [] -> true
  | f :: r -> mem_field f fs && all_present r fs

let rec find_field l f = match l with
  | [] -> Err ("unbound field " ^^ f)
  | (n, d) :: r -> if string_equal n f then Ok d else find_field r f

let rec find_ctor l c = match l with
  | [] -> Err ("unbound constructor " ^^ c)
  | (n, d) :: r -> if string_equal n c then Ok d else find_ctor r c

let rec find_alias n l = match l with
  | [] -> None
  | (m, d) :: r -> if string_equal m n then Some d else find_alias n r

let rec bind_params ps tys = match ps, tys with
  | p :: pr, t :: tr -> (p, t) :: bind_params pr tr
  | _, _ -> []

let rec lookup_sub sub v = match sub with
  | [] -> fresh_tv ()
  | (n, t) :: r -> if string_equal n v then t else lookup_sub r v

let rec ty_of_texp sub te = match te with
  | TEVar v -> lookup_sub sub v
  | TECon (n, []) when string_equal n "int" || string_equal n "unit" || string_equal n "char" -> TInt
  | TECon (n, []) when string_equal n "bool" -> TBool
  | TECon (n, []) when string_equal n "float" -> TFloat
  | TECon (n, []) when string_equal n "string" -> TString
  | TECon (n, l) ->
    (match find_alias n !aliases with
     | Some (ps, body) -> ty_of_texp (bind_params ps (ty_of_texps sub l)) body
     | None -> TCon (n, ty_of_texps sub l))
  | TEArrow (a, b) -> TArrow (ty_of_texp sub a, ty_of_texp sub b)
  | TETuple l -> TTuple (ty_of_texps sub l)
and ty_of_texps sub l = match l with
  | [] -> []
  | t :: r -> ty_of_texp sub t :: ty_of_texps sub r

let rec fresh_sub ps = match ps with
  | [] -> []
  | v :: r -> (v, fresh_tv ()) :: fresh_sub r

let rec sub_tys sub ps = match ps with
  | [] -> []
  | v :: r -> lookup_sub sub v :: sub_tys sub r

(* what a use of this constructor takes, and what it builds *)
let ctor_types c = match find_ctor !constructors c with
  | Err m -> Err m
  | Ok (tname, ps, args) ->
    let sub = fresh_sub ps in
    Ok (ty_of_texps sub args, TCon (tname, sub_tys sub ps))

(* the record type a field belongs to, and that field's type, both fresh *)
let field_types f = match find_field !fields f with
  | Err m -> Err m
  | Ok (tname, ps, te) ->
    let sub = fresh_sub ps in
    Ok (TCon (tname, sub_tys sub ps), ty_of_texp sub te)

(* the predefined exceptions: the global slot each has in every image (runtime/caml/fail.h), and
   whether it carries an argument, so that its identity is the first field of the value *)
let exn_slot c =
  if string_equal c "Out_of_memory" then 0 else if string_equal c "Sys_error" then 1
  else if string_equal c "Failure" then 2 else if string_equal c "Invalid_argument" then 3
  else if string_equal c "End_of_file" then 4 else if string_equal c "Division_by_zero" then 5
  else if string_equal c "Not_found" then 6 else if string_equal c "Match_failure" then 7
  else if string_equal c "Stack_overflow" then 8 else if string_equal c "Sys_blocked_io" then 9
  else if string_equal c "Assert_failure" then 10 else if string_equal c "Undefined_recursive_module" then 11
  else 0 - 1

let exn_has_arg c =
  string_equal c "Sys_error" || string_equal c "Failure" || string_equal c "Invalid_argument"
  || string_equal c "Match_failure" || string_equal c "Assert_failure"

let int_op op =
  string_equal op "+" || string_equal op "-" || string_equal op "*"
  || string_equal op "/" || string_equal op "mod"
  || string_equal op "land" || string_equal op "lor" || string_equal op "lxor"
  || string_equal op "lsl" || string_equal op "lsr"

let rec infer env e = match e with
  | Int _ -> Ok TInt
  | Float _ -> Ok TFloat
  | Str _ -> Ok TString
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
  | Field (e, f) ->
    (match field_types f with
     | Err m -> Err m
     | Ok (rt, ft) ->
       match infer env e with
       | Err m -> Err m
       | Ok te -> match unify rt te with Err m -> Err m | Ok () -> Ok ft)
  | Prim (_, _, _) -> Err "a primitive call has no type of its own"
  | ExnIs (_, _) -> Ok TBool
  | ExnVal _ -> Ok (TCon ("exn", []))
  | ExnArg _ -> Ok TString
  | Reraise _ -> Ok (fresh_tv ())
  | LetRecs (bs, body) ->
    (* the group is monomorphic while it is being checked, and every body sees every name *)
    let rec fresh l = match l with
      | [] -> []
      | (n, _) :: r -> (n, fresh_tv ()) :: fresh r in
    let tvs = fresh bs in
    let rec extend l e = match l with
      | [] -> e
      | (n, t) :: r -> (n, Forall ([], t)) :: extend r e in
    let inner = extend tvs env in
    let rec tv_of n l = match l with
      | [] -> fresh_tv ()
      | (m, t) :: r -> if string_equal m n then t else tv_of n r in
    let rec go l = match l with
      | [] -> infer inner body
      | (n, b) :: r ->
        (match infer inner b with
         | Err m -> Err m
         | Ok tb -> match unify (tv_of n tvs) tb with Err m -> Err m | Ok () -> go r) in
    go bs
  | Guard (g, b) ->
    (match infer env g with
     | Err m -> Err m
     | Ok tg ->
       match unify tg TBool with
       | Err _ -> Err "a when guard must be a bool"
       | Ok () -> infer env b)
  | ArrLit es ->
    let a = fresh_tv () in
    let rec go l = match l with
      | [] -> Ok (TCon ("array", [a]))
      | e :: r ->
        (match infer env e with
         | Err m -> Err m
         | Ok te -> match unify a te with Err m -> Err m | Ok () -> go r) in
    go es
  | While (c, b) ->
    (match infer env c with
     | Err m -> Err m
     | Ok tc ->
       match unify tc TBool with
       | Err _ -> Err "the condition of a while must be a bool"
       | Ok () -> (match infer env b with Err m -> Err m | Ok _ -> Ok TInt))
  | For (x, lo, hi, _, b) ->
    (match infer env lo with
     | Err m -> Err m
     | Ok tl ->
       match unify tl TInt with
       | Err _ -> Err "the bounds of a for must be ints"
       | Ok () ->
         match infer env hi with
         | Err m -> Err m
         | Ok th ->
           match unify th TInt with
           | Err _ -> Err "the bounds of a for must be ints"
           | Ok () ->
             match infer ((x, Forall ([], TInt)) :: env) b with
             | Err m -> Err m
             | Ok _ -> Ok TInt)
  | SetField (e, f, v) ->
    (match field_types f with
     | Err m -> Err m
     | Ok (rt, ft) ->
       match infer env e with
       | Err m -> Err m
       | Ok te ->
         match unify rt te with
         | Err m -> Err m
         | Ok () ->
           match infer env v with
           | Err m -> Err m
           | Ok tv -> match unify ft tv with Err m -> Err m | Ok () -> Ok TInt)
  | Record fs ->
    (match fs with
     | [] -> Err "a record needs at least one field"
     | (f0, _) :: _ ->
       match field_types f0 with
       | Err m -> Err m
       | Ok (rt, _) ->
         (* every field is checked against the same instance, so the
            parameters agree across them *)
         match infer_fields env fs rt with
         | Err m -> Err m
         | Ok () ->
           match rt with
           | TCon (n, _) ->
             (match find_rec_order !rec_order n with
              | Err m -> Err m
              | Ok want ->
                if all_present want fs then Ok rt
                else Err ("some fields of " ^^ n ^^ " are missing"))
           | _ -> Ok rt)
  | With (base, fs) ->
    (match infer env base with
     | Err m -> Err m
     | Ok rt ->
       match infer_fields env fs rt with Err m -> Err m | Ok () -> Ok rt)
  | Tuple es ->
    (match infer_all env es [] with
     | Err m -> Err m
     | Ok ts -> Ok (TTuple ts))
  (* The rules are spelled REFL, TRANS, MK_COMB, as they are in fusion.ml,
     and the parser reads a capitalised name as a constructor.  One that no
     declaration introduced is taken as an ordinary name instead, so those
     read as the applications they are. *)
  | Con (c, args) when (match find_ctor !constructors c with Err _ -> true | Ok _ -> false)
                       && (match lookup_scheme env c with Ok _ -> true | Err _ -> false) ->
    infer env (apps (Var c) args)
  | Con (c, args) when exn_slot c >= 0 ->
    (* Not_found, Failure "x", ...: a value of type exn *)
    let rec go l = match l with
      | [] -> Ok (TCon ("exn", []))
      | a :: r -> (match infer env a with Err m -> Err m | Ok _ -> go r) in
    go args
  | Con (c, args) ->
    (match ctor_types c with
     | Err m -> Err m
     | Ok (want, result) ->
       let rec go ws es = match ws, es with
         | [], [] -> Ok result
         | w :: wr, e :: er ->
           (match infer env e with
            | Err m -> Err m
            | Ok te ->
              match unify w te with Err m -> Err m | Ok () -> go wr er)
         | _ -> Err (c ^^ " is used with the wrong number of arguments") in
       go want args)
  | Match (scrut, arms) ->
    (match infer env scrut with
     | Err m -> Err m
     | Ok ts ->
       let result = fresh_tv () in
       let rec go l = match l with
         | [] -> Ok result
         | (q, body) :: r ->
           (match infer_pat env q ts with
            | Err m -> Err m
            | Ok env2 ->
              match infer env2 body with
              | Err m -> Err m
              | Ok tb ->
                match unify result tb with Err m -> Err m | Ok () -> go r) in
       go arms)

(* each field against the record type it is being used at *)
and infer_fields env fs rt = match fs with
  | [] -> Ok ()
  | (f, e) :: r ->
    (match field_types f with
     | Err m -> Err m
     | Ok (rt2, ft) ->
       match unify rt rt2 with
       | Err _ -> Err (f ^^ " is not a field of this record")
       | Ok () ->
         match infer env e with
         | Err m -> Err m
         | Ok te ->
           match unify ft te with Err m -> Err m | Ok () -> infer_fields env r rt)

and infer_all env l acc = match l with
  | [] -> Ok (rev_acc acc [])
  | e :: r ->
    (match infer env e with Err m -> Err m | Ok t -> infer_all env r (t :: acc))

(* a pattern against the type it is matched on, giving what it binds *)
and infer_pat env q t = match q with
  | PWild -> Ok env
  | PVar x -> Ok ((x, Forall ([], t)) :: env)
  | PInt _ -> (match unify t TInt with Err m -> Err m | Ok () -> Ok env)
  | PBool _ -> (match unify t TBool with Err m -> Err m | Ok () -> Ok env)
  | PTuple l ->
    let rec fresh_for l = match l with [] -> [] | _ :: r -> fresh_tv () :: fresh_for r in
    let ts = fresh_for l in
    (match unify t (TTuple ts) with
     | Err m -> Err m
     | Ok () -> infer_pats env l ts)
  | PRec fs -> infer_pat_rec env fs t
  | PCon (c, ps) ->
    (match ctor_types c with
     | Err m -> Err m
     | Ok (want, result) ->
       match unify t result with
       | Err m -> Err m
       | Ok () -> infer_pats env ps want)

(* a record pattern may name only some of the fields *)
and infer_pat_rec env fs t = match fs with
  | [] -> Ok env
  | (f, q) :: r ->
    (match field_types f with
     | Err m -> Err m
     | Ok (rt, ft) ->
       match unify t rt with
       | Err _ -> Err (f ^^ " is not a field of this record")
       | Ok () ->
         match infer_pat env q ft with
         | Err m -> Err m
         | Ok env2 -> infer_pat_rec env2 r t)

and infer_pats env ps ts = match ps, ts with
  | [], [] -> Ok env
  | q :: pr, t :: tr ->
    (match infer_pat env q t with Err m -> Err m | Ok env2 -> infer_pats env2 pr tr)
  | _ -> Err "a pattern has the wrong number of arguments"


(* ==== the code generator ====
   Each phrase is compiled into code memory above the program, and entered
   by patching the body of "doorway" below to branch at it.  Top-level
   names live in the globals array, which the machine already lets a
   running program write; locals live on the stack, and a name is looked up
   at compile time rather than at run time, which is where the speed comes
   from.  Nothing is reclaimed: the code pointer only goes up. *)
let code_win = 0x60000
let prog_words_reg = 0x100c

let op_acc = 8
let op_push = 9
let op_pop = 19
let op_constint = 103
let op_stop = 143
let op_assign = 20
let op_offsetint = 127
let op_andint = 115
let op_orint = 116
let op_xorint = 117
let op_lslint = 118
let op_lsrint = 119
let op_addint = 110
let op_subint = 111
let op_mulint = 112
let op_divint = 113
let op_modint = 114
let op_eq = 121
let op_neq = 122
let op_ltint = 123
let op_leint = 124
let op_gtint = 125
let op_geint = 126
let op_branch = 84
let op_branchifnot = 86
let op_closure = 43
let op_apply1 = 33
let op_return = 40
let op_getglobal = 53
let op_grab = 42
let op_apply2 = 34
let op_apply3 = 35
(* four or more arguments: the caller pushes the frame APPLY1..3 make for
   themselves, then APPLY takes the count as an immediate *)
let op_push_retaddr = 31
let op_apply = 32
let op_envacc = 25
let op_restart = 41
(* 117..119 are XORINT, LSLINT, LSRINT: getting these wrong emits a shift
   where a trap frame belongs, and the machine halts on the first raise *)
let op_pushtrap = 89
let op_poptrap = 90
let op_c_call1 = 93
let op_c_call2 = 94
(* the float primitives, at their indices in this program's table *)
let prim_add_float = 0x003
let prim_sub_float = 0x166
let prim_mul_float = 0x118
let prim_div_float = 0x054
let prim_float_of_int = 0x077
let prim_int_of_float = 0x0e1
let prim_sqrt_float = 0x157
let prim_abs_float = 0x000
let prim_neg_float = 0x12f
let op_setglobal = 57


let op_switch = 87
let op_getfield = 71
let op_setfield = 77
let op_makeblock = 62
let op_makeblock1 = 63
let op_makeblock2 = 64
let op_makeblock3 = 65

(* How a constructor is represented: a constant one is an integer, counted
   among the constant constructors of its type; one with arguments is a
   block whose tag counts among those.  SWITCH wants both totals. *)
let rec ctor_arity c = match find_ctor !constructors c with
  | Err _ -> 0 - 1
  | Ok (_, _, args) -> let rec n l = match l with [] -> 0 | _ :: r -> 1 + n r in n args

let rec find_order l t = match l with
  | [] -> Err ("unknown type " ^^ t)
  | (n, cs) :: r -> if string_equal n t then Ok cs else find_order r t

(* nconsts, nblocks, and this constructor's index within its own kind *)
let ctor_layout c = match find_ctor !constructors c with
  | Err m -> Err m
  | Ok (tname, _, _) ->
    match find_order !type_ctors tname with
    | Err m -> Err m
    | Ok cs ->
      let nc = ref 0 and nb = ref 0 and mine = ref (0 - 1) in
      let rec go l = match l with
        | [] -> ()
        | x :: r ->
          let a = ctor_arity x in
          (if string_equal x c then mine := (if a = 0 then !nc else !nb));
          (if a = 0 then nc := !nc + 1 else nb := !nb + 1);
          go r in
      go cs;
      if !mine < 0 then Err ("unknown constructor " ^^ c)
      else Ok (!nc, !nb, !mine, ctor_arity c)

(* ---- images ----
   Compiling for a chain load rather than for this session: the code goes
   into a file on the RAM disk, in the format of tools/mkvmimage.py, instead of
   the code RAM, and nothing is run.  While img_mode is set, code_wr and code_rd
   address the image: word w is the four bytes at img_at + 4 * w.  The disk is
   at 0x100000 (bytes), and a 32-bit word is written a byte at a time since an
   int here has only 31 bits. *)
let img_mode = ref false
let img_at = ref 0

let img_put4 off b0 b1 b2 b3 =
  io_write (0x100000 + off) b0; io_write (0x100000 + off + 1) b1;
  io_write (0x100000 + off + 2) b2; io_write (0x100000 + off + 3) b3

(* a word as the VM would hold it: two's complement in 32 bits *)
let img_wr32 off v =
  img_put4 off (v land 0xFF) ((v lsr 8) land 0xFF) ((v lsr 16) land 0xFF)
    (((v lsr 24) land 0x7F) lor (if v < 0 then 0x80 else 0))

let code_rd w =
  if !img_mode then begin
    let a = 0x100000 + !img_at + 32 + w * 4 in
    io_read a lor (io_read (a + 1) lsl 8) lor (io_read (a + 2) lsl 16)
  end else begin
    let a = code_win + w * 4 in
    io_read a lor (io_read (a + 1) lsl 8) lor (io_read (a + 2) lsl 16)
  end

let code_wr w v =
  if !img_mode then img_wr32 (!img_at + 32 + w * 4) v
  else begin
    let a = code_win + w * 4 in
    io_write a (v land 0xFF);
    io_write (a + 1) ((v lsr 8) land 0xFF);
    io_write (a + 2) ((v lsr 16) land 0xFF);
    io_write (a + 3) (((v lsr 24) land 0x7F) lor (if v < 0 then 0x80 else 0))
  end

(* where the next phrase goes, and the first free global slot *)
(* Set at startup from prog_words, which says where this program's own code
   ends.  It used to be a constant kept above that by hand, which is a
   footgun: let the program outgrow it and the first phrase compiled lands
   on top of the compiler. *)
let cp = ref 0
(* The globals array is 1 << GLOBALS_AW words and GLOBALS_AW is 12, so
   slot numbers are twelve bits wide: 4096 truncated to twelve bits is 0,
   and a compiler that started numbering there quietly wrote its
   definitions over the running program's own globals from slot 0 up.  The
   symptom was a parse that failed or not depending on how many phrases had
   been compiled before it, which reads like anything but a numbering bug.
   Start above what an image uses -- comp itself has some 530 -- and refuse
   rather than wrap at the top. *)
(* ---- externals ----
   external name : type = "primitive" makes the primitive a name.  What is kept
   for it is (kind, code, arity): kind 0 is no code at all (%identity), 1 is one
   opcode, 2 is a C call and code is the VM's number for the primitive.  The
   operators, ref, ! and := are the compiler's own and need no declaration, and
   neither do the float functions it already has; "" is how an operator
   comes back from parse_external.  The numbers are positions in the VM's
   primitive table (ocamlrun -p, then vm_io_read and vm_io_write). *)
let prim_table = [
  ("%identity", (0, 0, 1));
  ("%bytes_to_string", (0, 0, 1));
  ("%boolnot", (1, 88, 1));
  ("%raise", (1, 91, 1));
  ("%bytes_unsafe_get", (1, 82, 2));
  ("%bytes_unsafe_set", (1, 83, 3));
  ("%string_length", (2, 278, 1));
  ("%string_safe_get", (2, 347, 2));
  ("%array_safe_get", (2, 13, 2));
  ("%array_safe_set", (2, 15, 3));
  ("caml_create_bytes", (2, 82, 1));
  ("caml_string_equal", (2, 346, 2));
  ("vm_io_read", (2, 403, 1));
  ("vm_io_write", (2, 404, 2));
  ("caml_lt_float", (2, 238, 2));
  ("caml_le_float", (2, 230, 2));
  ("caml_eq_float", (2, 104, 2))]

let rec find_ext x l = match l with
  | [] -> None
  | (n, d) :: r -> if string_equal n x then Some d else find_ext x r

let prim_desc p = find_ext p prim_table

let externals : (string * (int * int * int)) list ref = ref []

(* the variables the closure just compiled captured, in field order from 2: what let rec patches *)
let last_caps : string list ref = ref []

let rec tyvars_of te acc = match te with
  | TEVar v -> if mem_name v acc then acc else v :: acc
  | TECon (_, l) -> tyvars_list l acc
  | TEArrow (a, b) -> tyvars_of b (tyvars_of a acc)
  | TETuple l -> tyvars_list l acc
and tyvars_list l acc = match l with [] -> acc | t :: r -> tyvars_list r (tyvars_of t acc)

let globals_max = 4096
let next_global = ref 1024
let doorway = ref (0 - 1)

(* ---- the emitter ----
   Code is written a word at a time, and what makes it small is done here, once, not at each of
   the places that emit: emit knows how many operand words each opcode takes, so it can tell when an
   instruction is complete and
     - use the one-word form where there is one (ACC0-7, ENVACC1-4, CONST0-3, GETFIELD0-3, SETFIELD0-3);
     - fold a PUSH into the instruction before it (PUSHACC, PUSHCONST, PUSHGETGLOBAL, PUSHENVACC);
     - add two POPs together, and fold POP k into a RETURN that follows it.
   Nothing is merged across a place a branch may land: here () is how the code asks where it is,
   so it marks the place, and a merge that would take an instruction away from under it is not done. *)
let em_last = ref (0 - 1)         (* where the latest instruction starts *)
let em_op = ref 0                 (* its opcode, as it is now (a merge changes it) *)
let em_pend = ref 0               (* operand words still to come *)
let em_nth = ref 0                (* operands so far *)
let em_prev = ref (0 - 1)         (* the instruction before that, and its opcode *)
let em_prev_op = ref 0
let em_barrier = ref (0 - 1)
let em_ret_add = ref 0

let em_reset () =
  em_last := 0 - 1; em_op := 0; em_pend := 0; em_nth := 0; em_prev := 0 - 1; em_prev_op := 0;
  em_barrier := 0 - 1; em_ret_add := 0

(* operand words after the opcode: 0 for nearly everything *)
let nops op =
  if op = 36 || op = 43 || op = 55 || op = 56 || op = 62 || op = 98 then 2
  else if op = 8 || op = 18 || op = 19 || op = 20 || op = 25 || op = 30 || op = 31 || op = 32
          || (op >= 37 && op <= 40) || op = 42 || op = 53 || op = 54 || op = 57 || op = 58 || op = 59
          || (op >= 63 && op <= 65) || op = 71 || op = 77 || op = 84 || op = 85 || op = 86 || op = 87
          || op = 89 || (op >= 93 && op <= 97) || op = 103 || op = 108 || op = 127 || op = 128 then 1
  else 0

(* the opcode that is this one followed by PUSH, or -1 *)
let pushed_form op =
  if op >= 0 && op <= 7 then op + 10
  else if op = 8 then 18
  else if op >= 21 && op <= 24 then op + 5
  else if op = 25 then 30
  else if op = 53 then 54
  else if op >= 99 && op <= 102 then op + 5
  else if op = 103 then 108
  else 0 - 1

(* PUSH followed by a load is one instruction: PUSHACC n is PUSH then ACC n, which is what the
   code is doing whenever it has pushed an operand and goes on to fetch the next *)
let em_fuse () =
  let f = pushed_form !em_op in
  let q = !em_last in
  if f >= 0 && !em_prev >= 0 && !em_prev_op = 9 && !em_prev + 1 = q && !em_barrier <> q then begin
    let p = !em_prev in
    let has_operand = !em_op = 8 || !em_op = 25 || !em_op = 53 || !em_op = 103 in
    (if has_operand then code_wr (p + 1) (code_rd (q + 1)));
    code_wr p f;
    cp := p + (if has_operand then 2 else 1);
    em_last := p; em_op := f; em_prev := 0 - 1; em_prev_op := 0
  end

let em_done () =
  let q = !em_last in
  let op = !em_op in
  if op = 8 then begin
    let n = code_rd (q + 1) in
    (if n < 8 then begin code_wr q n; cp := q + 1; em_op := n end);
    em_fuse ()
  end
  else if op = 25 then begin
    let n = code_rd (q + 1) in
    (if n >= 1 && n <= 4 then begin code_wr q (20 + n); cp := q + 1; em_op := 20 + n end);
    em_fuse ()
  end
  else if op = 103 then begin
    let n = code_rd (q + 1) in
    (if n >= 0 && n <= 3 then begin code_wr q (99 + n); cp := q + 1; em_op := 99 + n end);
    em_fuse ()
  end
  else if op = 53 then em_fuse ()
  else if op >= 0 && op <= 7 then em_fuse ()
  else if op = 71 then begin
    let n = code_rd (q + 1) in
    if n >= 0 && n <= 3 then begin code_wr q (67 + n); cp := q + 1; em_op := 67 + n end
  end
  else if op = 77 then begin
    let n = code_rd (q + 1) in
    if n >= 0 && n <= 3 then begin code_wr q (73 + n); cp := q + 1; em_op := 73 + n end
  end
  else if op = 19 then begin
    (* POP j then POP k is POP (j + k) *)
    if !em_prev_op = 19 && !em_prev >= 0 && !em_prev + 2 = q && !em_barrier <> q then begin
      code_wr (!em_prev + 1) (code_rd (!em_prev + 1) + code_rd (q + 1));
      cp := q; em_last := !em_prev; em_prev := 0 - 1; em_prev_op := 0
    end
  end
  else if op = 40 && !em_ret_add > 0 then begin
    code_wr (q + 1) (code_rd (q + 1) + !em_ret_add);
    em_ret_add := 0
  end

let emit w =
  if !em_pend > 0 then begin
    code_wr !cp w; cp := !cp + 1;
    em_nth := !em_nth + 1;
    (if !em_op = 87 && !em_nth = 1 then em_pend := (w land 0xFFFF) + (w lsr 16)
     else em_pend := !em_pend - 1);
    if !em_pend = 0 then em_done ()
  end
  else begin
    (* POP k just before a RETURN n is RETURN (n + k) *)
    (if w = 40 && !em_op = 19 && !em_last >= 0 && !em_barrier <> !cp && !em_last + 2 = !cp then begin
       em_ret_add := code_rd (!em_last + 1);
       cp := !em_last;
       em_last := !em_prev; em_op := !em_prev_op; em_prev := 0 - 1; em_prev_op := 0
     end);
    code_wr !cp w;
    em_prev := !em_last; em_prev_op := !em_op;
    em_last := !cp; em_op := w; cp := !cp + 1;
    em_pend := nops w; em_nth := 0;
    if !em_pend = 0 then em_done ()
  end
let here () = em_barrier := !cp; !cp

(* raise Match_failure: the exception value is a block of the predefined constructor (global 7) and its
   argument, which is the location in OCaml and here is 0 *)
let emit_match_failure () =
  emit 103; emit 0; emit 9;            (* CONSTINT 0; PUSH *)
  emit 53; emit 7;                     (* GETGLOBAL 7 *)
  emit 64; emit 0;                     (* MAKEBLOCK2, tag 0 *)
  emit 91                              (* RAISE *)

(* a branch's operand is relative to itself *)
let patch_branch at target = code_wr at (target - at)

(* the doorway: its body is one constant, which is what makes it findable,
   and a branch written over that constant is how a phrase is entered.  The constant is followed
   by RETURN: in an image the global that holds the marker has the same CONSTINT, followed by
   something else. *)
let marker = 0x5EED5E
let dispatch (_x : int) = 0x5EED5E

let find_doorway () =
  (* the program's own code is all there is to search, and its length is
     now something the machine will say *)
  let last = io_read prog_words_reg in
  cp := last;
  let p = ref 1 and f = ref (0 - 1) in
  while !f < 0 && !p < last do
    if code_rd !p = marker && code_rd (!p - 1) = op_constint && code_rd (!p + 1) = op_return then f := !p - 1;
    p := !p + 1
  done;
  doorway := !f;
  !f >= 0

(* ---- the compile-time environment ----
   A list of the names on the stack, innermost first; a temporary pushed
   between them is "".  The index of a name in that list is its ACC. *)
let globals : (string * int) list ref = ref []

let rec glob_slot l x = match l with
  | [] -> 0 - 1
  | (n, k) :: r -> if string_equal n x then k else glob_slot r x

let rec stack_idx l x i = match l with
  | [] -> 0 - 1
  | n :: r -> if string_equal n x then i else stack_idx r x (i + 1)

let comp_err = ref ""
let dump_code = ref false
(* unparseable, so it cannot collide with a name from the source *)
let scrut_name = " scrut"
(* what a closure being compiled has captured, in field order; saved and
   restored around each function so that nesting works *)
let cap : string list ref = ref []
(* closure bodies not yet emitted: the CLOSURE operand to patch, the parameters, the body and what
   it captures.  They go after the code that made them, so nothing has to branch over them. *)
let pending_bodies : (int * (string list * expr * string list)) list ref = ref []
(* a literal's global slot, so the same text is installed once *)
let literals : (string * int) list ref = ref []
(* boxed, so a float literal is installed the same way a string is *)
let float_lits : (float * int) list ref = ref []

(* the names an expression uses that it does not itself bind *)
let rec free_in e bound acc = match e with
  | Int _ -> acc
  | Float _ -> acc
  | Str _ -> acc
  | Bool _ -> acc
  | Var x -> if mem_str x bound then acc else (if mem_str x acc then acc else x :: acc)
  | Binop (_, a, b) -> free_in b bound (free_in a bound acc)
  | If (c, a, b) -> free_in b bound (free_in a bound (free_in c bound acc))
  | Let (r, x, bnd, body) ->
    let acc = free_in bnd (if r then x :: bound else bound) acc in
    free_in body (x :: bound) acc
  | Fun (x, b) -> free_in b (x :: bound) acc
  | App (f, a) -> free_in a bound (free_in f bound acc)
  | Con (_, l) -> free_in_list l bound acc
  | Tuple l -> free_in_list l bound acc
  | Match (sc, arms) ->
    let acc = free_in sc bound acc in
    let rec go l a = match l with
      | [] -> a
      | (pat, body) :: r -> go r (free_in body (pat_vars pat bound) a) in
    go arms acc
  | Try (b, n, h) -> free_in h (n :: bound) (free_in b bound acc)
  | Record fs -> free_in_fields fs bound acc
  | With (b, fs) -> free_in_fields fs bound (free_in b bound acc)
  | Field (b, _) -> free_in b bound acc
  | SetField (b, _, v) -> free_in v bound (free_in b bound acc)
  | Prim (_, _, l) -> free_in_list l bound acc
  | While (c, b) -> free_in b bound (free_in c bound acc)
  | ArrLit l -> free_in_list l bound acc
  | Guard (g, b) -> free_in b bound (free_in g bound acc)
  | ExnVal _ -> acc
  | ExnIs (_, e1) -> free_in e1 bound acc
  | ExnArg e1 -> free_in e1 bound acc
  | Reraise e1 -> free_in e1 bound acc
  | LetRecs (bs, body) ->
    let rec names l = match l with [] -> bound | (n, _) :: r -> n :: names r in
    let b2 = names bs in
    let rec each l a = match l with [] -> a | (_, e1) :: r -> each r (free_in e1 b2 a) in
    free_in body b2 (each bs acc)
  | For (x, lo, hi, _, b) -> free_in b (x :: bound) (free_in hi bound (free_in lo bound acc))
and free_in_list l bound acc = match l with
  | [] -> acc
  | x :: r -> free_in_list r bound (free_in x bound acc)
and free_in_fields l bound acc = match l with
  | [] -> acc
  | (_, x) :: r -> free_in_fields r bound (free_in x bound acc)
and pat_vars pat bound = match pat with
  | PVar x -> x :: bound
  | PTuple l -> pat_vars_list l bound
  | PCon (_, l) -> pat_vars_list l bound
  | PRec l -> let rec go m b = match m with
                | [] -> b
                | (_, q) :: r -> go r (pat_vars q b) in go l bound
  | _ -> bound
and pat_vars_list l bound = match l with
  | [] -> bound
  | q :: r -> pat_vars_list r (pat_vars q bound)

and mem_str x l = match l with
  | [] -> false
  | y :: r -> string_equal x y || mem_str x r

(* every literal in an expression, so each can be given a slot before the
   phrase that uses it is compiled *)
let rec strs_in e acc = match e with
  | Str t -> if mem_str t acc then acc else t :: acc
  | Binop (_, a, b) -> strs_in b (strs_in a acc)
  | If (c, a, b) -> strs_in b (strs_in a (strs_in c acc))
  | Let (_, _, bnd, body) -> strs_in body (strs_in bnd acc)
  | Fun (_, b) -> strs_in b acc
  | App (f, a) -> strs_in a (strs_in f acc)
  | Con (_, l) -> strs_in_list l acc
  | Tuple l -> strs_in_list l acc
  | Match (sc, arms) ->
    let rec go l a = match l with [] -> a | (_, b) :: r -> go r (strs_in b a) in
    go arms (strs_in sc acc)
  | Try (b, _, h) -> strs_in h (strs_in b acc)
  | Record fs -> strs_in_fields fs acc
  | With (b, fs) -> strs_in_fields fs (strs_in b acc)
  | Field (b, _) -> strs_in b acc
  | SetField (b, _, v) -> strs_in v (strs_in b acc)
  | Prim (_, _, l) -> strs_in_list l acc
  | While (c, b) -> strs_in b (strs_in c acc)
  | ArrLit l -> strs_in_list l acc
  | Guard (g, b) -> strs_in b (strs_in g acc)
  | ExnVal _ -> acc
  | ExnIs (_, e1) -> strs_in e1 acc
  | ExnArg e1 -> strs_in e1 acc
  | Reraise e1 -> strs_in e1 acc
  | LetRecs (bs, body) ->
    let rec each l a = match l with [] -> a | (_, e1) :: r -> each r (strs_in e1 a) in
    strs_in body (each bs acc)
  | For (_, lo, hi, _, b) -> strs_in b (strs_in hi (strs_in lo acc))
  | _ -> acc
and strs_in_list l acc = match l with
  | [] -> acc
  | x :: r -> strs_in_list r (strs_in x acc)
and strs_in_fields l acc = match l with
  | [] -> acc
  | (_, x) :: r -> strs_in_fields r (strs_in x acc)

let rec field_index l f i = match l with
  | [] -> 0 - 1
  | n :: r -> if string_equal n f then i else field_index r f (i + 1)

let rec_type_of_field f = match find_field !fields f with
  | Ok (tname, _, _) -> tname
  | Err _ -> ""

let rec_field_names tname = match find_rec_order !rec_order tname with
  | Ok fs -> fs
  | Err _ -> []

let rec assoc_expr l f = match l with
  | [] -> Err ("missing field " ^^ f)
  | (n, e) :: r -> if string_equal n f then Ok e else assoc_expr r f

(* A float is boxed, so a comparison of two of them compares pointers if it
   is compiled as an integer one.  The operators are shared with the
   integers, and nothing here carries a type, so the obvious cases are
   refused rather than quietly answered wrongly. *)
let rec looks_float e = match e with
  | Float _ -> true
  | Binop (op, _, _) ->
    string_equal op "+." || string_equal op "-."
    || string_equal op "*." || string_equal op "/."
  | App (Var f, _) ->
    string_equal f "float_of_int" || string_equal f "sqrt"
    || string_equal f "abs_float"
  | Let (_, _, _, b) -> looks_float b
  | If (_, a, _) -> looks_float a
  | _ -> false

let rec lit_slot l t = match l with
  | [] -> 0 - 1
  | (u, k) :: r -> if string_equal u t then k else lit_slot r t

let rec flit_slot l (t : float) = match l with
  | [] -> 0 - 1
  | (u, k) :: r -> if flt_eq u t then k else flit_slot r t

let rec floats_in e acc = match e with
  | Float f -> f :: acc
  | Binop (_, a, b) -> floats_in b (floats_in a acc)
  | If (c, a, b) -> floats_in b (floats_in a (floats_in c acc))
  | Let (_, _, bnd, body) -> floats_in body (floats_in bnd acc)
  | Fun (_, b) -> floats_in b acc
  | App (f, a) -> floats_in a (floats_in f acc)
  | Con (_, l) -> floats_in_list l acc
  | Tuple l -> floats_in_list l acc
  | Match (sc, arms) ->
    let rec go l a = match l with [] -> a | (_, b) :: r -> go r (floats_in b a) in
    go arms (floats_in sc acc)
  | Try (b, _, h) -> floats_in h (floats_in b acc)
  | Record fs -> floats_in_fields fs acc
  | With (b, fs) -> floats_in_fields fs (floats_in b acc)
  | Field (b, _) -> floats_in b acc
  | SetField (b, _, v) -> floats_in v (floats_in b acc)
  | Prim (_, _, l) -> floats_in_list l acc
  | While (c, b) -> floats_in b (floats_in c acc)
  | ArrLit l -> floats_in_list l acc
  | Guard (g, b) -> floats_in b (floats_in g acc)
  | ExnVal _ -> acc
  | ExnIs (_, e1) -> floats_in e1 acc
  | ExnArg e1 -> floats_in e1 acc
  | Reraise e1 -> floats_in e1 acc
  | LetRecs (bs, body) ->
    let rec each l a = match l with [] -> a | (_, e1) :: r -> each r (floats_in e1 a) in
    floats_in body (each bs acc)
  | For (_, lo, hi, _, b) -> floats_in b (floats_in hi (floats_in lo acc))
  | _ -> acc
and floats_in_list l acc = match l with
  | [] -> acc
  | x :: r -> floats_in_list r (floats_in x acc)
and floats_in_fields l acc = match l with
  | [] -> acc
  | (_, x) :: r -> floats_in_fields r (floats_in x acc)

let float_prim1 f =
  if string_equal f "float_of_int" then prim_float_of_int
  else if string_equal f "int_of_float" then prim_int_of_float
  else if string_equal f "sqrt" then prim_sqrt_float
  else if string_equal f "abs_float" then prim_abs_float
  else 0 - 1

let rec comp env e = match e with
  | Int n -> emit op_constint; emit n; true
  | Bool b -> emit op_constint; emit (if b then 1 else 0); true
  | Float f ->
    let k = flit_slot !float_lits f in
    if k >= 0 then begin emit op_getglobal; emit k; true end
    else begin comp_err := "this float has no slot"; false end
  | Str t ->
    let k = lit_slot !literals t in
    if k >= 0 then begin emit op_getglobal; emit k; true end
    else begin comp_err := "this literal has no slot"; false end
  | Var x ->
    let i = stack_idx env x 0 in
    if i >= 0 then begin emit op_acc; emit i; true end
    else begin
      let c = stack_idx !cap x 0 in
      if c >= 0 then begin emit op_envacc; emit (2 + c); true end
      else begin
        let g = glob_slot !globals x in
        if g >= 0 then begin emit op_getglobal; emit g; true end
        else match find_ext x !externals with
          | Some (k, c, n) ->
            (* a primitive used as a value: a closure around it *)
            let names = ["_p1"; "_p2"; "_p3"] in
            let rec take l m = if m = 0 then [] else (match l with [] -> [] | a :: r -> a :: take r (m - 1)) in
            let ps = take names n in
            let rec vars l = match l with [] -> [] | a :: r -> Var a :: vars r in
            let rec wrap l body = match l with [] -> body | a :: r -> Fun (a, wrap r body) in
            comp env (wrap ps (Prim (k, c, vars ps)))
          | None -> begin comp_err := "unbound " ^^ x; false end
      end
    end
  | Binop (op, a, b) -> comp_binop env op a b
  | If (c, a, b) ->
    if not_b (comp env c) then false
    else begin
      emit op_branchifnot; let p1 = here () in emit 0;
      if not_b (comp env a) then false
      else begin
        emit op_branch; let p2 = here () in emit 0;
        patch_branch p1 (here ());
        if not_b (comp env b) then false
        else begin patch_branch p2 (here ()); true end
      end
    end
  | Let (true, x, bound, body) -> comp env (LetRecs ([(x, bound)], body))
  | LetRecs (bs, body) -> comp_letrecs env bs body
  | Let (_, x, bound, body) ->
    if not_b (comp env bound) then false
    else begin
      emit op_push;
      if not_b (comp (x :: env) body) then false
      else begin emit op_pop; emit 1; true end
    end
  | Fun (_, _) ->
    (* fun x y -> e is one function of two arguments, not two of one: GRAB
       takes them together, so the inner one has nothing to capture.  Its
       names are its arguments or globals, and the closure has no fields. *)
    let rec params t acc = match t with
      | Fun (x, b) -> params b (x :: acc)
      | _ -> (rev_acc acc [], t) in
    let (ps, body) = params e [] in
    let rec count l = match l with [] -> 0 | _ :: r -> 1 + count r in
    (* whatever the body uses from out here has to travel with it; a global
       is reachable from anywhere and so is left alone *)
    let fv = free_in body ps [] in
    let rec keep l acc = match l with
      | [] -> acc
      | x :: r ->
        if stack_idx env x 0 >= 0 || stack_idx !cap x 0 >= 0 then keep r (x :: acc)
        else keep r acc in
    let caps = keep fv [] in
    let nc = count caps in
    (* field 2 comes from the accumulator and the rest from the stack, so
       they go on last-first, as a block's do *)
    let rec tl l = match l with [] -> [] | _ :: r -> r in
    let pushed = rev_acc (tl caps) [] in
    let e2 = ref env and ok = ref true in
    let rec push l = match l with
      | [] -> ()
      | x :: r ->
        if !ok then begin
          if not_b (comp !e2 (Var x)) then ok := false
          else begin emit op_push; e2 := "" :: !e2; push r end
        end in
    push pushed;
    (if !ok && nc > 0 then
       match caps with
       | first :: _ -> if not_b (comp !e2 (Var first)) then ok := false
       | [] -> ());
    if not_b !ok then false
    else begin
      emit op_closure; emit nc;
      let p = here () in emit 0;
      pending_bodies := (p, (ps, body, caps)) :: !pending_bodies;
      last_caps := caps;
      true
    end
  | Prim (k, c, args) -> comp_prim env k c args
  | App (_, _) when ext_arity env e >= 0 ->
    let rec spine t acc = match t with
      | App (f, a) -> spine f (a :: acc)
      | _ -> (t, acc) in
    let (f, args) = spine e [] in
    let n = ext_arity env e in
    let (k, c) = (match f with
      | Var x -> (match find_ext x !externals with Some (k, c, _) -> (k, c) | None -> (0, 0))
      | _ -> (0, 0)) in
    let rec split l m acc = if m = 0 then (rev_acc acc [], l) else
      (match l with [] -> (rev_acc acc [], []) | a :: r -> split r (m - 1) (a :: acc)) in
    let (first, rest) = split args n [] in
    comp env (apps (Prim (k, c, first)) rest)
  | App (Var f, a) when float_prim1 f >= 0 ->
    if not_b (comp env a) then false
    else begin emit op_c_call1; emit (float_prim1 f); true end
  | App (_, _) ->
    let rec spine t acc = match t with
      | App (f, a) -> spine f (a :: acc)
      | _ -> (t, acc) in
    let (f, args) = spine e [] in
    let rec count l = match l with [] -> 0 | _ :: r -> 1 + count r in
    let n = count args in
    (* APPLY1..3 build their own return frame; beyond that PUSH_RETADDR
       has to put one there first, and it is three words, so the
       compile-time stack grows by three as well or every local under it
       is read from the wrong slot. *)
    let big = n > 3 in
    let ra = ref 0 in
    let e2 = ref env and ok = ref true in
    if big then begin
      emit op_push_retaddr; ra := here (); emit 0;
      e2 := "" :: "" :: "" :: !e2
    end;
    let rec push l = match l with
      | [] -> ()
      | x :: r ->
        if !ok then begin
          if not_b (comp !e2 x) then ok := false
          else begin emit op_push; e2 := "" :: !e2; push r end
        end in
    push (rev_acc args []);
    if not_b !ok then false
    else if not_b (comp !e2 f) then false
    else begin
      (if n = 1 then emit op_apply1
       else if n = 2 then emit op_apply2
       else if n = 3 then emit op_apply3
       else begin emit op_apply; emit n end);
      if big then patch_branch !ra (here ());
      true
    end
  | Con (c, args) when exn_slot c >= 0 ->
    (* a predefined exception: its global, or a block of that and the argument *)
    (match args with
     | [] -> emit op_getglobal; emit (exn_slot c); true
     | _ -> comp_block env 0 (ExnVal c :: args))
  | ExnVal c -> emit op_getglobal; emit (exn_slot c); true
  | Con (c, args) -> comp_con env c args
  | Tuple es -> comp_block env 0 es
  | ArrLit es -> comp_block env 0 es
  | Match (scrut, arms) -> comp_match env scrut arms
  | Field (b, f) ->
    let idx = field_index (rec_field_names (rec_type_of_field f)) f 0 in
    if idx < 0 then begin comp_err := "unknown field " ^^ f; false end
    else if not_b (comp env b) then false
    else begin emit op_getfield; emit idx; true end
  | ExnIs (c, e1) ->
    let k = exn_slot c in
    if k < 0 then begin comp_err := "unknown exception " ^^ c; false end
    else if not_b (comp env e1) then false
    else begin
      (if exn_has_arg c then begin emit op_getfield; emit 0 end);
      emit op_push; emit op_getglobal; emit k; emit op_eq;
      true
    end
  | ExnArg e1 ->
    if not_b (comp env e1) then false
    else begin emit op_getfield; emit 1; true end
  | Reraise e1 ->
    if not_b (comp env e1) then false
    else begin emit 91; true end
  | While (c, b) ->
    (* a backward branch, not a recursive call: there are no tail calls here, and a loop
       of a hundred thousand turns would be a hundred thousand frames *)
    let top = here () in
    if not_b (comp env c) then false
    else begin
      emit op_branchifnot; let exit_at = here () in emit 0;
      if not_b (comp env b) then false
      else begin
        emit op_branch; let back = here () in emit 0;
        patch_branch back top;
        patch_branch exit_at (here ());
        emit op_constint; emit 0;
        true
      end
    end
  | For (x, lo, hi, up, b) ->
    (* the variable and the (once-evaluated) limit are two stack slots; the variable is
       compared with the limit, the body runs with the variable in scope, and the variable
       is stepped in place with ASSIGN *)
    if not_b (comp env lo) then false
    else begin
      emit op_push;
      let e1 = x :: env in
      if not_b (comp e1 hi) then false
      else begin
        emit op_push;
        let e2 = "" :: e1 in
        let top = here () in
        emit op_acc; emit 0; emit op_push;                  (* the limit, copied *)
        emit op_acc; emit 2;                                (* the variable *)
        emit (if up then op_leint else op_geint);
        emit op_branchifnot; let exit_at = here () in emit 0;
        if not_b (comp e2 b) then false
        else begin
          emit op_acc; emit 1;
          emit op_offsetint; emit (if up then 1 else 0 - 1);
          emit op_assign; emit 1;
          emit op_branch; let back = here () in emit 0;
          patch_branch back top;
          patch_branch exit_at (here ());
          emit op_pop; emit 2;
          emit op_constint; emit 0;
          true
        end
      end
    end
  | SetField (b, f, v) ->
    (* the value goes on the stack, the record into the accumulator, and
       SETFIELD takes the one and stores it in the other *)
    let idx = field_index (rec_field_names (rec_type_of_field f)) f 0 in
    if idx < 0 then begin comp_err := "unknown field " ^^ f; false end
    else if not_b (comp env v) then false
    else begin
      emit op_push;
      if not_b (comp ("" :: env) b) then false
      else begin emit op_setfield; emit idx; true end
    end
  | Record fs ->
    let names = rec_field_names (match fs with (f, _) :: _ -> rec_type_of_field f | [] -> "") in
    let bad = ref false in
    let rec ordered l acc = match l with
      | [] -> rev_acc acc []
      | fn :: r ->
        (match assoc_expr fs fn with
         | Ok x -> ordered r (x :: acc)
         | Err m -> comp_err := m; bad := true; []) in
    let es = ordered names [] in
    if !bad then false else comp_block env 0 es
  | With (base, fs) ->
    let names = rec_field_names (match fs with (f, _) :: _ -> rec_type_of_field f | [] -> "") in
    let rec count l = match l with [] -> 0 | _ :: r -> 1 + count r in
    let n = count names in
    if n = 0 then begin comp_err := "not a record"; false end
    else if not_b (comp env base) then false
    else begin
      emit op_push;
      (* the base stays on the stack while the fields are built, so it moves
         one slot further down with each of them *)
      let ok = ref true in
      let rec go i l = match l with
        | [] -> ()
        | fn :: r ->
          (match assoc_expr fs fn with
           | Ok x ->
             let rec pad k m = if k = 0 then m else pad (k - 1) ("" :: m) in
             if not_b (comp (pad i ("" :: env)) x) then ok := false
           | Err _ ->
             emit op_acc; emit i;
             emit op_getfield; emit (field_index names fn 0));
          if !ok then
            (match r with
             | [] -> ()
             | _ -> emit op_push; go (i + 1) r) in
      go 0 (rev_acc names []);
      if not_b !ok then false
      else begin
        (if n <= 3 then
           emit (if n = 1 then op_makeblock1 else if n = 2 then op_makeblock2 else op_makeblock3)
         else begin emit op_makeblock; emit n end);
        emit 0;
        emit op_pop; emit 1;
        true
      end
    end
  | Try (body, name, handler) ->
    emit op_pushtrap; let hp = here () in emit 0;
    (* PUSHTRAP leaves a four-word frame on the stack, so everything in the
       body is that much further from the accumulator *)
    let benv = "" :: "" :: "" :: "" :: env in
    if not_b (comp benv body) then false
    else begin
      emit op_poptrap;
      emit op_branch; let skip = here () in emit 0;
      patch_branch hp (here ());
      (* the raise leaves its value in the accumulator and the frame is
         gone, so a handler that names it has to put it on the stack *)
      let henv = if string_equal name "_" then env
                 else begin emit op_push; name :: env end in
      if not_b (comp henv handler) then false
      else begin
        (if not_b (string_equal name "_") then begin emit op_pop; emit 1 end);
        patch_branch skip (here ());
        true
      end
    end
  | _ -> comp_err := "this is not compiled yet"; false

(* field 0 comes from the accumulator and the rest from the stack, so the
   arguments are pushed last-first and the first is left in the accumulator *)
and comp_block env tag es =
  let rec count l = match l with [] -> 0 | _ :: r -> 1 + count r in
  let n = count es in
  if n = 0 then begin emit op_constint; emit 0; true end
  else begin
    let rec rev l acc = match l with [] -> acc | x :: r -> rev r (x :: acc) in
    let rec push_rest l e = match l with
      | [] -> true
      | x :: r ->
        if not_b (comp e x) then false
        else begin emit op_push; push_rest r ("" :: e) end in
    (* fields 1..n-1, pushed last first, so that sp[0] is field 1 *)
    let rest = rev (match es with [] -> [] | _ :: r -> r) [] in
    if not_b (push_rest rest env) then false
    else begin
      let e2 =
        let rec pad k l = if k = 0 then l else pad (k - 1) ("" :: l) in
        pad (n - 1) env in
      match es with
      | [] -> false
      | first :: _ ->
        if not_b (comp e2 first) then false
        else begin
          (if n <= 3 then begin
             emit (if n = 1 then op_makeblock1 else if n = 2 then op_makeblock2 else op_makeblock3);
             emit tag
           end else begin emit op_makeblock; emit n; emit tag end);
          true
        end
    end
  end


(* ---- match ----
   The scrutinee is kept on the stack while the arms are tried in order.
   Each arm tests its pattern, branching to the next arm on any failure;
   SWITCH is what reads a constructor's tag, since nothing else does, and a
   table whose entries all lead away except one is how a single tag is
   tested.  Binding happens only once an arm has matched, so a failure
   never has to undo a push. *)
and comp_path env depth path =
  emit op_acc; emit depth;
  let rec go l = match l with
    | [] -> ()
    | i :: r -> emit op_getfield; emit i; go r in
  go path

and comp_test env depth path pat fails = match pat with
  | PWild -> true
  | PVar _ -> true
  | PInt n ->
    comp_path env depth path; emit op_push; emit op_constint; emit n; emit op_eq;
    emit op_branchifnot; fails := here () :: !fails; emit 0; true
  | PBool b ->
    comp_path env depth path; emit op_push; emit op_constint; emit (if b then 1 else 0);
    emit op_eq; emit op_branchifnot; fails := here () :: !fails; emit 0; true
  | PRec fs ->
    (* a record has one shape, so only the sub-patterns can fail *)
    let ok = ref true in
    let rec go l = match l with
      | [] -> ()
      | (fn, q) :: r ->
        let idx = field_index (rec_field_names (rec_type_of_field fn)) fn 0 in
        if idx < 0 then begin comp_err := "unknown field " ^^ fn; ok := false end
        else begin
          if not_b (comp_test env depth (path_snoc path idx) q fails) then ok := false
          else go r
        end in
    go fs; !ok
  | PTuple sub -> comp_subtests env depth path sub 0 fails
  | PCon (c, sub) ->
    (match ctor_layout c with
     | Err m -> comp_err := m; false
     | Ok (nconsts, nblocks, idx, arity) ->
       comp_path env depth path;
       emit op_switch; emit (nconsts lor (nblocks lsl 16));
       let base = here () in
       let total = nconsts + nblocks in
       let i = ref 0 in
       while !i < total do emit 0; i := !i + 1 done;
       (* everything that is not this constructor leaves by here *)
       let away = here () in
       emit op_branch; fails := here () :: !fails; emit 0;
       let cont = here () in
       let want = if arity = 0 then idx else nconsts + idx in
       let k = ref 0 in
       while !k < total do
         code_wr (base + !k) ((if !k = want then cont else away) - (base + !k) + !k);
         k := !k + 1
       done;
       if arity = 0 then true else comp_subtests env depth path sub 0 fails)

and comp_subtests env depth path l i fails = match l with
  | [] -> true
  | p :: r ->
    if not_b (comp_test env depth (path_snoc path i) p fails) then false
    else comp_subtests env depth path r (i + 1) fails

and path_snoc path i = match path with
  | [] -> [i]
  | x :: r -> x :: path_snoc r i

(* once an arm has matched, its variables are pushed in order *)
and comp_bind env depth path pat pushed = match pat with
  | PVar x ->
    comp_path env (depth + pushed) path; emit op_push;
    Ok (x :: env, pushed + 1)
  | PWild -> Ok (env, pushed)
  | PInt _ -> Ok (env, pushed)
  | PBool _ -> Ok (env, pushed)
  | PTuple sub -> comp_binds env depth path sub 0 pushed
  | PCon (_, sub) -> comp_binds env depth path sub 0 pushed
  (* every named field binds, not only the first: this is what made
     { x = a; y = b } leave b unbound *)
  | PRec fs ->
    let rec go l e n = match l with
      | [] -> Ok (e, n)
      | (fn, q) :: r ->
        let idx = field_index (rec_field_names (rec_type_of_field fn)) fn 0 in
        if idx < 0 then Err ("unknown field " ^^ fn)
        else
          (match comp_bind e depth (path_snoc path idx) q n with
           | Err m -> Err m
           | Ok (e2, n2) -> go r e2 n2) in
    go fs env pushed

and comp_binds env depth path l i pushed = match l with
  | [] -> Ok (env, pushed)
  | p :: r ->
    (match comp_bind env depth (path_snoc path i) p pushed with
     | Err m -> Err m
     | Ok (e2, n2) -> comp_binds e2 depth path r (i + 1) n2)

(* The slot an arm's pattern has in a SWITCH table: constants first, then the constructors that
   carry arguments, as the machine numbers them.  -1 is an arm that takes anything (_ or a name),
   -2 one that is not a plain constructor pattern, which rules the dispatch out. *)
and arm_slot pat = match pat with
  | PWild -> 0 - 1
  | PVar _ -> 0 - 1
  | PCon (c, _) ->
    (match ctor_layout c with
     | Ok (nc, _, idx, arity) -> if arity = 0 then idx else nc + idx
     | Err _ -> 0 - 2)
  | _ -> 0 - 2

(* the constructors' shape if the whole match can be one dispatch: every arm a constructor of the
   one type or a catch-all, and at least two constructor arms; else (-1, 0) *)
and dispatch_shape arms =
  let rec go l shape count = match l with
    | [] -> if count >= 2 then shape else (0 - 1, 0)
    | (pat, _) :: r ->
      (match pat with
       | PCon (c, _) ->
         (match ctor_layout c with
          | Ok (nc, nb, _, _) ->
            let (a, _) = shape in
            if a < 0 then go r (nc, nb) (count + 1)
            else if (let (sc, sb) = shape in sc = nc && sb = nb) then go r shape (count + 1)   (* ints, not a tuple: caml_equal is not in the processor *)
            else (0 - 1, 0)
          | Err _ -> (0 - 1, 0))
       | PWild -> go r shape count
       | PVar _ -> go r shape count
       | _ -> (0 - 1, 0)) in
  go arms (0 - 1, 0) 0

(* the first arm after index i that could take what arm i's pattern would: the same constructor, or
   a catch-all; -1 if none *)
and next_arm i slot l =
  let rec go k l = match l with
    | [] -> 0 - 1
    | (pat, _) :: r ->
      if k > i && (let sl = arm_slot pat in sl = slot || sl = 0 - 1 || slot = 0 - 1) then k else go (k + 1) r in
  go 0 l

and label_of i labels = match labels with
  | [] -> 0 - 1
  | (k, p) :: r -> if k = i then p else label_of i r

and comp_match env scrut arms =
  let (nc, nb) = dispatch_shape arms in
  if nc >= 0 then comp_match_switch env scrut arms nc nb
  else comp_match_chain env scrut arms

(* one SWITCH for the whole match.  Each arm starts at a label of its own; what an arm's nested tests
   or guard cannot match goes on to the next arm that could take the same constructor.  Nothing
   matching leaves 0, as in the chain below. *)
and comp_match_switch env scrut arms nc nb =
  if not_b (comp env scrut) then false
  else begin
    emit op_push;
    let env = scrut_name :: env in
    let depth = stack_idx env scrut_name 0 in
    let total = nc + nb in
    emit op_switch; emit (nc lor (nb lsl 16));
    let base = here () in
    let rec zeros k = if k > 0 then begin emit 0; zeros (k - 1) end in
    zeros total;
    let labels = ref [] and pend = ref [] and ends = ref [] and ok = ref true in
    let rec go i l = match l with
      | [] -> ()
      | (pat, body) :: r ->
        if !ok then begin
          let here_now = here () in
          labels := (i, here_now) :: !labels;
          let nxt = next_arm i (arm_slot pat) arms in
          let fails = ref [] in
          let tested = match pat with
            | PCon (_, subs) -> comp_subtests env depth [] subs 0 fails
            | _ -> true in
          if not_b tested then ok := false
          else begin
            match comp_bind env depth [] pat 0 with
            | Err m -> comp_err := m; ok := false
            | Ok (env2, pushed) ->
              let (guard, body) = match body with Guard (g, b) -> (Some g, b) | _ -> (None, body) in
              let gfail = ref 0 in
              let guard_ok = match guard with
                | None -> true
                | Some g ->
                  if not_b (comp env2 g) then false
                  else begin emit op_branchifnot; gfail := here (); emit 0; true end in
              if not_b guard_ok then ok := false
              else if not_b (comp env2 body) then ok := false
              else begin
                (if pushed > 0 then begin emit op_pop; emit pushed end);
                emit op_branch; ends := here () :: !ends; emit 0;
                (* a failed guard gives back the variables and goes to the next arm that could match *)
                (if !gfail > 0 then begin
                   code_wr !gfail (here () - !gfail);
                   (if pushed > 0 then begin emit op_pop; emit pushed end);
                   emit op_branch; pend := (nxt, here ()) :: !pend; emit 0
                 end);
                let rec add l = match l with [] -> () | p :: t -> pend := (nxt, p) :: !pend; add t in
                add !fails;
                go (i + 1) r
              end
          end
        end in
    go 0 arms;
    if not_b !ok then false
    else begin
      let rec first_arm slot k l = match l with
        | [] -> 0 - 1
        | (pat, _) :: r ->
          let sl = arm_slot pat in
          if sl = slot || sl = 0 - 1 then k else first_arm slot (k + 1) r in
      (* Match_failure, predefined global 7, raised -- but only if some path can get there: a slot no
         arm takes, or a nested pattern or guard with no later arm to fall to *)
      let rec open_slot s = s < total && (first_arm s 0 arms < 0 || open_slot (s + 1)) in
      let rec open_pend l = match l with [] -> false | (t, _) :: r -> t < 0 || open_pend r in
      let nomatch = here () in
      (if open_slot 0 || open_pend !pend then emit_match_failure ());
      let fin = here () in
      let rec resolve l = match l with
        | [] -> ()
        | (t, p) :: r ->
          code_wr p ((if t < 0 then nomatch else label_of t !labels) - p); resolve r in
      resolve !pend;
      let rec fill s =
        if s < total then begin
          let a = first_arm s 0 arms in
          let target = if a < 0 then nomatch else label_of a !labels in
          code_wr (base + s) (target - base);
          fill (s + 1)
        end in
      fill 0;
      let rec patch l = match l with
        | [] -> ()
        | a :: t -> code_wr a (fin - a); patch t in
      patch !ends;
      emit op_pop; emit 1;
      true
    end
  end

and comp_match_chain env scrut arms =
  if not_b (comp env scrut) then false
  else begin
    emit op_push;
    let env = scrut_name :: env in
    let ends = ref [] in
    let ok = ref true in
    let rec go l = match l with
      | [] ->
        (* nothing matched: Match_failure, predefined global 7, raised *)
        emit_match_failure ()
      | (pat, body) :: r ->
        let fails = ref [] in
        let depth = stack_idx env scrut_name 0 in
        if not_b (comp_test env depth [] pat fails) then ok := false
        else begin
          match comp_bind env depth [] pat 0 with
          | Err m -> comp_err := m; ok := false
          | Ok (env2, pushed) ->
            (* a when guard is tested with the variables bound; if it fails they are
               popped and the next arm is tried, as if the pattern had not matched *)
            let (guard, body) = match body with Guard (g, b) -> (Some g, b) | _ -> (None, body) in
            let gfail = ref 0 in
            let guard_ok = match guard with
              | None -> true
              | Some g ->
                if not_b (comp env2 g) then false
                else begin emit op_branchifnot; gfail := here (); emit 0; true end in
            if not_b guard_ok then ok := false
            else if not_b (comp env2 body) then ok := false
            else begin
              (if pushed > 0 then begin emit op_pop; emit pushed end);
              emit op_branch; ends := here () :: !ends; emit 0;
              (if !gfail > 0 then begin
                 code_wr !gfail (here () - !gfail);
                 (if pushed > 0 then begin emit op_pop; emit pushed end)
               end);
              let next = here () in
              let rec patch l = match l with
                | [] -> ()
                | a :: t -> code_wr a (next - a); patch t in
              patch !fails;
              go r
            end
        end in
    go arms;
    if not_b !ok then false
    else begin
      let fin = here () in
      let rec patch l = match l with
        | [] -> ()
        | a :: t -> code_wr a (fin - a); patch t in
      patch !ends;
      emit op_pop; emit 1;
      true
    end
  end

(* how many arguments the external at the head of this application takes, if the
   head is one and not shadowed, and the call has that many; else -1 *)
and ext_arity env e =
  let rec head t n = match t with
    | App (f, _) -> head f (n + 1)
    | Var x -> (x, n)
    | _ -> ("", n) in
  let (x, nargs) = head e 0 in
  if string_equal x "" then 0 - 1
  else if stack_idx env x 0 >= 0 || stack_idx !cap x 0 >= 0 || glob_slot !globals x >= 0 then 0 - 1
  else match find_ext x !externals with
    | Some (_, _, n) -> if nargs >= n then n else 0 - 1
    | None -> 0 - 1

(* the first argument goes in the accumulator and the others on the stack, the last
   pushed first, which is how C_CALLn and the opcodes with operands read them *)
and comp_prim env k c args =
  match args with
  | [] -> false
  | a1 :: rest ->
    let rec push_all l e = match l with
      | [] -> Some e
      | a :: r -> if not_b (comp e a) then None else begin emit op_push; push_all r ("" :: e) end in
    let rec count l = match l with [] -> 0 | _ :: r -> 1 + count r in
    (match push_all (rev_acc rest []) env with
     | None -> false
     | Some e2 ->
       if not_b (comp e2 a1) then false
       else begin
         (if k = 2 then begin emit (93 + count rest); emit c end
          else if k = 1 then emit c);
         true
       end)

(* emit the closure bodies that were set aside, each where the code is up to; a body may set more
   aside.  GRAB's partial application returns a closure pointing one word before the GRAB, where
   RESTART has to be waiting to unpack what was saved; without it the second call lands on whatever
   preceded the function and takes the machine with it. *)
and comp_pending () =
  match !pending_bodies with
  | [] -> true
  | (p, (ps, body, caps)) :: rest ->
    pending_bodies := rest;
    let rec count l = match l with [] -> 0 | _ :: r -> 1 + count r in
    let n = count ps in
    em_reset ();
    (if n > 1 then emit op_restart);
    patch_branch p (here ());
    (if n > 1 then begin emit op_grab; emit (n - 1) end);
    let saved = !cap in
    cap := caps;
    let r = comp ps body in
    cap := saved;
    if not_b r then begin pending_bodies := []; false end
    else begin emit op_return; emit n; comp_pending () end

(* let rec f = ... and g = ... in body.  A slot on the stack for each function holds 0 until its
   closure exists; each closure is built capturing those slots (and what else it uses), then each
   slot a closure captured is patched, in the closure, to the closure it stands for.  The names
   are then ordinary locals of the body. *)
and comp_letrecs env bs body =
  let rec count l = match l with [] -> 0 | _ :: r -> 1 + count r in
  let n = count bs in
  let rec dummies l e = match l with
    | [] -> e
    | (nm, _) :: r -> emit op_constint; emit 0; emit op_push; dummies r (nm :: e) in
  let env2 = dummies bs env in
  let rec names l = match l with [] -> [] | (nm, _) :: r -> nm :: names r in
  let group = names bs in
  let ok = ref true in
  let made : (string * string list) list ref = ref [] in
  let rec build l = match l with
    | [] -> ()
    | (nm, b) :: r ->
      if !ok then begin
        (match b with
         | Fun (_, _) ->
           if not_b (comp env2 b) then ok := false
           else begin
             made := (nm, !last_caps) :: !made;
             emit op_assign; emit (stack_idx env2 nm 0);
             build r
           end
         | _ -> comp_err := "let rec needs a function"; ok := false)
      end in
  build bs;
  if not_b !ok then false
  else begin
    let rec patch_fns l = match l with
      | [] -> ()
      | (fname, caps) :: r ->
        let rec go cs p = match cs with
          | [] -> ()
          | c :: cr ->
            (if mem_name c group then begin
               emit op_acc; emit (stack_idx env2 c 0); emit op_push;
               emit op_acc; emit (stack_idx ("" :: env2) fname 0);
               emit op_setfield; emit (2 + p)
             end);
            go cr (p + 1) in
        go caps 0;
        patch_fns r in
    patch_fns !made;
    if not_b (comp env2 body) then false
    else begin emit op_pop; emit n; true end
  end

and comp_con env c args =
  match ctor_layout c with
  | Err m -> comp_err := m; false
  | Ok (_, _, idx, arity) ->
    if arity = 0 then begin emit op_constint; emit idx; true end
    else comp_block env idx args

(* accu holds the left operand and the stack the right, so the right is
   compiled first *)
and comp_binop env op a b =
  let fprim =
    if string_equal op "+." then prim_add_float
    else if string_equal op "-." then prim_sub_float
    else if string_equal op "*." then prim_mul_float
    else if string_equal op "/." then prim_div_float
    else 0 - 1 in
  if fprim >= 0 then begin
    if not_b (comp env b) then false
    else begin
      emit op_push;
      if not_b (comp ("" :: env) a) then false
      else begin emit op_c_call2; emit fprim; true end
    end
  end
  (* > and >= are < and <= the other way about.  The floating-point
     peripheral has no greater-than, and the comparisons now dispatch on
     the operands' tags in the VM, so it is cheaper to swap here than to
     teach the hardware an operation it does not have. *)
  else if string_equal op ">" then comp_binop env "<" b a
  else if string_equal op ">=" then comp_binop env "<=" b a
  else begin
    if not_b (comp env b) then false
    else begin
    emit op_push;
    if not_b (comp ("" :: env) a) then false
    else begin
      let o =
        if string_equal op "+" then op_addint
        else if string_equal op "-" then op_subint
        else if string_equal op "*" then op_mulint
        else if string_equal op "/" then op_divint
        else if string_equal op "mod" then op_modint
        else if string_equal op "land" then op_andint
        else if string_equal op "lor" then op_orint
        else if string_equal op "lxor" then op_xorint
        else if string_equal op "lsl" then op_lslint
        else if string_equal op "lsr" then op_lsrint
        else if string_equal op "=" then op_eq
        else if string_equal op "<>" then op_neq
        else if string_equal op "<" then op_ltint
        else if string_equal op "<=" then op_leint
        else if string_equal op ">" then op_gtint
        else if string_equal op ">=" then op_geint
        else 0 - 1 in
      if o < 0 then begin comp_err := op ^^ " is not compiled yet"; false end
      else begin emit o; true end
    end
    end
  end


(* A whole phrase: compile it above the program, point the doorway at it,
   and call.  A top-level binding takes a global slot -- the same one again
   if the name is being redefined -- and a recursive one is registered
   before its body is compiled, so the body can find it. *)
let slot_for name =
  let g = glob_slot !globals name in
  if g >= 0 then g
  else begin
    let k = !next_global in
    if k >= globals_max then begin comp_err := "no globals left"; 0 - 1 end
    else begin
      next_global := k + 1;
      globals := (name, k) :: !globals;
      k
    end
  end

(* what an image in progress has collected: where each phrase's code starts
   (latest first), and the literals, which become heap blocks at the end *)
let img_frags : int list ref = ref []
let img_strs : (string * int) list ref = ref []
let img_flts : (float * int) list ref = ref []
(* image_end is typed into a session that is compiling for an image, so it
   cannot be compiled into it: run_phrase answers it itself, through this *)
let img_end_hook = ref (fun (_ : int) -> 0)

(* A literal cannot be written into the heap from here, but it can be
   handed through the doorway: a phrase of four instructions puts the
   argument into a global, and from then on the text is fetched with
   GETGLOBAL, which works inside a closure as well as out. *)
let install_literal slot (t : string) =
  let st = here () in
  emit op_acc; emit 0;
  emit op_setglobal; emit slot;
  emit op_constint; emit 0;
  emit op_return; emit 1;
  io_write prog_words_reg (here ());
  code_wr !doorway op_branch;
  patch_branch (!doorway + 1) st;
  let _ = dispatch (magic t) in ()

let install_float slot (v : float) =
  let st = here () in
  emit op_acc; emit 0;
  emit op_setglobal; emit slot;
  emit op_constint; emit 0;
  emit op_return; emit 1;
  io_write prog_words_reg (here ());
  code_wr !doorway op_branch;
  patch_branch (!doorway + 1) st;
  let _ = dispatch (magic v) in ()

let rec install_floats l = match l with
  | [] -> ()
  | v :: r ->
    (if flit_slot !float_lits v < 0 then begin
       let k = !next_global in
       next_global := k + 1;
       float_lits := (v, k) :: !float_lits;
       if !img_mode then img_flts := (v, k) :: !img_flts else install_float k v
     end);
    install_floats r

(* A function of the compiler's own, put where compiled code can call it:
   the same doorway trick as a literal, but the value handed over is a
   closure.  Afterwards the name is an ordinary global, so it is reached
   with GETGLOBAL and applied like anything else -- inside a closure as
   well as out. *)
let install_fn nm (v : int) =
  let k = !next_global in
  next_global := k + 1;
  globals := (nm, k) :: !globals;
  let st = here () in
  emit op_acc; emit 0;
  emit op_setglobal; emit k;
  emit op_constint; emit 0;
  emit op_return; emit 1;
  io_write prog_words_reg (here ());
  code_wr !doorway op_branch;
  patch_branch (!doorway + 1) st;
  let _ = dispatch v in ()

let rec install_all l = match l with
  | [] -> ()
  | t :: r ->
    (if lit_slot !literals t < 0 then begin
       let k = !next_global in
       next_global := k + 1;
       literals := (t, k) :: !literals;
       if !img_mode then img_strs := (t, k) :: !img_strs else install_literal k t
     end);
    install_all r

let run_phrase_body e name =
  comp_err := "";
  em_reset ();
  (* the literals first, each into a global of its own, before anything
     that refers to them is compiled *)
  install_all (strs_in e []);
  install_floats (floats_in e []);
  let start = here () in
  let ok = match e with
    | LetRecs (bs, Var _) ->
      (* a top-level group: every name has its global slot before any body is compiled, so
         each can reach the others, and each closure is stored in its slot *)
      let rec reserve l = match l with
        | [] -> true
        | (n, _) :: r -> if slot_for n < 0 then false else reserve r in
      let rec each l = match l with
        | [] -> true
        | (n, b) :: r ->
          if not_b (comp [] b) then false
          else begin emit op_setglobal; emit (slot_for n); each r end in
      if reserve bs && each bs then begin emit op_constint; emit 0; emit op_return; emit 1; true end
      else false
    | Let (recursive, n, bound, Var v) when string_equal v n ->
      let slot = if recursive then slot_for n else (0 - 1) in
      if comp [] bound then begin
        let slot = if slot >= 0 then slot else slot_for n in
        (* -1 is both "not allocated yet" above and "none left" from
           slot_for, so the second call has to be checked or a setglobal
           with a negative slot is emitted *)
        if slot < 0 then begin comp_err := "no globals left"; false end
        else begin
          emit op_push;
          emit op_setglobal; emit slot;
          emit op_acc; emit 0;
          emit op_return; emit 2;
          true
        end
      end else false
    | _ -> if comp [] e then begin emit op_return; emit 1; true end else false in
  let ok = if ok then comp_pending () else begin pending_bodies := []; false end in
  (* what was emitted, on the console: there is no other way to look at it *)
  (if !dump_code && ok then begin
     uart_puts "emit ["; uart_dec start; uart_puts ".."; uart_dec (here ()); uart_puts "]:";
     let i = ref start in
     while !i < here () do
       uart_putc ' '; uart_dec (code_rd !i); i := !i + 1
     done;
     uart_putc '\n'
   end);
  if not_b ok then Err !comp_err
  else if !img_mode then begin
    (* for an image: remember where this phrase's code starts, and do not run it *)
    img_frags := start :: !img_frags;
    Ok 0
  end
  else if !doorway < 0 then Err "the doorway was not found"
  else begin
    if here () >= 65500 then Err "out of code space"       (* the code window is 64K words *)
    else begin
    io_write prog_words_reg (here ());
    code_wr !doorway op_branch;
    patch_branch (!doorway + 1) start;
    Ok (dispatch 0)
    end
  end

(* image_end is typed into a session that is compiling for an image, so it
   cannot be compiled into it: it is answered here, before anything is compiled *)
let run_phrase e name =
  match e with
  | App (Var f, _) when !img_mode && string_equal f "image_end" -> Ok (!img_end_hook 0)
  | _ -> run_phrase_body e name

(* what came back is the accumulator, which for an int or a bool is the
   value itself; a function stays in its global and is not brought out *)
let float_printer = ref (fun (_ : float) -> ())
let print_compiled ty v = match repr ty with
  | TInt -> put_int v
  | TBool -> puts (if v = 1 then "true" else "false")
  (* what came back is the string itself, which arrived as the
     accumulator and needs only to be read as one again *)
  | TString -> putc '"'; puts (magic v); putc '"'
  | TFloat -> (!float_printer) (magic v)
  | TArrow (_, _) -> puts "<fun>"
  | _ -> puts "<value>"


(* ==== the RAM disk, and a filing system on it ====
   Block RAM the sequencer never touches and the VM's reset does not reach,
   so what is written here outlives a chain load: compile in one image,
   leave the results, boot another and read them back.

   The format is ours, so it is the simple one.  A header, a directory of
   fixed entries, then the data, all of it contiguous:

     0     magic "RFS1"
     4     the number of files
     8     the first free byte of data
     16    the directory: 64 entries of 32 bytes, a 24-byte name then the
           offset and the length
     2064  the data

   The directory is a fixed size so that it cannot grow into the data; 64
   files is more than a scratch disk wants.

   Nothing is ever freed: a file written twice is written twice, and the
   later entry is the one found.  That suits a scratch disk and costs
   nothing to get right. *)
let disk = 0x100000
let disk_size_reg = 0x100d
(* three bytes, not four: d32 reads 24 bits because a 32-bit word with its
   top bit set does not fit in a 31-bit integer, and a magic that cannot be
   read back means the disk is reformatted every time it is opened *)
let rfs_magic = 0x534652            (* "RFS" *)
let rfs_dir = 16
let rfs_ent = 32
let rfs_name_max = 24
let rfs_max_files = 64
let rfs_data = 16 + 64 * 32

let db i = io_read (disk + i)
let db_set i v = io_write (disk + i) v

let d32 i = db i lor (db (i + 1) lsl 8) lor (db (i + 2) lsl 16)
let d32_set i v =
  db_set i (v land 0xFF); db_set (i + 1) ((v lsr 8) land 0xFF);
  db_set (i + 2) ((v lsr 16) land 0xFF); db_set (i + 3) 0

let rfs_count () = d32 4
let rfs_free () = d32 8
(* where the next file may start after one at a, n long: on a word boundary, so that an image in the
   disk is read a word at a time by the boot sequencer *)
let rfs_next at n = (at + n + 3) land (0 - 4)

let rfs_format () =
  d32_set 0 rfs_magic; d32_set 4 0; d32_set 8 rfs_data

let rfs_ready () =
  if d32 0 = rfs_magic then true else begin rfs_format (); true end

(* the name in entry k, compared without copying it out *)
let rfs_name_is k (nm : string) =
  let base = rfs_dir + k * rfs_ent in
  let n = string_length nm in
  if n > rfs_name_max then false
  else begin
    let ok = ref true and i = ref 0 in
    while !ok && !i < n do
      if db (base + !i) <> int_of_char (string_get nm !i) then ok := false;
      i := !i + 1
    done;
    !ok && db (base + n) = 0
  end

let rec rfs_find_from k nm =
  if k < 0 then 0 - 1
  else if rfs_name_is k nm then k
  else rfs_find_from (k - 1) nm

(* the last entry with this name, so a rewritten file wins *)
let rfs_find nm = rfs_find_from (rfs_count () - 1) nm

let rfs_offset k = d32 (rfs_dir + k * rfs_ent + rfs_name_max)
let rfs_length k = d32 (rfs_dir + k * rfs_ent + rfs_name_max + 4)

(* The directory entry, written once the length is known.  A file that
   arrives over the network is streamed into the free space first and
   committed when its last chunk lands, so the two are separate: while a
   fetch is in flight it owns everything above rfs_free (), and writing a
   file from the language in the middle of one would take that space from
   under it. *)
let rfs_commit nm at len =
  let k = rfs_count () in
  let n = string_length nm in
  if k >= rfs_max_files || n > rfs_name_max then 0 - 1
  else begin
    let base = rfs_dir + k * rfs_ent in
    for i = 0 to n - 1 do db_set (base + i) (int_of_char (string_get nm i)) done;
    for i = n to rfs_name_max - 1 do db_set (base + i) 0 done;
    d32_set (base + rfs_name_max) at;
    d32_set (base + rfs_name_max + 4) len;
    d32_set 4 (k + 1);
    d32_set 8 (rfs_next at len);
    at
  end

(* a new entry, and where its data is to go; -1 if the disk is full *)
let rfs_add nm len =
  let at = rfs_free () in
  if at + len > io_read disk_size_reg then 0 - 1
  else rfs_commit nm at len

(* ---- channels ----
   open_in and open_out as the standard library has them, over the files of the RAM disk, and the disk
   itself, raw.  A file is a run of bytes in the disk with a directory entry (name, offset, length);
   nothing is buffered, so what a channel writes is in the disk at once.

   Reading: any number of channels (max_in), each a position in a file.  Writing: one channel at a time,
   because a file being written is the free space at the end of the used part of the disk and two would
   want the same bytes.  open_out creates the file, or truncates it if it is the newest, whose space it
   then takes back; an older file of that name is shadowed (the later entry is the one found) and its
   space is lost, as on any scratch disk here.  The entry's length, and the free space, are brought up to
   date by flush and close_out, so a file that is never closed has length 0.

   The exceptions are the predefined ones: End_of_file at the end of a file, Sys_error (with the text the
   system gives) for a missing file, a closed channel, a full disk.  An in_channel and an out_channel
   are ints here, a handle each; the compiler types them apart. *)
let max_in = 8
let in_off = [| 0; 0; 0; 0; 0; 0; 0; 0 |]      (* the file's data, as a disk offset *)
let in_len = [| 0; 0; 0; 0; 0; 0; 0; 0 |]
let in_pos = [| 0; 0; 0; 0; 0; 0; 0; 0 |]
let in_live = [| 0; 0; 0; 0; 0; 0; 0; 0 |]

let out_live = ref false
let out_ent = ref 0                             (* its directory entry *)
let out_at = ref 0                              (* its data, as a disk offset *)
let out_pos = ref 0                             (* where the next byte goes, from the start of the file *)
let out_len = ref 0                             (* how far the file reaches *)

let open_in (nm : string) =
  let _ = rfs_ready () in
  let k = rfs_find nm in
  if k < 0 then raise (Sys_error (nm ^^ ": No such file or directory"))
  else begin
    let h = ref (0 - 1) and i = ref 0 in
    while !h < 0 && !i < max_in do
      (if array_get in_live !i = 0 then h := !i);
      i := !i + 1
    done;
    if !h < 0 then raise (Sys_error "Too many open files")
    else begin
      array_set in_off !h (rfs_offset k); array_set in_len !h (rfs_length k);
      array_set in_pos !h 0; array_set in_live !h 1;
      !h
    end
  end

let in_chk (h : int) =
  if h < 0 || h >= max_in || array_get in_live h = 0 then raise (Sys_error "Bad file descriptor")

let close_in (h : int) = in_chk h; array_set in_live h 0

let input_char (h : int) =
  in_chk h;
  let p = array_get in_pos h in
  if p >= array_get in_len h then raise End_of_file
  else begin array_set in_pos h (p + 1); db (array_get in_off h + p) end

(* up to the next newline, which is read and not returned; End_of_file only if there was nothing to read *)
let input_line (h : int) =
  in_chk h;
  let p = array_get in_pos h and len = array_get in_len h and off = array_get in_off h in
  if p >= len then raise End_of_file
  else begin
    let e = ref p in
    while !e < len && db (off + !e) <> 10 do e := !e + 1 done;
    let n = !e - p in
    let b = create_bytes n in
    for i = 0 to n - 1 do bytes_set b i (char_of_int (db (off + p + i))) done;
    array_set in_pos h (if !e < len then !e + 1 else !e);
    bytes_to_string b
  end

let really_input_string (h : int) (n : int) =
  in_chk h;
  let p = array_get in_pos h and off = array_get in_off h in
  if n < 0 then raise (Invalid_argument "really_input_string")
  else if p + n > array_get in_len h then raise End_of_file
  else begin
    let b = create_bytes n in
    for i = 0 to n - 1 do bytes_set b i (char_of_int (db (off + p + i))) done;
    array_set in_pos h (p + n);
    bytes_to_string b
  end

let in_channel_length (h : int) = in_chk h; array_get in_len h
let pos_in (h : int) = in_chk h; array_get in_pos h
let seek_in (h : int) (p : int) =
  in_chk h;
  if p < 0 || p > array_get in_len h then raise (Sys_error "Invalid argument")
  else array_set in_pos h p

let open_out (nm : string) =
  let _ = rfs_ready () in
  let n = string_length nm in
  if !out_live then raise (Sys_error "Too many open output files")
  else if n = 0 || n > rfs_name_max then raise (Sys_error (nm ^^ ": Invalid argument"))
  else begin
    let k = rfs_find nm and cnt = rfs_count () in
    (if k >= 0 && k = cnt - 1 && rfs_next (rfs_offset k) (rfs_length k) = rfs_free () then begin
       out_ent := k; out_at := rfs_offset k;
       d32_set (rfs_dir + k * rfs_ent + rfs_name_max + 4) 0;
       d32_set 8 !out_at
     end else begin
       let at = rfs_commit nm (rfs_next (rfs_free ()) 0) 0 in      (* on a word boundary, whatever came before *)
       if at < 0 then raise (Sys_error (nm ^^ ": No space left on device"))
       else begin out_ent := cnt; out_at := at end
     end);
    out_pos := 0; out_len := 0; out_live := true;
    1
  end

let out_chk (h : int) =
  if h <> 1 || not !out_live then raise (Sys_error "Bad file descriptor")

let out_room (n : int) =
  if !out_at + !out_pos + n > io_read disk_size_reg then raise (Sys_error "No space left on device")

let out_byte (c : int) =
  db_set (!out_at + !out_pos) c;
  out_pos := !out_pos + 1;
  if !out_pos > !out_len then out_len := !out_pos

let output_char (h : int) (c : int) = out_chk h; out_room 1; out_byte c

let output_string (h : int) (s : string) =
  out_chk h;
  let n = string_length s in
  out_room n;
  for i = 0 to n - 1 do out_byte (int_of_char (string_get s i)) done

let flush (h : int) =
  out_chk h;
  d32_set (rfs_dir + !out_ent * rfs_ent + rfs_name_max + 4) !out_len;
  d32_set 8 (rfs_next !out_at !out_len)

let close_out (h : int) = flush h; out_live := false

(* give a file up unwritten: its entry goes, and the space with it *)
let discard_out (h : int) =
  out_chk h;
  d32_set 4 !out_ent; d32_set 8 !out_at;
  out_live := false

let seek_out (h : int) (p : int) =
  out_chk h;
  if p < 0 then raise (Sys_error "Invalid argument") else out_pos := p

let pos_out (h : int) = out_chk h; !out_pos
let out_channel_length (h : int) = out_chk h; !out_len

let file_exists (nm : string) = let _ = rfs_ready () in rfs_find nm >= 0

(* the disk, raw: a byte at an offset from its start *)
let disk_size (_u : int) = io_read disk_size_reg
let disk_get (i : int) =
  if i < 0 || i >= io_read disk_size_reg then raise (Invalid_argument "disk_get") else db i
let disk_set (i : int) (v : int) =
  if i < 0 || i >= io_read disk_size_reg then raise (Invalid_argument "disk_set") else db_set i (v land 0xFF)

(* a file as a string in and a string out, for write_file and read_file: -1 or "" if it could not be *)
let rfs_put nm (v : string) =
  try
    let oc = open_out nm in
    output_string oc v; close_out oc;
    string_length v
  with Sys_error _ -> 0 - 1

let rfs_get nm =
  try
    let ic = open_in nm in
    let v = really_input_string ic (in_channel_length ic) in
    close_in ic;
    Ok v
  with Sys_error m -> Err m

(* ---- building an image ----
   image_begin "name" starts one: phrases compiled from then on go into it and
   are not run.  image_end () finishes: a main that calls each phrase's code in
   turn, the string literals as heap blocks, the globals, the header with its
   CRC, and the directory entry that makes it a file.  What it writes is the
   layout of tools/mkvmimage.py, which the boot sequencer loads. *)
(* the eight bytes of an IEEE double, low word first and little-endian, worked out by arithmetic:
   the bits cannot be read from a float here, which is one machine word on the host that runs
   this and two on the processor.  Zero is eight zero bytes; infinities and NaNs do not come up. *)
let float_bytes (f : float) =
  let b = [| 0; 0; 0; 0; 0; 0; 0; 0 |] in
  (if not_b (flt_eq f 0.0) then begin
     let neg = flt_lt f 0.0 in
     let a = if neg then ~-. f else f in
     let e = ref 0 and m = ref a in
     while flt_le 2.0 !m do m := !m /. 2.0; e := !e + 1 done;
     while flt_lt !m 1.0 do m := !m *. 2.0; e := !e - 1 done;
     let frac = (!m -. 1.0) *. 4503599627370496.0 in                  (* the 52 bits of the fraction *)
     let hi20 = int_of_float (frac /. 4294967296.0) in
     let lo = frac -. float_of_int hi20 *. 4294967296.0 in
     let lo_hi = int_of_float (lo /. 65536.0) in
     let lo_lo = int_of_float (lo -. float_of_int lo_hi *. 65536.0) in
     let biased = !e + 1023 in
     array_set b 0 (lo_lo land 255); array_set b 1 (lo_lo lsr 8);
     array_set b 2 (lo_hi land 255); array_set b 3 (lo_hi lsr 8);
     array_set b 4 (hi20 land 255); array_set b 5 ((hi20 lsr 8) land 255);
     array_set b 6 (((biased land 15) lsl 4) lor ((hi20 lsr 16) land 15));
     array_set b 7 ((if neg then 128 else 0) lor (biased lsr 4))
   end);
  b

let img_name = ref ""
let sv_cp = ref 0
let sv_next = ref 0
let sv_globals : (string * int) list ref = ref []
let sv_lits : (string * int) list ref = ref []
let sv_flts : (float * int) list ref = ref []

let img_oc = ref 0

(* the image is a file being written: the channel makes its entry and says where its data is, the code
   and the rest go into that space by raw writes as the compilation goes, and image_end gives the
   file its length. *)
let img_begin (nm : string) =
  let oc = (try open_out nm with Sys_error _ -> 0 - 1) in
  if oc < 0 then 0 - 1
  else begin
  img_oc := oc;
  img_name := nm;
  img_at := !out_at;
  sv_cp := !cp; sv_next := !next_global; sv_globals := !globals;
  sv_lits := !literals; sv_flts := !float_lits;
  globals := []; literals := []; float_lits := []; next_global := 12;   (* 0..11 are the predefined exceptions *)
  img_frags := []; img_strs := []; img_flts := [];
  img_mode := true;
  cp := 0;
  em_reset ();
  emit op_branch; emit 0;                       (* word 0 jumps to main, which comes last *)
  0
  end

(* CRC-16-CCITT (0x1021, from 0xFFFF), a byte at a time: 16 bits fit an int *)
let crc16_byte crc b =
  let c = ref (crc lxor (b lsl 8)) in
  for _i = 0 to 7 do
    c := (if !c land 0x8000 <> 0 then ((!c lsl 1) lxor 0x1021) land 0xFFFF else (!c lsl 1) land 0xFFFF)
  done;
  !c

let img_end (_n : int) =
  let main = here () in
  code_wr 0 op_branch; patch_branch 1 main;
  (* the oldest phrase first: the list is latest first *)
  let rec calls l = match l with
    | [] -> ()
    | start :: r ->
      calls r;
      emit op_constint; emit 0; emit op_push;
      emit op_closure; emit 0;
      let p = here () in emit 0;
      patch_branch p start;
      emit op_apply1 in
  calls !img_frags;
  (* finished: ask for the loader back (I/O 0x100f), which restarts the resident program with the RAM disk as
     it is; where there is no such register the STOP that follows halts the machine as it always did *)
  emit op_constint; emit 0; emit op_push;
  emit op_constint; emit 0x100f;
  emit 94; emit 404;                          (* C_CALL2 vm_io_write *)
  emit op_stop;
  let code_words = here () in
  let base = !img_at + 32 in
  let hbase = base + 4 * code_words in
  let hw = ref 0 in
  let ptrs : (int * int) list ref = ref [] in
  (* each string: a header, then its bytes four to a word, the last byte of the
     last word saying how much of it is padding, as OCaml lays them out *)
  let put_string t =
    let len = string_length t in
    let nw = len / 4 + 1 in
    let at = !hw in
    img_wr32 (hbase + 4 * at) ((nw lsl 16) lor 252);
    hw := at + 1;
    for w = 0 to nw - 1 do
      let byte i =
        if i < len then int_of_char (string_get t i)
        else if i = 4 * nw - 1 then 4 * nw - 1 - len
        else 0 in
      img_put4 (hbase + 4 * !hw) (byte (4 * w)) (byte (4 * w + 1)) (byte (4 * w + 2)) (byte (4 * w + 3));
      hw := !hw + 1
    done;
    at in
  let rec heap l = match l with
    | [] -> ()
    | (t, slot) :: r ->
      let at = put_string t in
      ptrs := (slot, at lsl 2) :: !ptrs;
      heap r in
  (* the predefined exceptions, globals 0..11, which is where the machine looks for the ones it
     raises itself: a block of tag 248 holding the name and an id, -1, -2, ... as ocamlc's are *)
  let rec exns l k = match l with
    | [] -> ()
    | nm :: r ->
      let s_at = put_string nm in
      let at = !hw in
      img_wr32 (hbase + 4 * at) ((2 lsl 16) lor 248);
      img_wr32 (hbase + 4 * (at + 1)) (s_at lsl 2);
      img_wr32 (hbase + 4 * (at + 2)) (2 * (0 - (k + 1)) + 1);
      hw := at + 3;
      ptrs := (k, at lsl 2) :: !ptrs;
      exns r (k + 1) in
  exns ["Out_of_memory"; "Sys_error"; "Failure"; "Invalid_argument"; "End_of_file"; "Division_by_zero";
        "Not_found"; "Match_failure"; "Stack_overflow"; "Sys_blocked_io"; "Assert_failure";
        "Undefined_recursive_module"] 0;
  heap !img_strs;
  (* a float is a block of tag 253 with its two words, low first *)
  let rec floats l = match l with
    | [] -> ()
    | (v, slot) :: r ->
      let b = float_bytes v in
      let at = !hw in
      img_wr32 (hbase + 4 * at) ((2 lsl 16) lor 253);
      img_put4 (hbase + 4 * (at + 1)) (array_get b 0) (array_get b 1) (array_get b 2) (array_get b 3);
      img_put4 (hbase + 4 * (at + 2)) (array_get b 4) (array_get b 5) (array_get b 6) (array_get b 7);
      hw := at + 3;
      ptrs := (slot, at lsl 2) :: !ptrs;
      floats r in
  floats !img_flts;
  let nglob = !next_global in
  let gbase = hbase + 4 * !hw in
  let total = gbase + 4 * nglob - !img_at in
  if !img_at + total > io_read disk_size_reg then begin
    puts "image too big: "; put_int code_words; puts " code words, "; put_int !hw; puts " heap words, ";
    put_int nglob; puts " globals; "; put_int (!img_at + total); puts " bytes against a disk of "; put_int (io_read disk_size_reg); newline ();
    img_mode := false;
    cp := !sv_cp; next_global := !sv_next; globals := !sv_globals;
    literals := !sv_lits; float_lits := !sv_flts;
    em_reset ();
    discard_out !img_oc;
    0 - 1
  end else begin
    for g = 0 to nglob - 1 do img_wr32 (gbase + 4 * g) 1 done;       (* int 0 *)
    let rec place l = match l with
      | [] -> ()
      | (slot, p) :: r -> img_wr32 (gbase + 4 * slot) p; place r in
    place !ptrs;
    (* the CRC covers every byte after the header *)
    let crc = ref 0xFFFF in
    for i = base to gbase + 4 * nglob - 1 do crc := crc16_byte !crc (io_read (0x100000 + i)) done;
    let h = !img_at in
    img_put4 h 0x4F 0x43 0x56 0x4D;                                  (* "OCVM" *)
    img_wr32 (h + 4) 1;
    img_wr32 (h + 8) code_words;
    img_wr32 (h + 12) !hw;
    img_wr32 (h + 16) nglob;
    img_wr32 (h + 20) 0;                                             (* primitive digest: the runtime's own *)
    img_wr32 (h + 24) !crc;
    img_wr32 (h + 28) 0;
    img_mode := false;
    cp := !sv_cp; next_global := !sv_next; globals := !sv_globals;
    literals := !sv_lits; float_lits := !sv_flts;
    em_reset ();
    out_len := total;
    close_out !img_oc;
    total
  end

let () = img_end_hook := img_end

(* Chain load the image in a file on the RAM disk: the boot sequencer takes the
   byte offset in the disk where the image's header is (0x100e), replaces the
   program with it and restarts the machine; the disk is left as it is, so what
   was compiled is still there to be read.  Returns only if there is no such file. *)
let boot_disk = 0x100e
(* Chain load a file on the RAM disk.  Its header (tools/mkvmimage.py's layout) is checked and the
   sequencer is told where the code, heap and globals are, in words from the start of the disk; then 0x100e
   asks it to load them, replace this program and start the machine again.  The disk stays as it is. *)
let boot_file (nm : string) =
  let _ = rfs_ready () in
  let k = rfs_find nm in
  if k < 0 then 0 - 1
  else begin
    let o = rfs_offset k in
    let code = d32 (o + 8) and heap = d32 (o + 12) and globals = d32 (o + 16) in
    if rfs_length k < 32 || o land 3 <> 0 || db o <> 0x4F || db (o + 1) <> 0x43 || db (o + 2) <> 0x56 || db (o + 3) <> 0x4D
       || code > 65535 || heap > 24576 || globals > 8192
       || 32 + 4 * (code + heap + globals) > rfs_length k then 0 - 2
    else begin
      let w = (o + 32) / 4 in
      io_write 0x1010 code; io_write 0x1011 heap; io_write 0x1012 globals;
      io_write 0x1013 w; io_write 0x1014 (w + code); io_write 0x1015 (w + code + heap);
      io_write boot_disk o;
      0
    end
  end

(* ---- NFS, straight into the RAM disk ----
   ONC RPC over UDP: portmap for mountd, mount for the root handle,
   portmap for nfsd, look the name up in it, then read it in chunks.  Each
   chunk goes to the disk as it arrives rather than to a buffer in the
   staging RAM -- io/replnet.ml read into 0x30000, one byte past what
   io_is_stage decodes, which staging going back to 128 KiB left stranded
   and nothing complained about -- so what arrives is a file in the filing
   system and run_file can compile it.

   Asynchronous, as the loader is: the replies come back in a later poll.
   nfs_fetch starts a load and nfs_done reports on it.  Pumping the network
   from inside the builtin instead would re-enter the receive window under
   whatever delivered the command, which is exactly the hazard that made
   re-entrant output draining unsafe. *)
(* >>> io/nfs.ml *)
let nfs_lport = 1010            (* privileged: an export without "insecure" insists *)
let pmap_port = 111
let nfs_chunk = 1024
let rpc_pmap = 100000
let rpc_mount = 100005
let rpc_nfs = 100003

(* its own address and MAC: the boot server is not usually the file server *)
let nfs_ip = [| 0; 0; 0; 0 |]
let nfs_mac = [| 0; 0; 0; 0; 0; 0 |]

(* where the file's bytes go, set by the host: begin (the file is found), room (bytes available), put (offset, byte),
   finish (the length: false if it cannot be kept) *)
let nfs_dest_begin = ref (fun (_u : int) -> ())
let nfs_dest_room = ref (fun (_u : int) -> 0)
let nfs_dest_put = ref (fun (_o : int) (_v : int) -> ())
let nfs_dest_finish = ref (fun (_n : int) -> false)

let xp = ref 42                 (* the write cursor into the TX window *)
let rp = ref 0                  (* and the read cursor into the RX window *)

let x32 v =
  tx !xp ((v lsr 24) land 0xFF); tx (!xp + 1) ((v lsr 16) land 0xFF);
  tx (!xp + 2) ((v lsr 8) land 0xFF); tx (!xp + 3) (v land 0xFF);
  xp := !xp + 4

let xpad n =
  let pad = (4 - (n land 3)) land 3 in
  for i = 0 to pad - 1 do tx (!xp + n + i) 0 done;
  xp := !xp + n + pad

(* the characters a..b-1 of s, as an XDR string *)
let xname s a b =
  let n = b - a in
  x32 n;
  for i = 0 to n - 1 do tx (!xp + i) (int_of_char (string_get s (a + i))) done;
  xpad n

let xstr s = xname s 0 (string_length s)

(* the file handle mount gave us (then each directory on the way), and the one for the file itself *)
let fh_root = create_bytes 64
let fh_root_len = ref 0
let fh_file = create_bytes 64
let fh_file_len = ref 0

let xfh b n =
  x32 n;
  for i = 0 to n - 1 do tx (!xp + i) (int_of_char (bytes_get b i)) done;
  xpad n

let r32 () =
  let v = (rx !rp lsl 24) lor (rx (!rp + 1) lsl 16)
          lor (rx (!rp + 2) lsl 8) lor rx (!rp + 3) in
  rp := !rp + 4; v

(* The xid stays under 2^24 so that reading it back cannot overflow a
   31-bit int, which a word with its top bit set would. *)
let nfs_xid = ref 0x515100

let rpc_call prog vers proc =
  nfs_xid := (!nfs_xid + 1) land 0xFFFFFF;
  xp := 42;
  x32 !nfs_xid; x32 0; x32 2; x32 prog; x32 vers; x32 proc;
  (* AUTH_UNIX with an empty machine name, uid and gid 0 *)
  x32 1; x32 20; x32 0; x32 0; x32 0; x32 0; x32 0;
  x32 0; x32 0                                    (* AUTH_NULL verifier *)

let nfs_udp dport payload_len =
  let len = 42 + payload_len in
  for i = 0 to 5 do tx i (array_get nfs_mac i); tx (6 + i) (mac i) done;
  tx 12 0x08; tx 13 0x00;
  tx 14 0x45; tx 15 0; tx 16 ((len - 14) lsr 8); tx 17 ((len - 14) land 0xFF);
  for i = 18 to 21 do tx i 0 done;
  tx 22 64; tx 23 17; tx 24 0; tx 25 0;
  for i = 0 to 3 do tx (26 + i) (ip i); tx (30 + i) (array_get nfs_ip i) done;
  let s = ip_checksum 14 20 in
  tx 24 (s lsr 8); tx 25 (s land 0xFF);
  tx 34 (nfs_lport lsr 8); tx 35 (nfs_lport land 0xFF);
  tx 36 (dport lsr 8); tx 37 (dport land 0xFF);
  tx 38 ((8 + payload_len) lsr 8); tx 39 ((8 + payload_len) land 0xFF);
  tx 40 0; tx 41 0;
  eth_send len

let nfs_send dport = nfs_udp dport (!xp - 42)

let nfs_arp_request () =
  for i = 0 to 5 do tx i 0xff; tx (6 + i) (mac i) done;
  tx 12 0x08; tx 13 0x06;
  tx 14 0x00; tx 15 0x01; tx 16 0x08; tx 17 0x00; tx 18 6; tx 19 4;
  tx 20 0x00; tx 21 0x01;
  for i = 0 to 5 do tx (22 + i) (mac i); tx (32 + i) 0 done;
  for i = 0 to 3 do tx (28 + i) (ip i); tx (38 + i) (array_get nfs_ip i) done;
  eth_send 42

(* the reply's header: the xid we sent, accepted, and the call succeeded *)
let rpc_reply_ok len =
  let udp = 34 in
  if len < udp + 8 + 24 then false
  else begin
    rp := udp + 8;
    let xid = r32 () in
    let mtype = r32 () in
    let rstat = r32 () in
    if xid <> !nfs_xid || mtype <> 1 || rstat <> 0 then false
    else begin
      let _flavor = r32 () in
      let vlen = r32 () in
      rp := !rp + ((vlen + 3) / 4) * 4;
      r32 () = 0                                   (* accept_stat = SUCCESS *)
    end
  end

let nfs_idle = 0
let nfs_arping = 1
let nfs_pmap_mnt = 2
let nfs_mounting = 3
let nfs_pmap_nfs = 4
let nfs_looking = 5
let nfs_reading = 6

let nfs_state = ref nfs_idle
let nfs_deadline = ref 0
let nfs_tries = ref 0
let mnt_port = ref 0
let nfsd_port = ref 2049
let nfs_off = ref 0              (* bytes taken so far *)
let nfs_export = ref ""
let nfs_path = ref ""            (* "dir/dir/file" below the export *)
let nfs_cs = ref 0               (* the component being looked up: nfs_path from nfs_cs to nfs_ce *)
let nfs_ce = ref 0
let nfs_result = ref (0 - 1)     (* -1 running, -2 failed, else the length *)

let nfs_find_end () =
  let e = ref !nfs_cs in
  let n = string_length !nfs_path in
  while !e < n && string_get !nfs_path !e <> '/' do e := !e + 1 done;
  nfs_ce := !e

let send_getport prog vers =
  rpc_call rpc_pmap 2 3;
  x32 prog; x32 vers; x32 17; x32 0;
  nfs_send pmap_port

let send_mnt () =
  rpc_call rpc_mount 3 1;
  xstr !nfs_export;
  nfs_send !mnt_port

let send_lookup () =
  rpc_call rpc_nfs 3 3;
  xfh fh_root !fh_root_len;
  xname !nfs_path !nfs_cs !nfs_ce;
  nfs_send !nfsd_port

let send_read () =
  rpc_call rpc_nfs 3 6;
  xfh fh_file !fh_file_len;
  x32 0; x32 !nfs_off;        (* a 64-bit offset, high word first *)
  x32 nfs_chunk;
  nfs_send !nfsd_port

(* a post_op_attr: a flag, and the 84 bytes of attributes if it is set *)
let skip_attr () = if r32 () = 1 then rp := !rp + 84

let take_fh b =
  let n = r32 () in
  if n > 64 then 0
  else begin
    for i = 0 to n - 1 do bytes_set b i (char_of_int (rx (!rp + i))) done;
    rp := !rp + ((n + 3) / 4) * 4;
    n
  end

let nfs_fail why =
  nfs_state := nfs_idle;
  nfs_result := 0 - 2;
  uart_puts "nfs: "; uart_puts why; uart_putc '\n'

let nfs_step () =
  nfs_tries := 0;
  nfs_deadline := now () + 1500

let nfs_reply len =
  if not_b (rpc_reply_ok len) then ()
  else if !nfs_state = nfs_pmap_mnt then begin
    mnt_port := r32 ();
    if !mnt_port = 0 then nfs_fail "no mountd"
    else begin nfs_state := nfs_mounting; send_mnt (); nfs_step () end
  end
  else if !nfs_state = nfs_mounting then begin
    if r32 () <> 0 then nfs_fail "mount refused"
    else begin
      fh_root_len := take_fh fh_root;
      if !fh_root_len = 0 then nfs_fail "bad handle"
      else begin nfs_state := nfs_pmap_nfs; send_getport rpc_nfs 3; nfs_step () end
    end
  end
  else if !nfs_state = nfs_pmap_nfs then begin
    let p = r32 () in
    nfsd_port := (if p = 0 then 2049 else p);
    nfs_state := nfs_looking; send_lookup (); nfs_step ()
  end
  else if !nfs_state = nfs_looking then begin
    if r32 () <> 0 then nfs_fail "no such file"
    else begin
      fh_file_len := take_fh fh_file;
      if !fh_file_len = 0 then nfs_fail "bad handle"
      else if !nfs_ce < string_length !nfs_path then begin
        (* a directory on the way: it becomes the one to look in, and the next component is looked up *)
        for i = 0 to 63 do bytes_set fh_root i (bytes_get fh_file i) done;
        fh_root_len := !fh_file_len;
        nfs_cs := !nfs_ce + 1;
        nfs_find_end ();
        send_lookup (); nfs_step ()
      end else begin
        nfs_off := 0;
        (!nfs_dest_begin) 0;
        nfs_state := nfs_reading; send_read (); nfs_step ()
      end
    end
  end
  else if !nfs_state = nfs_reading then begin
    if r32 () <> 0 then nfs_fail "read refused"
    else begin
      skip_attr ();
      let _count = r32 () in
      let eof = r32 () in
      let n = r32 () in
      if !nfs_off + n > (!nfs_dest_room) 0 then
        nfs_fail "disk full"
      else begin
        for i = 0 to n - 1 do
          (!nfs_dest_put) (!nfs_off + i) (rx (!rp + i))
        done;
        nfs_off := !nfs_off + n;
        if eof <> 0 || n = 0 then begin
          nfs_state := nfs_idle;
          if not_b ((!nfs_dest_finish) !nfs_off) then
            nfs_fail "disk full"
          else begin
            nfs_result := !nfs_off;
            uart_puts "nfs: "; uart_dec !nfs_off; uart_puts " bytes\n"
          end
        end else begin send_read (); nfs_step () end
      end
    end
  end

let nfs_tick () =
  if !nfs_state <> nfs_idle && now () > !nfs_deadline then begin
    nfs_tries := !nfs_tries + 1;
    if !nfs_tries > 4 then nfs_fail "no answer"
    else begin
      (if !nfs_state = nfs_arping then nfs_arp_request ()
       else if !nfs_state = nfs_pmap_mnt then send_getport rpc_mount 3
       else if !nfs_state = nfs_mounting then send_mnt ()
       else if !nfs_state = nfs_pmap_nfs then send_getport rpc_nfs 3
       else if !nfs_state = nfs_looking then send_lookup ()
       else send_read ());
      nfs_deadline := now () + 1500
    end
  end

let nfs_arp_reply len =
  if !nfs_state = nfs_arping && len >= 42 && rx 21 = 2
     && rx 28 = array_get nfs_ip 0 && rx 29 = array_get nfs_ip 1
     && rx 30 = array_get nfs_ip 2 && rx 31 = array_get nfs_ip 3 then begin
    for i = 0 to 5 do array_set nfs_mac i (rx (22 + i)) done;
    nfs_state := nfs_pmap_mnt;
    send_getport rpc_mount 3;
    nfs_step ()
  end

(* start fetching export + path, the server being nfs_ip; the host has checked it can *)
let nfs_launch export path =
  nfs_export := export; nfs_path := path;
  nfs_cs := 0; nfs_find_end ();
  nfs_result := 0 - 1;
  nfs_state := nfs_arping;
  nfs_arp_request ();
  nfs_step ()
(* <<< io/nfs.ml *)

(* the file goes to the RAM disk, as a file of that name *)
let nfs_at = ref 0               (* where its bytes are going on the disk *)
let () =
  nfs_dest_begin := (fun (_u : int) -> nfs_at := rfs_free ());
  nfs_dest_room := (fun (_u : int) -> io_read disk_size_reg - !nfs_at);
  (* straight to the disk: no copy in staging, and nothing to move afterwards -- the bytes are already where the file will live *)
  nfs_dest_put := (fun (o : int) (v : int) -> db_set (!nfs_at + o) v);
  nfs_dest_finish := (fun (n : int) -> rfs_commit !nfs_path !nfs_at n >= 0)

(* what the language sees *)
(* "192.168.1.106" as one argument: the compiler applies at most two at a
   time, so four octets could not be passed even though they would read
   better as numbers *)
let nfs_set_server (a : string) =
  let oct = ref 0 and k = ref 0 and ok = ref true in
  for i = 0 to string_length a - 1 do
    let c = int_of_char (string_get a i) in
    if c = 46 then begin
      (if !k < 4 then array_set nfs_ip !k !oct);
      k := !k + 1; oct := 0
    end
    else if c >= 48 && c <= 57 then oct := !oct * 10 + (c - 48)
    else ok := false
  done;
  (if !k < 4 then array_set nfs_ip !k !oct);
  if !ok && !k = 3 then begin
    for i = 0 to 5 do array_set nfs_mac i 0 done; 1
  end else begin
    for i = 0 to 3 do array_set nfs_ip i 0 done; 0
  end

let nfs_start export f =
  if not_b (bound ()) then 0
  else if !nfs_state <> nfs_idle then 0
  else if array_get nfs_ip 0 = 0 then 0
  else if string_length f > rfs_name_max then 0
  else begin
    let _ = rfs_ready () in
    nfs_launch export f;
    1
  end

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

let () = float_printer := print_float
let rec print_value v = match v with
  | VInt n -> put_int n
  | VFloat f -> print_float f
  | VBool b -> puts (if b then "true" else "false")
  (* printed back the way it would be written, so that a newline in a
     string does not come out as a line break in the middle of the value *)
  | VStr s ->
    putc '"';
    for i = 0 to string_length s - 1 do
      let c = int_of_char (string_get s i) in
      if c = 34 || c = 92 then begin putc '\\'; putc (char_of_int c) end
      else if c = 10 then begin putc '\\'; putc 'n' end
      else if c = 13 then begin putc '\\'; putc 'r' end
      else if c = 9 then begin putc '\\'; putc 't' end
      else putc (char_of_int c)
    done;
    putc '"'
  | VClosure _ -> puts "<fun>"
  | VBuiltin _ -> puts "<fun>"
  | VTuple l -> putc '('; print_commas l; putc ')'
  | VRec l -> puts "{ "; print_fields l; puts " }"
  | VCon (c, []) when string_equal c "[]" -> puts "[]"
  | VCon (c, [_; _]) when string_equal c "::" ->
    putc '['; print_items v; putc ']'
  | VCon (c, []) -> puts c
  | VCon (c, [a]) -> puts c; putc ' '; print_arg a
  | VCon (c, l) -> puts c; putc ' '; putc '('; print_commas l; putc ')'

and print_fields l = match l with
  | [] -> ()
  | [(f, v)] -> puts f; puts " = "; print_value v
  | (f, v) :: r -> puts f; puts " = "; print_value v; puts "; "; print_fields r

and print_commas l = match l with
  | [] -> ()
  | [v] -> print_value v
  | v :: r -> print_value v; puts ", "; print_commas r

(* the spine of a list, without the brackets *)
and print_items v = match v with
  | VCon (c, [h; t]) when string_equal c "::" ->
    print_value h;
    (match t with
     | VCon (d, []) when string_equal d "[]" -> ()
     | _ -> puts "; "; print_items t)
  | _ -> ()

(* a constructor's argument needs parentheses if it is itself applied *)
and print_arg v = match v with
  | VCon (c, _ :: _) when not_b (string_equal c "::") ->
    putc '('; print_value v; putc ')'
  | _ -> print_value v

(* The pervasives: a value and a type for each, so that "sin 0.5" needs no
   declaration and "sin 1" is refused before it runs. *)
let tin  = TCon ("in_channel", [])
let tout = TCon ("out_channel", [])
let f2f  = TArrow (TFloat, TFloat)
let ff2f = TArrow (TFloat, TArrow (TFloat, TFloat))

let builtins =
  (* sqrt and abs_float are the FPU's own, emitted as primitives; the
     series functions that used to sit beside them -- exp, log, sin, cos,
     tan, asin, acos, atan -- were only ever reachable from the
     tree-walker, so they went with it and come back as source over NFS. *)
  [ ("sqrt", 1, f2f); ("abs_float", 1, f2f);

    ("float_of_int", 1, TArrow (TInt, TFloat));
    ("int_of_float", 1, TArrow (TFloat, TInt));
    (* the RAM disk: what is written here outlives a chain load *)
    ("write_file", 2, TArrow (TString, TArrow (TString, TInt)));
    ("read_file", 1, TArrow (TString, TString));
    ("run_file", 1, TArrow (TString, TInt));
    ("files", 1, TArrow (TInt, TInt));
    ("nfs_server", 1, TArrow (TString, TInt));
    ("nfs_fetch", 2, TArrow (TString, TArrow (TString, TInt)));
    ("nfs_done", 1, TArrow (TInt, TInt));
    ("boot_file", 1, TArrow (TString, TInt));
    (* channels over the RAM disk's files (see the channel layer), and the disk itself, raw *)
    ("open_in", 1, TArrow (TString, tin)); ("open_in_bin", 1, TArrow (TString, tin));
    ("open_out", 1, TArrow (TString, tout)); ("open_out_bin", 1, TArrow (TString, tout));
    ("close_in", 1, TArrow (tin, TInt)); ("close_out", 1, TArrow (tout, TInt));
    ("input_char", 1, TArrow (tin, TInt)); ("input_byte", 1, TArrow (tin, TInt));
    ("input_line", 1, TArrow (tin, TString));
    ("really_input_string", 2, TArrow (tin, TArrow (TInt, TString)));
    ("in_channel_length", 1, TArrow (tin, TInt)); ("pos_in", 1, TArrow (tin, TInt));
    ("seek_in", 2, TArrow (tin, TArrow (TInt, TInt)));
    ("output_char", 2, TArrow (tout, TArrow (TInt, TInt)));
    ("output_byte", 2, TArrow (tout, TArrow (TInt, TInt)));
    ("output_string", 2, TArrow (tout, TArrow (TString, TInt)));
    ("flush", 1, TArrow (tout, TInt));
    ("out_channel_length", 1, TArrow (tout, TInt)); ("pos_out", 1, TArrow (tout, TInt));
    ("seek_out", 2, TArrow (tout, TArrow (TInt, TInt)));
    ("file_exists", 1, TArrow (TString, TBool));
    ("disk_size", 1, TArrow (TInt, TInt));
    ("disk_get", 1, TArrow (TInt, TInt));
    ("disk_set", 2, TArrow (TInt, TArrow (TInt, TInt)));
    ("image_begin", 1, TArrow (TString, TInt));
    ("image_end", 1, TArrow (TInt, TInt)) ]

let rec builtin_values l = match l with
  | [] -> []
  | (n, arity, _) :: rest -> (n, VBuiltin (n, arity, [])) :: builtin_values rest

let rec builtin_types l = match l with
  | [] -> []
  | (n, _, t) :: rest -> (n, Forall ([], t)) :: builtin_types rest

let rec builtin_types_names l = match l with
  | [] -> []
  | (n, _, _) :: rest -> (n, (0, 0, 0)) :: builtin_types_names rest

let session = ref (builtin_values builtins)


(* A name used but never bound is an error in the definition, not in the
   call that finds out: OCaml says so when the let is typed, and a mini-ML
   that waits until the closure runs gives "unbound fact" to someone who
   has just seen "val fact = <fun>".  This walks an expression for the
   first free name, with the session's own bindings counted as bound. *)
(* "ms" is the one name the evaluator answers for without a binding *)
(* The session's types, beside its values.  A top-level binding is parsed as
   "let x = e in x", so its scheme is generalised from the right-hand side
   and kept here; everything else is inferred against what is already bound. *)
let type_session : (string * scheme) list ref = ref (builtin_types builtins)

let infer_line e = match e with
  | LetRecs (bs, Var first) ->
    let rec fresh l = match l with
      | [] -> []
      | (n, _) :: r -> (n, fresh_tv ()) :: fresh r in
    let tvs = fresh bs in
    let rec extend l e = match l with
      | [] -> e
      | (n, t) :: r -> (n, Forall ([], t)) :: extend r e in
    let inner = extend tvs !type_session in
    let rec tv_of n l = match l with
      | [] -> fresh_tv ()
      | (m, t) :: r -> if string_equal m n then t else tv_of n r in
    let rec go l = match l with
      | [] -> Ok ()
      | (n, b) :: r ->
        (match infer inner b with
         | Err m -> Err m
         | Ok tb -> match unify (tv_of n tvs) tb with Err m -> Err m | Ok () -> go r) in
    (match go bs with
     | Err m -> Err m
     | Ok () ->
       (* every name of the group is known to the session from now on *)
       let rec reg l = match l with
         | [] -> ()
         | (n, _) :: r -> type_session := (n, generalize !type_session (tv_of n tvs)) :: !type_session; reg r in
       reg bs;
       Ok (first, generalize !type_session (tv_of first tvs), tv_of first tvs))
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

(* a line that starts with # is a directive, not a phrase:
     #image out.img src.ml    compile src.ml to an image on the RAM disk named out.img
   It is read here, so it works wherever the compiler runs -- on the host, where there is no doorway,
   as well as on the machine -- and the work is the same as image_begin, run_file and image_end. *)
let src_echo = ref false          (* name each phrase before it is compiled: for a long source *)

(* where the first thing on the line is: blanks before a directive's # are nothing, as they are in OCaml *)
let lead_blanks () =
  let k = ref 0 in
  while !k < !line_len && char_at !k = 32 do k := !k + 1 done;
  !k

let words_of_line () =
  let acc = ref [] and i = ref (lead_blanks () + 1) in
  while !i < !line_len do
    if char_at !i = 32 then i := !i + 1
    else begin
      let j = ref !i in
      while !j < !line_len && char_at !j <> 32 do j := !j + 1 done;
      acc := substring !i !j :: !acc;
      i := !j
    end
  done;
  rev_acc !acc []

let freeze_on_oob = ref false

let directive () =
  match words_of_line () with
  | [w; out; src] when string_equal w "image" ->
    if img_begin out < 0 then begin puts "error: cannot create "; puts out; newline () end
    else begin
      src_echo := false;
      let n = !fs_run src in
      src_echo := false;
      newline ();
      let size = img_end 0 in
      puts "image "; puts out; puts ": "; put_int n; puts " phrases, ";
      (if size < 0 then puts "not written" else begin put_int size; puts " bytes" end);
      newline ()
    end
  | [w] when string_equal w "freeze" ->
    (* bring-up: the next bounds error stops the machine in a loop that allocates nothing, so that its memories can be
       read back over JTAG as they were *)
    freeze_on_oob := true; puts "freeze on the first bounds error"; newline ()
  | _ -> puts "error: unknown directive"; newline ()

let evaluate_line_unsafe () =
  if lead_blanks () < !line_len && char_at (lead_blanks ()) = 35 then directive ()
  else if !line_len > 0 then begin
    match tokenize () with
    | Err m -> puts "error: "; puts m; newline ()
    | Ok toks when (match toks with t :: _ -> is_kw t "external" | [] -> false) ->
      (match parse_external (match toks with _ :: r -> r | [] -> []) with
       | Err m -> puts "error: "; puts m; newline ()
       | Ok (name, te, p, rest) ->
         match rest with
         | _ :: _ -> puts "error: unexpected input at the end"; newline ()
         | [] ->
           let known = string_equal name "" || string_equal name "ref"
                       || (match find_ext name (builtin_types_names builtins) with Some _ -> true | None -> false) in
           if known then ()
           else match prim_desc p with
             | None -> puts "error: unknown primitive "; puts p; newline ()
             | Some d ->
               let ty = ty_of_texp (fresh_sub (tyvars_of te [])) te in
               externals := (name, d) :: !externals;
               type_session := (name, generalize !type_session ty) :: !type_session;
               puts "external "; puts name; newline ())
    | Ok toks when (match toks with t :: _ -> is_kw t "type" | [] -> false) ->
      (* a declaration, not an expression: it binds constructors and has no
         value to print.  type a = ... and b = ... declares each in turn. *)
      let rec decls toks =
        match parse_typedecl toks with
        | Err m -> puts "error: "; puts m; newline ()
        | Ok (name, ps, arms, flds, rest) ->
          let rec add l = match l with
            | [] -> ()
            | (c, args) :: r ->
              constructors := (c, (name, ps, args)) :: !constructors;
              ctor_arities := (c, count_list args) :: !ctor_arities;
              add r in
          add arms;
          let rec names_of l = match l with
            | [] -> []
            | (c, _) :: r -> c :: names_of r in
          (match arms with
           | [] -> ()
           | _ -> type_ctors := (name, names_of arms) :: !type_ctors);
          let rec addf l names = match l with
            | [] -> rev_acc names []
            | (f, te) :: r ->
              fields := (f, (name, ps, te)) :: !fields;
              addf r (f :: names) in
          (match flds with
           | [] -> ()
           | _ -> rec_order := (name, addf flds []) :: !rec_order);
          puts "type "; puts name; newline ();
          match rest with
          | [] -> ()
          | t :: more when is_kw t "and" -> decls more
          | t :: _ ->
            puts "error: unexpected input at the end";
            if is_kw t "or" then puts " (constructors are separated by |)";
            newline () in
      decls (match toks with _ :: r -> r | [] -> [])
    | Ok toks ->
      let top_let = match toks with t :: _ -> is_kw t "let" | [] -> false in
      let parsed = match toks with
        | t :: rest when is_kw t "let" -> parse_let rest false
        | _ -> parse_seq toks in
      match parsed with
      | Err m -> puts "error: "; puts m; newline ()
      | Ok (_, _ :: _) -> puts "error: unexpected input at the end"; newline ()
      | Ok (e, []) ->
        match infer_line e with
        | Err m ->
          puts "error: "; puts m;
          (* the usual cause of an unbound name: a function that calls
             itself, written without rec, which binds nothing for its own
             body *)
          (match e with
           | Let (false, name, _, _) when string_equal m ("unbound " ^^ name) ->
             puts " (did you mean \"let rec\"?)"
           | _ -> ());
          newline ()
        | Ok (bound_name, sc, ty) ->
        let t0 = now () in
        (* compiled code raises as the machine does: a recursion past the
           stack reaches here rather than halting the processor *)
        (match (try run_phrase e bound_name with
                | Stack_overflow -> Err "stack overflow"
                | Out_of_memory -> Err "out of memory"
                | Invalid_argument _ -> Err "index out of bounds"
                | Match_failure _ -> Err "exception Match_failure"
                | Not_found -> Err "exception Not_found"
                | Division_by_zero -> Err "exception Division_by_zero"
                | End_of_file -> Err "exception End_of_file"
                | Failure m -> Err ("exception Failure \"" ^^ m ^^ "\"")
                | Sys_error m -> Err ("exception Sys_error \"" ^^ m ^^ "\"")
                | _ -> Err "uncaught exception") with
         | Err m -> puts "error: "; puts m; newline ()
         | Ok v ->
           let elapsed = now () - t0 in
           (* compiling for an image says nothing per phrase (the UART is much slower than the compiler, and nothing was
              run: there is no value to show); only the session's types are kept *)
           (match top_let, e with
            | true, Let (_, name, _, Var _) ->
              type_session := (bound_name, sc) :: !type_session;
              if not !img_mode then begin puts "val "; puts name; puts " : "; puts (type_name ty); puts " = " end
            | _ -> if not !img_mode then begin puts "- : "; puts (type_name ty); puts " = " end);
           if not !img_mode then begin
             print_compiled ty v;
             (if elapsed > 0 then begin puts "   ("; put_int elapsed; puts " ms)" end);
             newline ()
           end)
  end


(* a phrase, whole: reading, typing, compiling and running it.  The machine raises Stack_overflow when the
   stack is within a margin of its end and Out_of_memory when a collection frees too little; here they are
   reported and the session goes on, rather than leaving an uncaught exception that halts the processor.
   (The stack is 32K words, the heap two 32K-word semi-spaces: what the compiler's own recursion over a
   long phrase has to fit in.) *)
(* where the first ";;" is in the line, outside any string or character literal; -1 if none *)
let find_semis () =
  let n = !line_len in
  let i = ref 0 and r = ref (0 - 1) and inq = ref false in
  while !r < 0 && !i < n do
    let c = char_at !i in
    (if !inq then begin
       (if c = 92 then i := !i + 1 else if c = 34 then inq := false)
     end
     else if c = 34 then inq := true
     else if c = 39 && !i + 2 < n && char_at (!i + 2) = 39 then i := !i + 2
     else if c = 59 && !i + 1 < n && char_at (!i + 1) = 59 then r := !i);
    i := !i + 1
  done;
  !r

let evaluate_line_whole () =
  try evaluate_line_unsafe () with
  | Stack_overflow -> puts "error: stack overflow"; newline ()
  | Out_of_memory -> puts "error: out of memory"; newline ()
  | Invalid_argument _ -> puts "error: index out of bounds"; newline ();
    if !freeze_on_oob then begin puts "frozen"; newline (); while true do () done end
  | Not_found -> puts "error: internal Not_found"; newline ()
  | Failure m -> puts "error: Failure "; puts m; newline ()
  | _ -> puts "error: uncaught exception"; newline ()

(* a typed line may hold several phrases, ended by ";;" *)
let rec evaluate_line () =
  let k = find_semis () in
  if k < 0 then evaluate_line_whole ()
  else begin
    let n = !line_len in
    let rest = create_bytes (n - k - 2) in
    for j = 0 to n - k - 3 do bytes_set rest j (char_of_int (char_at (k + 2 + j))) done;
    line_len := k;
    evaluate_line_whole ();
    for j = 0 to n - k - 3 do bytes_set !line j (bytes_get rest j) done;
    line_len := n - k - 2;
    if !line_len > 0 then evaluate_line ()
  end

let () = fs_put := (fun nm v -> rfs_put nm v)
let () = fs_get := (fun nm -> rfs_get nm)

let () = fs_ls := (fun (_ : int) ->
  let _ = rfs_ready () in
  let n = rfs_count () in
  for k = 0 to n - 1 do
    let base = rfs_dir + k * rfs_ent in
    let i = ref 0 in
    while !i < rfs_name_max && db (base + !i) <> 0 do
      putc (char_of_int (db (base + !i))); i := !i + 1
    done;
    puts "  "; put_int (rfs_length k); newline ()
  done;
  n)

(* A source file, a phrase at a time.  Comments are skipped (they nest, and a string or a
   character literal inside one is read as such, so "*)" in a string does not end it); a
   newline is a space; and a line that starts in column 0 with let, type, external,
   exception, open or module begins the next phrase.  Each phrase is compiled as though it
   had been typed, from a buffer big enough for it. *)
(* byte i of what an in channel reads, whatever its position *)
let inch (ic : int) i = char_of_int (db (array_get in_off ic + i))

let starts_phrase (ic : int) i =
  let n = array_get in_len ic in
  let at w =
    let m = string_length w in
    i + m < n && (let ok = ref true and j = ref 0 in
                  while !ok && !j < m do
                    (if inch ic (i + !j) <> string_get w !j then ok := false);
                    j := !j + 1
                  done;
                  !ok && inch ic (i + m) = ' ') in
  at "let" || at "type" || at "external" || at "exception" || at "open" || at "module"

let run_source (ic : int) =
  let n = array_get in_len ic in
  let small = !line in
  let cap = ref 4096 in
  let big = ref (create_bytes !cap) in
  line := !big;
  let i = ref 0 and count = ref 0 and depth = ref 0 in
  (* the phrase buffer grows to the longest phrase and no further, not to the size of the file *)
  let put c =
    (if !line_len + 2 > !cap then begin
       let nb = create_bytes (2 * !cap) in
       for k = 0 to !line_len - 1 do bytes_set nb k (bytes_get !big k) done;
       big := nb; line := nb; cap := 2 * !cap
     end);
    bytes_set !big !line_len c; line_len := !line_len + 1 in
  let flush () =
    (* a phrase that is only blanks is nothing *)
    let blank = ref true in
    for k = 0 to !line_len - 1 do if bytes_get !big k <> ' ' then blank := false done;
    (if not_b !blank then begin
       (if !src_echo then begin
          puts "@ ";
          for k = 0 to (if !line_len < 70 then !line_len else 70) - 1 do putc (bytes_get !big k) done;
          newline ()
        end);
       evaluate_line (); count := !count + 1;
       (if !img_mode && !count land 15 = 0 then putc '.')
     end);
    line_len := 0 in
  line_len := 0;
  while !i < n do
    let c = inch ic !i in
    if !depth > 0 then begin
      (if c = '(' && !i + 1 < n && inch ic (!i + 1) = '*' then begin depth := !depth + 1; i := !i + 2 end
       else if c = '*' && !i + 1 < n && inch ic (!i + 1) = ')' then begin depth := !depth - 1; i := !i + 2 end
       else if c = '"' then begin
         (* a string inside a comment *)
         i := !i + 1;
         while !i < n && inch ic !i <> '"' do
           (if inch ic !i = '\\' then i := !i + 1);
           i := !i + 1
         done;
         i := !i + 1
       end
       else if c = '\'' && !i + 2 < n && inch ic (!i + 2) = '\'' then i := !i + 3
       else i := !i + 1)
    end
    else if c = '(' && !i + 1 < n && inch ic (!i + 1) = '*' then begin depth := 1; put ' '; i := !i + 2 end
    else if c = '"' then begin
      (* a string literal, copied as it stands *)
      put c; i := !i + 1;
      while !i < n && inch ic !i <> '"' do
        (if inch ic !i = '\\' && !i + 1 < n then begin put (inch ic !i); i := !i + 1 end);
        put (inch ic !i); i := !i + 1
      done;
      (if !i < n then begin put '"'; i := !i + 1 end)
    end
    else if c = '\'' && !i + 2 < n && inch ic (!i + 2) = '\'' then begin
      put c; put (inch ic (!i + 1)); put c; i := !i + 3
    end
    else if c = '\'' && !i + 3 < n && inch ic (!i + 1) = '\\' && inch ic (!i + 3) = '\'' then begin
      put c; put (inch ic (!i + 1)); put (inch ic (!i + 2)); put c; i := !i + 4
    end
    else if c = ';' && !i + 1 < n && inch ic (!i + 1) = ';' then begin flush (); i := !i + 2 end   (* ;; ends a phrase *)
    else if c = '\n' then begin
      put ' '; i := !i + 1;
      (if !i < n && starts_phrase ic !i then flush ())
    end
    else begin put c; i := !i + 1 end
  done;
  flush ();
  line := small;
  line_len := 0;
  !count

let () = fs_run := (fun nm ->
  try
    let ic = open_in nm in
    let n = run_source ic in
    close_in ic;
    n
  with Sys_error m -> puts m; newline (); 0)

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
let out_max = 8192                 (* unsent + unacknowledged output *)
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

(* The last bytes are kept back so that a value which did not fit can say
   so: printing stops at out_limit, and the notice goes in above it. *)
let out_limit = out_max - 24
let out_over = ref false

let out_raw c =
  if !out_len < out_max then begin
    bytes_set out !out_len c;
    out_len := !out_len + 1
  end

(* The buffer holds what is unsent and unacknowledged together, so a value
   larger than it cannot be handed over in one go.  What will not fit is
   still dropped -- emptying it here means running the receive path from
   inside the one already reading a packet, which is its own trouble -- but
   the reader is told, rather than the value simply stopping mid-character. *)
let out_char c = if !out_len < out_limit then out_raw c else out_over := true

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
  out_over := false;
  evaluate_line ();
  line_len := 0;
  if !out_over then begin
    let m = "\r\n  ... (truncated)" in
    for i = 0 to string_length m - 1 do out_raw (string_get m i) done;
    out_over := false
  end;
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
      bytes_set !line !line_len c;
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
      for i = 0 to !uart_len - 1 do bytes_set !line i (bytes_get uart_line i) done;
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
        bytes_set !line !line_len (char_of_int c);
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



(* the loader's serial boot leaves 0x4E in the RAM disk's last byte: then the network is not touched at all, so that
   what the compiler allocates cannot depend on what frames arrive *)
let net_on = ref true

let poll () =
  uart_poll ();
  if !net_on then begin
  dhcp_tick ();
  tcp_tick ();
  nfs_tick ();
  let st = io_read eth_status in
  if st land eth_rx_valid <> 0 then begin
    let len = io_read eth_rxlen land 0x7FF in
    if rx 12 = 0x08 && rx 13 = 0x06 then begin
      handle_arp len; nfs_arp_reply len
    end
    else if rx 12 = 0x08 && rx 13 = 0x00 && len >= 42 then begin
      let ihl = (rx 14 land 0x0F) * 4 in
      let dport = (rx (14 + ihl + 2) lsl 8) lor rx (14 + ihl + 3) in
      if rx 23 = 1 then handle_icmp len ihl
      else if rx 23 = 17 && dport = 68 then handle_dhcp len
      else if rx 23 = 17 && dport = repl_port then handle_repl len ihl
      else if rx 23 = 17 && dport = nfs_lport then nfs_reply len

      else if rx 23 = 6 then handle_tcp len ihl
    end;
    io_write eth_rxlen 0;
    packets := !packets + 1;
    io_write leds ((if bound () then 2 else 0) lor ((!packets land 0x3F) lsl 2))
  end
  end

(* Emptying the output buffer: send what is queued and take the
   acknowledgements, until there is room or the connection has gone. *)
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
  net_on := io_read (disk + io_read disk_size_reg - 1) <> 0x4E;
  if not_b (find_doorway ()) then uart_puts "compiler: the doorway is missing\n"
  else begin
    uart_puts "compiler: doorway at "; uart_dec !doorway;
    uart_puts ", emitting from "; uart_dec !cp; uart_putc '\n';
    (* the filing system, reachable from compiled code *)
    install_fn "write_file" (magic (fun (a : string) (b : string) -> (!fs_put) a b));
    install_fn "read_file"
      (magic (fun (a : string) -> match (!fs_get) a with Ok v -> v | Err _ -> ""));
    install_fn "run_file" (magic (fun (a : string) -> (!fs_run) a));
    install_fn "files" (magic (fun (n : int) -> (!fs_ls) n));
    install_fn "nfs_server" (magic (fun (a : string) -> nfs_set_server a));
    install_fn "nfs_fetch"
      (magic (fun (e : string) (f : string) -> nfs_start e f));
    install_fn "nfs_done" (magic (fun (_n : int) -> !nfs_result));
    install_fn "boot_file" (magic (fun (a : string) -> boot_file a));
    install_fn "open_in" (magic (fun (a : string) -> open_in a));
    install_fn "open_in_bin" (magic (fun (a : string) -> open_in a));
    install_fn "open_out" (magic (fun (a : string) -> open_out a));
    install_fn "open_out_bin" (magic (fun (a : string) -> open_out a));
    install_fn "close_in" (magic (fun (h : int) -> close_in h; 0));
    install_fn "close_out" (magic (fun (h : int) -> close_out h; 0));
    install_fn "input_char" (magic (fun (h : int) -> input_char h));
    install_fn "input_byte" (magic (fun (h : int) -> input_char h));
    install_fn "input_line" (magic (fun (h : int) -> input_line h));
    install_fn "really_input_string" (magic (fun (h : int) (n : int) -> really_input_string h n));
    install_fn "in_channel_length" (magic (fun (h : int) -> in_channel_length h));
    install_fn "pos_in" (magic (fun (h : int) -> pos_in h));
    install_fn "seek_in" (magic (fun (h : int) (p : int) -> seek_in h p; 0));
    install_fn "output_char" (magic (fun (h : int) (c : int) -> output_char h c; 0));
    install_fn "output_byte" (magic (fun (h : int) (c : int) -> output_char h c; 0));
    install_fn "output_string" (magic (fun (h : int) (a : string) -> output_string h a; 0));
    install_fn "flush" (magic (fun (h : int) -> flush h; 0));
    install_fn "out_channel_length" (magic (fun (h : int) -> out_channel_length h));
    install_fn "pos_out" (magic (fun (h : int) -> pos_out h));
    install_fn "seek_out" (magic (fun (h : int) (p : int) -> seek_out h p; 0));
    install_fn "file_exists" (magic (fun (a : string) -> file_exists a));
    install_fn "disk_size" (magic (fun (u : int) -> disk_size u));
    install_fn "disk_get" (magic (fun (i : int) -> disk_get i));
    install_fn "disk_set" (magic (fun (i : int) (v : int) -> disk_set i v; 0));
    install_fn "image_begin" (magic (fun (a : string) -> img_begin a));
    install_fn "image_end" (magic (fun (n : int) -> img_end n))
  end;
  puts "OCaml processor mini-ML (UART, UDP 7777, telnet 23) -- build ";
  uart_build ();
  newline ();
  puts "# ";
  while true do poll () done
(* ==== END MAIN ==== *)
