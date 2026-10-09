(* A read-only FAT32 reader over io/sd.ml (run that first): the first MBR partition, the root directory, files by 8.3 name.
   Little-endian fields are read out of the 512-byte block buffer; a 32-bit field is a 31-bit int here, which is plenty for
   cluster numbers and sizes on a card this size. *)
(* >>> io/fat.ml *)
external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"
external string_get : string -> int -> char = "%string_safe_get"
let putc c = io_write 0x1005 (int_of_char c)
external string_length : string -> int = "%string_length"
let puts s = for i = 0 to string_length s - 1 do putc (string_get s i) done
let newline () = putc (char_of_int 13); putc (char_of_int 10)
let rec put_int n = if n >= 10 then put_int (n / 10); putc (char_of_int (48 + n mod 10))
let b16 o = (sd_byte o) + 256 * (sd_byte (o + 1))
let b32 o = (b16 o) + 65536 * (b16 (o + 2))

let fat_lba = ref 0
let data_lba = ref 0
let fat_spc = ref 0
let fat_root = ref 0
let fat_part = ref 0      (* which of the four MBR partitions *)

(* 0 if the card holds a FAT32 volume in partition fat_part (0..3) and it is mounted, else the step that failed *)
let fat_mount () =
  if not (sd_read 0) then 1
  else if (sd_byte 510) <> 0x55 then 2
  else begin
    let part = b32 (454 + 16 * !fat_part) in
    if (sd_byte (450 + 16 * !fat_part)) = 0 then 5
    else if not (sd_read part) then 3
    else if b16 11 <> 512 then 4
    else begin
      fat_spc := sd_byte 13;
      fat_lba := part + b16 14;
      data_lba := !fat_lba + (sd_byte 16) * (b32 36);
      fat_root := b32 44;
      0
    end
  end

let clus_lba c = !data_lba + (c - 2) * !fat_spc

(* the cluster after c in its chain; >= 0x0FFFFFF8 ends it *)
let fat_next c =
  if not (sd_read (!fat_lba + c / 128)) then 0x0FFFFFFF
  else (b32 ((c mod 128) * 4)) land 0x0FFFFFFF

let put_name o = for i = 0 to 10 do putc (char_of_int (sd_byte (o + i))) done

(* list directory cluster c: name, size, first cluster *)
let fat_ls c0 =
  let c = ref c0 and fin = ref false in
  while not !fin && !c >= 2 && !c < 0x0FFFFFF8 do
    let s = ref 0 in
    while not !fin && !s < !fat_spc do
      if not (sd_read (clus_lba !c + !s)) then fin := true
      else begin
        let e = ref 0 in
        while not !fin && !e < 16 do
          let o = !e * 32 in
          let first = sd_byte o and attr = sd_byte (o + 11) in
          if first = 0 then fin := true
          else if first <> 0xE5 && attr <> 0x0F then begin
            put_name o; puts " "; put_int (b32 (o + 28)); puts " @"; put_int ((b16 (o + 20)) * 65536 + b16 (o + 26)); newline ()
          end;
          e := !e + 1
        done
      end;
      s := !s + 1
    done;
    if not !fin then c := fat_next !c
  done

(* the first cluster of the root-directory entry whose 11 name bytes are get 0 .. get 10, or 0; its size in fat_size *)
let fat_size = ref 0
let fat_find_by (get : int -> int) =
  let c = ref !fat_root and found = ref 0 and fin = ref false in
  while not !fin && !found = 0 && !c >= 2 && !c < 0x0FFFFFF8 do
    let s = ref 0 in
    while not !fin && !found = 0 && !s < !fat_spc do
      if not (sd_read (clus_lba !c + !s)) then fin := true
      else begin
        let e = ref 0 in
        while not !fin && !found = 0 && !e < 16 do
          let o = !e * 32 in
          if sd_byte o = 0 then fin := true
          else begin
            let same = ref true in
            for i = 0 to 10 do if sd_byte (o + i) <> get i then same := false done;
            if !same then begin found := (b16 (o + 20)) * 65536 + b16 (o + 26); fat_size := b32 (o + 28) end
          end;
          e := !e + 1
        done
      end;
      s := !s + 1
    done;
    if not !fin && !found = 0 then c := fat_next !c
  done;
  !found

(* by a name written as it is on the disk: "DISK    RFS" *)
let fat_find name = fat_find_by (fun (i : int) -> int_of_char (string_get name i))

