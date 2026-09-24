(* netboot: the resident loader.  It leases an address by DHCP (as
   dhcp.ml), then fetches a program image by TFTP -- from the server and file
   the DHCP reply names (siaddr, file) -- or, when the DIP switches are
   set, this board's own network with the switches as the host number
   (1..255) -- else 10.10.10.10 and "vm.img" --
   into the staging RAM, checks it (tools/mkvmimage.py's format) and writes
   BOOT: the boot sequencer then loads it into the VM and starts it.
   (siaddr counts only when the reply names a file too.)

   I/O space as ethmin.ml, plus
     0x1006   milliseconds since reset (30 bits)
     0x1007   w: boot the staged image
     0x10000  the staging RAM, a byte per address (64 KiB)

   Init -> DISCOVER -> Selecting -> (OFFER) REQUEST -> Requesting -> (ACK)
   Bound; a timeout in Selecting or Requesting starts again, and a Bound
   client renews (REQUEST) at T1, half the lease.  Addresses and the
   transaction id are 4-byte arrays: 32 bits do not fit an OCaml int here. *)

(* regress-tftp: hellofor.ml -- the program the regression's model serves *)

external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
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
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
external not : bool -> bool = "%boolnot"
external string_length : string -> int = "%string_length"
external string_get : string -> int -> char = "%string_safe_get"
external int_of_char : char -> int = "%identity"
external array_get : 'a array -> int -> 'a = "%array_safe_get"
external array_set : 'a array -> int -> 'a -> unit = "%array_safe_set"

type 'a ref = { mutable contents : 'a }
external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"

external io_read : int -> int = "vm_io_read"
external io_write : int -> int -> unit = "vm_io_write"

(* ---- memory map ---- *)
let rx_base = 0x0000
let tx_base = 0x0800
let eth_status = 0x1000
let eth_status_phy = 0x1001
let eth_rxlen = 0x1002
let eth_txlen = 0x1003
let leds = 0x1004
let uart = 0x1005
let timer_ms = 0x1006
let dip_sw = 0x1009
let buttons = 0x100b
let boot_reg = 0x1007
let stage = 0x10000
let stage_size = 0x20000   (* 128 KiB of staging RAM *)

let eth_rx_valid = 1
let eth_tx_busy = 2
let eth_rx_trunc = 4

let rx i = io_read (rx_base + i)
let tx i v = io_write (tx_base + i) v
let tx_get i = io_read (tx_base + i)
let now () = io_read timer_ms

(* ---- identity ---- *)
let my_mac = "\x02\x00\x00\x4d\x47\x33"  (* "MG3": its own DHCP client and per-MAC TFTP directory *)
let mac i = int_of_char (string_get my_mac i)

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

(* ---- uart ---- *)
let uart_putc c = io_write uart (int_of_char c)
let uart_puts s =
  for i = 0 to string_length s - 1 do uart_putc (string_get s i) done
let rec uart_dec n =
  if n >= 10 then uart_dec (n / 10);
  io_write uart (48 + n mod 10)
let uart_ip a =
  for i = 0 to 3 do
    uart_dec (array_get a i);
    if i < 3 then uart_putc '.'
  done

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
    eth_send 42;
    uart_puts " -> arp reply\n"
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
    eth_send len;
    uart_puts " -> echo reply\n"
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
  uart_puts "dhcp: discover\n";
  dhcp_send Discover;
  state := Selecting;
  deadline := now () + 4000

let request () =
  uart_puts "dhcp: request ";
  uart_ip offered_ip;
  uart_putc '\n';
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

(* ---- where to boot from ---- *)
let server_ip = [| 10; 10; 10; 10 |]
let server_mac = [| 0; 0; 0; 0; 0; 0 |]
let file_name = [| 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0;
                   0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0; 0 |]
let file_len = ref 0
let default_file = "vm.img"

(* The ACK's boot file and siaddr (the BOOTP fields), when it names a file.
   siaddr alone is no sign of a boot service: home routers commonly put
   their own address there, so without a file the defaults stand. *)
let note_boot_server () =
  file_len := 0;
  while !file_len < 31 && rx (bootp + 108 + !file_len) <> 0 do
    array_set file_name !file_len (rx (bootp + 108 + !file_len));
    file_len := !file_len + 1
  done;
  if !file_len > 0 && rx (bootp + 20) <> 0 then
    for i = 0 to 3 do array_set server_ip i (rx (bootp + 20 + i)) done;
  if !file_len = 0 then begin
    for i = 0 to string_length default_file - 1 do
      array_set file_name i (int_of_char (string_get default_file i))
    done;
    file_len := string_length default_file
  end

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
      note_boot_server ();
      (* The address is the one the server handed out.  The DIP switches
         (SW11) say who serves the image: this board's own network, with the
         eight switches as the host number, 1..255 -- so the board can move
         to another network with nothing to set, and which machine holds
         vm.img is a front-panel decision.  All switches off leaves the
         reply's siaddr (or the 10.10.10.10 fallback) in charge. *)
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
        uart_puts " (dip "; uart_dec (io_read dip_sw land 0xFF);
        uart_puts ": tftp from "; uart_ip server_ip; uart_putc ')'
      end;
      uart_puts " lease ";
      uart_dec !lease_s;
      uart_puts " s from ";
      uart_ip server_id;
      uart_putc '\n'
    | Requesting, 6 -> uart_puts "dhcp: nak\n"; state := Init  (* NAK *)
    | _ -> ()
  end

let dhcp_tick () =
  match !state with
  | Init -> discover ()
  | Selecting | Requesting -> if now () > !deadline then begin
      uart_puts "dhcp: timeout\n"; state := Init end
  | Bound -> if now () > !deadline then request ()             (* renew *)

(* ---- TFTP into the staging RAM, then boot ---- *)
let tftp_port = 6969
let local_port = 50000
let block_size = 512

type boot = Waiting | Arping | Loading | Checking | Done

let boot_state = ref Waiting
let server_port = ref tftp_port      (* the server's TID once its DATA arrives *)
let next_block = ref 1
let received = ref 0                 (* bytes staged *)
let boot_deadline = ref 0
let tries = ref 0

(* Ethernet, IP and UDP headers to the boot server; the payload goes at 42. *)
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
  tx 34 (local_port lsr 8); tx 35 (local_port land 0xFF);
  tx 36 (dport lsr 8); tx 37 (dport land 0xFF);
  tx 38 ((8 + payload_len) lsr 8); tx 39 ((8 + payload_len) land 0xFF);
  tx 40 0; tx 41 0;                                             (* no UDP checksum *)
  eth_send len

let arp_for_server () =
  for i = 0 to 5 do tx i 0xff; tx (6 + i) (mac i) done;
  tx 12 0x08; tx 13 0x06;
  tx 14 0x00; tx 15 0x01; tx 16 0x08; tx 17 0x00; tx 18 6; tx 19 4;
  tx 20 0x00; tx 21 0x01;                                       (* request *)
  for i = 0 to 5 do tx (22 + i) (mac i); tx (32 + i) 0 done;
  for i = 0 to 3 do tx (28 + i) (ip i); tx (38 + i) (array_get server_ip i) done;
  eth_send 42

let send_rrq () =
  tx 42 0; tx 43 1;                                             (* RRQ *)
  for i = 0 to !file_len - 1 do tx (44 + i) (array_get file_name i) done;
  let o = 44 + !file_len in
  tx o 0;
  let mode = "octet" in
  for i = 0 to 4 do tx (o + 1 + i) (int_of_char (string_get mode i)) done;
  tx (o + 6) 0;
  udp_to_server tftp_port (o + 7 - 42)

let send_ack block =
  tx 42 0; tx 43 4; tx 44 (block lsr 8); tx 45 (block land 0xFF);
  udp_to_server !server_port 4

let start_boot () =
  uart_puts "boot: arp for ";
  uart_ip server_ip;
  uart_putc '\n';
  arp_for_server ();
  boot_state := Arping;
  tries := 0;
  boot_deadline := now () + 1000

let server_arp_reply len =
  if !boot_state = Arping && len >= 42 && rx 21 = 2
     && rx 28 = array_get server_ip 0 && rx 29 = array_get server_ip 1
     && rx 30 = array_get server_ip 2 && rx 31 = array_get server_ip 3 then begin
    for i = 0 to 5 do array_set server_mac i (rx (22 + i)) done;
    uart_puts "boot: tftp ";
    for i = 0 to !file_len - 1 do io_write uart (array_get file_name i) done;
    uart_putc '\n';
    server_port := tftp_port;
    next_block := 1;
    received := 0;
    tries := 0;
    send_rrq ();
    boot_state := Loading;
    boot_deadline := now () + 1000
  end

(* ---- the image: tools/mkvmimage.py's header, then code, heap, globals ---- *)
let byte i = io_read (stage + i)
let small i = byte i lor (byte (i + 1) lsl 8) lor (byte (i + 2) lsl 16)   (* a word < 2^24 *)
let code_max = 32768         (* the program code RAM, in words *)
let heap_max = 4096          (* heap image words the VM's heap can take *)
let globals_max = 4096
let prims_digest = [| 0x21; 0xad; 0xa2; 0x86 |]   (* mkvmimage.py: this VM's primitives *)

let crc16 from upto =
  let crc = ref 0xFFFF in
  for i = from to upto - 1 do
    crc := !crc lxor (byte i lsl 8);
    for _bit = 1 to 8 do
      if !crc land 0x8000 <> 0 then crc := ((!crc lsl 1) lxor 0x1021) land 0xFFFF
      else crc := (!crc lsl 1) land 0xFFFF
    done
  done;
  !crc

let reject why = uart_puts "boot: image rejected: "; uart_puts why; uart_putc '\n'

let check_and_boot () =
  let code = small 8 and heap = small 12 and globals = small 16 in
  if !received < 32 then reject "short"
  else if byte 0 <> 0x4f || byte 1 <> 0x43 || byte 2 <> 0x56 || byte 3 <> 0x4d then reject "magic"
  else if byte 4 <> 1 || small 5 <> 0 then reject "version"
  else if byte 11 <> 0 || byte 15 <> 0 || byte 19 <> 0
          || code > code_max || heap > heap_max || globals > globals_max then reject "too large"
  else if 32 + 4 * (code + heap + globals) <> !received then reject "length"
  else if byte 20 <> array_get prims_digest 0 || byte 21 <> array_get prims_digest 1
          || byte 22 <> array_get prims_digest 2 || byte 23 <> array_get prims_digest 3 then
    reject "built for other primitives"
  else if crc16 32 !received <> (byte 24 lor (byte 25 lsl 8)) then reject "checksum"
  else begin
    uart_puts "boot: ";
    uart_dec code; uart_puts " code, ";
    uart_dec heap; uart_puts " heap, ";
    uart_dec globals; uart_puts " globals words: starting it\n";
    io_write boot_reg 1
  end

let tftp_data len =
  let udp = 34 in
  let opcode = (rx (udp + 8) lsl 8) lor rx (udp + 9) in
  if !boot_state = Loading && ip_is_mine 30
     && rx 26 = array_get server_ip 0 && rx 27 = array_get server_ip 1
     && rx 28 = array_get server_ip 2 && rx 29 = array_get server_ip 3
     && ((rx (udp + 2) lsl 8) lor rx (udp + 3)) = local_port then begin
    if opcode = 3 then begin
      let block = (rx (udp + 10) lsl 8) lor rx (udp + 11) in
      let n = ((rx (udp + 4) lsl 8) lor rx (udp + 5)) - 12 in
      server_port := (rx udp lsl 8) lor rx (udp + 1);
      if block = !next_block && !received + n > stage_size then begin
        (* silence here looks like a dead server: say so instead *)
        uart_puts "boot: image needs more than ";
        uart_dec stage_size;
        uart_puts " bytes of staging RAM\n";
        boot_state := Waiting;
        boot_deadline := now () + 5000
      end else if block = !next_block && !received + n <= stage_size && len >= udp + 12 + n then begin
        for i = 0 to n - 1 do io_write (stage + !received + i) (rx (udp + 12 + i)) done;
        received := !received + n;
        send_ack block;
        next_block := block + 1;
        tries := 0;
        boot_deadline := now () + 1000;
        if n < block_size then begin
          uart_puts "boot: ";
          uart_dec !received;
          uart_puts " bytes\n";
          boot_state := Checking
        end
      end else if block < !next_block then send_ack block        (* a repeat: ACK again *)
    end else if opcode = 5 then begin
      uart_puts "boot: tftp error\n";
      boot_state := Waiting;
      boot_deadline := now () + 5000
    end
  end

let boot_tick () =
  if bound () then
    match !boot_state with
    | Waiting -> if now () > !boot_deadline then start_boot ()
    | Arping | Loading ->
      if now () > !boot_deadline then begin
        tries := !tries + 1;
        if !tries > 5 then begin
          uart_puts "boot: no answer\n";
          boot_state := Waiting;
          boot_deadline := now () + 5000
        end else begin
          (match !boot_state with
           | Arping -> arp_for_server ()
           | _ -> if !next_block = 1 then send_rrq () else send_ack (!next_block - 1));
          boot_deadline := now () + 1000
        end
      end
    | Checking -> check_and_boot (); boot_state := Done
    | Done -> ()

(* The receive log: a line per frame -- what it was, from whom, and whether
   its destination was this board, which is what a ping that does not come
   back is asking.  It costs a few milliseconds of UART per frame, so on a
   busy network it is not something to leave on: hold any of the board's
   push buttons and the frames are logged while the button is down.
   debug_rx_hex adds the raw head, for a receive path that delivers damaged
   frames. *)
let debug_rx () = io_read buttons land 0x1F <> 0
let debug_rx_hex = false
let uart_ip_at off =
  for i = 0 to 3 do
    uart_dec (rx (off + i));
    if i < 3 then uart_putc '.'
  done

let uart_hex8 v =
  let d n = if n < 10 then int_of_char '0' + n else int_of_char 'a' + n - 10 in
  io_write uart (d ((v lsr 4) land 15)); io_write uart (d (v land 15))
let uart_hex16 v =
  let digits = "0123456789abcdef" in
  for k = 3 downto 0 do uart_putc (string_get digits ((v lsr (4 * k)) land 0xF)) done

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

let () =
  io_write leds 1;
  uart_puts "netboot (OCaml processor): build ";
  uart_build ();
  uart_puts " phy=";
  uart_hex16 (io_read eth_status_phy);
  uart_putc '\n';
  let pkts = ref 0 in
  while true do
    dhcp_tick ();
    boot_tick ();
    let st = io_read eth_status in
    if st land eth_rx_valid <> 0 then begin
      let len = io_read eth_rxlen land 0x7FF in
      if debug_rx () then begin
        (* One line per frame, named rather than dumped: which protocol
           arrived, from and to which address, and -- the question a ping
           that does not come back asks -- whether it was for us.  The raw
           head is still there under debug_rx_hex, for a receive path that
           delivers damaged frames. *)
        uart_puts "rx "; uart_dec len; uart_putc ' ';
        let et = (rx 12 lsl 8) lor rx 13 in
        if et = 0x0806 then begin
          uart_puts "arp ";
          uart_dec (rx 27);                                  (* opcode: 1 request, 2 reply *)
          uart_puts " who-has "; uart_ip_at 38;
          uart_puts " tell "; uart_ip_at 28
        end else if et = 0x0800 then begin
          let ihl = (rx 14 land 0x0F) * 4 in
          let proto = rx 23 in
          uart_ip_at 26; uart_puts " -> "; uart_ip_at 30;
          uart_puts (if ip_is_mine 30 then " (mine)" else " (not mine)");
          if proto = 1 then begin
            uart_puts " icmp type "; uart_dec (rx (14 + ihl))
          end else if proto = 17 then begin
            uart_puts " udp "; uart_dec ((rx (14 + ihl) lsl 8) lor rx (14 + ihl + 1));
            uart_puts " -> "; uart_dec ((rx (14 + ihl + 2) lsl 8) lor rx (14 + ihl + 3))
          end else begin
            uart_puts " proto "; uart_dec proto
          end
        end else begin
          uart_puts "ethertype 0x"; uart_hex16 et
        end;
        uart_putc '\n';
        if debug_rx_hex then begin
          uart_puts "   ";
          for i = 0 to 15 do uart_putc ' '; uart_hex8 (rx i) done;
          uart_putc '\n'
        end
      end;
      if rx 12 = 0x08 && rx 13 = 0x06 then begin handle_arp len; server_arp_reply len end
      else if rx 12 = 0x08 && rx 13 = 0x00 && len >= 42 then begin
        let ihl = (rx 14 land 0x0F) * 4 in
        if rx 23 = 1 then handle_icmp len ihl
        else if rx 23 = 17 && rx (14 + ihl + 2) = 0 && rx (14 + ihl + 3) = 68 then handle_dhcp len
        else if rx 23 = 17 && ihl = 20 then tftp_data len
      end;
      io_write eth_rxlen 0;
      pkts := !pkts + 1;
      io_write leds ((if bound () then 2 else 0) lor ((!pkts land 0x3F) lsl 2))
    end
  done
