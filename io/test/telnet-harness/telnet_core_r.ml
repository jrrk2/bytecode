(* telnet: a minimal TCP, enough to hold an interactive session with a
   telnet (or `nc`) client.  DHCP, ARP and ICMP as dhcp.ml; then one TCP
   connection at a time on port 23, character-at-a-time, with a small
   command shell behind it.

     $ telnet 10.10.10.60
     OCaml processor.  Type "help".
     > time
     1843 ms since reset
     > quit

   What it implements, and no more: a passive open, the three-way
   handshake, in-order data with an immediate ACK, one outstanding segment
   with a retransmission timer, FIN both ways, RST on anything it cannot
   place.  Out-of-order segments are dropped and re-ACKed (the sender
   retransmits); there is no window scaling, no options besides MSS, no
   second connection.  For a line at a time from a person that is the whole
   of TCP that matters, and it costs about 1,200 bytecode instructions per
   packet -- the processor can answer a keystroke in under two
   milliseconds.

   Sequence numbers are 32-bit and this processor's int is 31 bits, so a
   sequence is a two-element array of 16-bit halves ([| hi; lo |]) and the
   arithmetic below is all 16-bit: add, compare, difference.  Nothing here
   needs a primitive the processor does not already have.

   I/O space as dhcp.ml, plus 0x1008: the next UART byte, or -1. *)



open Host_hw_r

let string_length = String.length
let string_get = String.get
let string_equal (a : string) b = a = b
let create_bytes = Bytes.create
let bytes_set = Bytes.set
let bytes_get = Bytes.get
let bytes_to_string = Bytes.to_string
let array_get = Array.get
let array_set = Array.set
let int_of_char = Char.code
let char_of_int = Char.chr


let uart_puts s = for i = 0 to string_length s - 1 do uart_putc (string_get s i) done
let rec uart_dec n =
  if n >= 10 then uart_dec (n / 10);
  uart_putc (char_of_int (48 + n mod 10))
let uart_ip a =
  for i = 0 to 3 do uart_dec (array_get a i); if i < 3 then uart_putc '.' done
let uart_hex16 v =
  let digits = "0123456789abcdef" in
  for k = 3 downto 0 do uart_putc (string_get digits ((v lsr (4 * k)) land 0xF)) done

(* ---- identity ---- *)
let my_mac = "\x02\x00\x00\x4d\x47\x34"   (* "MG4" *)
let mac i = int_of_char (string_get my_mac i)

(* ---- DHCP state (as dhcp.ml) ---- *)
type state = Init | Selecting | Requesting | Bound

let state = ref Init
let my_ip = [| 0; 0; 0; 0 |]
let offered_ip = [| 0; 0; 0; 0 |]
let server_id = [| 0; 0; 0; 0 |]
let xid = [| 0x56; 0x4d; 0; 0 |]
let deadline = ref 0
let lease_s = ref 0

let bound () = !state = Bound
let ip i = array_get my_ip i

(* ---- checksums over the TX window ---- *)
let lnot_16 s = s lxor 0xFFFF

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

let ip_checksum start len = fold (sum_tx start len)

let sum_rx start len =
  let s = ref 0 in
  let i = ref 0 in
  while !i + 1 < len do
    s := !s + ((rx (start + !i) lsl 8) lor rx (start + !i + 1));
    i := !i + 2
  done;
  if !i < len then s := !s + (rx (start + !i) lsl 8);
  !s

let ip_is_mine off =
  rx off = ip 0 && rx (off + 1) = ip 1 && rx (off + 2) = ip 2 && rx (off + 3) = ip 3

(* ---- ARP and ICMP echo ---- *)
let handle_arp len =
  if bound () && len >= 42 && rx 20 = 0x00 && rx 21 = 0x01 && ip_is_mine 38 then begin
    for i = 0 to 5 do tx i (rx (6 + i)); tx (6 + i) (mac i) done;
    tx 12 0x08; tx 13 0x06;
    tx 14 0x00; tx 15 0x01; tx 16 0x08; tx 17 0x00; tx 18 6; tx 19 4;
    tx 20 0x00; tx 21 0x02;
    for i = 0 to 5 do tx (22 + i) (mac i) done;
    for i = 0 to 3 do tx (28 + i) (ip i) done;
    for i = 0 to 5 do tx (32 + i) (rx (22 + i)) done;
    for i = 0 to 3 do tx (38 + i) (rx (28 + i)) done;
    eth_send 42
  end

