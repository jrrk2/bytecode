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
(* ==== MATH ==== *)

let pi      = 3.14159265358979312
let pio2    = 1.57079632679489656
let pio6    = 0.523598775598298927
let sqrt3   = 1.73205080756887730
(* pi/2 and ln 2 in two pieces: subtracting k * pi/2 from a large argument
   loses the low bits of pi/2 to rounding, so the high part is kept short
   enough to multiply exactly and the remainder is taken off afterwards. *)
let pio2_hi = 1.57079632673412562
let pio2_lo = 6.07710050650619225e-11
let ln2_hi  = 0.693147180369123816
let ln2_lo  = 1.90821492927058770e-10
let ln2     = 0.693147180559945286
let two_over_pi = 0.636619772367581343

(* 2^n, by squaring rather than n multiplications *)
let pow2 n =
  let rec go b e acc =
    if e = 0 then acc
    else go (b *. b) (e / 2) (if e mod 2 = 1 then acc *. b else acc) in
  if n >= 0 then go 2.0 n 1.0 else 1.0 /. go 2.0 (0 - n) 1.0

(* nearest integer, as an int: the reduction needs round-to-nearest and
   int_of_float truncates *)
let round_to_int x = int_of_float (if x <. 0.0 then x -. 0.5 else x +. 0.5)

(* ---- exp and log ---- *)

let exp x =
  if x <. -745.0 then 0.0
  else if 709.8 <. x then 1.0 /. 0.0
  else begin
    let k = round_to_int (x /. ln2) in
    let kf = float_of_int k in
    let r = x -. kf *. ln2_hi -. kf *. ln2_lo in
    (* Taylor about zero on |r| <= ln2/2; the term after the last is about
       1e-19 of the sum *)
    let sum = ref 1.0 and term = ref 1.0 in
    for i = 1 to 14 do
      term := !term *. r /. float_of_int i;
      sum := !sum +. !term
    done;
    !sum *. pow2 k
  end

let log x =
  if x <. 0.0 then 0.0 /. 0.0
  else if x =. 0.0 then ~-. (1.0 /. 0.0)
  else begin
    (* x = m * 2^e with m in [sqrt(1/2), sqrt(2)), coarsely first so that a
       huge argument does not take a thousand halvings *)
    let e = ref 0 and m = ref x in
    while 65536.0 <=. !m do m := !m /. 65536.0; e := !e + 16 done;
    while !m <. 1.52587890625e-05 do m := !m *. 65536.0; e := !e - 16 done;
    while 1.41421356237309515 <=. !m do m := !m /. 2.0; e := !e + 1 done;
    while !m <. 0.707106781186547524 do m := !m *. 2.0; e := !e - 1 done;
    (* log m = 2 atanh s, s = (m-1)/(m+1), |s| <= 0.1716 *)
    let s = (!m -. 1.0) /. (!m +. 1.0) in
    let s2 = s *. s in
    let acc = ref 0.0 and t = ref s in
    for i = 0 to 12 do
      acc := !acc +. !t /. float_of_int (2 * i + 1);
      t := !t *. s2
    done;
    2.0 *. !acc +. float_of_int !e *. ln2
  end

(* ---- sine, cosine, tangent ---- *)

let sin_small r =
  let r2 = r *. r in
  let term = ref r and sum = ref r in
  for n = 1 to 10 do
    term := ~-. (!term *. r2 /. float_of_int ((2 * n) * (2 * n + 1)));
    sum := !sum +. !term
  done;
  !sum

let cos_small r =
  let r2 = r *. r in
  let term = ref 1.0 and sum = ref 1.0 in
  for n = 1 to 10 do
    term := ~-. (!term *. r2 /. float_of_int ((2 * n - 1) * (2 * n)));
    sum := !sum +. !term
  done;
  !sum

(* x = k * pi/2 + r with |r| <= pi/4; which of sine and cosine to use, and
   with which sign, follows k around the circle *)
let quadrant x =
  let k = round_to_int (x *. two_over_pi) in
  let kf = float_of_int k in
  let r = x -. kf *. pio2_hi -. kf *. pio2_lo in
  (((k mod 4) + 4) mod 4, r)

let sin x =
  let (q, r) = quadrant x in
  if q = 0 then sin_small r
  else if q = 1 then cos_small r
  else if q = 2 then ~-. (sin_small r)
  else ~-. (cos_small r)

