module ocaml4142_vm_rtl #(
    parameter int PCW        = 24,
    parameter int VALUEW     = 32,
    parameter int STACK_AW   = 16,
    parameter int HEAP_AW    = 18,
    parameter int GLOBALS_AW = 12,
    // Initial heap (the program's structured constants) and global table, as
    // laid out by bc2image; the heap allocates from HEAP_INIT_WORDS upwards.
    // In simulation +heap=, +globals= and +heap_words= override them.
    parameter HEAP_INIT = "",  // untyped: Vivado 2020.1 synthesis has no string parameters
    parameter GLOBALS_INIT = "",
    parameter int HEAP_INIT_WORDS = 0,
    // EXTERNAL_IMAGE: the program's heap and globals are written through the
    // load port while in reset (a boot sequencer), and image_heap_words says
    // where its heap image ends, in place of HEAP_INIT/HEAP_INIT_WORDS.
    parameter bit EXTERNAL_IMAGE = 1'b0
) (
    input logic clk,
    input logic reset,


    output logic [PCW-1:0] pc,
    input  logic [   31:0] code_rdata,


    output logic                trap_valid,
    output logic [         7:0] trap_prim,
    output logic [  VALUEW-1:0] trap_arg0,
    output logic [  VALUEW-1:0] trap_arg1,
    input  logic                trap_ready,
    input  logic [  VALUEW-1:0] trap_result,
    output logic [  VALUEW-1:0] accu,
    output logic [STACK_AW-1:0] sp,
    output logic [         6:0] state_out,
    output logic [        31:0] imm,
    output logic [        31:0] nvars,
    output logic [        31:0] offset,
    output logic [        31:0] alloc_wosize,
    output logic [        31:0] alloc_base,
    output logic [        31:0] alloc_tag,
    output logic [        31:0] closure_codeptr,
    output logic [         7:0] closure_nvars,
    output logic [         7:0] closure_i,
    output logic [         7:0] opcode_out,
    output logic [        31:0] tos,
    output logic                halted,
    // caml_ml_output_char: one-cycle strobe with the character written
    output logic                putc_valid,
    output logic [         7:0] putc_char,

    // Load port: while reset is held, load_we writes load_data to
    // heap_mem[load_addr] (or globals_mem[load_addr] with load_globals).
    input  logic                load_we,
    input  logic                load_globals,
    input  logic [HEAP_AW-1:0]  load_addr,
    input  logic [VALUEW-1:0]   load_data,
    input  logic [HEAP_AW-1:0]  image_heap_words
);










  typedef enum logic [7:0] {

    ACC0,
    ACC1,
    ACC2,
    ACC3,
    ACC4,
    ACC5,
    ACC6,
    ACC7,
    ACC,
    PUSH,
    PUSHACC0,
    PUSHACC1,
    PUSHACC2,
    PUSHACC3,
    PUSHACC4,
    PUSHACC5,
    PUSHACC6,
    PUSHACC7,
    PUSHACC,
    POP,
    ASSIGN,
    ENVACC1,
    ENVACC2,
    ENVACC3,
    ENVACC4,
    ENVACC,
    PUSHENVACC1,
    PUSHENVACC2,
    PUSHENVACC3,
    PUSHENVACC4,
    PUSHENVACC,
    PUSH_RETADDR,
    APPLY,
    APPLY1,
    APPLY2,
    APPLY3,
    APPTERM,
    APPTERM1,
    APPTERM2,
    APPTERM3,
    RETURN,
    RESTART,
    GRAB,
    CLOSURE,
    CLOSUREREC,
    OFFSETCLOSUREM3,
    OFFSETCLOSURE0,
    OFFSETCLOSURE3,
    OFFSETCLOSURE,
    PUSHOFFSETCLOSUREM3,
    PUSHOFFSETCLOSURE0,
    PUSHOFFSETCLOSURE3,
    PUSHOFFSETCLOSURE,
    GETGLOBAL,
    PUSHGETGLOBAL,
    GETGLOBALFIELD,
    PUSHGETGLOBALFIELD,
    SETGLOBAL,
    ATOM0,
    ATOM,
    PUSHATOM0,
    PUSHATOM,
    MAKEBLOCK,
    MAKEBLOCK1,
    MAKEBLOCK2,
    MAKEBLOCK3,
    MAKEFLOATBLOCK,
    GETFIELD0,
    GETFIELD1,
    GETFIELD2,
    GETFIELD3,
    GETFIELD,
    GETFLOATFIELD,
    SETFIELD0,
    SETFIELD1,
    SETFIELD2,
    SETFIELD3,
    SETFIELD,
    SETFLOATFIELD,
    VECTLENGTH,
    GETVECTITEM,
    SETVECTITEM,
    GETBYTESCHAR,
    SETBYTESCHAR,
    BRANCH,
    BRANCHIF,
    BRANCHIFNOT,
    SWITCH,
    BOOLNOT,
    PUSHTRAP,
    POPTRAP,
    RAISE,
    CHECK_SIGNALS,
    C_CALL1,
    C_CALL2,
    C_CALL3,
    C_CALL4,
    C_CALL5,
    C_CALLN,
    CONST0,
    CONST1,
    CONST2,
    CONST3,
    CONSTINT,
    PUSHCONST0,
    PUSHCONST1,
    PUSHCONST2,
    PUSHCONST3,
    PUSHCONSTINT,
    NEGINT,
    ADDINT,
    SUBINT,
    MULINT,
    DIVINT,
    MODINT,
    ANDINT,
    ORINT,
    XORINT,
    LSLINT,
    LSRINT,
    ASRINT,
    EQ,
    NEQ,
    LTINT,
    LEINT,
    GTINT,
    GEINT,
    OFFSETINT,
    OFFSETREF,
    ISINT,
    GETMETHOD,
    BEQ,
    BNEQ,
    BLTINT,
    BLEINT,
    BGTINT,
    BGEINT,
    ULTINT,
    UGEINT,
    BULTINT,
    BUGEINT,
    GETPUBMET,
    GETDYNMET,
    STOP,
    EVENT,
    BREAK,
    RERAISE,
    RAISE_NOTRACE,
    GETSTRINGCHAR
  } opcode_t;



  localparam int unsigned FIRST_UNIMPLEMENTED_OP = int'(GETSTRINGCHAR) + 1;





  function automatic bit opcode_has_imm8(opcode_t op);
    unique case (op)

      PUSHACC, ACC, POP, ASSIGN,
      PUSHENVACC, ENVACC, PUSH_RETADDR, APPLY,
      APPTERM1, APPTERM2, APPTERM3, RETURN,
      GRAB, PUSHGETGLOBAL, GETGLOBAL, SETGLOBAL,
      PUSHATOM, ATOM, MAKEBLOCK1, MAKEBLOCK2,
      MAKEBLOCK3, MAKEFLOATBLOCK, GETFIELD,
      GETFLOATFIELD, SETFIELD, SETFLOATFIELD,
      BRANCH, BRANCHIF, BRANCHIFNOT, PUSHTRAP,
      C_CALL1, C_CALL2, C_CALL3, C_CALL4, C_CALL5,
      CONSTINT, PUSHCONSTINT, OFFSETINT,
      OFFSETREF, OFFSETCLOSURE, PUSHOFFSETCLOSURE, SWITCH
      :
      opcode_has_imm8 = 1'b1;
      default: opcode_has_imm8 = 1'b0;
    endcase
  endfunction

  function automatic bit opcode_has_imm16(opcode_t op);
    unique case (op)
      APPTERM, CLOSURE, PUSHGETGLOBALFIELD,
      GETGLOBALFIELD, MAKEBLOCK, C_CALLN,
      BEQ, BNEQ, BLTINT, BLEINT, BGTINT, BGEINT,
      BULTINT, BUGEINT, GETPUBMET
      :
      opcode_has_imm16 = 1'b1;
      default: opcode_has_imm16 = 1'b0;
    endcase
  endfunction






  opcode_t opcode;
  assign opcode_out = opcode;






  function automatic logic [VALUEW-1:0] Val_int(input integer n);
    Val_int = ((n <<< 1) | 1);
  endfunction

  function automatic integer Int_val(input logic [VALUEW-1:0] v);

    Int_val = $signed(v) >>> 1;
  endfunction

  function automatic bit Is_int(input logic [VALUEW-1:0] v);
    Is_int = v[0];
  endfunction

  function automatic logic [VALUEW-1:0] Wosize_hd(input logic [VALUEW-1:0] hdr);
    Wosize_hd = hdr[31:16];  // the VM's header: {wosize[31:16], color[15:8], tag[7:0]}
  endfunction

  function automatic logic [VALUEW-1:0] Val_long(input logic [VALUEW-1:0] n);
    Val_long = (n << 1) | 1;  // Tag as OCaml integer
  endfunction

  localparam logic [VALUEW-1:0] VAL_FALSE = Val_int(0);
  localparam logic [VALUEW-1:0] VAL_TRUE = Val_int(1);
  localparam logic [VALUEW-1:0] VAL_UNIT = Val_int(0);







  logic [  VALUEW-1:0] stack_mem[0:(1<<STACK_AW)-1];
  logic [STACK_AW-1:0] trapsp;









  logic [  VALUEW-1:0] heap_mem [ 0:(1<<HEAP_AW)-1];
  logic [ HEAP_AW-1:0] hp;
  logic [ HEAP_AW-1:0] hp_after_image = HEAP_INIT_WORDS;

  // ---- Garbage collection: Cheney's copying collector ----
  // heap_mem: [0, heap_lo) the image's constants, never moved (they cannot
  // point into the dynamic heap); above that two semi-spaces of gc_semi
  // words.  Allocation bumps hp within the current space (from_lo up to
  // hp_limit).  When an allocation would not fit, the VM stops and copies
  // everything reachable from the roots (accu, env, the live stack, the
  // globals) into the other space, then restarts the allocating
  // instruction.  In simulation +semispace=N shrinks the spaces.
  logic [HEAP_AW:0] heap_lo, gc_semi, from_lo, to_lo, hp_limit;
  logic [HEAP_AW:0] gc_semispace_override = '0;
  logic [HEAP_AW:0] gc_free, gc_scan, gc_obj, gc_new_idx;
  logic [VALUEW-1:0] gc_val, gc_new, gc_hdr;
  logic [15:0] gc_size, gc_rd, gc_wr, gc_j;
  logic [15:0] gc_scan_size;  // the block being scanned (gc_size is the one being copied)
  logic gc_copy_valid, gc_mark_second;
  logic [STACK_AW:0] gc_i;
  logic [31:0] gc_need, alloc_need;
  logic [2:0] gc_phase;
  localparam logic [2:0] GC_ACCU = 0, GC_ENV = 1, GC_STACK = 2, GC_GLOBALS = 3, GC_SCAN = 4;
  logic gc_return_to_scan;  // where S_GC_FWD's result goes
  logic [15:0] gc_infix_off;  // gc_val pointed at an infix header this many words into its block
  localparam logic [7:0] GC_FORWARDED = 8'hFF;  // header colour of a copied block
  localparam int NO_SCAN_TAG = 251;             // strings, floats, custom: no pointers inside
  int gc_count;

  // Where the dynamic heap starts (above the image) and each semi-space's size.
  // The upper space stops one word short of the top: hp and alloc_base are
  // HEAP_AW bits, so a space ending at 1 << HEAP_AW would let an allocation
  // that exactly fills it wrap hp to 0 and then allocate over the image.
  logic [HEAP_AW-1:0] image_words;
  logic [HEAP_AW:0] heap_base, semi_space;
  assign image_words = EXTERNAL_IMAGE ? image_heap_words : hp_after_image;
  assign heap_base = (image_words == 0) ? 1 : image_words;
  assign semi_space = (gc_semispace_override != 0) ? gc_semispace_override
                    : (((1 << HEAP_AW) - 1 - heap_base) >> 1);

  // A pointer into the current from-space: even, no code-pointer marker,
  // an index in [from_lo, from_lo + gc_semi).
  function automatic logic gc_points_to_from(input logic [VALUEW-1:0] v);
    logic [VALUEW-1:0] idx;
    idx = {2'b00, v[VALUEW-1:2]};
    gc_points_to_from = !v[0] && !v[VALUEW-1] && idx >= from_lo && idx < from_lo + gc_semi;
  endfunction

  // Code pointers (closure field 0, return addresses on the stack) set the
  // top bit, which no heap pointer (index << 2) has: the GC must tell them
  // apart, since both are otherwise even words.
  function automatic logic [VALUEW-1:0] Make_codeptr(input logic [PCW-1:0] pc);
    Make_codeptr = {1'b1, {(VALUEW - PCW - 3) {1'b0}}, pc, 2'b00};
  endfunction

  function automatic logic [VALUEW-1:0] Ptr_of_heap_index(input logic [HEAP_AW-1:0] idx);

    Ptr_of_heap_index = {{(VALUEW - 2 - HEAP_AW) {1'b0}}, idx, 2'b00};
  endfunction

  function automatic logic [HEAP_AW-1:0] Heap_index_of_ptr(input logic [VALUEW-1:0] ptr);

    Heap_index_of_ptr = ptr[HEAP_AW+1:2];
  endfunction

  function automatic logic [PCW-1:0] Codeptr_val(input logic [VALUEW-1:0] ptr);
    Codeptr_val = ptr[PCW+1:2];
  endfunction


  function automatic logic [VALUEW-1:0] Make_header(input int wosize, input int tag);
    logic [ 7:0] tag8 = tag;
    logic [15:0] wosize16 = wosize;

    Make_header = {wosize16, 8'd0, tag8};
  endfunction






  localparam int TAG_CLOSURE = 247;




  logic [VALUEW-1:0] env;
  logic [       7:0] extra_args;






  typedef enum logic [6:0] 
`include "state_rtl_complete.h" 

  state_t state;
  assign state_out = state;
  








  logic [       7:0] imm_b;
  logic [      31:0] imm2;

  // The allocator (S_ALLOC_*): a block of alloc_wosize fields, tag
  // alloc_tag.  Closures start with a prefix: code pointer, closinfo, and
  // for GRAB's partial application the current env (alloc_prefix = 2 or 3).
  // The remaining fields are accu (if alloc_use_accu), then sp[0], sp[1], ...
  // (OCaml 4.14's MAKEBLOCK, CLOSURE, which pushes accu first, and GRAB).
  logic [15:0] alloc_i;        // the field being written
  logic [15:0] alloc_prefix;   // 0 for blocks, 2 for closures, 3 for GRAB, 3f-1 for CLOSUREREC
  // CLOSUREREC with f functions: one block of f closures -- code, closinfo,
  // then for each further function an infix header, code and closinfo --
  // and the shared variables.  alloc_table is the offset table after the
  // instruction; alloc_fn_i/alloc_phase track the triple being written.
  logic [ 7:0] alloc_nfuncs;   // 0: not a CLOSUREREC
  logic [PCW-1:0] alloc_table;
  logic [ 7:0] alloc_fn_i;
  logic [ 1:0] alloc_phase;    // (field + 1) mod 3: 0 infix header, 1 code, 2 closinfo
  logic [ 7:0] alloc_push_i;   // CLOSUREREC: results pushed so far
  localparam int INFIX_TAG = 249;
  logic        alloc_use_accu;
  logic [PCW-1:0] alloc_code;  // a closure's code
  logic        alloc_push_result;  // CLOSUREREC pushes the closure too
  logic        alloc_then_return;  // GRAB returns the closure to its caller
  logic [ 7:0] restart_n;          // RESTART: arguments saved in the closure
  localparam logic [VALUEW-1:0] CLOSINFO = 32'h5;  // Make_closinfo(0, 2): env from field 2

  logic [VALUEW-1:0] temp_arg1, temp_arg2, temp_arg3;
  logic [VALUEW-1:0] temp_field1, temp_field2, temp_field3;
  logic [VALUEW-1:0] temp_stack_val;
  logic [VALUEW-1:0] temp_heap_val;
  logic [VALUEW-1:0] temp_value;
  logic [VALUEW-1:0] temp_index;
  logic [VALUEW-1:0] temp_array_ptr;
  logic [VALUEW-1:0] temp_base_ptr;
  logic [VALUEW-1:0] temp_return_pc, temp_return_env;
  logic [7:0] temp_extra_args;


  logic [7:0] op_cycle_count;

  // The trap port as an I/O bus for vm_io_read/vm_io_write: trap_valid is
  // held, with trap_prim and plain-integer arguments, until trap_ready; a
  // read takes trap_result.  The device acts once per request.
  localparam logic [7:0] TRAP_IO_READ = 8'h01;
  localparam logic [7:0] TRAP_IO_WRITE = 8'h02;

  logic [15:0] str_words;  // caml_ml_string_length: the string's wosize
  logic [ 1:0] str_byte;   // caml_string_get: byte within the word
  logic [ 7:0] byte_value;   // SETBYTESCHAR / caml_bytes_set: the byte to store
  logic        streq_negate; // caml_string_notequal: invert the answer
  logic [HEAP_AW-1:0] str2_addr;  // caml_string_equal: the second string's header
  localparam int STRING_TAG = 252;

  // Sequential divider for DIVINT/MODINT: restoring division of the
  // magnitudes, one quotient bit per cycle, signs applied at the end so the
  // result truncates toward zero (OCaml and C semantics).
  logic [31:0] div_quo;  // dividend shifting out, quotient shifting in
  logic [31:0] div_rem;  // partial remainder
  logic [31:0] div_dsr;  // divisor magnitude
  logic [ 5:0] div_bits_left;
  logic        div_quo_negative;
  logic        div_rem_negative;
  logic        div_want_mod;
  state_t next_state_after_mem;


  logic [STACK_AW-1:0] temp_stack_addr;
  logic [HEAP_AW-1:0] temp_heap_addr;
  logic [GLOBALS_AW-1:0] temp_globals_addr;


  logic [VALUEW-1:0] globals_mem[0:(1<<GLOBALS_AW)-1];

  initial begin
`ifndef SYNTHESIS
    string heap_file, globals_file;
    int heap_words;
`endif
    if (HEAP_INIT != "") $readmemh(HEAP_INIT, heap_mem);
    if (GLOBALS_INIT != "") $readmemh(GLOBALS_INIT, globals_mem);
`ifndef SYNTHESIS
    if ($value$plusargs("heap=%s", heap_file)) $readmemh(heap_file, heap_mem);
    if ($value$plusargs("globals=%s", globals_file)) $readmemh(globals_file, globals_mem);
    if ($value$plusargs("heap_words=%d", heap_words)) hp_after_image = heap_words;
    if ($value$plusargs("semispace=%d", heap_words)) gc_semispace_override = heap_words;
`endif
  end

  // ------------------------------------------------------------------
  // Memory ports: at most two accesses per memory per clock.
  //
  // stack_mem, heap_mem and globals_mem each have two ports, A and B, with
  // synchronous reads, so each maps onto one true-dual-port block RAM. The
  // state machine never indexes a memory directly: it asks for reads and
  // writes through the *_read_a/_b and *_write tasks below, which fill in
  // the port requests (blocking temporaries, cleared every cycle), and the
  // only accesses are the port statements at the end of the clocked block.
  // A read requested in one cycle delivers its data in *_rd_a/_b the next.
  //
  // A state that reads memory therefore runs in two cycles, told apart by
  // rd_phase: with rd_phase clear it only requests its reads (from the same
  // addresses its body uses) and holds; with rd_phase set it runs its body
  // on the delivered data. The request cycle writes nothing and changes no
  // register an address depends on, so every read sees exactly the memory
  // state it would have seen when reads were combinational.
  // ------------------------------------------------------------------
  logic                  st_re_a, st_we_a, st_re_b;
  logic [  STACK_AW-1:0] st_addr_a, st_addr_b;
  logic [    VALUEW-1:0] st_wd_a, st_rd_a, st_rd_b;
  logic                  hm_re_a, hm_we_a, hm_re_b;
  logic [   HEAP_AW-1:0] hm_addr_a, hm_addr_b;
  logic [    VALUEW-1:0] hm_wd_a, hm_rd_a, hm_rd_b;
  logic                  gm_re_a, gm_we_a, gm_re_b;
  logic [GLOBALS_AW-1:0] gm_addr_a, gm_addr_b;
  logic [    VALUEW-1:0] gm_wd_a, gm_rd_a, gm_rd_b;
  logic                  rd_phase;

  // tos: a register loaded from stack port A whenever it reads stack[sp],
  // a cycle after the read, instead of a third, always-on read port.
  logic [    VALUEW-1:0] tos_q;
  logic                  st_a_was_tos;
  assign tos = tos_q;
  // Debug outputs of the old closure path, no longer driven by anything.
  assign closure_codeptr = alloc_code;
  assign closure_nvars = nvars[7:0];
  assign closure_i = alloc_i[7:0];

  task automatic stack_read_a(input logic [STACK_AW-1:0] a);
    st_re_a = 1'b1;
    st_addr_a = a;
  endtask
  task automatic stack_read_b(input logic [STACK_AW-1:0] a);
    st_re_b = 1'b1;
    st_addr_b = a;
  endtask
  task automatic heap_read_a(input logic [HEAP_AW-1:0] a);
    hm_re_a = 1'b1;
    hm_addr_a = a;
  endtask
  task automatic heap_read_b(input logic [HEAP_AW-1:0] a);
    hm_re_b = 1'b1;
    hm_addr_b = a;
  endtask
  task automatic globals_read_a(input logic [GLOBALS_AW-1:0] a);
    gm_re_a = 1'b1;
    gm_addr_a = a;
  endtask

  // Each memory is one read/write port (A) and one read-only port (B): a
  // write needs port A, so a state writes a memory at most once per cycle.
  // Two tools' RAM inference depend on this shape (yosys and Vivado).
  task automatic stack_write(input logic [STACK_AW-1:0] a, input logic [VALUEW-1:0] d);
    if (!st_re_a && !st_we_a) begin
      st_we_a = 1'b1;
      st_addr_a = a;
      st_wd_a = d;
    end else begin
`ifndef SYNTHESIS
      $error("stack_mem: port A already in use this cycle (state %s)", state.name());
`endif
    end
  endtask
  task automatic heap_write(input logic [HEAP_AW-1:0] a, input logic [VALUEW-1:0] d);
    if (!hm_re_a && !hm_we_a) begin
      hm_we_a = 1'b1;
      hm_addr_a = a;
      hm_wd_a = d;
    end else begin
`ifndef SYNTHESIS
      $error("heap_mem: port A already in use this cycle (state %s)", state.name());
`endif
    end
  endtask
  task automatic globals_write(input logic [GLOBALS_AW-1:0] a, input logic [VALUEW-1:0] d);
    if (!gm_re_a && !gm_we_a) begin
      gm_we_a = 1'b1;
      gm_addr_a = a;
      gm_wd_a = d;
    end else begin
`ifndef SYNTHESIS
      $error("globals_mem: port A already in use this cycle (state %s)", state.name());
`endif
    end
  endtask

  // The request cycle of a two-cycle state: keep the state (overriding
  // S_EXEC's default move to S_DONE) and run the body next cycle.
  task automatic hold_for_read;
    rd_phase <= 1'b1;
    state    <= state;
  endtask




  always_ff @(posedge clk) begin
    if (reset) halted <= 1'b0;
    else if (opcode == STOP && state == S_EXEC) halted <= 1'b1;
  end



  // accu <= heap[Heap_index_of_ptr(ptr_value) + offset_used], in two
  // cycles: request the read, then take the delivered word.
  task read_acc_from_heap;
    input [31:0] ptr_value, offset_used;
    begin
      if (!rd_phase) begin
        heap_read_a(Heap_index_of_ptr(ptr_value) + offset_used);
        hold_for_read();
      end else begin
`ifndef SYNTHESIS
        $display("  [HEAP_READ] op=%s ptr=0x%08x heap_idx=%d offset=%d", opcode.name(), ptr_value,
                 Heap_index_of_ptr(ptr_value), offset_used);
        $display("  [HEAP_READ] addr=%d value=0x%08x is_header=%b",
                 Heap_index_of_ptr(ptr_value) + offset_used, hm_rd_a, (offset_used == 0));
`endif
        accu <= hm_rd_a;
      end
    end
  endtask
  task caml_ml_open_descriptor_in;
    begin
      $display("caml_ml_open_descriptor_in");
      accu <= 32'hC0010000;
    end
  endtask

  task caml_ml_open_descriptor_out;
    begin
      $display("caml_ml_open_descriptor_out");
      accu <= 32'hF00D0000;
    end
  endtask

  task caml_ml_output_char;
    begin
      $display("caml_ml_output_char %c (%d)", Int_val(st_rd_a), Int_val(st_rd_a));
      putc_valid <= 1'b1;
      putc_char  <= st_rd_a[8:1];  // Int_val, low byte
      accu <= Val_int(0);
    end
  endtask

  task caml_ml_flush;
    begin
      $display("caml_ml_flush");
      accu <= Val_int(0);
    end
  endtask

  task caml_string_get;
    begin
      $display("caml_string_get %x %x", accu, Int_val(st_rd_a));
      // bytes pack little-endian after the header; index = Int_val(tos)
      temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + st_rd_a[HEAP_AW+2:3];
      str_byte <= st_rd_a[2:1];
      state <= S_STRGET_READ;
    end
  endtask





  task automatic div_start(input logic signed [31:0] dividend,
                           input logic signed [31:0] divisor, input logic want_mod);
    div_quo          <= dividend[31] ? -dividend : dividend;
    div_dsr          <= divisor[31] ? -divisor : divisor;
    div_rem          <= '0;
    div_bits_left    <= 6'd32;
    div_quo_negative <= dividend[31] ^ divisor[31];
    div_rem_negative <= dividend[31];
    div_want_mod     <= want_mod;
  endtask

`ifndef SYNTHESIS
  // After a collection (at S_GC_DONE, before the spaces swap): to-space must
  // be a run of blocks from to_lo exactly to gc_free, none left marked
  // forwarded, and every pointer in them, in the live stack and in the
  // globals must land on a block header in to-space or in the image below
  // heap_lo -- never in from-space.
  function automatic bit gc_valid_target(input logic [VALUEW-1:0] v, input bit is_block[int]);
    int p;
    logic [VALUEW-1:0] h;
    p = int'(v >> 2);
    if (p < heap_lo || is_block.exists(p)) return 1;
    h = heap_mem[p];
    return h[7:0] == INFIX_TAG && is_block.exists(p - int'(h[31:16]));
  endfunction

  task automatic gc_check_to_space();
    bit is_block[int];
    int idx, bad, f;
    logic [VALUEW-1:0] hdr, v;
    bad = 0;
    for (idx = to_lo; idx < gc_free; idx += 1 + heap_mem[idx][31:16]) begin
      is_block[idx] = 1;
      if (heap_mem[idx][15:8] == GC_FORWARDED) bad++;
    end
    if (idx != gc_free) bad++;
    for (idx = to_lo; idx < gc_free; idx += 1 + hdr[31:16]) begin
      hdr = heap_mem[idx];
      if (hdr[7:0] < NO_SCAN_TAG)
        for (f = 1; f <= hdr[31:16]; f++) begin
          v = heap_mem[idx+f];
          if (!v[0] && !v[VALUEW-1] && !gc_valid_target(v, is_block)) bad++;
        end
    end
    for (idx = sp; idx < (1 << STACK_AW) - 1; idx++) begin
      v = stack_mem[idx];
      if (!v[0] && !v[VALUEW-1] && !gc_valid_target(v, is_block)) bad++;
    end
    for (idx = 0; idx < (1 << GLOBALS_AW); idx++) begin
      v = globals_mem[idx];
      if (!v[0] && !v[VALUEW-1] && !gc_valid_target(v, is_block)) bad++;
    end
    $display("GC %0d: %0d words live, semi-space %0d%s", gc_count + 1, gc_free - to_lo, gc_semi,
             bad ? " -- HEAP CHECK FAILED" : "");
    if (bad) $error("GC: %0d inconsistencies in to-space", bad);
  endtask
`endif

  always_comb begin
    case (opcode)
      MAKEBLOCK1: alloc_need = 2;
      MAKEBLOCK2: alloc_need = 3;
      MAKEBLOCK3: alloc_need = 4;
      MAKEBLOCK: alloc_need = alloc_wosize + 1;
      CLOSURE: alloc_need = 3 + nvars;
      CLOSUREREC: alloc_need = 3 * imm + nvars;  // header + 3f - 1 + nvars
      GRAB: alloc_need = (extra_args < imm) ? 5 + extra_args : 0;
      C_CALL1: alloc_need = (imm == 16'h052) ? (Int_val(accu) >> 2) + 2 : 0;  // caml_create_bytes
      default: alloc_need = 0;
    endcase
  end

  always_ff @(posedge clk) begin
    // No memory requests unless a state makes them this cycle.
    st_re_a = 1'b0;
    st_we_a = 1'b0;
    st_re_b = 1'b0;
    st_addr_a = '0;
    st_addr_b = '0;
    st_wd_a = '0;
    hm_re_a = 1'b0;
    hm_we_a = 1'b0;
    hm_re_b = 1'b0;
    hm_addr_a = '0;
    hm_addr_b = '0;
    hm_wd_a = '0;
    gm_re_a = 1'b0;
    gm_we_a = 1'b0;
    gm_re_b = 1'b0;
    gm_addr_a = '0;
    gm_addr_b = '0;
    gm_wd_a = '0;
    putc_valid <= 1'b0;

    // Loading an image through port A while reset holds the VM still.
    if (reset && load_we) begin
      if (load_globals) begin
        gm_we_a = 1'b1;
        gm_addr_a = load_addr[GLOBALS_AW-1:0];
        gm_wd_a = load_data;
      end else begin
        hm_we_a = 1'b1;
        hm_addr_a = load_addr;
        hm_wd_a = load_data;
      end
    end

    if (reset) begin
      putc_char    <= '0;
      trap_valid   <= 1'b0;
      trap_prim    <= '0;
      trap_arg0    <= '0;
      trap_arg1    <= '0;
      rd_phase     <= 1'b0;
      tos_q        <= '0;
      st_a_was_tos <= 1'b0;
      state        <= S_FETCH;
      pc                    <= '0;
      opcode                <= STOP;
      imm                   <= '0;
      imm_b                 <= '0;
      imm2                  <= '0;
      nvars                 <= '0;
      offset                <= '0;
      alloc_wosize          <= '0;
      alloc_tag             <= '0;
      accu                  <= VAL_UNIT;
      env                   <= '0;
      extra_args            <= 8'd0;
      temp_arg1             <= '0;
      temp_arg2             <= '0;
      temp_arg3             <= '0;
      temp_field1           <= '0;
      temp_field2           <= '0;
      temp_field3           <= '0;
      temp_stack_val        <= '0;
      temp_heap_val         <= '0;
      temp_return_pc        <= '0;
      temp_return_env       <= '0;
      temp_extra_args       <= '0;
      op_cycle_count        <= '0;
      next_state_after_mem  <= S_DONE;
      temp_stack_addr       <= '0;
      temp_heap_addr        <= '0;
      temp_globals_addr     <= '0;


      sp                    <= (1 << STACK_AW) - 1;
      trapsp                <= (1 << STACK_AW) - 1;


      // the dynamic heap starts above the image, and never at index 0
      heap_lo  <= heap_base;
      gc_semi  <= semi_space;
      from_lo  <= heap_base;
      hp       <= heap_base;
      hp_limit <= heap_base + semi_space;
      gc_count <= 0;
    end else if (!halted) begin
      // A two-cycle state's request cycle sets this again (hold_for_read).
      rd_phase <= 1'b0;
      unique case (state)




        S_FETCH: begin
          opcode <= opcode_t'(code_rdata[7:0]);
          imm <= '0;
          nvars <= '0;
          offset <= '0;
          alloc_wosize <= '0;
          alloc_tag <= '0;

          $display("  at fetch, acc=0x%08x, pc=%d, bytecode=%d", accu, pc, code_rdata);
          `ifndef SYNTHESIS  // debug peeks; not part of the two-port datapath
          $display("  stack[sp+0]=0x%08x", stack_mem[sp+0]);
          $display("  stack[sp+1]=0x%08x", stack_mem[sp+1]);
          $display("  stack[sp+2]=0x%08x", stack_mem[sp+2]);
          $display("  stack[sp+3]=0x%08x", stack_mem[sp+3]);
          $display("  stack[sp+4]=0x%08x", stack_mem[sp+4]);
          $display("  heap[hp-1]=0x%08x", heap_mem[hp-1]);
          $display("  heap[hp-2]=0x%08x", heap_mem[hp-2]);
          $display("  heap[hp-3]=0x%08x", heap_mem[hp-3]);
          $display("  heap[hp-4]=0x%08x", heap_mem[hp-4]);
          `endif
          pc    <= pc + 1;
          state <= S_DECIDE_IMM;
        end




        S_DECIDE_IMM: begin
          if (opcode_has_imm8(opcode)) begin
            state <= S_FETCH_IMM;
          end else if (opcode_has_imm16(opcode) || opcode == CLOSUREREC) begin
            state <= S_FETCH_IMM;
            if (opcode == CLOSURE) begin
              nvars <= code_rdata;
              pc <= pc + 1;
            end else if (opcode == CLOSUREREC) begin

              imm <= code_rdata;
              pc  <= pc + 1;
            end else if (opcode == MAKEBLOCK) begin

              alloc_wosize <= code_rdata;
              pc <= pc + 1;
            end else if (opcode == BEQ || opcode == BNEQ || 
                           opcode == BLTINT || opcode == BLEINT ||
                           opcode == BGTINT || opcode == BGEINT ||
                           opcode == BULTINT || opcode == BUGEINT) begin

              imm <= code_rdata;
              pc  <= pc + 1;
            end else begin  // APPTERM, (PUSH)GETGLOBALFIELD, C_CALLN, GETPUBMET
              imm <= code_rdata;
              pc  <= pc + 1;
            end
          end else begin
            state <= S_EXEC;
          end
        end




        S_FETCH_IMM: begin
          if (opcode == CLOSUREREC) begin

            nvars <= code_rdata;
            pc <= pc + 1;
            state <= S_EXEC;
          end else if (opcode == CLOSURE) begin

            offset <= code_rdata;
            pc <= pc + 1;
            state <= S_EXEC;
          end else if (opcode == MAKEBLOCK) begin

            alloc_tag <= code_rdata;
            pc <= pc + 1;
            state <= S_EXEC;
          end else if (opcode == BEQ || opcode == BNEQ || opcode == BRANCHIF ||
                       opcode == BLTINT || opcode == BLEINT || opcode == BRANCHIFNOT ||
                       opcode == BGTINT || opcode == BGEINT || opcode == BRANCH ||
                       opcode == BULTINT || opcode == BUGEINT) begin

            offset <= code_rdata;
            pc <= pc + 1;
            state <= S_EXEC;
          end else if (opcode_has_imm16(opcode)) begin  // the second operand
            imm2  <= code_rdata;
            pc    <= pc + 1;
            state <= S_EXEC;
          end else begin
            imm   <= code_rdata;
            pc    <= pc + 1;
            state <= S_EXEC;
          end
        end




        S_EXEC: begin


          state <= S_DONE;

          if (!rd_phase && alloc_need != 0 && {1'b0, hp} + alloc_need > hp_limit) begin
            gc_need <= alloc_need;  // collect, then run this instruction again
            state <= S_GC_START;
          end else
          unique case (opcode)






            ACC0: begin
              temp_stack_addr <= sp + 0;
              next_state_after_mem <= S_DONE;
              state <= S_STACK_READ;
            end





            ACC1: begin
              temp_stack_addr <= sp + 1;
              next_state_after_mem <= S_DONE;
              state <= S_STACK_READ;
            end

            ACC2: begin
              temp_stack_addr <= sp + 2;
              next_state_after_mem <= S_DONE;
              state <= S_STACK_READ;
            end

            ACC3: begin
              temp_stack_addr <= sp + 3;
              next_state_after_mem <= S_DONE;
              state <= S_STACK_READ;
            end

            ACC4: begin
              temp_stack_addr <= sp + 4;
              next_state_after_mem <= S_DONE;
              state <= S_STACK_READ;
            end

            ACC5: begin
              temp_stack_addr <= sp + 5;
              next_state_after_mem <= S_DONE;
              state <= S_STACK_READ;
            end

            ACC6: begin
              temp_stack_addr <= sp + 6;
              next_state_after_mem <= S_DONE;
              state <= S_STACK_READ;
            end

            ACC7: begin
              temp_stack_addr <= sp + 7;
              next_state_after_mem <= S_DONE;
              state <= S_STACK_READ;
            end

            ACC: begin
              temp_stack_addr <= sp + imm;
              next_state_after_mem <= S_DONE;
              state <= S_STACK_READ;
            end




            APPLY: begin
              extra_args <= imm - 1;
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1;  // Read closure[1]
              state <= S_HEAP_READ;
              next_state_after_mem <= S_APPLY1_SETPC;
            end



            APPLY1:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              stack_write(sp - 3, st_rd_a);
              op_cycle_count <= 0;
              state          <= S_APPLY1_WRITE_FRAME;
            end


            PUSH_RETADDR: begin
              op_cycle_count <= 0;
              state <= S_PUSH_RETADDR_WRITE_FRAME;
            end



































            // APPLY2/APPLY3: the arguments move down 3 slots, and the return
            // frame (pc, env, extra_args) goes in above them:
            //   sp -= 3; sp[0..n-1] = args; sp[n..n+2] = pc, env, extra_args
            APPLY2, APPLY3:
            if (!rd_phase) begin
              stack_read_a(sp);
              stack_read_b(sp + 1);
              hold_for_read();
            end else begin
              stack_write(sp - 3, st_rd_a);
              temp_arg2 <= st_rd_b;  // written next cycle: one stack write per cycle
              op_cycle_count <= 0;
              state <= (opcode == APPLY2) ? S_APPLY2_WRITE_FRAME : S_APPLY3_WRITE_FRAME;
            end


































































            APPTERM1:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              temp_arg1 <= st_rd_a;
              sp        <= sp + imm - 1;
              state     <= S_APPTERM1_WRITE;
            end

























            APPTERM2: begin
              temp_stack_addr <= sp;
              imm_b <= 2;
              op_cycle_count <= 0;
              state <= S_APPTERM2_READ_ARGS;
            end












































            // APPTERM nargs, slotsize: the nargs arguments slide up over the
            // slotsize - nargs slots of the current frame, top one first
            // (the destination is never below the source), then a jump.
            APPTERM: begin
              op_cycle_count <= imm - 1;
              state <= S_APPTERM_COPY;
            end

            APPTERM3: begin
              temp_stack_addr <= sp;
              imm_b <= 3;
              op_cycle_count <= 0;
              state <= S_APPTERM3_READ_ARGS;
            end






















































            NEGINT: begin
              accu <= Val_int(-Int_val(accu));
            end

            ADDINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= Val_int(Int_val(accu) + Int_val(st_rd_a));
              sp   <= sp + 1;
            end

            SUBINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= Val_int(Int_val(accu) - Int_val(st_rd_a));
              sp   <= sp + 1;
            end

            MULINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= Val_int(Int_val(accu) * Int_val(st_rd_a));
              sp   <= sp + 1;
            end

            DIVINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              div_start(Int_val(accu), Int_val(st_rd_a), 1'b0);
              sp    <= sp + 1;
              state <= S_DIV_ITER;
            end

            MODINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              div_start(Int_val(accu), Int_val(st_rd_a), 1'b1);
              sp    <= sp + 1;
              state <= S_DIV_ITER;
            end

            ANDINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= Val_int(Int_val(accu) & Int_val(st_rd_a));
              sp   <= sp + 1;
            end

            ORINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= Val_int(Int_val(accu) | Int_val(st_rd_a));
              sp   <= sp + 1;
            end

            XORINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= Val_int(Int_val(accu) ^ Int_val(st_rd_a));
              sp   <= sp + 1;
            end

            LSLINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= Val_int(Int_val(accu) << Int_val(st_rd_a));
              sp   <= sp + 1;
            end

            LSRINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= Val_int(Int_val(accu) >>> Int_val(st_rd_a));
              sp   <= sp + 1;
            end

            ASRINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= Val_int($signed(Int_val(accu)) >>> Int_val(st_rd_a));
              sp   <= sp + 1;
            end


            EQ:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= (accu == st_rd_a) ? VAL_TRUE : VAL_FALSE;
              sp   <= sp + 1;
            end

            NEQ:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= (accu != st_rd_a) ? VAL_TRUE : VAL_FALSE;
              sp   <= sp + 1;
            end

            LTINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= (Int_val(accu) < Int_val(st_rd_a)) ? VAL_TRUE : VAL_FALSE;
              sp   <= sp + 1;
            end

            LEINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= (Int_val(accu) <= Int_val(st_rd_a)) ? VAL_TRUE : VAL_FALSE;
              sp   <= sp + 1;
            end

            GTINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= (Int_val(accu) > Int_val(st_rd_a)) ? VAL_TRUE : VAL_FALSE;
              sp   <= sp + 1;
            end

            GEINT:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              accu <= (Int_val(accu) >= Int_val(st_rd_a)) ? VAL_TRUE : VAL_FALSE;
              sp   <= sp + 1;
            end


            CONST0:   accu <= Val_int(0);
            CONST1:   accu <= Val_int(1);
            CONST2:   accu <= Val_int(2);
            CONST3:   accu <= Val_int(3);
            CONSTINT: accu <= Val_int($signed(imm));


            OFFSETINT: accu <= Val_int(Int_val(accu) + $signed(imm));


            PUSHCONST0: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              accu <= Val_int(0);
            end

            PUSHCONST1: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              accu <= Val_int(1);
            end

            PUSHCONST2: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              accu <= Val_int(2);
            end

            PUSHCONST3: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              accu <= Val_int(3);
            end

            PUSHCONSTINT: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              accu <= Val_int($signed(imm));
            end





            ASSIGN: begin
              stack_write(sp+imm, accu);
              accu  <= VAL_UNIT;
              state <= S_DONE;
            end





            BOOLNOT: accu <= (accu == VAL_FALSE) ? VAL_TRUE : VAL_FALSE;

            BRANCH: begin
              pc <= pc + $signed(offset) - 1;
            end

            BRANCHIF: begin
              if (accu != VAL_FALSE) begin
                pc <= pc + $signed(offset) - 1;
              end
            end

            BRANCHIFNOT: begin
              if (accu == VAL_FALSE) begin
                pc <= pc + $signed(offset) - 1;
              end
            end




            BEQ: begin
              if ($signed(imm) == Int_val(accu)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end

            BNEQ: begin
              if ($signed(imm) != Int_val(accu)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end

            BLTINT: begin
              if ($signed(imm) < Int_val(accu)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end

            BLEINT: begin
              if ($signed(imm) <= Int_val(accu)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end

            BGTINT: begin
              if ($signed(imm) > Int_val(accu)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end

            BGEINT: begin
              if ($signed(imm) >= Int_val(accu)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end

            BULTINT: begin
              if ($unsigned($signed(imm)) < $unsigned(Int_val(accu))) begin
                pc <= pc + $signed(offset) - 1;
              end
            end

            BUGEINT: begin
              if ($unsigned($signed(imm)) >= $unsigned(Int_val(accu))) begin
                pc <= pc + $signed(offset) - 1;
              end
            end


            // SWITCH sizes: a jump table follows, (sizes & 0xFFFF) entries for
            // the constant constructors, then one per block tag.  pc is the
            // table: step to the entry, then jump to table + entry.
            SWITCH:
            if (accu[0]) begin
              temp_index <= Int_val(accu);
              pc <= pc + Int_val(accu);
              state <= S_SWITCH_JUMP;
            end else begin
              temp_heap_addr <= Heap_index_of_ptr(accu);  // the tag is in the header
              state <= S_SWITCH_TAG;
            end


            // GRAB n: enough arguments, or partial application: a closure
            // {RESTART, closinfo, env, the 1 + extra_args arguments} returned
            // to the caller.  RESTART (just before GRAB) unpacks one again.
            GRAB:
            if (extra_args >= imm) begin
              extra_args <= extra_args - imm;
            end else begin
              alloc_wosize <= 3 + 1 + extra_args;
              alloc_tag <= TAG_CLOSURE;
              alloc_prefix <= 3;
              alloc_nfuncs <= 0;
              alloc_use_accu <= 1'b0;
              alloc_code <= pc - 3;  // the RESTART before this GRAB
              alloc_push_result <= 1'b0;
              alloc_then_return <= 1'b1;
              state <= S_ALLOC_HDR;
            end

            RESTART: begin
              temp_heap_addr <= Heap_index_of_ptr(env);
              state <= S_RESTART_HDR;
            end


            STOP: begin

              state <= S_DONE;
            end





            ENVACC1: begin
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 1;
              next_state_after_mem <= S_DONE;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end

            ENVACC2: begin
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 2;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end

            ENVACC3: begin
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 3;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end

            ENVACC4: begin
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 4;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end

            ENVACC: begin
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + imm;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end





            GETFIELD0: begin
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + 0;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_GETFIELD_DONE;
            end

            GETFIELD1: begin
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_GETFIELD_DONE;
            end

            GETFIELD2: begin
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + 2;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_GETFIELD_DONE;
            end

            GETFIELD3: begin
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + 3;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_GETFIELD_DONE;
            end

            GETFIELD: begin
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + imm;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_GETFIELD_DONE;
            end





            GETGLOBAL: begin
              temp_globals_addr <= imm[GLOBALS_AW-1:0];
              state <= S_GLOBALS_READ;
              next_state_after_mem <= S_DONE;
            end




            SETGLOBAL: begin
              globals_write(imm[GLOBALS_AW-1:0], accu);
              accu <= VAL_UNIT;
              state <= S_DONE;
            end



            // MAKEBLOCK n,tag (both operands fetched into alloc_wosize,
            // alloc_tag) and MAKEBLOCK1-3 tag: field 0 = accu, then sp[0]...
            MAKEBLOCK, MAKEBLOCK1, MAKEBLOCK2, MAKEBLOCK3: begin
              if (opcode != MAKEBLOCK) begin
                alloc_wosize <= (opcode == MAKEBLOCK1) ? 1 : (opcode == MAKEBLOCK2) ? 2 : 3;
                alloc_tag    <= imm;
              end
              alloc_prefix <= 0;
              alloc_nfuncs <= 0;
              alloc_use_accu <= 1'b1;
              alloc_push_result <= 1'b0;
              alloc_then_return <= 1'b0;
              state <= S_ALLOC_HDR;
            end





























































            // OFFSETREF n: Field(accu, 0) += n (as an OCaml int); accu = unit
            OFFSETREF:
            if (!rd_phase) begin
              heap_read_a(Heap_index_of_ptr(accu) + 1);
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1, hm_rd_a + (imm << 1));
              accu <= VAL_UNIT;
            end











            POP: begin
              sp <= sp + imm;
              state <= S_DONE;
            end





            PUSH: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              state <= S_DONE;
            end





            PUSHACC0: begin
              temp_stack_addr <= sp - 1;
              state <= S_PUSHACC_WRITE;
            end

            PUSHACC1: begin
              temp_stack_addr <= sp + 0;
              state <= S_PUSHACC_WRITE;
            end

            PUSHACC2: begin
              temp_stack_addr <= sp + 1;
              state <= S_PUSHACC_WRITE;
            end

            PUSHACC3: begin
              temp_stack_addr <= sp + 2;
              state <= S_PUSHACC_WRITE;
            end

            PUSHACC4: begin
              temp_stack_addr <= sp + 3;
              state <= S_PUSHACC_WRITE;
            end

            PUSHACC5: begin
              temp_stack_addr <= sp + 4;
              state <= S_PUSHACC_WRITE;
            end

            PUSHACC6: begin
              temp_stack_addr <= sp + 5;
              state <= S_PUSHACC_WRITE;
            end

            PUSHACC7: begin
              temp_stack_addr <= sp + 6;
              state <= S_PUSHACC_WRITE;
            end

            PUSHACC: begin
              temp_stack_addr <= sp + imm - 1;
              state <= S_PUSHACC_WRITE;
            end





            PUSHENVACC1: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end

            PUSHENVACC2: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 2;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end

            PUSHENVACC3: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 3;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end

            PUSHENVACC4: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 4;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end

            PUSHENVACC: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              temp_heap_addr <= Heap_index_of_ptr(env) + 1 + imm;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_ENVACC_DONE;
            end





            PUSHOFFSETCLOSURE: begin
              sp <= sp - 1;
              stack_write(sp-1, accu);
              accu <= env + (imm << 2);
            end





            RETURN:
            if (extra_args != 0) begin  // over-application: apply the result
              sp <= sp + imm;
              extra_args <= extra_args - 1;
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_APPLY1_SETPC;  // pc = Code_val(accu), env = accu
            end else begin
              op_cycle_count <= 0;
              state <= S_RETURN_READ_FRAME;
            end

































            SETFIELD0:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + 0, st_rd_a);
              sp <= sp + 1;  // Field(accu, n) = *sp++; accu = unit
              accu <= VAL_UNIT;
              state <= S_DONE;
            end

            SETFIELD1:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + 1, st_rd_a);
              sp <= sp + 1;  // Field(accu, n) = *sp++; accu = unit
              accu <= VAL_UNIT;
              state <= S_DONE;
            end

            SETFIELD2:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + 2, st_rd_a);
              sp <= sp + 1;  // Field(accu, n) = *sp++; accu = unit
              accu <= VAL_UNIT;
              state <= S_DONE;
            end

            SETFIELD3:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + 3, st_rd_a);
              sp <= sp + 1;  // Field(accu, n) = *sp++; accu = unit
              accu <= VAL_UNIT;
              state <= S_DONE;
            end

            SETFIELD:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + imm, st_rd_a);
              sp <= sp + 1;  // Field(accu, n) = *sp++; accu = unit
              accu <= VAL_UNIT;
              state <= S_DONE;
            end

            VECTLENGTH: begin
              temp_heap_addr <= Heap_index_of_ptr(accu);
              state <= S_HEAP_READ;
              next_state_after_mem <= S_VECTLENGTH_CALC;
            end

            // GETSTRINGCHAR / GETBYTESCHAR: accu = the byte at Int_val sp[0]; pops it
            GETSTRINGCHAR, GETBYTESCHAR:
            if (!rd_phase) begin
              stack_read_a(sp);  // index
              hold_for_read();
            end else begin
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + st_rd_a[HEAP_AW+2:3];
              str_byte <= st_rd_a[2:1];
              sp <= sp + 1;
              state <= S_STRGET_READ;
            end

            // SETBYTESCHAR: accu.[Int_val sp[0]] <- Int_val sp[1]; pops both; accu = unit
            SETBYTESCHAR:
            if (!rd_phase) begin
              stack_read_a(sp);  // index
              stack_read_b(sp + 1);  // the char
              hold_for_read();
            end else begin
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + st_rd_a[HEAP_AW+2:3];
              str_byte <= st_rd_a[2:1];
              byte_value <= st_rd_b[8:1];
              sp <= sp + 2;
              accu <= VAL_UNIT;
              state <= S_BYTESET_RMW;
            end

            // SETVECTITEM: accu.(Int_val sp[0]) <- sp[1]; pops both
            SETVECTITEM:
            if (!rd_phase) begin
              stack_read_a(sp);  // index
              stack_read_b(sp + 1);  // value
              hold_for_read();
            end else begin
              temp_index <= Int_val(st_rd_a);
              temp_value <= st_rd_b;
              temp_base_ptr <= accu;
              state <= S_SETVECTITEM_WRITE;
            end

            GETVECTITEM:
            if (!rd_phase) begin
              stack_read_a(sp);  // the index
              hold_for_read();
            end else begin
              temp_index <= Int_val(st_rd_a);  // Get index from stack
              temp_array_ptr <= accu;  // Save array pointer
              sp <= sp + 1;  // Pop index from stack
              // Read from array[index + 1] (skip header at index 0)
              temp_heap_addr <= Heap_index_of_ptr(accu) + Int_val(st_rd_a) + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_GETVECTITEM_DONE;
            end

            C_CALL1: begin
              unique case (imm)
                16'h0fd: caml_ml_flush();
                16'h103: caml_ml_open_descriptor_in();
                16'h104: caml_ml_open_descriptor_out();
                16'h136: begin  // caml_obj_dup: copy a block (array literals)
                  if (accu[0]) state <= S_DONE;  // an immediate is its own copy
                  else begin
                    temp_heap_addr <= Heap_index_of_ptr(accu);
                    state <= S_DUP_HDR;
                  end
                end
                16'h052: begin  // caml_create_bytes len: zero-filled, padded like a string
                  alloc_base <= hp;
                  alloc_wosize <= (Int_val(accu) >> 2) + 1;
                  temp_index <= Int_val(accu);
                  heap_write(hp, Make_header((Int_val(accu) >> 2) + 1, STRING_TAG));
                  alloc_i <= 0;
                  state <= S_CREATE_BYTES;
                end
                16'h164: ;  // caml_string_of_bytes: the same block (safe-string)
                16'h0f7, 16'h116: begin  // caml_ml_bytes_length, caml_ml_string_length
                  temp_heap_addr <= Heap_index_of_ptr(accu);
                  state <= S_STRLEN_HDR;
                end
                16'h193: begin  // vm_io_read addr
                  trap_valid <= 1'b1;
                  trap_prim  <= TRAP_IO_READ;
                  trap_arg0  <= Int_val(accu);
                  state      <= S_IO_WAIT;
                end
                default: $display("Unsupported C_CALL1: 0x%x", imm);
              endcase
            end

            C_CALL2:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos, printed by the primitives
              hold_for_read();
            end else begin
              unique case (imm)
                16'h108: caml_ml_output_char();
                16'h00d: begin  // caml_array_get_addr: Field(accu, Int_val(tos))
                  temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + st_rd_a[HEAP_AW:1];
                  state <= S_HEAP_READ;
                  next_state_after_mem <= S_GETFIELD_DONE;
                end
                16'h15b, 16'h03a: caml_string_get();  // caml_string_get, caml_bytes_get
                16'h15a, 16'h163: begin  // caml_string_equal, caml_string_notequal
                  temp_heap_addr <= Heap_index_of_ptr(accu);
                  str2_addr <= Heap_index_of_ptr(st_rd_a);
                  streq_negate <= imm == 16'h163;
                  state <= S_STREQ_HDR;
                end
                16'h194: begin  // vm_io_write addr data
                  trap_valid <= 1'b1;
                  trap_prim  <= TRAP_IO_WRITE;
                  trap_arg0  <= Int_val(accu);
                  trap_arg1  <= Int_val(st_rd_a);
                  state      <= S_IO_WAIT;
                end
                default: $display("Unsupported C_CALL2: 0x%x", imm);
              endcase
              sp += 1;
            end

            C_CALL3:
            if (imm == 16'h044) begin  // caml_bytes_set: SETBYTESCHAR's layout
              if (!rd_phase) begin
                stack_read_a(sp);  // index
                stack_read_b(sp + 1);  // the char
                hold_for_read();
              end else begin
                temp_heap_addr <= Heap_index_of_ptr(accu) + 1 + st_rd_a[HEAP_AW+2:3];
                str_byte <= st_rd_a[2:1];
                byte_value <= st_rd_b[8:1];
                sp <= sp + 2;
                accu <= VAL_UNIT;
                state <= S_BYTESET_RMW;
              end
            end else if (imm == 16'h00f) begin  // caml_array_set_addr: SETVECTITEM's layout
              if (!rd_phase) begin
                stack_read_a(sp);  // index
                stack_read_b(sp + 1);  // value
                hold_for_read();
              end else begin
                temp_index <= Int_val(st_rd_a);
                temp_value <= st_rd_b;
                temp_base_ptr <= accu;
                state <= S_SETVECTITEM_WRITE;  // pops both, accu = unit
              end
            end else begin
              $display("Unsupported C_CALL3: 0x%x", imm);
              accu <= VAL_UNIT;
              sp += 2;
            end

            C_CALL4: begin

              accu <= VAL_UNIT;
              sp += 3;
            end

            C_CALL5: begin

              accu <= VAL_UNIT;
              sp += 4;
            end

            C_CALLN: begin

              accu <= VAL_UNIT;
              sp += imm;
            end

            ATOM0: begin
            end

            // CLOSURE nvars,ofs and CLOSUREREC 1,nvars,ofs: a closure block
            // {code, closinfo, accu, sp[0], ...}; CLOSUREREC then pushes it.
            CLOSURE: begin
              alloc_wosize <= 2 + nvars;
              alloc_tag <= TAG_CLOSURE;
              alloc_prefix <= 2;
              alloc_code <= $signed(pc) + $signed(offset) - 1;
              alloc_nfuncs <= 0;
              alloc_use_accu <= nvars != 0;
              alloc_push_result <= 1'b0;
              alloc_then_return <= 1'b0;
              state <= S_ALLOC_HDR;
            end

            // CLOSUREREC f, v, offsets: f closures in one block (see
            // alloc_nfuncs); pc is at the offset table.
            CLOSUREREC: begin
              alloc_wosize <= 3 * imm - 1 + nvars;
              alloc_tag <= TAG_CLOSURE;
              alloc_prefix <= 3 * imm - 1;
              alloc_nfuncs <= imm;
              alloc_table <= pc;
              alloc_use_accu <= nvars != 0;
              alloc_push_result <= 1'b1;
              alloc_then_return <= 1'b0;
              state <= S_ALLOC_HDR;
            end

            // OFFSETCLOSURE n: accu = env + n words -- a sibling in a CLOSUREREC block
            OFFSETCLOSURE0:  accu <= env;
            OFFSETCLOSURE3:  accu <= env + 12;
            OFFSETCLOSUREM3: accu <= env - 12;
            OFFSETCLOSURE:   accu <= env + (imm << 2);

            PUSHOFFSETCLOSURE0: begin
              logic [31:0] old_sp;
              old_sp = sp;
              sp <= sp - 1;
              stack_write(old_sp-1, accu);
              accu <= env;
            end

            PUSHOFFSETCLOSURE3: begin
              logic [31:0] old_sp;
              old_sp = sp;
              sp <= sp - 1;
              stack_write(old_sp-1, accu);
              accu <= env + 12;
            end

            PUSHOFFSETCLOSUREM3: begin
              logic [31:0] old_sp;
              old_sp = sp;
              sp <= sp - 1;
              stack_write(old_sp-1, accu);
              accu <= env - 12;
            end

            PUSHGETGLOBAL:
            if (!rd_phase) begin
              globals_read_a(imm);
              hold_for_read();
            end else begin
              logic [31:0] old_sp;
              old_sp = sp;
              sp <= sp - 1;
              stack_write(old_sp - 1, accu);  // push accu, then load the global
              accu <= gm_rd_a;
            end

            // accu = Field(global[imm], imm2); the PUSH form pushes accu first
            GETGLOBALFIELD, PUSHGETGLOBALFIELD:
            if (!rd_phase) begin
              globals_read_a(imm);
              hold_for_read();
            end else begin
              if (opcode == PUSHGETGLOBALFIELD) begin
                stack_write(sp - 1, accu);
                sp <= sp - 1;
              end
              temp_heap_addr <= Heap_index_of_ptr(gm_rd_a) + 1 + imm2;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_GETFIELD_DONE;
            end


            CHECK_SIGNALS: begin
            end

            default: begin
              $display(
                  "almost complete, unhandled ops go to trap instead of silently wrong behavior.");
              trap_valid <= 1'b1;
              trap_prim  <= 8'hFF;
              trap_arg0  <= Val_int(opcode);
              state      <= S_TRAP_WAIT;
            end
          endcase
        end





        // ---- GC: roots, then Cheney scan of to-space ----
        S_GC_START: begin
          to_lo <= (from_lo == heap_lo) ? heap_lo + gc_semi : heap_lo;
          gc_free <= (from_lo == heap_lo) ? heap_lo + gc_semi : heap_lo;
          gc_scan <= (from_lo == heap_lo) ? heap_lo + gc_semi : heap_lo;
          gc_phase <= GC_ACCU;
          gc_i <= {1'b0, sp};
          gc_infix_off <= 0;
          state <= S_GC_ROOT;
        end

        S_GC_ROOT:
        case (gc_phase)
          GC_ACCU, GC_ENV: begin
            gc_val <= (gc_phase == GC_ACCU) ? accu : env;
            gc_return_to_scan <= 1'b0;
            if (gc_points_to_from((gc_phase == GC_ACCU) ? accu : env)) state <= S_GC_FWD;
            else gc_phase <= gc_phase + 1;
          end
          GC_STACK:  // the live stack: sp up to (not including) the top slot
          if (gc_i >= (1 << STACK_AW) - 1) begin
            gc_i <= 0;
            gc_phase <= GC_GLOBALS;
          end else if (!rd_phase) begin
            stack_read_a(gc_i[STACK_AW-1:0]);
            hold_for_read();
          end else begin
            gc_val <= st_rd_a;
            gc_return_to_scan <= 1'b0;
            if (gc_points_to_from(st_rd_a)) state <= S_GC_FWD;
            else gc_i <= gc_i + 1;
          end
          GC_GLOBALS:
          if (gc_i >= (1 << GLOBALS_AW)) gc_phase <= GC_SCAN;
          else if (!rd_phase) begin
            globals_read_a(gc_i[GLOBALS_AW-1:0]);
            hold_for_read();
          end else begin
            gc_val <= gm_rd_a;
            gc_return_to_scan <= 1'b0;
            if (gc_points_to_from(gm_rd_a)) state <= S_GC_FWD;
            else gc_i <= gc_i + 1;
          end
          default: state <= S_GC_SCAN;
        endcase

        S_GC_ROOT_WB: begin  // store the forwarded root
          gc_infix_off <= 0;
          case (gc_phase)
            GC_ACCU: accu <= gc_new;
            GC_ENV: env <= gc_new;
            GC_STACK: stack_write(gc_i[STACK_AW-1:0], gc_new);
            default: globals_write(gc_i[GLOBALS_AW-1:0], gc_new);
          endcase
          if (gc_phase == GC_ACCU || gc_phase == GC_ENV) gc_phase <= gc_phase + 1;
          else gc_i <= gc_i + 1;
          state <= S_GC_ROOT;
        end

        // Forward gc_val: its new address in gc_new, copying the block to
        // gc_free unless an earlier copy left a forwarding header.
        S_GC_FWD:
        if (!rd_phase) begin
          heap_read_a(gc_val[HEAP_AW+1:2]);      // header
          heap_read_b(gc_val[HEAP_AW+1:2] + 1);  // field 0: the forward pointer, if copied
          hold_for_read();
        end else if (hm_rd_a[7:0] == INFIX_TAG) begin
          // inside a CLOSUREREC block: forward the block, keep the offset
          gc_val <= gc_val - {hm_rd_a[31:16], 2'b00};
          gc_infix_off <= gc_infix_off + hm_rd_a[31:16];
        end else if (hm_rd_a[15:8] == GC_FORWARDED) begin
          gc_new <= hm_rd_b + {gc_infix_off, 2'b00};
          state <= gc_return_to_scan ? S_GC_SCAN_WB : S_GC_ROOT_WB;
        end else begin
          heap_write(gc_free, hm_rd_a);
          gc_obj <= gc_val[HEAP_AW+1:2];
          gc_hdr <= hm_rd_a;
          gc_size <= hm_rd_a[31:16];
          gc_new <= Ptr_of_heap_index(gc_free) + {gc_infix_off, 2'b00};
          gc_new_idx <= gc_free;
          gc_rd <= 0;
          gc_wr <= 0;
          gc_copy_valid <= 1'b0;
          state <= S_GC_COPY;
        end

        // One word per cycle: port B reads from-space field gc_rd while port
        // A writes the field read the cycle before.
        S_GC_COPY: begin
          if (gc_copy_valid) begin
            heap_write(gc_new_idx + 1 + gc_wr, hm_rd_b);
            gc_wr <= gc_wr + 1;
          end
          if (gc_rd < gc_size) begin
            heap_read_b(gc_obj + 1 + gc_rd);
            gc_rd <= gc_rd + 1;
            gc_copy_valid <= 1'b1;
          end else gc_copy_valid <= 1'b0;
          if (gc_wr + gc_copy_valid == gc_size && gc_rd == gc_size) begin
            gc_mark_second <= 1'b0;
            state <= S_GC_MARK;
          end
        end

        // Leave a forwarding header (and pointer in field 0) in from-space.
        S_GC_MARK:
        if (!gc_mark_second) begin
          heap_write(gc_obj, {gc_hdr[31:16], GC_FORWARDED, gc_hdr[7:0]});
          gc_mark_second <= 1'b1;
          if (gc_size == 0) begin  // nowhere for a forward pointer: an empty block is copied each time
            gc_free <= gc_free + 1;
            state <= gc_return_to_scan ? S_GC_SCAN_WB : S_GC_ROOT_WB;
          end
        end else begin
          heap_write(gc_obj + 1, Ptr_of_heap_index(gc_new_idx));  // the block's new address
          gc_free <= gc_free + 1 + gc_size;
          state <= gc_return_to_scan ? S_GC_SCAN_WB : S_GC_ROOT_WB;
        end

        // Cheney scan: every block copied to to-space has its fields forwarded.
        S_GC_SCAN:
        if (gc_scan == gc_free) state <= S_GC_DONE;
        else if (!rd_phase) begin
          heap_read_a(gc_scan);
          hold_for_read();
        end else if (hm_rd_a[7:0] >= NO_SCAN_TAG || hm_rd_a[31:16] == 0) begin
          gc_scan <= gc_scan + 1 + hm_rd_a[31:16];
        end else begin
          gc_scan_size <= hm_rd_a[31:16];
          gc_j <= 0;
          state <= S_GC_SCAN_FIELD;
        end

        S_GC_SCAN_FIELD:
        if (gc_j == gc_scan_size) begin
          gc_scan <= gc_scan + 1 + gc_scan_size;
          state <= S_GC_SCAN;
        end else if (!rd_phase) begin
          heap_read_a(gc_scan + 1 + gc_j);
          hold_for_read();
        end else if (gc_points_to_from(hm_rd_a)) begin
          gc_val <= hm_rd_a;
          gc_return_to_scan <= 1'b1;
          state <= S_GC_FWD;
        end else gc_j <= gc_j + 1;

        S_GC_SCAN_WB: begin
          gc_infix_off <= 0;
          heap_write(gc_scan + 1 + gc_j, gc_new);
          gc_j <= gc_j + 1;
          state <= S_GC_SCAN_FIELD;
        end

        S_GC_DONE: begin
`ifndef SYNTHESIS
          gc_check_to_space();
`endif
          from_lo <= to_lo;
          hp <= gc_free;
          hp_limit <= to_lo + gc_semi;
          gc_count <= gc_count + 1;
          if (gc_free + gc_need > to_lo + gc_semi) begin
            $display("GC: out of memory (%0d words live, %0d needed, semi-space %0d)",
                     gc_free - to_lo, gc_need, gc_semi);
            trap_valid <= 1'b1;
            trap_prim <= 8'hF1;
            state <= S_TRAP_WAIT;
          end else state <= S_EXEC;  // run the allocating instruction again
        end

        // caml_obj_dup: a new block with the source's header and fields,
        // copied one field per two cycles (read, then write, both on port A).
        S_DUP_HDR:
        if (!rd_phase) begin
          heap_read_a(temp_heap_addr);
          hold_for_read();
        end else if ({1'b0, hp} + hm_rd_a[31:16] + 1 > hp_limit) begin
          gc_need <= hm_rd_a[31:16] + 1;  // collect, then C_CALL1 runs again
          state <= S_GC_START;
        end else begin
          heap_write(hp, hm_rd_a);  // same size and tag
          alloc_base <= hp;
          alloc_wosize <= hm_rd_a[31:16];
          alloc_i <= 0;
          state <= S_DUP_FIELD;
        end

        S_DUP_FIELD:
        if (alloc_i == alloc_wosize) begin
          hp <= alloc_base + 1 + alloc_wosize;
          accu <= Ptr_of_heap_index(alloc_base);
          state <= S_DONE;
        end else if (!rd_phase) begin
          heap_read_a(temp_heap_addr + 1 + alloc_i);
          hold_for_read();
        end else begin
          heap_write(alloc_base + 1 + alloc_i, hm_rd_a);
          alloc_i <= alloc_i + 1;
        end

        // RESTART: env is a GRAB closure {code, closinfo, env', args...}:
        // push the args, env = env', extra_args += their count.
        S_RESTART_HDR:
        if (!rd_phase) begin
          heap_read_a(temp_heap_addr);
          hold_for_read();
        end else begin
          restart_n <= hm_rd_a[31:16] - 3;
          sp <= sp - (hm_rd_a[31:16] - 3);
          alloc_i <= 0;
          state <= S_RESTART_ARG;
        end

        S_RESTART_ARG:
        if (alloc_i == restart_n) state <= S_RESTART_ENV;
        else if (!rd_phase) begin
          heap_read_a(Heap_index_of_ptr(env) + 1 + 3 + alloc_i);
          hold_for_read();
        end else begin
          stack_write(sp + alloc_i, hm_rd_a);
          alloc_i <= alloc_i + 1;
        end

        S_RESTART_ENV:
        if (!rd_phase) begin
          heap_read_a(Heap_index_of_ptr(env) + 1 + 2);
          hold_for_read();
        end else begin
          env <= hm_rd_a;
          extra_args <= extra_args + restart_n;
          state <= S_DONE;
        end

        S_SWITCH_TAG:
        if (!rd_phase) begin
          heap_read_a(temp_heap_addr);
          hold_for_read();
        end else begin
          temp_index <= imm[15:0] + hm_rd_a[7:0];
          pc <= pc + imm[15:0] + hm_rd_a[7:0];
          state <= S_SWITCH_JUMP;
        end

        S_SWITCH_JUMP: begin  // code_rdata is the table entry at pc
          pc <= pc - temp_index + $signed(code_rdata);
          state <= S_DONE;
        end

        S_VECTLENGTH_CALC: begin  // temp_heap_val holds the block's header
          accu  <= Val_long(Wosize_hd(temp_heap_val));
          state <= S_DONE;
        end

        S_ALLOC_HDR: begin
          heap_write(hp, Make_header(alloc_wosize, alloc_tag));
          alloc_base <= hp;
          alloc_i <= 0;
          alloc_fn_i <= 0;
          alloc_phase <= 1;  // field 0 is function 0's code
          alloc_push_i <= 0;
          state <= S_ALLOC_FIELD;
        end

        S_ALLOC_FIELD: begin
          logic [15:0] item;         // index into [accu,] sp[0], sp[1], ...
          logic [15:0] stack_item;   // index into sp[0], sp[1], ...
          logic field_is_accu, field_from_stack;
          logic [VALUEW-1:0] prefix_field;
          logic rec_code_field;      // a CLOSUREREC code pointer: read from the table first
          item = alloc_i - alloc_prefix;
          field_is_accu = alloc_i >= alloc_prefix && alloc_use_accu && item == 0;
          field_from_stack = alloc_i >= alloc_prefix && !field_is_accu;
          stack_item = alloc_use_accu ? item - 1 : item;
          if (alloc_nfuncs != 0)
            case (alloc_phase)
              2'd0: prefix_field = Make_header(3 * alloc_fn_i, INFIX_TAG);
              2'd1: prefix_field = Make_codeptr($signed(alloc_table) + $signed(code_rdata));
              default: prefix_field = ((3 * (alloc_nfuncs - alloc_fn_i) - 1) << 1) | 1;  // closinfo
            endcase
          else
            prefix_field = (alloc_i == 0) ? Make_codeptr(alloc_code) : (alloc_i == 1) ? CLOSINFO : env;
          rec_code_field = alloc_nfuncs != 0 && alloc_i < alloc_prefix && alloc_phase == 1;
          if (alloc_i == alloc_wosize) state <= S_ALLOC_DONE;
          else if (field_from_stack && !rd_phase) begin
            stack_read_a(sp + stack_item);
            hold_for_read();
          end else if (rec_code_field && !rd_phase) begin
            pc <= alloc_table + alloc_fn_i;  // code_rdata is the offset next cycle
            hold_for_read();
          end else begin
            heap_write(alloc_base + 1 + alloc_i,
                       (alloc_i < alloc_prefix) ? prefix_field : field_is_accu ? accu : st_rd_a);
            alloc_i <= alloc_i + 1;
            alloc_phase <= (alloc_phase == 2) ? 2'd0 : alloc_phase + 1;
            if (alloc_phase == 2) alloc_fn_i <= alloc_fn_i + 1;
          end
        end

        S_ALLOC_DONE: begin
          logic [STACK_AW-1:0] sp_after;  // the stacked fields popped
          sp_after = sp + (alloc_wosize - alloc_prefix - alloc_use_accu);
          hp <= alloc_base + 1 + alloc_wosize;
          accu <= Ptr_of_heap_index(alloc_base);
          sp <= sp_after;
          if (alloc_nfuncs != 0) pc <= alloc_table + alloc_nfuncs;  // past the offset table
          if (alloc_push_result) state <= S_ALLOC_PUSH;
          else if (alloc_then_return) begin  // GRAB: return the closure through the frame
            imm <= 0;
            op_cycle_count <= 0;
            state <= S_RETURN_READ_FRAME;
          end else state <= S_DONE;
        end

        // CLOSUREREC pushes the block, then each further function's infix
        // pointer (block + 3i words), one stack write a cycle.
        S_ALLOC_PUSH:
        if (alloc_push_i == alloc_nfuncs) state <= S_DONE;
        else begin
          stack_write(sp - 1, Ptr_of_heap_index(alloc_base + 3 * alloc_push_i));
          sp <= sp - 1;
          alloc_push_i <= alloc_push_i + 1;
        end

        S_DIV_ITER: begin
          logic [32:0] trial;  // {remainder, next dividend bit} - divisor
          logic divisor_fits, divide_by_zero;
          logic [31:0] quotient, remainder;
          trial = {div_rem, div_quo[31]} - {1'b0, div_dsr};
          divisor_fits = !trial[32];
          if (div_bits_left != 0) begin
            div_rem       <= divisor_fits ? trial[31:0] : {div_rem[30:0], div_quo[31]};
            div_quo       <= {div_quo[30:0], divisor_fits};
            div_bits_left <= div_bits_left - 1;
          end else begin
            // x / 0 and x mod 0 give 0, as the combinational operators did in simulation
            divide_by_zero = (div_dsr == 0);
            quotient = div_quo_negative ? -div_quo : div_quo;
            remainder = div_rem_negative ? -div_rem : div_rem;
            accu  <= Val_int(divide_by_zero ? 32'd0 : div_want_mod ? remainder : quotient);
            state <= S_DONE;
          end
        end

        S_STRLEN_HDR:
        if (!rd_phase) begin
          heap_read_a(temp_heap_addr);
          hold_for_read();
        end else begin
          str_words <= hm_rd_a[31:16];
          temp_heap_addr <= temp_heap_addr + hm_rd_a[31:16];  // the last word
          state <= S_STRLEN_LAST;
        end

        S_STRLEN_LAST:
        if (!rd_phase) begin
          heap_read_a(temp_heap_addr);
          hold_for_read();
        end else begin
          // length = 4 * wosize - 1 - padding, the padding in the last byte
          accu  <= Val_int({str_words, 2'b00} - 1 - hm_rd_a[31:24]);
          state <= S_DONE;
        end

        // A byte store: read the word, write it back with one byte replaced.
        S_BYTESET_RMW:
        if (!rd_phase) begin
          heap_read_a(temp_heap_addr);
          hold_for_read();
        end else begin
          logic [VALUEW-1:0] word;
          word = hm_rd_a;
          word[8*str_byte+:8] = byte_value;
          heap_write(temp_heap_addr, word);
          state <= S_DONE;
        end

        // caml_create_bytes: the header is written; now the zero fields, the
        // last carrying the padding count in its top byte, as OCaml's strings.
        S_CREATE_BYTES:
        if (alloc_i == alloc_wosize) begin
          hp <= alloc_base + 1 + alloc_wosize;
          accu <= Ptr_of_heap_index(alloc_base);
          state <= S_DONE;
        end else begin
          heap_write(alloc_base + 1 + alloc_i,
                     (alloc_i == alloc_wosize - 1) ? {8'(4 * alloc_wosize - 1 - temp_index), 24'd0} : '0);
          alloc_i <= alloc_i + 1;
        end

        // caml_string_equal: both headers, then word by word (equal lengths
        // pad alike, so whole words compare), reading both on ports A and B.
        S_STREQ_HDR:
        if (!rd_phase) begin
          heap_read_a(temp_heap_addr);
          heap_read_b(str2_addr);
          hold_for_read();
        end else if (hm_rd_a[31:16] != hm_rd_b[31:16]) begin
          accu <= streq_negate ? VAL_TRUE : VAL_FALSE;
          state <= S_DONE;
        end else begin
          alloc_wosize <= hm_rd_a[31:16];
          alloc_i <= 0;
          state <= S_STREQ_WORD;
        end

        S_STREQ_WORD:
        if (alloc_i == alloc_wosize) begin
          accu <= streq_negate ? VAL_FALSE : VAL_TRUE;
          state <= S_DONE;
        end else if (!rd_phase) begin
          heap_read_a(temp_heap_addr + 1 + alloc_i);
          heap_read_b(str2_addr + 1 + alloc_i);
          hold_for_read();
        end else if (hm_rd_a != hm_rd_b) begin
          accu <= streq_negate ? VAL_TRUE : VAL_FALSE;
          state <= S_DONE;
        end else alloc_i <= alloc_i + 1;

        S_STRGET_READ:
        if (!rd_phase) begin
          heap_read_a(temp_heap_addr);
          hold_for_read();
        end else begin
          accu  <= Val_int(hm_rd_a[8*str_byte+:8]);
          state <= S_DONE;
        end

        S_IO_WAIT:
        if (trap_ready) begin
          trap_valid <= 1'b0;
          accu <= (trap_prim == TRAP_IO_READ) ? Val_int(trap_result) : VAL_UNIT;
          state <= S_DONE;
        end

        S_TRAP_WAIT: begin
`ifndef SYNTHESIS
          $finish;  // an unimplemented opcode: stop the simulation
`endif

          if (trap_ready) begin
            accu  <= trap_result;
            state <= S_DONE;
          end
        end















        S_STACK_READ:
        if (!rd_phase) begin
          stack_read_a(temp_stack_addr);
          hold_for_read();
        end else begin
          accu  <= st_rd_a;
          state <= next_state_after_mem;
        end

        S_HEAP_READ:
        if (!rd_phase) begin
          heap_read_a(temp_heap_addr);
          hold_for_read();
        end else begin
          temp_heap_val <= hm_rd_a;
          state <= next_state_after_mem;
        end

        S_GLOBALS_READ:
        if (!rd_phase) begin
          globals_read_a(temp_globals_addr);
          hold_for_read();
        end else begin
          accu  <= gm_rd_a;
          state <= next_state_after_mem;
        end





        S_PUSHACC_WRITE: begin

          stack_write(sp-1, accu);
          sp <= sp - 1;
          state <= S_PUSHACC_READ;
        end

        S_PUSHACC_READ:
        if (!rd_phase) begin
          stack_read_a(temp_stack_addr);
          hold_for_read();
        end else begin
          accu  <= st_rd_a;
          state <= S_DONE;
        end





        S_ENVACC_DONE: begin
          accu  <= temp_heap_val;
          state <= S_DONE;
        end

        S_GETFIELD_DONE: begin
          accu  <= temp_heap_val;
          state <= S_DONE;
        end







        S_APPTERM1_WRITE: begin
          stack_write(sp, temp_arg1);
          temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
          state <= S_HEAP_READ;
          next_state_after_mem <= S_APPTERM1_SETPC;
        end

        S_APPTERM1_SETPC: begin
          pc <= Codeptr_val(temp_heap_val);
          env <= accu;
          state <= S_DONE;
        end





        S_APPTERM2_READ_ARGS:
        if (!rd_phase) begin
          stack_read_a(sp + op_cycle_count);  // sp, sp+1
          hold_for_read();
        end else begin
          case (op_cycle_count)
            0: begin
              temp_arg1 <= st_rd_a;
              op_cycle_count <= 1;
            end
            1: begin
              temp_arg2 <= st_rd_a;
              sp <= sp + imm - 2;
              op_cycle_count <= 0;
              state <= S_APPTERM2_WRITE_ARGS;
            end
          endcase
        end

        S_APPTERM2_WRITE_ARGS: begin
          case (op_cycle_count)
            0: begin
              stack_write(sp, temp_arg1);
              op_cycle_count <= 1;
            end
            1: begin
              stack_write(sp+1, temp_arg2);
              extra_args <= extra_args + 1;
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_APPTERM2_SETPC;
            end
          endcase
        end

        S_APPTERM2_SETPC: begin
          pc <= Codeptr_val(temp_heap_val);
          env <= accu;
          state <= S_DONE;
        end





        S_APPTERM3_READ_ARGS:
        if (!rd_phase) begin
          stack_read_a(sp + op_cycle_count);  // sp, sp+1, sp+2
          hold_for_read();
        end else begin
          case (op_cycle_count)
            0: begin
              temp_arg1 <= st_rd_a;
              op_cycle_count <= 1;
            end
            1: begin
              temp_arg2 <= st_rd_a;
              op_cycle_count <= 2;
            end
            2: begin
              temp_arg3 <= st_rd_a;
              sp <= sp + imm - 3;
              op_cycle_count <= 0;
              state <= S_APPTERM3_WRITE_ARGS;
            end
          endcase
        end

        S_APPTERM3_WRITE_ARGS: begin
          case (op_cycle_count)
            0: begin
              stack_write(sp, temp_arg1);  // sp is already sp + imm - 3
              op_cycle_count <= 1;
            end
            1: begin
              stack_write(sp + 1, temp_arg2);
              op_cycle_count <= 2;
            end
            2: begin
              stack_write(sp + 2, temp_arg3);
              extra_args <= extra_args + 2;
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_APPTERM3_SETPC;
            end
          endcase
        end

        S_APPTERM_COPY:
        if (!rd_phase) begin
          stack_read_a(sp + op_cycle_count);
          hold_for_read();
        end else begin
          stack_write(sp + imm2 - imm + op_cycle_count, st_rd_a);
          if (op_cycle_count == 0) begin
            sp <= sp + imm2 - imm;
            extra_args <= extra_args + imm - 1;
            temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
            state <= S_HEAP_READ;
            next_state_after_mem <= S_APPTERM3_SETPC;  // pc = Code_val(accu), env = accu
          end else op_cycle_count <= op_cycle_count - 1;
        end

        S_APPTERM3_SETPC: begin
          pc <= Codeptr_val(temp_heap_val);
          env <= accu;
          state <= S_DONE;
        end





        S_APPLY1_WRITE_FRAME: begin
          case (op_cycle_count)
            0: begin
              stack_write(sp-2, Make_codeptr(pc));
              op_cycle_count  <= 1;
            end
            1: begin
              stack_write(sp-1, env);
              op_cycle_count  <= 2;
            end
            2: begin
              stack_write(sp-0, Val_int(extra_args));
              sp <= sp - 3;
              extra_args <= 0;
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_APPLY1_SETPC;
            end
          endcase
        end

        S_APPLY1_SETPC: begin
          pc <= Codeptr_val(temp_heap_val);
          env <= accu;
          state <= S_DONE;
        end





        S_APPLY2_WRITE_FRAME: begin  // arg 1 already at old sp-3
          case (op_cycle_count)
            0: begin
              stack_write(sp - 2, temp_arg2);
              op_cycle_count <= 1;
            end
            1: begin
              stack_write(sp - 1, Make_codeptr(pc));
              op_cycle_count <= 2;
            end
            2: begin
              stack_write(sp, env);
              op_cycle_count <= 3;
            end
            3: begin
              stack_write(sp + 1, Val_int(extra_args));
              sp <= sp - 3;
              extra_args <= 1;
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_APPLY2_SETPC;
            end
          endcase
        end

        S_APPLY2_SETPC: begin
          pc <= Codeptr_val(temp_heap_val);
          env <= accu;
          state <= S_DONE;
        end





        S_APPLY3_WRITE_FRAME: begin  // arg 1 already at old sp-3
          case (op_cycle_count)
            0:
            if (!rd_phase) begin
              stack_read_a(sp + 2);  // arg 3
              hold_for_read();
            end else begin
              stack_write(sp - 2, temp_arg2);
              temp_arg3 <= st_rd_a;
              op_cycle_count <= 1;
            end
            1: begin
              stack_write(sp - 1, temp_arg3);
              op_cycle_count <= 2;
            end
            2: begin
              stack_write(sp, Make_codeptr(pc));
              op_cycle_count <= 3;
            end
            3: begin
              stack_write(sp + 1, env);
              op_cycle_count <= 4;
            end
            4: begin
              stack_write(sp + 2, Val_int(extra_args));
              sp <= sp - 3;
              extra_args <= 2;
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_APPLY3_SETPC;
            end
          endcase
        end

        S_APPLY3_SETPC: begin
          pc <= Codeptr_val(temp_heap_val);
          env <= accu;
          state <= S_DONE;
        end





        S_RETURN_READ_FRAME:
        if (!rd_phase) begin
          stack_read_a(sp + imm + op_cycle_count);  // pc, env, extra_args
          hold_for_read();
        end else begin
          case (op_cycle_count)
            0: begin
              temp_return_pc <= st_rd_a;
              op_cycle_count <= 1;
            end
            1: begin
              temp_return_env <= st_rd_a;
              op_cycle_count  <= 2;
            end
            2: begin
              temp_extra_args <= Int_val(st_rd_a);
              sp <= sp + imm + 3;
              state <= S_RETURN_RESTORE;
            end
          endcase
        end

        S_RETURN_RESTORE: begin
          pc <= Codeptr_val(temp_return_pc);
          env <= temp_return_env;
          extra_args <= temp_extra_args;
          state <= S_DONE;
        end






        S_PUSH_RETADDR_WRITE_FRAME: begin
          case (op_cycle_count)
            0: begin
              stack_write(sp-3, Make_codeptr($signed(pc - 1) + $signed(imm)));
              op_cycle_count  <= 1;
            end
            1: begin
              stack_write(sp-2, env);
              op_cycle_count  <= 2;
            end
            2: begin
              stack_write(sp-1, Val_int(extra_args));
              sp <= sp - 3;
              state <= S_DONE;
            end
          endcase
        end


        S_GETVECTITEM_DONE: begin
          accu  <= temp_heap_val;  // Array element now in accu
          state <= S_DONE;
        end

        S_SETVECTITEM_WRITE: begin
          // Write to array[index + 1] (skip header)
          heap_write(Heap_index_of_ptr(temp_base_ptr)+temp_index+1, temp_value);
          sp <= sp + 2;  // Pop index and value
          accu <= VAL_UNIT;
          state <= S_DONE;
        end


        S_DONE: begin
          $display("  instruction done, acc=0x%08x, pc=%d", accu, pc);
          `ifndef SYNTHESIS  // debug peeks; not part of the two-port datapath
          $display("  stack[sp+0]=0x%08x", stack_mem[sp+0]);
          $display("  stack[sp+1]=0x%08x", stack_mem[sp+1]);
          $display("  stack[sp+2]=0x%08x", stack_mem[sp+2]);
          $display("  stack[sp+3]=0x%08x", stack_mem[sp+3]);
          $display("  stack[sp+4]=0x%08x", stack_mem[sp+4]);
          $display("  heap[hp-1]=0x%08x", heap_mem[hp-1]);
          $display("  heap[hp-2]=0x%08x", heap_mem[hp-2]);
          $display("  heap[hp-3]=0x%08x", heap_mem[hp-3]);
          $display("  heap[hp-4]=0x%08x", heap_mem[hp-4]);
          `endif
`ifndef SYNTHESIS
          if (accu == 32'h00000043) begin
            $display("[TRACK] accu=0x43 set by %s at PC=%d", opcode.name(), pc);
          end
`endif
          state <= S_FETCH;
        end

        default: begin
          $display("Invalid state %d", state);
`ifndef SYNTHESIS
          $finish;
`endif
        end
      endcase
    end

    // ---- The memory ports: the only accesses to the three memories. ----
    if (st_we_a) stack_mem[st_addr_a] <= st_wd_a;
    if (st_re_a) st_rd_a <= stack_mem[st_addr_a];
    if (st_re_b) st_rd_b <= stack_mem[st_addr_b];
    if (hm_we_a) heap_mem[hm_addr_a] <= hm_wd_a;
    if (hm_re_a) hm_rd_a <= heap_mem[hm_addr_a];
    if (hm_re_b) hm_rd_b <= heap_mem[hm_addr_b];
    if (gm_we_a) globals_mem[gm_addr_a] <= gm_wd_a;
    if (gm_re_a) gm_rd_a <= globals_mem[gm_addr_a];
    if (gm_re_b) gm_rd_b <= globals_mem[gm_addr_b];

    // tos follows stack port A's reads of stack[sp], a cycle later.
    st_a_was_tos <= st_re_a && (st_addr_a == sp);
    if (st_a_was_tos) tos_q <= st_rd_a;
  end

endmodule