let handle_icmp len ihl =
  if bound () && rx (14 + ihl) = 8 && ip_is_mine 30 then begin
    for i = 0 to len - 1 do tx i (rx i) done;
    for i = 0 to 5 do tx i (rx (6 + i)); tx (6 + i) (mac i) done;
    for i = 0 to 3 do tx (26 + i) (ip i); tx (30 + i) (rx (26 + i)) done;
    tx 24 0; tx 25 0;
    let s = ip_checksum 14 ihl in
    tx 24 (s lsr 8); tx 25 (s land 0xFF);
    tx (14 + ihl) 0;
    tx (14 + ihl + 2) 0; tx (14 + ihl + 3) 0;
    let s = fold (sum_tx (14 + ihl) (len - 14 - ihl)) in
    tx (14 + ihl + 2) (s lsr 8); tx (14 + ihl + 3) (s land 0xFF);
    eth_send len
  end

(* ---- DHCP client (as dhcp.ml) ---- *)
let bootp = 42
let dhcp_frame_len = 342

type dhcp_msg = Discover | Request

let dhcp_send msg =
  for i = 0 to dhcp_frame_len - 1 do tx i 0 done;
  for i = 0 to 5 do tx i 0xff; tx (6 + i) (mac i) done;
  tx 12 0x08; tx 13 0x00;
  tx 14 0x45; tx 16 ((dhcp_frame_len - 14) lsr 8); tx 17 ((dhcp_frame_len - 14) land 0xFF);
  tx 22 64; tx 23 17;
  for i = 0 to 3 do tx (30 + i) 0xff done;
  let s = ip_checksum 14 20 in
  tx 24 (s lsr 8); tx 25 (s land 0xFF);
  tx 35 68; tx 37 67;
  tx 38 ((dhcp_frame_len - 34) lsr 8); tx 39 ((dhcp_frame_len - 34) land 0xFF);
  tx bootp 1; tx (bootp + 1) 1; tx (bootp + 2) 6;
  for i = 0 to 3 do tx (bootp + 4 + i) (array_get xid i) done;
  tx (bootp + 10) 0x80;
  for i = 0 to 5 do tx (bootp + 28 + i) (mac i) done;
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
  opt 55; opt 3; opt 1; opt 3; opt 6;
  opt 255;
  eth_send dhcp_frame_len

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
    | Selecting, 2 -> request ()
    | Requesting, 5 ->
      for i = 0 to 3 do array_set my_ip i (array_get offered_ip i) done;
      state := Bound;
      deadline := now () + !lease_s * 500;
      uart_puts "dhcp: bound ";
      uart_ip my_ip;
      uart_putc '\n'
    | Requesting, 6 -> uart_puts "dhcp: nak\n"; state := Init
    | _ -> ()
  end

let dhcp_tick () =
  match !state with
  | Init -> discover ()
  | Selecting | Requesting -> if now () > !deadline then begin
      uart_puts "dhcp: timeout\n"; state := Init end
  | Bound -> if now () > !deadline then request ()

(* ---- 32-bit sequence numbers as two 16-bit halves ---- *)
let seq_set a hi lo = array_set a 0 hi; array_set a 1 lo
let seq_copy dst src = seq_set dst (array_get src 0) (array_get src 1)

(* a + n, n >= 0 and small *)
let seq_add a n =
  let lo = array_get a 1 + n in
  array_set a 1 (lo land 0xFFFF);
  array_set a 0 ((array_get a 0 + (lo lsr 16)) land 0xFFFF)

(* a - b as a signed distance, saturating outside +-32767: everything this
   code decides (is this the next byte? is this ack in flight?) is a
   comparison of numbers that are close together *)
let seq_diff a b =
  let dlo = array_get a 1 - array_get b 1 in
  let borrow = if dlo < 0 then 1 else 0 in
  let dhi = (array_get a 0 - array_get b 0 - borrow) land 0xFFFF in
  let dlo = dlo land 0xFFFF in
  if dhi = 0 then (if dlo < 32768 then dlo else 32767)
  else if dhi = 0xFFFF then (if dlo >= 32768 then dlo - 65536 else -32768)
  else if dhi land 0x8000 <> 0 then -32768
  else 32767

let seq_eq a b = array_get a 0 = array_get b 0 && array_get a 1 = array_get b 1

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
  out_len := 0;
  close_after := false;
  uart_puts "tcp: closed\n"

(* ---- the application behind the connection ---- *)
let line_max = 120
let line = create_bytes line_max
let line_len = ref 0
let prompt () = out_string "> "

let banner () =
  out_string "\r\nOCaml processor on an FPGA.  Type \"help\".\r\n";
  prompt ()

let line_string () =
  let b = create_bytes !line_len in
  for i = 0 to !line_len - 1 do bytes_set b i (bytes_get line i) done;
  bytes_to_string b

