(* The NFS client shared by io/comp.ml (the REPL) and io/netboot.ml (the loader).  Neither can call into the
   other -- the loader is a separate code bank and the loaded image replaces its heap and globals -- so this text is
   spliced into both by tools/nfs_splice.py between the >>> and <<< lines; edit it here, not there.

   ONC RPC over UDP, NFS version 3: portmap for mountd, mount for the root handle, portmap for nfsd, one LOOKUP for
   each component of the path, then READ in 1 KiB pieces.  A path is "dir/dir/file" below the export.  It is
   asynchronous: nfs_launch starts it, the host calls nfs_reply / nfs_arp_reply as frames arrive and nfs_tick often, and
   nfs_result says how it went (-1 running, -2 failed, else the length).

   What the host defines before this text: rx tx mac ip ip_checksum eth_send now uart_puts uart_dec uart_putc not_b
   create_bytes bytes_get bytes_set array_get array_set string_get string_length int_of_char char_of_int.
   What it assigns after it: the four nfs_dest_ hooks (where the file's bytes go). *)
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
let nfs_creating = 7
let nfs_writing = 8
let nfs_readdiring = 9

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
(* writing a file: nfs_launch_write creates the leaf of the path (the part after the last '/') in the directory the rest names
   and writes nfs_src_len bytes, nfs_src_get i being byte i of them *)
let nfs_mode = ref 0             (* 0 read the file, 1 write it, 2 read one piece of an open file, 3 open (handle and size only) *)
let nfs_count = ref nfs_chunk    (* bytes asked for by each READ *)
let nfs_size = ref 0             (* a file's size, from the LOOKUP that opened it *)
let nfs_keep = ref false         (* a streamed write: stop after the CREATE (keeping the handle), and after each piece *)
(* reading a directory: nfs_launch_openroot / nfs_launch_open leave the directory's handle in fh_file; nfs_launch_readdir asks for the entries after a
   cookie, each name goes to nfs_dir_name, and when it ends nfs_result is how many came, nfs_eof says whether that was the last of them and the
   cookie of the last entry is in nfs_cookie_hi / nfs_cookie_lo for the next call *)
let nfs_dir_name = ref (fun (_s : string) -> ())
let nfs_cookie_hi = ref 0
let nfs_cookie_lo = ref 0
let nfs_eof = ref false
let nfs_leaf = ref 0             (* where the leaf name starts in nfs_path *)
let nfs_src_len = ref 0
let nfs_src_get = ref (fun (_i : int) -> 0)

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

(* CREATE of the leaf, UNCHECKED (an existing file is truncated to nothing), mode 0644, as uid 0 *)
let send_create () =
  rpc_call rpc_nfs 3 8;
  xfh fh_root !fh_root_len;
  xname !nfs_path !nfs_leaf (string_length !nfs_path);
  x32 0;                                       (* createmode3 UNCHECKED *)
  x32 1; x32 420;                              (* sattr3: mode 0644 *)
  x32 0; x32 0;                                (* uid, gid: unchanged *)
  x32 1; x32 0; x32 0;                         (* size 0 *)
  x32 0; x32 0;                                (* atime, mtime: unchanged *)
  nfs_send !nfsd_port

(* WRITE of the next piece at nfs_off, FILE_SYNC *)
let send_write () =
  let n = if !nfs_src_len - !nfs_off > nfs_chunk then nfs_chunk else !nfs_src_len - !nfs_off in
  rpc_call rpc_nfs 3 7;
  xfh fh_file !fh_file_len;
  x32 0; x32 !nfs_off;
  x32 n; x32 2;
  x32 n;
  for i = 0 to n - 1 do tx (!xp + i) ((!nfs_src_get) (!nfs_off + i)) done;
  xpad n;
  nfs_send !nfsd_port

let send_readdir () =
  rpc_call rpc_nfs 3 16;
  xfh fh_file !fh_file_len;
  x32 !nfs_cookie_hi; x32 !nfs_cookie_lo;       (* the cookie, 64 bits *)
  x32 0; x32 0;                                 (* the cookie verifier *)
  x32 1000;                                     (* room for the reply *)
  nfs_send !nfsd_port

let send_read () =
  rpc_call rpc_nfs 3 6;
  xfh fh_file !fh_file_len;
  x32 0; x32 !nfs_off;        (* a 64-bit offset, high word first *)
  x32 !nfs_count;
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
    if !nfs_mode = 5 then begin
      for i = 0 to 63 do bytes_set fh_file i (bytes_get fh_root i) done;
      fh_file_len := !fh_root_len;
      nfs_state := nfs_idle; nfs_result := 0
    end
    else if !nfs_mode = 1 && !nfs_leaf = 0 then begin nfs_state := nfs_creating; send_create (); nfs_step () end
    else begin nfs_state := nfs_looking; send_lookup (); nfs_step () end
  end
  else if !nfs_state = nfs_looking then begin
    if r32 () <> 0 then nfs_fail "no such file"
    else begin
      fh_file_len := take_fh fh_file;
      if !fh_file_len = 0 then nfs_fail "bad handle"
      else if !nfs_mode = 1 then begin
        for i = 0 to 63 do bytes_set fh_root i (bytes_get fh_file i) done;
        fh_root_len := !fh_file_len;
        if !nfs_ce + 1 >= !nfs_leaf then begin nfs_state := nfs_creating; send_create (); nfs_step () end
        else begin nfs_cs := !nfs_ce + 1; nfs_find_end (); send_lookup (); nfs_step () end
      end
      else if !nfs_ce < string_length !nfs_path then begin
        (* a directory on the way: it becomes the one to look in, and the next component is looked up *)
        for i = 0 to 63 do bytes_set fh_root i (bytes_get fh_file i) done;
        fh_root_len := !fh_file_len;
        nfs_cs := !nfs_ce + 1;
        nfs_find_end ();
        send_lookup (); nfs_step ()
      end else if !nfs_mode = 3 then begin
        (* LOOKUP3resok: the handle, then post_op_attr; fattr3's size follows type, mode, nlink, uid and gid *)
        (if r32 () = 1 then begin rp := !rp + 20; let _hi = r32 () in nfs_size := r32 () end else nfs_size := 0);
        nfs_state := nfs_idle; nfs_result := !nfs_size
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
        if !nfs_mode = 2 then begin nfs_state := nfs_idle; nfs_result := n end
        else if eof <> 0 || n = 0 then begin
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
  else if !nfs_state = nfs_readdiring then begin
    if r32 () <> 0 then nfs_fail "readdir refused"
    else begin
      skip_attr ();
      rp := !rp + 8;                                (* cookieverf *)
      let cnt = ref 0 and more = ref (r32 ()) in
      while !more <> 0 do
        let _fid_hi = r32 () in
        let _fid_lo = r32 () in
        let nl = r32 () in
        let b = create_bytes nl in
        for i = 0 to nl - 1 do bytes_set b i (char_of_int (rx (!rp + i))) done;
        rp := !rp + ((nl + 3) / 4) * 4;
        nfs_cookie_hi := r32 ();
        nfs_cookie_lo := r32 ();
        (!nfs_dir_name) (bytes_to_string b);
        cnt := !cnt + 1;
        more := r32 ()
      done;
      nfs_eof := (r32 () <> 0);
      nfs_state := nfs_idle; nfs_result := !cnt
    end
  end
  else if !nfs_state = nfs_creating then begin
    if r32 () <> 0 then nfs_fail "create refused"
    else if r32 () = 0 then nfs_fail "no handle for the new file"
    else begin
      fh_file_len := take_fh fh_file;
      nfs_off := 0;
      if !fh_file_len = 0 then nfs_fail "bad handle"
      else if !nfs_keep || !nfs_src_len = 0 then begin nfs_state := nfs_idle; nfs_result := 0 end
      else begin nfs_state := nfs_writing; send_write (); nfs_step () end
    end
  end
  else if !nfs_state = nfs_writing then begin
    if r32 () <> 0 then nfs_fail "write refused"
    else begin
      (if r32 () = 1 then rp := !rp + 24);         (* wcc_data: pre_op_attr, then post_op_attr *)
      skip_attr ();
      let count = r32 () in
      if count = 0 then nfs_fail "short write"
      else begin
        nfs_off := !nfs_off + count;
        if !nfs_keep then begin nfs_state := nfs_idle; nfs_result := count end
        else if !nfs_off >= !nfs_src_len then begin
          nfs_state := nfs_idle; nfs_result := !nfs_off;
          uart_puts "nfs: "; uart_dec !nfs_off; uart_puts " bytes written\n"
        end else begin send_write (); nfs_step () end
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
       else if !nfs_state = nfs_creating then send_create ()
       else if !nfs_state = nfs_writing then send_write ()
       else if !nfs_state = nfs_readdiring then send_readdir ()
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
  nfs_mode := 0; nfs_keep := false;
  nfs_export := export; nfs_path := path;
  nfs_cs := 0; nfs_find_end ();
  nfs_result := 0 - 1;
  nfs_state := nfs_arping;
  nfs_arp_request ();
  nfs_step ()

(* the same, to create path (truncating it) and write nfs_src_len bytes from nfs_src_get *)
let nfs_launch_write export path =
  let leaf = ref 0 in
  for i = 0 to string_length path - 1 do if string_get path i = '/' then leaf := i + 1 done;
  nfs_mode := 1; nfs_keep := false; nfs_leaf := !leaf;
  nfs_export := export; nfs_path := path;
  nfs_cs := 0; nfs_find_end ();
  nfs_result := 0 - 1;
  nfs_state := nfs_arping;
  nfs_arp_request ();
  nfs_step ()

(* open export + path for reading, repeatedly: the mount and the lookups are done, nfs_result is the size and the file's handle
   is in fh_file / fh_file_len for the host to keep *)
let nfs_launch_open export path =
  nfs_launch export path;
  nfs_mode := 3

(* one READ of nfs_count bytes at off from the file whose handle is fh (n bytes), reaching the host through nfs_dest_put (absolute
   offsets); the server, its ports and the MAC are those of the open before; nfs_result is the bytes read *)
let nfs_launch_piece (fh : bytes) (n : int) (off : int) =
  for i = 0 to 63 do bytes_set fh_file i (bytes_get fh i) done;
  fh_file_len := n;
  nfs_mode := 2; nfs_off := off; nfs_result := 0 - 1;
  nfs_state := nfs_reading;
  send_read ();
  nfs_step ()

(* create path (truncating it) and keep its handle (fh_file / fh_file_len) for the host: nfs_result is 0 *)
let nfs_launch_create export path =
  nfs_launch_write export path;
  nfs_keep := true

(* one WRITE of len bytes at off into the file whose handle is fh (n bytes), the bytes being nfs_src_get at (off + 0 .. off + len - 1);
   nfs_result is the count the server took *)
let nfs_launch_wpiece (fh : bytes) (n : int) (off : int) (len : int) (get : int -> int) =
  for i = 0 to 63 do bytes_set fh_file i (bytes_get fh i) done;
  fh_file_len := n;
  nfs_mode := 1; nfs_keep := true;
  nfs_src_len := off + len; nfs_src_get := get; nfs_off := off;
  nfs_result := 0 - 1;
  nfs_state := nfs_writing;
  send_write ();
  nfs_step ()

(* the export's root as the directory to read (fh_file after the mount) *)
let nfs_launch_openroot export =
  nfs_launch export "";
  nfs_mode := 5

(* the entries of the directory whose handle is fh (n bytes) after the cookie hi/lo (0 0 for the first) *)
let nfs_launch_readdir (fh : bytes) (n : int) (hi : int) (lo : int) =
  for i = 0 to 63 do bytes_set fh_file i (bytes_get fh i) done;
  fh_file_len := n;
  nfs_cookie_hi := hi; nfs_cookie_lo := lo;
  nfs_result := 0 - 1;
  nfs_state := nfs_readdiring;
  send_readdir ();
  nfs_step ()
(* <<< io/nfs.ml *)
