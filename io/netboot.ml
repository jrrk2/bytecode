(* netboot: the resident loader.  It leases an address by DHCP (as
   dhcp.ml), then fetches a program image by TFTP -- from the server and file
   the DHCP reply names (siaddr, file) -- or, when the DIP switches are
   set, this board's own network with the switches as the host number
   (1..255) -- else 10.10.10.10 and "vm.img" --
   into the staging RAM, checks it -- tools/mkvmimage.py's format, or a bytecode
   executable as ocamlc writes it, which is stripped where it lies to what the
   machine runs (its code, its global data as a heap image) -- and writes
   BOOT: the boot sequencer then loads it into the VM and starts it.
   (siaddr counts only when the reply names a file too.)

   I/O space as ethmin.ml, plus
     0x1006   milliseconds since reset (30 bits)
     0x1007   w: boot the staged image
     0x10000  the staging RAM, a byte per address (256 KiB)
     0x1010..0x1015  w: the staged image, where the sequencer is to find it (describe below)

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
external char_of_int : int -> char = "%identity"
external create_bytes : int -> bytes = "caml_create_bytes"
external bytes_set : bytes -> int -> char -> unit = "%bytes_unsafe_set"
external bytes_get : bytes -> int -> char = "%bytes_unsafe_get"

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
let stage_size = 0x40000   (* 256 KiB of staging RAM *)

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
let not_b (a : bool) = if a then false else true
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
        uart_puts ": boot server "; uart_ip server_ip; uart_putc ')'
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

(* ---- NFS: the image and the RAM disk's contents, with TFTP below as the fallback ---- *)
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

(* The export, and the files below it: bytecode/ and then one directory for each board, named by its MAC as the TFTP root's were.  Keep
   nfs_dir the same as my_mac.  tools/ and docs/NFS_README.md say how to export it. *)
let nfs_root = "/srv/nfs/vc707"
let nfs_image = "bytecode/02:00:00:4d:47:33/vm.img"
let nfs_disk_file = "bytecode/02:00:00:4d:47:33/disk.img"

(* where the fetched file goes: the staging RAM, or the RAM disk *)
let nfs_base = ref 0x10000
let nfs_limit = ref 0x40000
let () =
  nfs_dest_begin := (fun (_u : int) -> ());
  nfs_dest_room := (fun (_u : int) -> !nfs_limit);
  nfs_dest_put := (fun (o : int) (v : int) -> io_write (!nfs_base + o) v);
  nfs_dest_finish := (fun (_n : int) -> true)

(* ---- TFTP into the staging RAM, then boot ---- *)
let tftp_port = 6969
(* a fresh one for each request, so that a transfer the server is still running for an earlier request (it starts
   a second when a request is repeated) cannot be taken for the answer to this one *)
let local_port_base = 50000
let request_no = ref 0
let local_port = ref local_port_base
let block_size = 512

type boot = Waiting | Arping | Loading | Checking | Done | NfsImage | NfsDisk

let boot_state = ref Waiting
let server_port = ref tftp_port      (* the server's TID once its DATA arrives *)
let next_block = ref 1
let received = ref 0                 (* bytes of the file being fetched so far *)
let img_len = ref 0                  (* the program image's length, once it is staged *)
let want_disk = ref false            (* fetching the RAM disk's contents ("disk.img") after the image *)
let disk_name = "disk.img"
let disk_ram = 0x100000
(* the RFS magic, "RFS" in the first three bytes: the disk holds a file system *)
let disk_formatted () =
  io_read disk_ram = 0x52 && io_read (disk_ram + 1) = 0x46 && io_read (disk_ram + 2) = 0x53
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
  tx 34 (!local_port lsr 8); tx 35 (!local_port land 0xFF);
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
  let n = if !want_disk then string_length disk_name else !file_len in
  for i = 0 to n - 1 do
    tx (44 + i) (if !want_disk then int_of_char (string_get disk_name i) else array_get file_name i)
  done;
  let o = 44 + n in
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

let nfs_begin file base limit =
  for i = 0 to 3 do array_set nfs_ip i (array_get server_ip i) done;
  for i = 0 to 5 do array_set nfs_mac i 0 done;
  nfs_base := base; nfs_limit := limit;
  uart_puts "boot: nfs "; uart_ip server_ip; uart_putc ':'; uart_puts nfs_root; uart_putc '/'; uart_puts file; uart_putc '\n';
  nfs_launch nfs_root file

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
    want_disk := false;
    request_no := !request_no + 1; local_port := local_port_base + !request_no;
    send_rrq ();
    boot_state := Loading;
    boot_deadline := now () + 1000
  end

(* ---- the image: tools/mkvmimage.py's header, then code, heap, globals ---- *)
let byte i = io_read (stage + i)
let small i = byte i lor (byte (i + 1) lsl 8) lor (byte (i + 2) lsl 16)   (* a word < 2^24 *)
let code_max = 65535         (* the program code RAM, in words *)
let heap_max = 24576         (* heap image words: a semi-space is 32768, and the program has to live in it *)
let globals_max = 8192
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

(* Tell the sequencer where the staged image's sections are: lengths in words, then
   each section's first word in the staging RAM, then BOOT. *)
let describe code heap globals code_at heap_at globals_at =
  io_write 0x1010 code; io_write 0x1011 heap; io_write 0x1012 globals;
  io_write 0x1013 code_at; io_write 0x1014 heap_at; io_write 0x1015 globals_at

let start_it code heap globals =
  uart_puts "boot: ";
  uart_dec code; uart_puts " code, ";
  uart_dec heap; uart_puts " heap, ";
  uart_dec globals; uart_puts " globals words: starting it\n";
  io_write boot_reg 1

(* ---- a bytecode executable, stripped where it lies ----
   ocamlc's file is the shebang line, then the sections in the order of the table
   that ends the file (CODE, DLPT, DLLS, PRIM, DATA, SYMB, CRCS), then the table
   (a name and a big-endian length each), its count and "Caml1999X0nn".  What the
   machine runs is the code as it is and the DATA section, a marshalled block whose
   fields are the program's globals, laid out as the VM keeps a heap
   (tools/bc2image.ml does the same on the host).  The code stays where it is, the
   sequencer being told where; the heap image and the globals are built after the
   end of the file. *)
let be4 i = (byte i lsl 24) lor (byte (i + 1) lsl 16) lor (byte (i + 2) lsl 8) lor byte (i + 3)
let name_at i s =
  byte i = int_of_char (string_get s 0) && byte (i + 1) = int_of_char (string_get s 1)
  && byte (i + 2) = int_of_char (string_get s 2) && byte (i + 3) = int_of_char (string_get s 3)

let um = ref 0              (* the marshalled data: the next byte *)
let bad = ref false
let hb = ref 0              (* the heap image's base, and the next free byte of it *)
let hp = ref 0
let tbl = ref 0             (* the objects read so far: heap offsets, a word each *)
let nobj = ref 0
let atoms = ref 0           (* the zero-sized blocks, by tag: heap offset + 4, 0 for none yet *)

let nxt () = let c = byte !um in um := !um + 1; c
let rd n = let v = ref 0 in for _i = 1 to n do v := (!v lsl 8) lor nxt () done; !v
let sext bits v = if v >= 1 lsl (bits - 1) then v - (1 lsl bits) else v
(* a byte into the staging RAM at offset a *)
let sput a v = io_write (stage + a) v
let put3 a v = sput a (v land 0xFF); sput (a + 1) ((v lsr 8) land 0xFF); sput (a + 2) ((v lsr 16) land 0xFF)
let get3 a = byte a lor (byte (a + 1) lsl 8) lor (byte (a + 2) lsl 16)
(* an OCaml int n is the word 2n + 1, to its bit 31 *)
let put_int a n =
  sput a (((n lsl 1) lor 1) land 0xFF); sput (a + 1) ((n lsr 7) land 0xFF);
  sput (a + 2) ((n lsr 15) land 0xFF); sput (a + 3) ((n lsr 23) land 0xFF)
let put_ptr a off = put3 a off; sput (a + 3) 0       (* off is the block's byte offset: its index << 2 *)
let put_hdr a size tag = sput a tag; sput (a + 1) 0; sput (a + 2) (size land 0xFF); sput (a + 3) (size lsr 8)

let room n = if !hp + n > stage_size then bad := true
let nobj_max = ref 0
let register off =
  (if !nobj > !nobj_max then bad := true else put3 (!tbl + 4 * !nobj) off);
  nobj := !nobj + 1

(* one value of the marshalled data into the word at dst *)
let rec value dst =
  if not !bad then begin
    let c = nxt () in
    if c >= 0x80 then block dst (c land 0xF) ((c lsr 4) land 7)
    else if c >= 0x40 then put_int dst (c land 0x3F)
    else if c >= 0x20 then str dst (c land 0x1F)
    else if c = 0x00 then put_int dst (sext 8 (rd 1))
    else if c = 0x01 then put_int dst (sext 16 (rd 2))
    else if c = 0x02 then put_int dst (rd 4)
    else if c = 0x03 then begin um := !um + 4; put_int dst (rd 4) end
    else if c = 0x04 then shared dst (rd 1)
    else if c = 0x05 then shared dst (rd 2)
    else if c = 0x06 then shared dst (rd 4)
    else if c = 0x08 then begin let h = rd 4 in block dst (h land 0xFF) (h lsr 10) end
    else if c = 0x09 then str dst (rd 1)
    else if c = 0x0A then str dst (rd 4)
    else if c = 0x0C then copied dst 1 253
    else if c = 0x0E then copied dst (rd 1) 254
    else if c = 0x07 then copied dst (rd 4) 254
    else bad := true                        (* big-endian doubles, code pointers, custom blocks *)
  end

and shared dst k =
  let o = !nobj - k in
  if o < 0 || o >= !nobj then bad := true else put_ptr dst (get3 (!tbl + 4 * o))

and block dst tag size =
  if size = 0 then begin
    let e = get3 (!atoms + 4 * tag) in
    let off = if e <> 0 then e - 4 else begin
        room 4;
        let off = !hp - !hb in
        put_hdr !hp 0 tag; put3 (!atoms + 4 * tag) (off + 4); hp := !hp + 4; off
      end in
    put_ptr dst off
  end else begin
    room (4 + 4 * size);
    if size > 0xFFFF then bad := true;
    if not !bad then begin
      let off = !hp - !hb in
      register off;
      put_ptr dst off;
      put_hdr !hp size tag;
      let base = !hp + 4 in
      hp := base + 4 * size;
      for i = 0 to size - 1 do value (base + 4 * i) done
    end
  end

and str dst len =
  let nw = len / 4 + 1 in
  room (4 + 4 * nw);
  if not !bad then begin
    let off = !hp - !hb in
    register off;
    put_ptr dst off;
    put_hdr !hp nw 252;
    for i = 0 to 4 * nw - 1 do
      sput (!hp + 4 + i) (if i < len then nxt () else if i = 4 * nw - 1 then 4 * nw - 1 - len else 0)
    done;
    hp := !hp + 4 + 4 * nw
  end

(* doubles, little-endian: the bytes are the two words, low half first *)
and copied dst n tag =
  room (4 + 8 * n);
  if not !bad then begin
    let off = !hp - !hb in
    register off;
    put_ptr dst off;
    put_hdr !hp (2 * n) tag;
    for i = 0 to 8 * n - 1 do sput (!hp + 4 + i) (nxt ()) done;
    hp := !hp + 4 + 8 * n
  end

let strip_and_boot () =
  let e = !img_len in
  let n = if e >= 32 then be4 (e - 16) else 0 in
  let table = e - 16 - 8 * n in
  if e < 32 || byte (e - 12) <> int_of_char 'C' || byte (e - 4) <> int_of_char 'X' || n < 2 || n > 16 || table < 0 then
    reject "neither an image nor a bytecode executable"
  else begin
    let total = ref 0 in
    for i = 0 to n - 1 do total := !total + be4 (table + 8 * i + 4) done;
    let code_at = ref 0 and code_len = ref 0 and data_at = ref 0 and data_len = ref 0 in
    let pos = ref (table - !total) in
    for i = 0 to n - 1 do
      let len = be4 (table + 8 * i + 4) in
      if name_at (table + 8 * i) "CODE" then begin code_at := !pos; code_len := len end
      else if name_at (table + 8 * i) "DATA" then begin data_at := !pos; data_len := len end;
      pos := !pos + len
    done;
    let d = !data_at in
    if !code_len = 0 || !data_len < 24 || !pos < 0 then reject "no code or data section"
    else if !code_at land 3 <> 0 || !code_len land 3 <> 0 then reject "code not word aligned"
    else if !code_len / 4 > code_max then reject "too much code"
    else if byte d <> 0x84 || byte (d + 1) <> 0x95 || byte (d + 2) <> 0xA6 || byte (d + 3) <> 0xBE then
      reject "data is not marshalled"
    else begin
      let nobjects = be4 (d + 8) in
      um := d + 20;
      (* the root: a block whose fields are the globals *)
      let c = nxt () in
      let nglobals = if c >= 0x80 then (c lsr 4) land 7 else if c = 0x08 then rd 4 lsr 10 else 0 in
      let g0 = (e + 3) land (0 - 4) in
      tbl := g0 + 4 * nglobals;
      nobj_max := nobjects;
      atoms := !tbl + 4 * (nobjects + 1);
      hb := !atoms + 1024;
      hp := !hb;
      bad := nglobals = 0 || nglobals > globals_max || !hb + 4 > stage_size;
      if not !bad then begin
        for i = 0 to 255 do put3 (!atoms + 4 * i) 0 done;
        nobj := 0;
        register 0;                                   (* the root is object 0 *)
        for i = 0 to nglobals - 1 do value (g0 + 4 * i) done
      end;
      let heap = (!hp - !hb) / 4 in
      if !bad then reject "global data not convertible"
      else if heap > heap_max then reject "too much data"
      else begin
        describe (!code_len / 4) heap nglobals (!code_at / 4) (!hb / 4) (g0 / 4);
        start_it (!code_len / 4) heap nglobals
      end
    end
  end

let check_and_boot () =
  let code = small 8 and heap = small 12 and globals = small 16 in
  if !img_len >= 4 && not (byte 0 = 0x4f && byte 1 = 0x43 && byte 2 = 0x56 && byte 3 = 0x4d) then strip_and_boot ()
  else if !img_len < 32 then reject "short"
  else if byte 0 <> 0x4f || byte 1 <> 0x43 || byte 2 <> 0x56 || byte 3 <> 0x4d then reject "magic"
  else if byte 4 <> 1 || small 5 <> 0 then reject "version"
  else if byte 11 <> 0 || byte 15 <> 0 || byte 19 <> 0
          || code > code_max || heap > heap_max || globals > globals_max then reject "too large"
  else if 32 + 4 * (code + heap + globals) <> !img_len then reject "length"
  else if byte 20 <> array_get prims_digest 0 || byte 21 <> array_get prims_digest 1
          || byte 22 <> array_get prims_digest 2 || byte 23 <> array_get prims_digest 3 then
    reject "built for other primitives"
  else if crc16 32 !img_len <> (byte 24 lor (byte 25 lsl 8)) then reject "checksum"
  else begin
    describe code heap globals 8 (8 + code) (8 + code + heap);
    start_it code heap globals
  end

let tftp_data len =
  let udp = 34 in
  let opcode = (rx (udp + 8) lsl 8) lor rx (udp + 9) in
  if !boot_state = Loading && ip_is_mine 30
     && rx 26 = array_get server_ip 0 && rx 27 = array_get server_ip 1
     && rx 28 = array_get server_ip 2 && rx 29 = array_get server_ip 3
     && ((rx (udp + 2) lsl 8) lor rx (udp + 3)) = !local_port then begin
    if opcode = 3 then begin
      let block = (rx (udp + 10) lsl 8) lor rx (udp + 11) in
      let n = ((rx (udp + 4) lsl 8) lor rx (udp + 5)) - 12 in
      (* the server's TID is the port its first block comes from, and from then on the only one listened to *)
      let from_port = (rx udp lsl 8) lor rx (udp + 1) in
      (if !next_block = 1 && !received = 0 then server_port := from_port);
      if from_port <> !server_port then ()
      else
      let limit = if !want_disk then io_read 0x100d else stage_size in
      let base = if !want_disk then disk_ram else stage in
      if block = !next_block && !received + n > limit then begin
        (* silence here looks like a dead server: say so instead *)
        uart_puts (if !want_disk then "boot: disk image needs more than " else "boot: image needs more than ");
        uart_dec limit;
        uart_puts (if !want_disk then " bytes of RAM disk\n" else " bytes of staging RAM\n");
        want_disk := false;
        boot_state := Waiting;
        boot_deadline := now () + 5000
      end else if block = !next_block && !received + n <= limit && len >= udp + 12 + n then begin
        for i = 0 to n - 1 do io_write (base + !received + i) (rx (udp + 12 + i)) done;
        received := !received + n;
        send_ack block;
        next_block := block + 1;
        tries := 0;
        boot_deadline := now () + 1000;
        if n < block_size then begin
          if !want_disk then begin
            uart_puts "boot: RAM disk "; uart_dec !received; uart_puts " bytes\n";
            boot_state := Checking
          end else begin
            uart_puts "boot: ";
            uart_dec !received;
            uart_puts " bytes\n";
            img_len := !received;
            if disk_formatted () then begin
              (* back from a program that ran: the disk has its files, which a fetch would replace *)
              uart_puts "boot: RAM disk kept\n";
              boot_state := Checking
            end else begin
              (* then the RAM disk's contents, if the server has them: a file system with what the
                 program is to work on *)
              want_disk := true;
              next_block := 1;
              received := 0;
              tries := 0;
              server_port := tftp_port;
              request_no := !request_no + 1; local_port := local_port_base + !request_no;
              send_rrq ();
              boot_deadline := now () + 1000
            end
          end
        end
      end else if block < !next_block then send_ack block        (* a repeat: ACK again *)
    end else if opcode = 5 then begin
      if !want_disk then begin
        uart_puts "boot: no RAM disk image\n";             (* not every program wants one *)
        boot_state := Checking
      end else begin
        uart_puts "boot: tftp error\n";
        boot_state := Waiting;
        boot_deadline := now () + 5000
      end
    end
  end

let try_tftp = ref false     (* NFS did not answer: the next attempt is by TFTP *)

let boot_tick () =
  if bound () then
    match !boot_state with
    | Waiting ->
      if now () > !boot_deadline then begin
        if !try_tftp then begin try_tftp := false; start_boot () end
        else begin nfs_begin nfs_image stage stage_size; boot_state := NfsImage end
      end
    | NfsImage ->
      if !nfs_result >= 0 then begin
        img_len := !nfs_result; received := !nfs_result;
        if disk_formatted () then begin
          uart_puts "boot: RAM disk kept\n";
          boot_state := Checking
        end else begin
          nfs_begin nfs_disk_file disk_ram (io_read 0x100d);
          boot_state := NfsDisk
        end
      end else if !nfs_result = 0 - 2 then begin
        uart_puts "boot: nfs failed, trying tftp\n";
        try_tftp := true;
        boot_state := Waiting;
        boot_deadline := now ()
      end
    | NfsDisk ->
      if !nfs_result >= 0 then begin
        uart_puts "boot: RAM disk "; uart_dec !nfs_result; uart_puts " bytes\n";
        boot_state := Checking
      end else if !nfs_result = 0 - 2 then begin
        uart_puts "boot: no RAM disk image\n";
        boot_state := Checking
      end
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

(* ---- boot over the serial line, with the network left alone ----
   For a run whose behaviour must not depend on what is on the network (frames arriving change what the compiler
   allocates, and so when it collects), the program and the RAM disk come in over the UART.  Within a few
   seconds of reset the host sends 0x01; then: the program's length (4 bytes, little-endian) and its bytes, with 0x14 and 0x7D escaped as 0x7D and the byte xor 0x20, the
   RAM disk image's length (4 bytes) and its bytes (0 for none).  The loader checks and boots the program as for
   TFTP, and leaves a mark in the last byte of the RAM disk (0x4E, "N") that the compiler reads to keep its network
   handling off too. *)
let uart_rx = 0x1008

let rec wait_byte limit_ms =
  let t0 = now () in
  let rec go () =
    let c = io_read uart_rx in
    if c >= 0 then c
    else if now () - t0 > limit_ms then 0 - 1
    else go () in
  go ()

(* 0x14 (Ctrl-T, the trace dump) never reaches a program, so the stream escapes it: 0x7D then the byte xor 0x20 *)
let sbyte () =
  let c = wait_byte 5000 in
  if c = 0x7D then (let d = wait_byte 5000 in if d < 0 then d else d lxor 0x20) else c

let serial_len () =
  let a = sbyte () in let b = sbyte () in let c = sbyte () in let d = sbyte () in
  if a < 0 || b < 0 || c < 0 || d < 0 then 0 - 1 else a lor (b lsl 8) lor (c lsl 16) lor (d lsl 24)

let serial_boot () =
  uart_puts "serial boot: program length?\n";
  let n1 = serial_len () in
  if n1 <= 0 || n1 > stage_size then uart_puts "serial boot: bad program length\n"
  else begin
    let i = ref 0 and ok = ref true in
    while !ok && !i < n1 do
      let c = sbyte () in
      if c < 0 then ok := false else begin io_write (stage + !i) c; i := !i + 1 end
    done;
    if not !ok then uart_puts "serial boot: program cut short\n"
    else begin
      let n2 = serial_len () in
      let disk = io_read 0x100d in
      if n2 < 0 || n2 > disk - 1 then uart_puts "serial boot: bad disk length\n"
      else begin
        let j = ref 0 and ok2 = ref true in
        while !ok2 && !j < n2 do
          let c = sbyte () in
          if c < 0 then ok2 := false else begin io_write (disk_ram + !j) c; j := !j + 1 end
        done;
        if not !ok2 then uart_puts "serial boot: disk cut short\n"
        else begin
          io_write (disk_ram + disk - 1) 0x4E;                          (* no network, please *)
          received := n1; img_len := n1;
          uart_puts "serial boot: "; uart_dec n1; uart_puts " + "; uart_dec n2; uart_puts " bytes\n";
          check_and_boot ()
        end
      end
    end
  end

(* the window after reset in which the host may ask for it *)
let serial_window () =
  uart_puts "serial boot window\n";
  let t0 = now () in
  while now () - t0 < 4000 do
    if io_read uart_rx = 1 then serial_boot ()
  done

(* ---- an image already in the staging RAM when the board starts ----
   tools/preload.py can set a block RAM's initial contents in a built bitstream, so the staging RAM can hold a program from
   power-up: the image from offset 0, and at 0x3FFF0 "PREL" and its length (3 bytes, little-endian).  The loader boots it before
   it looks at the network.  A button held down skips it, and so does an image that does not check out. *)
let preload_at = 0x3FFF0
let try_preload () =
  if byte preload_at = 0x50 && byte (preload_at + 1) = 0x52 && byte (preload_at + 2) = 0x45 && byte (preload_at + 3) = 0x4C
     && io_read buttons land 0x1F = 0 then begin
    img_len := small (preload_at + 4);
    uart_puts "boot: preloaded image, "; uart_dec !img_len; uart_puts " bytes\n";
    check_and_boot ()
  end

let () =
  io_write leds 1;
  uart_puts "netboot (OCaml processor): build ";
  uart_build ();
  uart_puts " phy=";
  uart_hex16 (io_read eth_status_phy);
  uart_putc '\n';
  serial_window ();
  try_preload ();
  let pkts = ref 0 in
  while true do
    dhcp_tick ();
    nfs_tick ();
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
      if rx 12 = 0x08 && rx 13 = 0x06 then begin handle_arp len; server_arp_reply len; nfs_arp_reply len end
      else if rx 12 = 0x08 && rx 13 = 0x00 && len >= 42 then begin
        let ihl = (rx 14 land 0x0F) * 4 in
        if rx 23 = 1 then handle_icmp len ihl
        else if rx 23 = 17 && rx (14 + ihl + 2) = 0 && rx (14 + ihl + 3) = 68 then handle_dhcp len
        else if rx 23 = 17 && ihl = 20 then begin
          if ((rx 36 lsl 8) lor rx 37) = nfs_lport then nfs_reply len else tftp_data len
        end
      end;
      io_write eth_rxlen 0;
      pkts := !pkts + 1;
      io_write leds ((if bound () then 2 else 0) lor ((!pkts land 0x3F) lsl 2))
    end
  done