let run_line () =
  let s = line_string () in
  line_len := 0;
  if string_equal s "help" then
    out_string "commands: help, time, phy, ip, led <n>, echo <text>, quit\r\n"
  else if string_equal s "time" then begin
    out_dec (now ()); out_string " ms since reset\r\n" end
  else if string_equal s "phy" then begin
    out_string "phy status 0x"; 
    let v = phy () in
    let digits = "0123456789abcdef" in
    for k = 3 downto 0 do out_char (string_get digits ((v lsr (4 * k)) land 0xF)) done;
    out_string "\r\n" end
  else if string_equal s "ip" then begin
    for i = 0 to 3 do out_dec (ip i); if i < 3 then out_char '.' done;
    out_string "\r\n" end
  else if string_equal s "quit" then begin
    out_string "bye\r\n"; close_after := true end
  else if string_length s = 0 then ()
  else begin
    (* led <n> and echo <text>, else a complaint *)
    let word_is w =
      string_length s >= string_length w &&
      (let ok = ref true in
       for i = 0 to string_length w - 1 do
         if string_get s i <> string_get w i then ok := false done;
       !ok) in
    if word_is "led " then begin
      let v = ref 0 in
      for i = 4 to string_length s - 1 do
        let c = int_of_char (string_get s i) in
        if c >= 48 && c <= 57 then v := !v * 10 + c - 48
      done;
      set_leds !v;
      out_string "leds = "; out_dec !v; out_string "\r\n"
    end else if word_is "echo " then begin
      for i = 5 to string_length s - 1 do out_char (string_get s i) done;
      out_string "\r\n"
    end else
      out_string "?  try \"help\"\r\n"
  end;
  if not !close_after then prompt ()

(* One received byte, after telnet's escapes have been removed: echo it and
   collect a line.  The client is in character-at-a-time mode, so this is
   where the editing happens. *)
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
  end else if v = 3 then begin                     (* ^C *)
    line_len := 0;
    out_string "^C\r\n";
    prompt ()
  end else if v >= 32 && v < 127 then begin
    if !line_len < line_max then begin
      bytes_set line !line_len c;
      line_len := !line_len + 1;
      out_char c                                   (* the echo the client is not doing *)
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
        uart_puts "tcp: syn from ";
        uart_ip peer_ip;
        uart_putc ':';
        uart_dec sport;
        uart_putc '\n';
        send_segment 0x12 snd_nxt 0 true;                          (* SYN|ACK with MSS *)
        seq_add snd_nxt 1;
        rtx_at := now () + 400
      end else if syn && not ack && !tcp_state <> Closed then
        (* a second client while we are busy: refuse it *)
        (let s = [| 0; 0 |] in
         seq_copy s seg_ack;
         let saved_port = !peer_port and saved_mac = [| 0; 0; 0; 0; 0; 0 |]
         and saved_ip = [| 0; 0; 0; 0 |] in
         for i = 0 to 5 do array_set saved_mac i (array_get peer_mac i) done;
         for i = 0 to 3 do array_set saved_ip i (array_get peer_ip i) done;
         for i = 0 to 5 do array_set peer_mac i (rx (6 + i)) done;
         for i = 0 to 3 do array_set peer_ip i (rx (26 + i)) done;
         peer_port := sport;
         seq_copy rcv_nxt seg_seq;
         seq_add rcv_nxt 1;
         send_rst_to 0 0;
         for i = 0 to 5 do array_set peer_mac i (array_get saved_mac i) done;
         for i = 0 to 3 do array_set peer_ip i (array_get saved_ip i) done;
         peer_port := saved_port)
      else if from_peer then begin
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
    if in_flight > 0 && !rtx_at <> 0 && now () > !rtx_at then begin
      (* the head of the window again: SYN, data or FIN, whichever it was *)
      if !tcp_state = SynRcvd then send_segment 0x12 snd_una 0 true
      else if !tcp_state = LastAck then send_segment 0x11 snd_una 0 false
      else begin
        seq_copy snd_nxt snd_una;
        send_data ()
      end;
      rtx_at := now () + 800
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

(* ---- one pass of the machine ---- *)
let packets = ref 0

let poll () =
  dhcp_tick ();
  tcp_tick ();
  if rx_ready () then begin
    let len = rx_len () in
    if rx 12 = 0x08 && rx 13 = 0x06 then handle_arp len
    else if rx 12 = 0x08 && rx 13 = 0x00 && len >= 34 then begin
      let ihl = (rx 14 land 0x0F) * 4 in
      if rx 23 = 1 then handle_icmp len ihl
      else if rx 23 = 17 && rx (14 + ihl + 2) = 0 && rx (14 + ihl + 3) = 68 then handle_dhcp len
      else if rx 23 = 6 then handle_tcp len ihl
    end;
    rx_done ();
    packets := !packets + 1
  end;
  (* the UART is a second console: anything typed there goes to the client *)
  let c = uart_getc () in
  if c >= 0 && !tcp_state = Estab then out_char (char_of_int c)

