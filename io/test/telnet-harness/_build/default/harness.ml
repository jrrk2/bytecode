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
      (if Array.length Sys.argv > 1 && Sys.argv.(1) = "big" then
         (* one long line: a paste into the session, so the frames are full *)
         typ ("echo " ^ String.make 400 'x' ^ "\r") >>= fun () ->
         typ ("echo " ^ String.make 400 'y' ^ "\r")
       else
         typ "help\r" >>= fun () ->
         typ "time\r" >>= fun () ->
         typ "echo hello from telnet\r" >>= fun () ->
         typ "led 5\r") >>= fun () ->
      typ "quit\r" >>= fun () ->
      Lwt_unix.sleep 0.3 >>= fun () ->
      Printf.printf "---- what the client saw ----\n%s\n---- end ----\n"
        (String.concat "" (List.map (fun c -> if Char.code c = 255 then "<IAC>" else String.make 1 c)
                             (List.init (Buffer.length got) (Buffer.nth got))));
      Printf.printf "uart: %s" (uart ());
      Printf.printf "device passes: %d\n" !dev_steps;
      close_out trace;
      Lwt.return_unit)
