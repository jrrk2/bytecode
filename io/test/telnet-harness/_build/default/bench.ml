(* where the per-byte cost goes: the checksum, the echo path, the copy out *)
let n = try int_of_string Sys.argv.(2) with _ -> 100
let () =
  match Sys.argv.(1) with
  | "nothing" -> ()
  | "sum_rx" -> for _ = 1 to n do ignore (Telnet_core_b.sum_rx 34 1000) done
  | "feed" ->
      Telnet_core_b.tcp_state := Telnet_core_b.Estab;
      for _ = 1 to n do
        for _ = 1 to 1000 do Telnet_core_b.feed_byte 97 done;
        Telnet_core_b.out_len := 0
      done
  | "copyout" ->
      for _ = 1 to n do
        for i = 0 to 999 do Host_hw_b.tx (54 + i) i done
      done
  | _ -> ()