let cos x =
  let (q, r) = quadrant x in
  if q = 0 then cos_small r
  else if q = 1 then ~-. (sin_small r)
  else if q = 2 then ~-. (cos_small r)
  else sin_small r

let tan x = sin x /. cos x

(* ---- the inverses ---- *)

let atan_small t =
  let t2 = t *. t in
  let p = ref t and sum = ref t in
  for n = 1 to 16 do
    p := ~-. (!p *. t2);
    sum := !sum +. !p /. float_of_int (2 * n + 1)
  done;
  !sum

(* 0 <= a: fold a > 1 through atan a = pi/2 - atan (1/a), then the rest
   through atan a = pi/6 + atan ((a sqrt3 - 1)/(sqrt3 + a)), which leaves
   |t| <= tan(pi/12) = 0.268 and a series that falls by 14 each term *)
let atan_pos a =
  let reduce b =
    if 0.267949192431122706 <. b then
      pio6 +. atan_small ((b *. sqrt3 -. 1.0) /. (sqrt3 +. b))
    else atan_small b in
  if 1.0 <. a then pio2 -. reduce (1.0 /. a) else reduce a

let atan x = if x <. 0.0 then ~-. (atan_pos (~-. x)) else atan_pos x

let atan2 y x =
  if 0.0 <. x then atan (y /. x)
  else if x <. 0.0 then
    (if y <. 0.0 then atan (y /. x) -. pi else atan (y /. x) +. pi)
  else if 0.0 <. y then pio2
  else if y <. 0.0 then ~-. pio2
  else 0.0

(* asin a = atan (a / sqrt (1 - a^2)) loses its footing as a nears one,
   where the square root is the difference of two close numbers; the half
   angle moves the work back to the middle of the range *)
let rec asin_pos a =
  if a <=. 0.7 then atan (a /. sqrt (1.0 -. a *. a))
  else if 1.0 <. a then 0.0 /. 0.0
  else pio2 -. 2.0 *. asin_pos (sqrt ((1.0 -. a) /. 2.0))

let asin x = if x <. 0.0 then ~-. (asin_pos (~-. x)) else asin_pos x
let acos x = pio2 -. asin x

let pow x y = exp (y *. log x)

(* ---- tokens ---- *)
type token = TInt of int | TFloat of float | TId of string | TSym of string
            | TStr of string

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
  (* +. -. *. /. are two characters, as are <= <> >= -> :: *)
  if (c = 60 && (d = 61 || d = 62)) || (c = 62 && d = 61) || (c = 45 && d = 62)
     || (c = 58 && d = 58)
     || ((c = 43 || c = 45 || c = 42 || c = 47) && d = 46) then 2
  else if c = 43 || c = 45 || c = 42 || c = 47 || c = 61 || c = 60 || c = 62
       || c = 40 || c = 41 || c = 44 || c = 91 || c = 93 || c = 124 || c = 59
       (* { } . : for records; a float literal and +. -. *. /. are taken
          before this, so a lone point can only be a field selection *)
       || c = 123 || c = 125 || c = 46 || c = 58 then 1
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
      end else if c = 34 then begin
        (* a string literal.  A backslash escapes the next character, with
           n, r and t meaning newline, return and tab; anything else after
           one stands for itself, which covers the quote and the backslash.
           Escapes change the length, so it is built in a buffer rather
           than cut out of the line. *)
        let b = create_bytes line_max and n = ref 0 and j = ref (i + 1) in
        while !j < !line_len && char_at !j <> 34 do
          let ch = char_at !j in
          if ch = 92 && !j + 1 < !line_len then begin
            let e = char_at (!j + 1) in
            let v = if e = 110 then 10 else if e = 114 then 13
                    else if e = 116 then 9 else e in
            bytes_set b !n (char_of_int v); n := !n + 1; j := !j + 2
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

let keyword s = string_equal s "try" || string_equal s "with"
                || string_equal s "match" || string_equal s "type" || string_equal s "of"
                || string_equal s "let" || string_equal s "rec" || string_equal s "in"
                || string_equal s "if" || string_equal s "then" || string_equal s "else"
                || string_equal s "fun" || string_equal s "true" || string_equal s "false"
                || string_equal s "mod"

