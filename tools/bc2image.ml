(* bc2image prog.bc outdir
   Lays out the global data of an OCaml 4.14 bytecode executable (its DATA
   section, which ocamlrun unmarshals into caml_global_data) in the VM's own
   heap format, for $readmemh:

     outdir/heap.hex     the structured constants, from heap word 0
     outdir/globals.hex  globals_mem: field i of the global data
     outdir/image.txt    "heap_words N" and "globals N"

   VM value format (ocaml4142_vm_rtl.sv): 32-bit words; ints are 2n+1; a
   pointer is (index of the block's header) << 2; a header is
   {wosize[31:16], color[15:8], tag[7:0]}.  Strings pack their bytes
   little-endian into words, the last byte giving the padding, as OCaml does. *)

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic; s

let be32 s off =
  (Char.code s.[off] lsl 24) lor (Char.code s.[off + 1] lsl 16)
  lor (Char.code s.[off + 2] lsl 8) lor Char.code s.[off + 3]

(* The section table sits before the 16-byte trailer; sections are laid out
   in table order and end where the table starts. *)
let section file name =
  let len = String.length file in
  let nsec = be32 file (len - 16) in
  let table = len - 16 - 8 * nsec in
  let descs = List.init nsec (fun i ->
    String.sub file (table + 8 * i) 4, be32 file (table + 8 * i + 4)) in
  let total = List.fold_left (fun acc (_, n) -> acc + n) 0 descs in
  let rec find pos = function
    | [] -> failwith ("no " ^ name ^ " section")
    | (n, size) :: rest -> if n = name then String.sub file pos size else find (pos + size) rest in
  find (table - total) descs

let heap_words = ref 0
let words : int array ref = ref (Array.make 1024 0)
let emit w =
  if !heap_words >= Array.length !words then
    words := Array.append !words (Array.make (Array.length !words) 0);
  !words.(!heap_words) <- w land 0xFFFFFFFF;
  incr heap_words;
  !heap_words - 1

(* The VM's ints are 31 bits: a wider constant wraps, as the VM's own
   arithmetic would, with a warning. *)
let val_int n =
  if n < -(1 lsl 30) || n >= 1 lsl 30 then
    Printf.eprintf "bc2image: warning: integer %d wraps to 31 bits\n" n;
  ((n lsl 1) lor 1) land 0xFFFFFFFF

let header wosize tag =
  if wosize > 0xFFFF then failwith "block too large for a 16-bit wosize";
  (wosize lsl 16) lor tag

(* Blocks are shared by physical identity, as the marshaller shared them. *)
let placed : (Obj.t * int) list ref = ref []

let rec place (v : Obj.t) : int =
  if Obj.is_int v then val_int (Obj.obj v : int)
  else match List.assq_opt v !placed with
    | Some idx -> idx lsl 2
    | None ->
      let tag = Obj.tag v in
      if tag = Obj.string_tag then begin
        let s : string = Obj.obj v in
        let len = String.length s in
        let nwords = len / 4 + 1 in
        let idx = emit (header nwords tag) in
        placed := (v, idx) :: !placed;
        let byte i =
          if i < len then Char.code s.[i]
          else if i = 4 * nwords - 1 then 4 * nwords - 1 - len
          else 0 in
        for w = 0 to nwords - 1 do
          ignore (emit (byte (4 * w) lor (byte (4 * w + 1) lsl 8)
                        lor (byte (4 * w + 2) lsl 16) lor (byte (4 * w + 3) lsl 24)))
        done;
        idx lsl 2
      end else if tag < Obj.no_scan_tag then begin
        let size = Obj.size v in
        let idx = emit (header size tag) in
        placed := (v, idx) :: !placed;
        let first = !heap_words in
        for _ = 1 to size do ignore (emit 0) done;
        for i = 0 to size - 1 do
          let f = place (Obj.field v i) in
          !words.(first + i) <- f
        done;
        idx lsl 2
      end else failwith (Printf.sprintf "unsupported constant with tag %d (floats etc.)" tag)

let write_hex path arr n =
  let oc = open_out path in
  for i = 0 to n - 1 do Printf.fprintf oc "%08x\n" arr.(i) done;
  close_out oc

let () =
  let file = read_file Sys.argv.(1) and outdir = Sys.argv.(2) in
  let globals : Obj.t = Marshal.from_string (section file "DATA") 0 in
  let nglobals = Obj.size globals in
  let g = Array.init nglobals (fun i -> place (Obj.field globals i)) in
  write_hex (Filename.concat outdir "heap.hex") !words !heap_words;
  write_hex (Filename.concat outdir "globals.hex") g nglobals;
  let oc = open_out (Filename.concat outdir "image.txt") in
  Printf.fprintf oc "heap_words %d\nglobals %d\n" !heap_words nglobals;
  close_out oc;
  Printf.printf "%s: %d heap words, %d globals\n" Sys.argv.(1) !heap_words nglobals
