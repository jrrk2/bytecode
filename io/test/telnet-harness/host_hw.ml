(* the processor's I/O space, simulated: two 2 KB packet windows, a clock,
   a UART, and frame queues the driver moves packets through *)
let mem_rx = Array.make 2048 0
let mem_tx = Array.make 2048 0
let clock = ref 0
let leds_v = ref 0
let uart_buf = Buffer.create 256
let rx_q : Bytes.t Queue.t = Queue.create ()
let tx_q : Bytes.t Queue.t = Queue.create ()
let rx_valid = ref false
let rx_length = ref 0

let rx i = if i < 2048 then mem_rx.(i) else 0
let tx i v = if i < 2048 then mem_tx.(i) <- v land 0xFF
let tx_get i = if i < 2048 then mem_tx.(i) else 0
let now () = !clock
let rx_len () = !rx_length
let rx_ready () = !rx_valid
let rx_done () = rx_valid := false; rx_length := 0
let eth_send len =
  let b = Bytes.create len in
  for i = 0 to len - 1 do Bytes.set b i (Char.chr (mem_tx.(i) land 0xFF)) done;
  Queue.add b tx_q
let uart_putc c = Buffer.add_char uart_buf c
let uart_getc () = -1
let set_leds v = leds_v := v
let phy () = 0x796d

(* the driver's side of the wire *)
let deliver (b : Bytes.t) =
  let n = Bytes.length b in
  for i = 0 to n - 1 do mem_rx.(i) <- Char.code (Bytes.get b i) done;
  rx_length := n;
  rx_valid := true

(* replnet.ml calls io_read/io_write directly outside the HW block (the UART,
   the LEDs, the status and length registers), so the shim answers those too *)
let io_read a =
  if a < 0x800 then mem_rx.(a)
  else if a < 0x1000 then mem_tx.(a - 0x800)
  else if a = 0x1000 then (if !rx_valid then 1 else 0)
  else if a = 0x1002 then !rx_length
  else if a = 0x1006 then !clock
  else if a = 0x1008 then -1
  else if a = 0x1001 then 0x796d
  else if a = 0x1009 then 0x00                 (* DIP switches: all off *)
  else if a = 0x100a then 0x4024d65            (* a stamped build, for the banner *)
  else 0

let io_write a v =
  if a >= 0x800 && a < 0x1000 then mem_tx.(a - 0x800) <- v land 0xFF
  else if a = 0x1003 then eth_send v
  else if a = 0x1004 then leds_v := v
  else if a = 0x1005 then Buffer.add_char uart_buf (Char.chr (v land 0xFF))
  else if a = 0x1002 then (rx_valid := false; rx_length := 0)

(* the I/O addresses themselves, since the device file keeps them in the HW
   block that this module replaces *)
let rx_base = 0x0000
let tx_base = 0x0800
let eth_status = 0x1000
let eth_status_phy = 0x1001
let eth_rxlen = 0x1002
let eth_txlen = 0x1003
let leds = 0x1004
let uart = 0x1005
let timer_ms = 0x1006
let uart_rx = 0x1008
let dip_sw = 0x1009
let build_id_addr = 0x100a
let eth_rx_valid = 1
let eth_tx_busy = 2