let is_sym t s = match t with TSym x -> string_equal x s | _ -> false
let is_kw t s = match t with TId x -> string_equal x s | _ -> false

let rec rev_acc l acc = match l with [] -> acc | x :: r -> rev_acc r (x :: acc)
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
       | Ok (a, rest2) -> Ok (PCon (c, (match a with PTuple l -> l | _ -> [a])), rest2))
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
  | t :: rest when is_kw t "match" ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (scrut, rest) ->
       match expect rest "with" with
       | Err e -> Err e
       | Ok rest ->
         let rest = match rest with t2 :: r when is_sym t2 "|" -> r | _ -> rest in
         match parse_arms rest [] with
         | Err e -> Err e
         | Ok (arms, rest) -> Ok (Match (scrut, arms), rest))
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

and parse_arms toks acc =
  match parse_pat toks with
  | Err e -> Err e
  | Ok (q, rest) ->
    match expect rest "->" with
    | Err e -> Err e
    | Ok rest ->
      match parse_expr rest with
      | Err e -> Err e
      | Ok (body, rest) ->
        match rest with
        | t :: rest2 when is_sym t "|" -> parse_arms rest2 ((q, body) :: acc)
        | _ -> Ok (rev_acc ((q, body) :: acc) [], rest)

and parse_cmp toks =
  match parse_cons toks with
  | Err e -> Err e
  | Ok (a, rest) ->
    match rest with
    | TSym op :: rest2 when string_equal op "=" || string_equal op "<>" || string_equal op "<"
                           || string_equal op ">" || string_equal op "<=" || string_equal op ">=" ->
      (match parse_cons rest2 with
       | Err e -> Err e
       | Ok (b, rest3) -> Ok (Binop (op, a, b), rest3))
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
        | Con (c, []) -> Con (c, (match a with Tuple l -> l | _ -> [a]))
        | _ -> App (f, a) in
      app_more applied rest
  else Ok (f, toks)
and starts_atom toks = match toks with
  | TInt _ :: _ -> true
  | TFloat _ :: _ -> true
  | TStr _ :: _ -> true
  | TId x :: _ -> not (keyword x) || string_equal x "true" || string_equal x "false"
  | t :: _ -> is_sym t "(" || is_sym t "[" || is_sym t "{"
  | [] -> false

and parse_atom toks = match toks with
  | TInt n :: rest -> Ok (Int n, rest)
  | TFloat f :: rest -> Ok (Float f, rest)
  | TStr s :: rest -> Ok (Str s, rest)
  | TId x :: rest when string_equal x "true" -> Ok (Bool true, rest)
  | TId x :: rest when string_equal x "false" -> Ok (Bool false, rest)
  | TId c :: rest when is_ctor c -> Ok (Con (c, []), rest)
  | TId x :: rest when not (keyword x) -> Ok (Var x, rest)
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
     | Ok (e, rest) -> parse_tuple_rest [e] rest)
  | _ -> Err "syntax error"

and parse_tuple_rest acc toks = match toks with
  | t :: rest when is_sym t "," ->
    (match parse_expr rest with
     | Err e -> Err e
     | Ok (e, rest) -> parse_tuple_rest (e :: acc) rest)
  | t :: rest when is_sym t ")" ->
    Ok ((match acc with [e] -> e | _ -> Tuple (rev_acc acc [])), rest)
  | _ -> Err "expected , or ) "

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
       | t :: rest1 when is_sym t "{" ->
         (* a record: fields and their types, rather than constructors *)
         let rec flds toks acc = match toks with
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

let rec rev_list l acc = match l with [] -> acc | x :: r -> rev_list r (x :: acc)
let rec list_len l = match l with [] -> 0 | _ :: r -> 1 + list_len r

(* The ones the FPU makes worth having.  Everything here is either a float
   function or a conversion; the types are seeded into the session below so
   that inference knows them without a declaration. *)
(* Set once the loader below is in scope.  boot returns only if it could
   not start; a successful one never comes back, because the machine it
   would return to has been replaced. *)
let boot_action = ref (fun (_ : string) -> 0)
let restart_action = ref (fun (_ : int) -> 0)

