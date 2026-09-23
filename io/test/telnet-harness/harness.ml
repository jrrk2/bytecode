(* The device's TCP against mirage-tcpip: an independent implementation as
   the peer.  Frames move between the simulated packet window and a vnetif
   port; the mirage side connects to port 23, types lines and reads the
   answers. *)
open Lwt.Infix

module B = Basic_backend.Make
module V = Vnetif.Make(B)
module E = Ethernet.Make(V)
module Arp = struct
  type t = { table : (Ipaddr.V4.t * Macaddr.t) list }
  type error = Mirage_protocols.Arp.error
  let pp_error = Mirage_protocols.Arp.pp_error
  let disconnect _ = Lwt.return_unit
  let pp fmt _ = Format.pp_print_string fmt "static"
  let get_ips t = List.map fst t.table
  let set_ips _ _ = Lwt.return_unit
  let remove_ip _ _ = Lwt.return_unit
  let add_ip _ _ = Lwt.return_unit
  let query t ip = match List.assoc_opt ip t.table with
    | Some m -> Lwt.return (Ok m) | None -> Lwt.return (Error `Timeout)
  let input _ _ = Lwt.return_unit
  let connect table = Lwt.return { table }
end
module Rnd = struct type g = unit let generate ?g n = ignore g; Cstruct.create n end
module Time = struct let sleep_ns ns = Lwt_unix.sleep (Int64.to_float ns /. 1e9) end
module Ip = Static_ipv4.Make(Rnd)(Mclock)(E)(Arp)
module Tcp = Tcp.Flow.Make(Ip)(Time)(Mclock)(Rnd)

let dev_ip = Ipaddr.V4.of_string_exn "10.0.0.2"
let host_ip = Ipaddr.V4.of_string_exn "10.0.0.1"
let dev_mac = Macaddr.of_string_exn "02:00:00:4d:47:34"   (* the device's my_mac *)

(* give the device an address without a DHCP server *)
let () =
  Telnet_core.state := Telnet_core.Bound;
  Telnet_core.my_ip.(0) <- 10; Telnet_core.my_ip.(1) <- 0;
  Telnet_core.my_ip.(2) <- 0; Telnet_core.my_ip.(3) <- 2;
  Telnet_core.deadline := max_int

let dev_steps = ref 0
let step_device push =
  incr dev_steps;
  Host_hw.clock := !Host_hw.clock + 1;
  Telnet_core.poll ();
  let sent = ref [] in
  while not (Queue.is_empty Host_hw.tx_q) do sent := Queue.pop Host_hw.tx_q :: !sent done;
  Lwt_list.iter_s push (List.rev !sent)

let uart () = let s = Buffer.contents Host_hw.uart_buf in Buffer.clear Host_hw.uart_buf; s

let trace = open_out_bin "session.frames"

let () =
  let backend = B.create ~use_async_readers:true ~yield:(fun () -> Lwt.pause ()) () in
  Lwt_main.run (
    V.connect backend >>= fun netif ->
    E.connect netif >>= fun eth ->
    Arp.connect [ (dev_ip, dev_mac) ] >>= fun arp ->
    Ip.connect ~cidr:(Ipaddr.V4.Prefix.of_string_exn "10.0.0.1/24") eth arp >>= fun ip ->
    Tcp.connect ip >>= fun tcp ->
    (* the host stack's receive path *)
    Lwt.async (fun () ->
        V.listen netif ~header_size:14
          (E.input ~arpv4:(fun _ -> Lwt.return_unit)
             ~ipv4:(Ip.input ip ~tcp:(Tcp.input tcp)
                      ~udp:(fun ~src:_ ~dst:_ _ -> Lwt.return_unit)
                      ~default:(fun ~proto:_ ~src:_ ~dst:_ _ -> Lwt.return_unit))
             ~ipv6:(fun _ -> Lwt.return_unit) eth) >|= fun _ -> ());
    (* the device's transmit path: its frames go out of its own port *)
    let devif_ref = ref None in
    let send_frame (f : Bytes.t) =
      match !devif_ref with
      | None -> Lwt.return_unit
      | Some d -> V.write d ~size:(Bytes.length f)
                    (fun buf -> Cstruct.blit_from_bytes f 0 buf 0 (Bytes.length f); Bytes.length f)
                  >|= fun _ -> () in
    (* the device's receive path: frames the host sends, one at a time *)
    let push_to_device (b : Cstruct.t) =
      (* keep every frame the peer sent, so the cost of handling exactly this
         session can be counted later without Lwt or mirage in the loop *)
      let f = Cstruct.to_bytes b in
      output_binary_int trace (Bytes.length f); output_bytes trace f;
      Host_hw.deliver f;
      (* the device gets a few passes to answer *)
      let rec spin n = if n = 0 then Lwt.return_unit
        else step_device send_frame >>= fun () -> Lwt.pause () >>= fun () -> spin (n - 1) in
      spin 4
    in
    (* a second port on the backend is the device: every frame on the wire
       that is addressed to it (or broadcast) goes into its RX window *)
    V.connect backend >>= fun devif ->
    devif_ref := Some devif;
    Lwt.async (fun () ->
        V.listen devif ~header_size:14 (fun frame ->
            let dst = Macaddr.of_octets_exn (Cstruct.to_string ~len:6 frame) in
            if Macaddr.compare dst dev_mac = 0 || Macaddr.compare dst Macaddr.broadcast = 0
            then push_to_device frame else Lwt.return_unit) >|= fun _ -> ());
    Lwt.async (fun () ->
        let rec loop () =
          step_device send_frame >>= fun () -> Lwt_unix.sleep 0.002 >>= loop in
        loop ());
    Lwt_unix.sleep 0.05 >>= fun () ->
    Printf.printf "uart: %s" (uart ());
    Tcp.create_connection tcp (dev_ip, 23) >>= function
    | Error e -> Format.printf "connect failed: %a@." Tcp.pp_error e; exit 1
    | Ok flow ->
      Printf.printf "connected\n%!";
      let got = Buffer.create 1024 in
      Lwt.async (fun () ->
          let rec rd () = Tcp.read flow >>= function
            | Ok (`Data b) -> Buffer.add_string got (Cstruct.to_string b); rd ()
            | _ -> Lwt.return_unit in rd ());
      let typ s = Tcp.write flow (Cstruct.of_string s) >>= fun _ -> Lwt_unix.sleep 0.05 in
      Lwt_unix.sleep 0.1 >>= fun () ->
      (if Array.length Sys.argv > 1 && Sys.argv.(1) = "reuse" then
         (* a session closed properly must give the next customer the door:
            the device has one connection, so a close that does not free it
            locks everyone out until something resets it *)
         Tcp.close flow >>= fun () ->
         Lwt_unix.sleep 0.5 >>= fun () ->
         Printf.printf "first session closed; device says: %s%!" (uart ());
         Tcp.create_connection tcp (dev_ip, 23) >>= (function
           | Error e -> Format.printf "SECOND CONNECTION REFUSED: %a@." Tcp.pp_error e; Lwt.return_unit
           | Ok f2 ->
             let got2 = Buffer.create 256 in
             Lwt.async (fun () ->
                 let rec rd () = Tcp.read f2 >>= function
                   | Ok (`Data b) -> Buffer.add_string got2 (Cstruct.to_string b); rd ()
                   | _ -> Lwt.return_unit in rd ());
             Lwt_unix.sleep 1.0 >>= fun () ->
             let t = Buffer.contents got2 in
             Printf.printf "second session got: %s\n"
               (if t = "" then "NOTHING"
                else if String.length t > 8 &&
                        (try ignore (Str.search_forward (Str.regexp_string "busy") t 0); true
                         with Not_found -> false) then "BUSY (the closed session is still held)"
                else "the banner -- the session was released");
             Lwt.return_unit)
       else if Array.length Sys.argv > 1 && Sys.argv.(1) = "busy" then
         (* a second customer while the first holds the session *)
         Tcp.create_connection tcp (dev_ip, 23) >>= (function
           | Error e ->
             Format.printf "second connection refused outright: %a@." Tcp.pp_error e;
             Lwt.return_unit
           | Ok f2 ->
             Printf.printf "second connection accepted; what it was told:\n";
             let rec rd () = Tcp.read f2 >>= function
               | Ok (`Data b) -> print_string (Cstruct.to_string b); rd ()
               | Ok `Eof -> Printf.printf "[closed by the device]\n%!"; Lwt.return_unit
               | Error e -> Format.printf "[read error: %a]@." Tcp.pp_error e; Lwt.return_unit in
             Lwt.pick [ rd (); Lwt_unix.sleep 2.0 ] >>= fun () ->
             Tcp.close f2)
       else if Array.length Sys.argv > 1 && Sys.argv.(1) = "rec" then
         typ "type point = { x : int; y : int }\r" >>= fun () ->
         typ "let p = { x = 3; y = 4 }\r" >>= fun () ->
         typ "p\r" >>= fun () ->
         typ "p.x\r" >>= fun () ->
         typ "p.x + p.y\r" >>= fun () ->
         typ "let q = { p with y = 10 }\r" >>= fun () ->
         typ "q\r" >>= fun () ->
         typ "p\r" >>= fun () ->
         typ "let dist s = match s with { x = a; y = b } -> a * a + b * b\r" >>= fun () ->
         typ "dist p\r" >>= fun () ->
         typ "let shift d s = { s with x = s.x + d }\r" >>= fun () ->
         typ "shift 5 p\r" >>= fun () ->
         typ "p = { x = 3; y = 4 }\r" >>= fun () ->
         typ "p = q\r" >>= fun () ->
         typ "type named = { nm : int; pt : point }\r" >>= fun () ->
         typ "let n = { nm = 7; pt = p }\r" >>= fun () ->
         typ "n\r" >>= fun () ->
         typ "n.pt.y\r" >>= fun () ->
         typ "[p; q]\r" >>= fun () ->
         typ "{ x = 1 }\r" >>= fun () ->
         typ "p.z\r" >>= fun () ->
         typ "{ x = 1; y = true }\r" >>= fun () ->
         typ "let f r = r.x\r" >>= fun () ->
         typ "f q\r"
       else if Array.length Sys.argv > 1 && Sys.argv.(1) = "adt" then
         typ "[1; 2; 3]\r" >>= fun () ->
         typ "1 :: 2 :: []\r" >>= fun () ->
         typ "(1, true, 2.5)\r" >>= fun () ->
         typ "let rec len l = match l with [] -> 0 | _ :: t -> 1 + len t\r" >>= fun () ->
         typ "len [1; 2; 3; 4]\r" >>= fun () ->
         typ "let rec map f l = match l with [] -> [] | h :: t -> f h :: map f t\r" >>= fun () ->
         typ "map (fun x -> x * x) [1; 2; 3; 4]\r" >>= fun () ->
         typ "map (fun x -> x +. 1.) [1.5; 2.5]\r" >>= fun () ->
         typ "let rec sum l = match l with [] -> 0 | h :: t -> h + sum t\r" >>= fun () ->
         typ "let rec upto n = if n = 0 then [] else n :: upto (n - 1)\r" >>= fun () ->
         typ "sum (upto 100)\r" >>= fun () ->
         typ "type 'a option = None | Some of 'a\r" >>= fun () ->
         typ "Some 3\r" >>= fun () ->
         typ "Some (Some 3)\r" >>= fun () ->
         typ "let get d o = match o with None -> d | Some x -> x\r" >>= fun () ->
         typ "get 0 (Some 7)\r" >>= fun () ->
         typ "get 0 None\r" >>= fun () ->
         typ "type shape = Circle of float | Rect of float * float\r" >>= fun () ->
         typ "let area s = match s with Circle r -> 3.14159 *. r *. r | Rect (w, h) -> w *. h\r" >>= fun () ->
         typ "area (Circle 1.)\r" >>= fun () ->
         typ "area (Rect (3., 4.))\r" >>= fun () ->
         typ "[Circle 1.; Rect (2., 3.)]\r" >>= fun () ->
         typ "(1, 2) = (1, 2)\r" >>= fun () ->
         typ "[1; 2] = [1; 3]\r" >>= fun () ->
         typ "Some 1 = Some 1\r" >>= fun () ->
         typ "1 :: [true]\r" >>= fun () ->
         typ "map\r" >>= fun () ->
         typ "len [1; 2] + len [true]\r" >>= fun () ->
         typ "match Some 1 with None -> 0\r" >>= fun () ->
         typ "let rec stack n = if n > 0 then n :: stack (n-1) else []\r" >>= fun () ->
         typ "stack 300\r"
       else if Array.length Sys.argv > 1 && Sys.argv.(1) = "big" then
         (* one long line: a paste into the session, so the frames are full *)
         typ ("echo " ^ String.make 400 'x' ^ "\r") >>= fun () ->
         typ ("echo " ^ String.make 400 'y' ^ "\r")
       else
         typ "sin 0.5\r" >>= fun () ->
         typ "cos 0.5 *. cos 0.5 +. sin 0.5 *. sin 0.5\r" >>= fun () ->
         typ "exp 1.\r" >>= fun () ->
         typ "log (exp 3.)\r" >>= fun () ->
         typ "sqrt 2.\r" >>= fun () ->
         typ "atan2 1. 1. *. 4.\r" >>= fun () ->
         typ "pow 2. 10.\r" >>= fun () ->
         typ "asin (sin 0.3)\r" >>= fun () ->
         typ "sin\r" >>= fun () ->
         typ "sin 1\r" >>= fun () ->
         typ "let rec area n acc = if n <= 0 then acc else area (n-1) (acc +. sin (float_of_int n /. 100.) /. 100.)\r" >>= fun () ->
         typ "area 314 0.\r" >>= fun () ->
         typ "2 + 3\r" >>= fun () ->
         typ "let fact n = if n <= 0 then 1 else fact (n-1) * n\r" >>= fun () ->
         typ "let rec fact n = if n <= 0 then 1 else fact (n-1) * n\r" >>= fun () ->
         typ "fact 5\r" >>= fun () ->
         typ "let x = try 0/0 with _ -> 0 in x\r" >>= fun () ->
         typ "try 7/0 with m -> m\r" >>= fun () ->
         typ "nosuch 3\r") >>= fun () ->
      (if Array.length Sys.argv > 1 && Sys.argv.(1) = "busy" then typ "fact 6\r"
       else if Array.length Sys.argv > 1 && Sys.argv.(1) = "reuse" then Lwt.return_unit
       else typ "let g y = y * nosuchthing\r") >>= fun () ->
      Lwt_unix.sleep 0.3 >>= fun () ->
      Printf.printf "---- what the client saw ----\n%s\n---- end ----\n"
        (String.concat "" (List.map (fun c -> if Char.code c = 255 then "<IAC>" else String.make 1 c)
                             (List.init (Buffer.length got) (Buffer.nth got))));
      Printf.printf "uart: %s" (uart ());
      Printf.printf "device passes: %d\n" !dev_steps;
      close_out trace;
      Lwt.return_unit)
