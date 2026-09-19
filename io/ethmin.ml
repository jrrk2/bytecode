(* ethmin in OCaml: ARP + ICMP echo, a port of
   vc707-openflow-demos/ethmin/fw/ethmin.c for the OCaml bytecode VM.

   The VM reaches the hardware through two primitives on one I/O space:
     0x0000..0x07FF  RX window (a byte per address)
     0x0800..0x0FFF  TX window
     0x1000  ETH_STATUS[15:0]: bit0 rx valid, bit1 tx busy, bit2 rx truncated
     0x1001  ETH_STATUS[31:16]: PHY status (split: an OCaml int is 31 bits)
     0x1002  ETH_RXLEN: read the frame length; write to release the RX window
     0x1003  ETH_TXLEN: write a length to send the TX window
     0x1004  LEDS
     0x1005  UART: write a byte *)

external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
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

let eth_rx_valid = 1
let eth_tx_busy = 2
let eth_rx_trunc = 4

let rx i = io_read (rx_base + i)
let tx i v = io_write (tx_base + i) v
let tx_get i = io_read (tx_base + i)

(* ---- identity ---- *)
let my_mac = "\x02\x00\x00\x4d\x47\x31"  (* "MG1" *)
let my_ip = "\192\168\001\042"
let mac i = int_of_char (string_get my_mac i)
let ip i = int_of_char (string_get my_ip i)

(* ---- uart ---- *)
let uart_putc c = io_write uart (int_of_char c)
let uart_puts s =
  for i = 0 to string_length s - 1 do uart_putc (string_get s i) done

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

(* ARP reply, built in the TX window from the request in the RX window. *)
let handle_arp len =
  if len >= 42 && rx 20 = 0x00 && rx 21 = 0x01 && ip_is_mine 38 then begin
    for i = 0 to 5 do
      tx i (rx (6 + i));               (* dest = requester *)
      tx (6 + i) (mac i)
    done;
    tx 12 0x08; tx 13 0x06;            (* ethertype ARP *)
    tx 14 0x00; tx 15 0x01;            (* HW: ethernet *)
    tx 16 0x08; tx 17 0x00;            (* proto: IPv4 *)
    tx 18 6; tx 19 4;
    tx 20 0x00; tx 21 0x02;            (* reply *)
    for i = 0 to 5 do tx (22 + i) (mac i) done;
    for i = 0 to 3 do tx (28 + i) (ip i) done;
    for i = 0 to 5 do tx (32 + i) (rx (22 + i)) done;
    for i = 0 to 3 do tx (38 + i) (rx (28 + i)) done;
    eth_send 42;
    uart_puts " -> arp reply\n"
  end

(* ICMP echo reply: copy the request across and patch it. *)
let handle_icmp len =
  if len >= 42 then begin
    let ihl = (rx 14 land 0x0F) * 4 in
    if rx 23 = 1 && ip_is_mine 30 && rx (14 + ihl) = 8 then begin
      for i = 0 to len - 1 do tx i (rx i) done;
      for i = 0 to 5 do
        tx i (rx (6 + i));
        tx (6 + i) (mac i)
      done;
      for i = 0 to 3 do                (* swap IPs *)
        tx (26 + i) (ip i);
        tx (30 + i) (rx (26 + i))
      done;
      tx 24 0; tx 25 0;                (* IP checksum *)
      let s = ip_checksum 14 ihl in
      tx 24 (s lsr 8); tx 25 (s land 0xFF);
      tx (14 + ihl) 0;                 (* echo REPLY *)
      tx (14 + ihl + 2) 0; tx (14 + ihl + 3) 0;
      let s = ip_checksum (14 + ihl) (len - 14 - ihl) in
      tx (14 + ihl + 2) (s lsr 8); tx (14 + ihl + 3) (s land 0xFF);
      eth_send len;
      uart_puts " -> echo reply\n"
    end
  end

let uart_hex16 v =
  let digits = "0123456789abcdef" in
  for k = 3 downto 0 do uart_putc (string_get digits ((v lsr (4 * k)) land 0xF)) done

let print_phy () =
  uart_puts " phy=";
  uart_hex16 (io_read eth_status_phy);
  uart_putc '\n'

let () =
  io_write leds 1;
  uart_puts "ethmin (OCaml VM): zero-copy eth DMA\n";
  print_phy ();
  let pkts = ref 0 in
  while true do
    let st = io_read eth_status in
    if st land eth_rx_valid <> 0 then begin
      let len = io_read eth_rxlen land 0x7FF in
      if st land eth_rx_trunc <> 0 then uart_puts " !! rx truncated\n";
      if rx 12 = 0x08 && rx 13 = 0x06 then handle_arp len
      else if rx 12 = 0x08 && rx 13 = 0x00 then handle_icmp len;
      io_write eth_rxlen 0;            (* release the RX window *)
      pkts := !pkts + 1;
      io_write leds (2 lor ((!pkts land 0x3F) lsl 2));
      print_phy ()                     (* bring-up oracle *)
    end
  done