let call_builtin name args = match args with
  | [VFloat x] ->
    if string_equal name "sin" then Ok (VFloat (sin x))
    else if string_equal name "cos" then Ok (VFloat (cos x))
    else if string_equal name "tan" then Ok (VFloat (tan x))
    else if string_equal name "asin" then Ok (VFloat (asin x))
    else if string_equal name "acos" then Ok (VFloat (acos x))
    else if string_equal name "atan" then Ok (VFloat (atan x))
    else if string_equal name "exp" then Ok (VFloat (exp x))
    else if string_equal name "log" then Ok (VFloat (log x))
    else if string_equal name "sqrt" then Ok (VFloat (sqrt x))
    else if string_equal name "abs_float" then Ok (VFloat (abs_float x))
    else if string_equal name "int_of_float" then Ok (VInt (int_of_float x))
    else Err ("bad argument for " ^^ name)
  | [VInt n] ->
    if string_equal name "float_of_int" then Ok (VFloat (float_of_int n))
    else if string_equal name "restart" then Ok (VInt ((!restart_action) n))
    else Err ("bad argument for " ^^ name)
  | [VStr f] ->
    if string_equal name "boot" then Ok (VInt ((!boot_action) f))
    else Err ("bad argument for " ^^ name)
  | [VFloat a; VFloat b] ->
    if string_equal name "atan2" then Ok (VFloat (atan2 a b))
    else if string_equal name "pow" then Ok (VFloat (pow a b))
    else Err ("bad argument for " ^^ name)
  | _ -> Err ("bad argument for " ^^ name)


let rec lookup_rec l f = match l with
  | [] -> Err ("no field " ^^ f)
  | (g, v) :: r -> if string_equal f g then Ok v else lookup_rec r f

let bool_eq (a : bool) (b : bool) = if a then b else if b then false else true
let not_b (a : bool) = if a then false else true

(* = and <> on the structured values: two constructors are equal when they
   are the same one and their arguments are *)
let rec val_eq a b = match a, b with
  | VInt x, VInt y -> x = y
  | VBool x, VBool y -> bool_eq x y
  | VFloat x, VFloat y -> flt_eq x y
  | VStr x, VStr y -> string_equal x y
  | VTuple l, VTuple m -> val_eq_list l m
  | VCon (n, l), VCon (m, k) -> string_equal n m && val_eq_list l k
  | VRec l, VRec m -> val_eq_rec l m
  | _ -> false
and val_eq_rec l m = match l with
  | [] -> true
  | (f, v) :: r ->
    (match lookup_rec m f with
     | Err _ -> false
     | Ok w -> val_eq v w && val_eq_rec r m)
and val_eq_list l m = match l, m with
  | [], [] -> true
  | x :: r, y :: s -> val_eq x y && val_eq_list r s
  | _ -> false

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
        ("::", ("list", ["'a"], [TEVar "'a"; TECon ("list", [TEVar "'a"])])) ]

(* field name -> the record type it belongs to, that type's parameters, and
   the field's own type.  A field is looked up by name alone, so the last
   declaration of a name wins, as it does in OCaml. *)
let fields : (string * (string * string list * tyexp)) list ref = ref []
(* record type name -> its fields in declaration order, for printing *)
let rec_order : (string * string list) list ref = ref []

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

let rec lookup_sub sub v = match sub with
  | [] -> fresh_tv ()
  | (n, t) :: r -> if string_equal n v then t else lookup_sub r v

let rec ty_of_texp sub te = match te with
  | TEVar v -> lookup_sub sub v
  | TECon (n, []) when string_equal n "int" -> TInt
  | TECon (n, []) when string_equal n "bool" -> TBool
  | TECon (n, []) when string_equal n "float" -> TFloat
  | TECon (n, []) when string_equal n "string" -> TString
  | TECon (n, l) -> TCon (n, ty_of_texps sub l)
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

let int_op op =
  string_equal op "+" || string_equal op "-" || string_equal op "*"
  || string_equal op "/" || string_equal op "mod"

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

