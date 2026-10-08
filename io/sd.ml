(* SD card driver for the lowRISC host in fpga/vc707-ethmin/sd_wrap.v, written for io/comp.ml's dialect.
   Registers are 32 bits wide and an int here has 31, so every register is written and read as two 16-bit halves; a command's
   argument is likewise given as two halves (the host-capacity bit of ACMD41 is bit 30 and does not survive as one number).
   Registers (index n at I/O 0x1100 + 2n, high half at +1): writes 0 align, 1 clock divider (SD clock = clk / (2 (n + 1))),
   2 argument, 3 command, 4 setting, 5 start, 6 run flags, 7 block count, 8 block size, 9 timeout;
   reads 0..3 response, 5 status, 12 card detect (1 = present on the VC707), 14 {finish_data, finish_cmd}.  The 4 KB block buffer is at I/O 0x2000.
   Reading only: nothing here writes a block. *)
external io_read : int -> int = "vm_io_read"
external io_write : int -> int -> unit = "vm_io_write"
external not : bool -> bool = "%boolnot"

let sdw n v = io_write (0x1100 + 2 * n + 1) ((v lsr 16) land 0xFFFF); io_write (0x1100 + 2 * n) (v land 0xFFFF)
let sdlo n = io_read (0x1100 + 2 * n)
let sdhi n = io_read (0x1100 + 2 * n + 1)
let delay n = let i = ref 0 in while !i < n do i := !i + 1 done

(* start a command: the argument as two halves, the setting 0 none / 1 short / 3 long response, + 4 data, + 0x10 read, + 0x20 4 bit *)
let sd_start idx hi lo setting =
  sdw 6 5; sdw 0 0; io_write (0x1100 + 5) hi; io_write (0x1100 + 4) lo;
  sdw 3 idx; sdw 4 setting; sdw 5 0; sdw 6 7; sdw 9 100000; sdw 5 1

let sd_wait_bit bit =
  let n = ref 0 in
  while (sdlo 14) land bit = 0 && !n < 400000 do n := !n + 1 done;
  !n < 400000

(* a command and its response; true if it finished *)
let sd_cmd idx hi lo setting = sd_start idx hi lo setting; delay 3000; sd_wait_bit 1

let rec sd_acmd41 n =
  if n = 0 then false
  else begin
    let _ = sd_cmd 55 0 0 1 in
    let _ = sd_cmd 41 0x40FF 0x8000 1 in
    if (sdhi 0) land 0x8000 <> 0 then true else sd_acmd41 (n - 1)
  end

let sd_rca = ref 0

(* power up at 400 kHz and bring an SDHC card to the transfer state; 0 if it did, else the step that failed *)
let sd_init () =
  sdw 1 77; sdw 6 5; delay 20000;
  if (sdlo 12) land 1 = 0 then 1                 (* the VC707's detect pin is high with a card in the slot *)
  else if not (sd_cmd 0 0 0 0) then 2
  else if not (sd_cmd 8 0 0x1AA 1) || sdlo 0 <> 0x1AA then 3
  else if not (sd_acmd41 200) then 4
  else if not (sd_cmd 2 0 0 3) then 5
  else if not (sd_cmd 3 0 0 1) then 6
  else begin
    sd_rca := sdhi 0;
    if not (sd_cmd 7 !sd_rca 0 1) then 7 else 0
  end

(* block blk (SDHC: a block number, 512-byte blocks, 24 bits here) into the buffer at I/O 0x2000; true if the data arrived and checked *)
let sd_read blk =
  sdw 7 1; sdw 8 512;
  sd_start 17 (blk lsr 16) (blk land 0xFFFF) 0x15;
  delay 3000;
  sd_wait_bit 1 && sd_wait_bit 2 && (sdlo 5) land 64 <> 0

let sd_byte i = io_read (0x2000 + i)