(* by a name as typed, "vm.img": upper case, the name and then the extension padded with blanks *)
let upper c = if c >= 97 && c <= 122 then c - 32 else c
let fat_dot s =
  let n = string_length s in
  let d = ref n in
  for i = n - 1 downto 0 do if string_get s i = '.' then d := i done;
  !d
let fat_user_char s (d : int) (i : int) =
  let n = string_length s in
  if i < 8 then (if i < d then upper (int_of_char (string_get s i)) else 32)
  else (let j = d + 1 + (i - 8) in if j < n then upper (int_of_char (string_get s j)) else 32)
let fat_find_user s = let d = fat_dot s in fat_find_by (fun (i : int) -> fat_user_char s d i)

(* where the bytes of a file read go (offset in the file, byte), and how many the place can take *)
let fat_put = ref (fun (_o : int) (_v : int) -> ())
let fat_limit = ref 0x7FFFFFF

(* read the file found by get through fat_put; its length, -1 if it is not there or a block failed, -2 if it does not fit.
   A cluster goes in one multi-block transfer (up to 8 blocks at a time). *)
let fat_read_by (get : int -> int) =
  let c = ref (fat_find_by get) in
  let size = !fat_size and pos = ref 0 and ok = ref (!c >= 2) in
  if !ok && size > !fat_limit then 0 - 2
  else begin
    while !ok && !pos < size && !c >= 2 && !c < 0x0FFFFFF8 do
      let s = ref 0 in
      while !ok && !s < !fat_spc && !pos < size do
        let n = if !fat_spc - !s > 8 then 8 else !fat_spc - !s in
        if not (sd_read_n (clus_lba !c + !s) n) then ok := false
        else begin
          let m = if size - !pos < 512 * n then size - !pos else 512 * n in
          for i = 0 to m - 1 do (!fat_put) (!pos + i) (sd_byte i) done;
          pos := !pos + m
        end;
        s := !s + n
      done;
      if !ok && !pos < size then c := fat_next !c
    done;
    if !ok && !pos = size then size else 0 - 1
  end
(* <<< io/fat.ml *)

(* copy the file whose 8.3 name is given into the RAM disk from byte offset off; its length, or -1 if it is not there or a block failed *)
external disk_set : int -> int -> int = "disk_set"
external disk_get : int -> int = "disk_get"
let fat_base = ref 0
let () = fat_put := (fun (o : int) (v : int) -> let _ = disk_set (!fat_base + o) v in ())
let fat_load name off = fat_base := off; fat_read_by (fun (i : int) -> int_of_char (string_get name i))

let disk_sum off n =
  let a = ref 0 and b = ref 0 in
  for i = 0 to n - 1 do a := (!a + disk_get (off + i)) mod 65521; b := (!b + !a) mod 65521 done;
  !b * 65536 + !a

let fat_pos = ref 0   (* where a failed fat_store stopped *)

(* write RAM-disk bytes from offset off over the existing file of that name (its size does not change); true if every block was taken *)
let fat_store_with name (get : int -> int) =
  let c = ref (fat_find name) in
  let size = !fat_size and pos = ref 0 and ok = ref (!c >= 2) in
  while !ok && !pos < size && !c >= 2 && !c < 0x0FFFFFF8 do
    let s = ref 0 in
    while !ok && !s < !fat_spc && !pos < size do
      let n = if !fat_spc - !s > 8 then 8 else !fat_spc - !s in
      let m = if size - !pos < 512 * n then size - !pos else 512 * n in
      if m < 512 * n && not (sd_read_n (clus_lba !c + !s) n) then ok := false      (* a partial last block keeps the rest of the card's data *)
      else begin
        for i = 0 to m - 1 do sd_put i (get (!pos + i)) done;
        if not (sd_write_n (clus_lba !c + !s) n) then ok := false;
        pos := !pos + m; fat_pos := !pos
      end;
      s := !s + n
    done;
    if !ok && !pos < size then c := fat_next !c
  done;
  !ok && !pos = size

let fat_store name off = fat_store_with name (fun (i : int) -> disk_get (off + i))

(* the staging RAM (I/O 0x10000, where the loader leaves the image it booted) over a file of the same length *)
external io_read_stage : int -> int = "vm_io_read"
let fat_store_stage name = fat_store_with name (fun (i : int) -> io_read_stage (0x10000 + i))
