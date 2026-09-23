(* The device's TCP meeting frames a real network produces: a SYN with the
   options Linux sends, a peer that stops answering, and a caller knocking
   while a session whose peer has gone home is still held. *)
let () =
  Telnet_core.state := Telnet_core.Bound;
  Telnet_core.my_ip.(0) <- 10; Telnet_core.my_ip.(1) <- 0;
  Telnet_core.my_ip.(2) <- 0; Telnet_core.my_ip.(3) <- 2;
  Telnet_core.deadline := max_int

let put f i v = Bytes.set f i (Char.chr (v land 0xFF))
let put16 f i v = put f i (v lsr 8); put f (i + 1) v
let get16 f i = (Char.code (Bytes.get f i) lsl 8) lor Char.code (Bytes.get f (i + 1))

let seg ?(opts = Bytes.empty) ?(sport = 40000) ~flags ~seq ~ack () =
  let olen = Bytes.length opts in
  let tcp_len = 20 + olen in
  let ip_len = 20 + tcp_len in
  let f = Bytes.make (14 + ip_len) '\000' in
  List.iteri (fun i v -> put f i v) [0x02;0x00;0x00;0x4d;0x47;0x34;
                                     0x02;0x00;0x00;0x11;0x22;0x33];
  put16 f 12 0x0800;
  put f 14 0x45; put16 f 16 ip_len; put16 f 18 0x1234; put f 20 0x40;
  put f 22 64; put f 23 6;
  List.iteri (fun i v -> put f (26 + i) v) [10;0;0;1];
  List.iteri (fun i v -> put f (30 + i) v) [10;0;0;2];
  let s = ref 0 in
  for i = 0 to 9 do s := !s + get16 f (14 + 2*i) done;
  while !s > 0xFFFF do s := (!s land 0xFFFF) + (!s lsr 16) done;
  put16 f 24 ((lnot !s) land 0xFFFF);
  put16 f 34 sport; put16 f 36 23;
  put16 f 38 (seq lsr 16); put16 f 40 (seq land 0xFFFF);
  put16 f 42 (ack lsr 16); put16 f 44 (ack land 0xFFFF);
  put f 46 ((5 + olen / 4) lsl 4); put f 47 flags;
  put16 f 48 64240;
  Bytes.blit opts 0 f 54 olen;
  let ps = ref (((10 lsl 8) lor 0) + 1 + ((10 lsl 8) lor 0) + 2 + 6 + tcp_len) in
  for i = 0 to tcp_len / 2 - 1 do ps := !ps + get16 f (34 + 2*i) done;
  while !ps > 0xFFFF do ps := (!ps land 0xFFFF) + (!ps lsr 16) done;
  put16 f 50 ((lnot !ps) land 0xFFFF);
  f

let opts_linux =
  Bytes.of_string "\002\004\005\180\004\002\008\010\000\000\000\001\000\000\000\000\001\003\003\007"
let opts_mss = Bytes.of_string "\002\004\005\180"

let answers () =
  let l = ref [] in
  while not (Queue.is_empty Host_hw.tx_q) do l := Queue.pop Host_hw.tx_q :: !l done;
  List.rev !l

let run ?frame passes =
  (match frame with Some f -> Host_hw.deliver f | None -> ());
  for _ = 1 to passes do incr Host_hw.clock; Telnet_core.poll () done;
  answers ()

let describe fs =
  String.concat " " (List.map (fun b ->
      Printf.sprintf "[%d bytes flags 0x%02x seq %04x%04x]" (Bytes.length b)
        (Char.code (Bytes.get b 47)) (get16 b 38) (get16 b 40)) fs)

let uart () = let s = Buffer.contents Host_hw.uart_buf in Buffer.clear Host_hw.uart_buf; s
let state () = if !Telnet_core.tcp_state = Telnet_core.Closed then "Closed" else "held"

let check name ok = Printf.printf "%-34s %s\n" name (if ok then "ok" else "FAILED")

(* 1. a SYN as Linux sends it, options and all *)
let () =
  let fs = run ~frame:(seg ~flags:0x02 ~seq:0x11112222 ~ack:0 ~opts:opts_linux ()) 40 in
  ignore (uart ());
  check "SYN with 20 bytes of options" (List.length fs = 1 && Char.code (Bytes.get (List.hd fs) 47) = 0x12);
  Telnet_core.tcp_state := Telnet_core.Closed

(* 2. a peer that stops answering does not keep the session for ever *)
let () =
  ignore (run ~frame:(seg ~flags:0x02 ~seq:0x11112222 ~ack:0 ~opts:opts_mss ()) 10);
  ignore (uart ());
  Host_hw.clock := !Host_hw.clock + 700_000;
  ignore (run 10);
  check "a silent peer is dropped" (state () = "Closed")

(* 3. a caller knocking while a session is held by a peer that has gone *)
let () =
  Telnet_core.tcp_state := Telnet_core.Closed;
  let sa = run ~frame:(seg ~flags:0x02 ~seq:0x11112222 ~ack:0 ~opts:opts_mss ()) 10 in
  let our_isn = (get16 (List.hd sa) 38 lsl 16) lor get16 (List.hd sa) 40 in
  ignore (run ~frame:(seg ~flags:0x10 ~seq:0x11112223 ~ack:(our_isn + 1) ()) 400);   (* the banner goes out *)
  ignore (answers ()); ignore (uart ());
  (* the peer takes the banner -- all of it -- and then goes home without
     saying so, which is what a closed laptop looks like from here *)
  let all = (Telnet_core.snd_nxt.(0) lsl 16) lor Telnet_core.snd_nxt.(1) in
  ignore (run ~frame:(seg ~flags:0x10 ~seq:0x11112223 ~ack:all ()) 20);
  ignore (uart ());
  (* someone else knocks *)
  let k = run ~frame:(seg ~sport:40001 ~flags:0x02 ~seq:0x33334444 ~ack:0 ~opts:opts_linux ()) 20 in
  let u = uart () in
  let said_busy = try ignore (Str.search_forward (Str.regexp_string "busy") u 0); true
                  with Not_found -> false in
  check "a knock is answered, not ignored"
    (said_busy && List.exists (fun b -> Char.code (Bytes.get b 47) = 0x12) k);
  (* and in the same breath the incumbent is asked whether it is still there *)
  check "the incumbent is probed after a knock"
    (List.exists (fun b -> Char.code (Bytes.get b 47) = 0x10 && get16 b 36 = 40000) k);
  (* its host answers for it: the connection is gone *)
  ignore (run ~frame:(seg ~flags:0x04 ~seq:0x11112223 ~ack:0 ()) 10);
  check "a reset for the probe frees the session" (state () = "Closed");
  (* so the caller who knocked gets in next time *)
  let fs = run ~frame:(seg ~sport:40001 ~flags:0x02 ~seq:0x33335555 ~ack:0 ~opts:opts_linux ()) 20 in
  let u = uart () in
  check "the next caller is let in"
    (List.length fs = 1 && (try ignore (Str.search_forward (Str.regexp_string "syn from") u 0); true
                            with Not_found -> false))
