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