let rec eval env e = match e with
  | Int n -> Ok (VInt n)
  | Float f -> Ok (VFloat f)
  | Str s -> Ok (VStr s)
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
         | VBool x, VBool y when string_equal op "=" -> Ok (VBool (bool_eq x y))
         | VBool x, VBool y when string_equal op "<>" -> Ok (VBool (not_b (bool_eq x y)))
         | _, _ when string_equal op "=" -> Ok (VBool (val_eq va vb))
         | _, _ when string_equal op "<>" -> Ok (VBool (not_b (val_eq va vb)))
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
     | Ok (VBuiltin (name, arity, got)) ->
       (match eval env a with
        | Err m -> Err m
        | Ok va ->
          let got2 = va :: got in
          if list_len got2 = arity then call_builtin name (rev_list got2 [])
          else Ok (VBuiltin (name, arity, got2)))
     | Ok _ -> Err "not a function")
  | Try (body, name, handler) ->
    (match (try eval env body with
            | Stack_overflow -> Err "stack overflow"
            | Out_of_memory -> Err "out of memory"
            | Invalid_argument _ -> Err "index out of bounds") with
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
  | Field (e, f) ->
    (match eval env e with
     | Err m -> Err m
     | Ok (VRec l) -> lookup_rec l f
     | Ok _ -> Err "not a record")
  | Record fs ->
    (match eval_fields env fs [] with Err m -> Err m | Ok l -> Ok (VRec l))
  | With (base, fs) ->
    (match eval env base with
     | Err m -> Err m
     | Ok (VRec l) ->
       (match eval_fields env fs [] with
        | Err m -> Err m
        | Ok upd ->
          (* the base's order is kept, with the named fields replaced *)
          let rec merge b = match b with
            | [] -> []
            | (f, v) :: r ->
              (match lookup_rec upd f with
               | Ok w -> (f, w) :: merge r
               | Err _ -> (f, v) :: merge r) in
          Ok (VRec (merge l)))
     | Ok _ -> Err "not a record")
  | Tuple es ->
    (match eval_all env es [] with Err m -> Err m | Ok vs -> Ok (VTuple vs))
  | Con (c, args) ->
    (match eval_all env args [] with Err m -> Err m | Ok vs -> Ok (VCon (c, vs)))
  | Match (scrut, arms) ->
    (match eval env scrut with
     | Err m -> Err m
     | Ok v ->
       let rec go l = match l with
         | [] -> Err "no case matches this value"
         | (q, body) :: r ->
           (match match_pat env q v with
            | None -> go r
            | Some env2 -> eval env2 body) in
       go arms)

and eval_fields env fs acc = match fs with
  | [] -> Ok (rev_acc acc [])
  | (f, e) :: r ->
    (match eval env e with
     | Err m -> Err m
     | Ok v -> eval_fields env r ((f, v) :: acc))

and eval_all env l acc = match l with
  | [] -> Ok (rev_acc acc [])
  | e :: r ->
    (match eval env e with Err m -> Err m | Ok v -> eval_all env r (v :: acc))

(* a pattern against a value: the bindings it makes, or nothing *)
and match_pat env q v = match q, v with
  | PWild, _ -> Some env
  | PVar x, _ -> Some ((x, v) :: env)
  | PInt n, VInt m -> if n = m then Some env else None
  | PBool b, VBool c -> if bool_eq b c then Some env else None
  | PTuple ps, VTuple vs -> match_pats env ps vs
  | PCon (c, ps), VCon (d, vs) -> if string_equal c d then match_pats env ps vs else None
  | PRec fs, VRec l -> match_rec env fs l
  | _ -> None

and match_rec env fs l = match fs with
  | [] -> Some env
  | (f, q) :: r ->
    (match lookup_rec l f with
     | Err _ -> None
     | Ok v ->
       match match_pat env q v with
       | None -> None
       | Some env2 -> match_rec env2 r l)

and match_pats env ps vs = match ps, vs with
  | [], [] -> Some env
  | q :: pr, v :: vr ->
    (match match_pat env q v with None -> None | Some env2 -> match_pats env2 pr vr)
  | _ -> None

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
let f2f  = TArrow (TFloat, TFloat)
let ff2f = TArrow (TFloat, TArrow (TFloat, TFloat))

let builtins =
  [ ("sin", 1, f2f); ("cos", 1, f2f); ("tan", 1, f2f);
    ("asin", 1, f2f); ("acos", 1, f2f); ("atan", 1, f2f);
    ("exp", 1, f2f); ("log", 1, f2f); ("sqrt", 1, f2f);
    ("abs_float", 1, f2f);
    ("atan2", 2, ff2f); ("pow", 2, ff2f);
    ("float_of_int", 1, TArrow (TInt, TFloat));
    ("int_of_float", 1, TArrow (TFloat, TInt));
    (* chain loading: restart () runs the staged image again, boot "f"
       fetches f over TFTP into the staging RAM and runs that instead *)
    ("restart", 1, TArrow (TInt, TInt));
    ("boot", 1, TArrow (TString, TInt)) ]

let rec builtin_values l = match l with
  | [] -> []
  | (n, arity, _) :: rest -> (n, VBuiltin (n, arity, [])) :: builtin_values rest

let rec builtin_types l = match l with
  | [] -> []
  | (n, _, t) :: rest -> (n, Forall ([], t)) :: builtin_types rest

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
    | Ok toks when (match toks with t :: _ -> is_kw t "type" | [] -> false) ->
      (* a declaration, not an expression: it binds constructors and has no
         value to print *)
      (match parse_typedecl (match toks with _ :: r -> r | [] -> []) with
       | Err m -> puts "error: "; puts m; newline ()
       | Ok (name, ps, arms, flds, rest) ->
         match rest with
         | t :: _ ->
           puts "error: unexpected input at the end";
           if is_kw t "or" then puts " (constructors are separated by |)";
           newline ()
         | [] ->
           let rec add l = match l with
             | [] -> ()
             | (c, args) :: r ->
               constructors := (c, (name, ps, args)) :: !constructors; add r in
           add arms;
           let rec addf l names = match l with
             | [] -> rev_acc names []
             | (f, te) :: r ->
               fields := (f, (name, ps, te)) :: !fields;
               addf r (f :: names) in
           (match flds with
            | [] -> ()
            | _ -> rec_order := (name, addf flds []) :: !rec_order);
           puts "type "; puts name; newline ())
    | Ok toks ->
      let top_let = match toks with t :: _ -> is_kw t "let" | [] -> false in
      let parsed = match toks with
        | t :: rest when is_kw t "let" -> parse_let rest false
        | _ -> parse_expr toks in
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
        (* Stack_overflow and Invalid_argument come from the hardware --
           a recursion deeper than the stack, an index outside an array or
           a string -- and reach here as exceptions rather than as Err.
           Uncaught they would halt the processor and take the session
           with them. *)
        match (try eval !session e with
               | Stack_overflow -> Err "stack overflow"
               | Out_of_memory -> Err "out of memory"
               | Invalid_argument _ -> Err "index out of bounds") with
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

(* ---- chain loading ----
   The same path the netboot loader takes, and the same hardware: the
   staging RAM is written a byte per address through the I/O window, and a
   write to boot_reg holds the VM, copies the staged image over the running
   one and starts it.  The sequencer takes that request from SEQ_RUN, so a
   running program can replace itself -- which is what the loader does, and
   what these two do from the prompt.

   There is no returning from it.  This program, its network stack and the
   connection carrying the command all cease to exist, so the caller sees
   the session drop rather than a result. *)
let boot_reg = 0x1007
let stage = 0x10000
let stage_size = 0x20000
let tftp_port = 6969
let tftp_local = 50000

let file_name = create_bytes 64
let file_len = ref 0

let boot_idle = 0
let boot_arping = 1
let boot_loading = 2
let boot_state = ref boot_idle
let boot_server_port = ref tftp_port
let next_block = ref 1
let received = ref 0
let boot_deadline = ref 0
let boot_tries = ref 0

let udp_to_server dport payload_len =
  let len = 42 + payload_len in
  for i = 0 to 5 do tx i (array_get server_mac i); tx (6 + i) (mac i) done;
  tx 12 0x08; tx 13 0x00;
  tx 14 0x45; tx 15 0; tx 16 ((len - 14) lsr 8); tx 17 ((len - 14) land 0xFF);
  for i = 18 to 21 do tx i 0 done;
  tx 22 64; tx 23 17; tx 24 0; tx 25 0;
  for i = 0 to 3 do tx (26 + i) (ip i); tx (30 + i) (array_get server_ip i) done;
  let s = ip_checksum 14 20 in
  tx 24 (s lsr 8); tx 25 (s land 0xFF);
  tx 34 (tftp_local lsr 8); tx 35 (tftp_local land 0xFF);
  tx 36 (dport lsr 8); tx 37 (dport land 0xFF);
  tx 38 ((8 + payload_len) lsr 8); tx 39 ((8 + payload_len) land 0xFF);
  tx 40 0; tx 41 0;
  eth_send len

let arp_for_server () =
  for i = 0 to 5 do tx i 0xff; tx (6 + i) (mac i) done;
  tx 12 0x08; tx 13 0x06;
  tx 14 0x00; tx 15 0x01; tx 16 0x08; tx 17 0x00; tx 18 6; tx 19 4;
  tx 20 0x00; tx 21 0x01;
  for i = 0 to 5 do tx (22 + i) (mac i); tx (32 + i) 0 done;
  for i = 0 to 3 do tx (28 + i) (ip i); tx (38 + i) (array_get server_ip i) done;
  eth_send 42

let send_rrq () =
  tx 42 0; tx 43 1;
  for i = 0 to !file_len - 1 do tx (44 + i) (int_of_char (bytes_get file_name i)) done;
  let o = 44 + !file_len in
  tx o 0;
  let mode = "octet" in
  for i = 0 to 4 do tx (o + 1 + i) (int_of_char (string_get mode i)) done;
  tx (o + 6) 0;
  udp_to_server tftp_port (o + 7 - 42)

let send_ack block =
  tx 42 0; tx 43 4; tx 44 (block lsr 8); tx 45 (block land 0xFF);
  udp_to_server !boot_server_port 4

(* ---- the staged image, as tools/mkvmimage.py wrote it ---- *)
let sbyte i = io_read (stage + i)
let sword i = sbyte i lor (sbyte (i + 1) lsl 8) lor (sbyte (i + 2) lsl 16)
let code_max = 32768
let heap_max = 4096
let globals_max = 4096
let prims_digest = [| 0x21; 0xad; 0xa2; 0x86 |]

let crc16 from upto =
  let crc = ref 0xFFFF in
  for i = from to upto - 1 do
    crc := !crc lxor (sbyte i lsl 8);
    for _bit = 1 to 8 do
      if !crc land 0x8000 <> 0 then crc := ((!crc lsl 1) lxor 0x1021) land 0xFFFF
      else crc := (!crc lsl 1) land 0xFFFF
    done
  done;
  !crc

(* Checked before the machine is handed over, because a half-written image
   leaves the staging RAM holding something that is no longer what this
   program was booted from. *)
let check_image n =
  let code = sword 8 and heap = sword 12 and globals = sword 16 in
  if n < 32 then Err "too short"
  else if sbyte 0 <> 0x4f || sbyte 1 <> 0x43 || sbyte 2 <> 0x56 || sbyte 3 <> 0x4d then
    Err "not an image"
  else if sbyte 4 <> 1 || sword 5 <> 0 then Err "wrong version"
  else if sbyte 11 <> 0 || sbyte 15 <> 0 || sbyte 19 <> 0
          || code > code_max || heap > heap_max || globals > globals_max then Err "too large"
  else if 32 + 4 * (code + heap + globals) <> n then Err "truncated"
  else if sbyte 20 <> array_get prims_digest 0 || sbyte 21 <> array_get prims_digest 1
          || sbyte 22 <> array_get prims_digest 2 || sbyte 23 <> array_get prims_digest 3 then
    Err "built for other primitives"
  else if crc16 32 n <> (sbyte 24 lor (sbyte 25 lsl 8)) then Err "checksum"
  else Ok (code + heap + globals)

let staged_len () = 32 + 4 * (sword 8 + sword 12 + sword 16)

let boot_now n = match check_image n with
  | Err why ->
    puts "boot refused: "; puts why; newline ();
    uart_puts "boot refused: "; uart_puts why; uart_putc '\n'; 0
  | Ok _ ->
    uart_puts "chain loading the staged image\n";
    io_write boot_reg 1;
    0

let start_boot f =
  if not (bound ()) then begin puts "no address yet"; newline (); 0 end
  else if string_length f = 0 || string_length f > 63 then begin
    puts "boot needs a file name"; newline (); 0
  end else begin
    file_len := string_length f;
    for i = 0 to !file_len - 1 do bytes_set file_name i (string_get f i) done;
    puts "fetching "; puts f; puts " from "; put_int (array_get server_ip 0);
    putc '.'; put_int (array_get server_ip 1); putc '.';
    put_int (array_get server_ip 2); putc '.'; put_int (array_get server_ip 3);
    newline ();
    received := 0; next_block := 1; boot_tries := 0;
    boot_server_port := tftp_port;
    arp_for_server ();
    boot_state := boot_arping;
    boot_deadline := now () + 1000;
    0
  end

let server_arp_reply len =
  if !boot_state = boot_arping && len >= 42 && rx 21 = 2
     && rx 28 = array_get server_ip 0 && rx 29 = array_get server_ip 1
     && rx 30 = array_get server_ip 2 && rx 31 = array_get server_ip 3 then begin
    for i = 0 to 5 do array_set server_mac i (rx (22 + i)) done;
    send_rrq ();
    boot_state := boot_loading;
    boot_tries := 0;
    boot_deadline := now () + 1000
  end

let tftp_data len =
  let udp = 34 in
  let opcode = (rx (udp + 8) lsl 8) lor rx (udp + 9) in
  if !boot_state = boot_loading && ip_is_mine 30
     && rx 26 = array_get server_ip 0 && rx 27 = array_get server_ip 1
     && rx 28 = array_get server_ip 2 && rx 29 = array_get server_ip 3 then begin
    if opcode = 3 then begin
      let block = (rx (udp + 10) lsl 8) lor rx (udp + 11) in
      let n = ((rx (udp + 4) lsl 8) lor rx (udp + 5)) - 12 in
      boot_server_port := (rx udp lsl 8) lor rx (udp + 1);
      if block = !next_block && !received + n <= stage_size && len >= udp + 12 + n then begin
        for i = 0 to n - 1 do io_write (stage + !received + i) (rx (udp + 12 + i)) done;
        received := !received + n;
        send_ack block;
        next_block := block + 1;
        boot_tries := 0;
        boot_deadline := now () + 1000;
        (* a short block ends the transfer *)
        if n < 512 then begin
          boot_state := boot_idle;
          let _ = boot_now !received in ()
        end
      end else if block < !next_block then send_ack block
    end else if opcode = 5 then begin
      boot_state := boot_idle;
      uart_puts "boot: the server refused the file\n"
    end
  end

let boot_tick () =
  if !boot_state <> boot_idle && now () > !boot_deadline then begin
    boot_tries := !boot_tries + 1;
    if !boot_tries > 5 then begin
      boot_state := boot_idle;
      uart_puts "boot: no answer\n"
    end else begin
      if !boot_state = boot_arping then arp_for_server ()
      else if !next_block = 1 then send_rrq () else send_ack (!next_block - 1);
      boot_deadline := now () + 1000
    end
  end

let () = boot_action := start_boot
(* restart runs what is already staged, which is the image this program was
   booted from unless a boot has since overwritten it *)
let () = restart_action := (fun (_ : int) -> boot_now (staged_len ()))

let poll () =
  uart_poll ();
  dhcp_tick ();
  tcp_tick ();
  boot_tick ();
  let st = io_read eth_status in
  if st land eth_rx_valid <> 0 then begin
    let len = io_read eth_rxlen land 0x7FF in
    if rx 12 = 0x08 && rx 13 = 0x06 then begin
      handle_arp len;            (* requests for us *)
      server_arp_reply len       (* and the reply we asked for *)
    end
    else if rx 12 = 0x08 && rx 13 = 0x00 && len >= 42 then begin
      let ihl = (rx 14 land 0x0F) * 4 in
      let dport = (rx (14 + ihl + 2) lsl 8) lor rx (14 + ihl + 3) in
      if rx 23 = 1 then handle_icmp len ihl
      else if rx 23 = 17 && dport = 68 then handle_dhcp len
      else if rx 23 = 17 && dport = repl_port then handle_repl len ihl
      else if rx 23 = 17 && dport = tftp_local then tftp_data len
      else if rx 23 = 6 then handle_tcp len ihl
    end;
    io_write eth_rxlen 0;
    packets := !packets + 1;
    io_write leds ((if bound () then 2 else 0) lor ((!packets land 0x3F) lsl 2))
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
  puts "OCaml processor mini-ML (UART, UDP 7777, telnet 23) -- build ";
  uart_build ();
  newline ();
  puts "# ";
  while true do poll () done
(* ==== END MAIN ==== *)
