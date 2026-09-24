(* The same device logic, fed the frames of a recorded session with nothing
   else running: what one telnet session costs in bytecode instructions. *)
let () =
  Telnet_core_r.state := Telnet_core_r.Bound;
  Telnet_core_r.my_ip.(0) <- 10; Telnet_core_r.my_ip.(1) <- 0;
  Telnet_core_r.my_ip.(2) <- 0; Telnet_core_r.my_ip.(3) <- 2;
  Telnet_core_r.deadline := max_int;
  let ic = open_in_bin "session.frames" in
  let frames = ref [] in
  (try
     while true do
       let n = input_binary_int ic in
       let b = Bytes.create n in
       really_input ic b 0 n;
       frames := b :: !frames
     done
   with End_of_file -> ());
  let frames = List.rev !frames in
  let sent = ref 0 and bytes_out = ref 0 in
  List.iter (fun f ->
      Host_hw_r.deliver f;
      for _ = 1 to 3 do
        Host_hw_r.clock := !Host_hw_r.clock + 1;
        Telnet_core_r.poll ();
        while not (Queue.is_empty Host_hw_r.tx_q) do
          let b = Queue.pop Host_hw_r.tx_q in
          incr sent; bytes_out := !bytes_out + Bytes.length b
        done
      done) frames;
  Printf.printf "replayed %d frames in, %d frames out (%d bytes)\n"
    (List.length frames) !sent !bytes_out;
  print_string (Buffer.contents Host_hw_r.uart_buf)
