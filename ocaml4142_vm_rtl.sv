module ocaml4142_vm_rtl #(
    parameter int PCW        = 24,
    parameter int VALUEW     = 32,
    parameter int STACK_AW   = 16,
    parameter int HEAP_AW    = 18,
    parameter int GLOBALS_AW = 12,
    // Initial heap (the program's structured constants) and global table, as
    // laid out by bc2image; the heap allocates from HEAP_INIT_WORDS upwards.
    // In simulation +heap=, +globals= and +heap_words= override them.
    parameter string HEAP_INIT = "",
    parameter string GLOBALS_INIT = "",
    parameter int HEAP_INIT_WORDS = 0
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
    output logic [         7:0] putc_char
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
      OFFSETREF, OFFSETCLOSURE, PUSHOFFSETCLOSURE
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
    Wosize_hd = hdr[VALUEW-1:10];  // Extract size from header bits [31:10]
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

  function automatic logic [VALUEW-1:0] Make_codeptr(input logic [PCW-1:0] pc);
    Make_codeptr = {pc, 2'b00};
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
  

  int                alloc_fields_left;
  logic [VALUEW-1:0] alloc_result_ptr;
  logic              closurerec_push;



  logic [VALUEW-1:0] pending_field;




  logic [       7:0] imm_b;
  logic [      31:0] imm2;  // second operand of APPTERM, (PUSH)GETGLOBALFIELD, C_CALLN, GETPUBMET

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
  logic [7:0] field_write_idx;
  logic [7:0] total_fields_to_write;


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
  logic                  st_re_a, st_we_a, st_re_b, st_we_b;
  logic [  STACK_AW-1:0] st_addr_a, st_addr_b;
  logic [    VALUEW-1:0] st_wd_a, st_wd_b, st_rd_a, st_rd_b;
  logic                  hm_re_a, hm_we_a, hm_re_b, hm_we_b;
  logic [   HEAP_AW-1:0] hm_addr_a, hm_addr_b;
  logic [    VALUEW-1:0] hm_wd_a, hm_wd_b, hm_rd_a, hm_rd_b;
  logic                  gm_re_a, gm_we_a, gm_re_b, gm_we_b;
  logic [GLOBALS_AW-1:0] gm_addr_a, gm_addr_b;
  logic [    VALUEW-1:0] gm_wd_a, gm_wd_b, gm_rd_a, gm_rd_b;
  logic                  rd_phase;

  // tos: a register loaded from stack port A whenever it reads stack[sp],
  // a cycle after the read, instead of a third, always-on read port.
  logic [    VALUEW-1:0] tos_q;
  logic                  st_a_was_tos;
  assign tos = tos_q;

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
  task automatic globals_read_a(input logic [GLOBALS_AW-1:0] a);
    gm_re_a = 1'b1;
    gm_addr_a = a;
  endtask

  // Writes take whichever port is still free this cycle.
  task automatic stack_write(input logic [STACK_AW-1:0] a, input logic [VALUEW-1:0] d);
    if (!st_re_a && !st_we_a) begin
      st_we_a = 1'b1;
      st_addr_a = a;
      st_wd_a = d;
    end else if (!st_re_b && !st_we_b) begin
      st_we_b = 1'b1;
      st_addr_b = a;
      st_wd_b = d;
    end else begin
`ifndef SYNTHESIS
      $error("stack_mem: third access in one cycle (state %s)", state.name());
`endif
    end
  endtask
  task automatic heap_write(input logic [HEAP_AW-1:0] a, input logic [VALUEW-1:0] d);
    if (!hm_re_a && !hm_we_a) begin
      hm_we_a = 1'b1;
      hm_addr_a = a;
      hm_wd_a = d;
    end else if (!hm_re_b && !hm_we_b) begin
      hm_we_b = 1'b1;
      hm_addr_b = a;
      hm_wd_b = d;
    end else begin
`ifndef SYNTHESIS
      $error("heap_mem: third access in one cycle (state %s)", state.name());
`endif
    end
  endtask
  task automatic globals_write(input logic [GLOBALS_AW-1:0] a, input logic [VALUEW-1:0] d);
    if (!gm_re_a && !gm_we_a) begin
      gm_we_a = 1'b1;
      gm_addr_a = a;
      gm_wd_a = d;
    end else if (!gm_re_b && !gm_we_b) begin
      gm_we_b = 1'b1;
      gm_addr_b = a;
      gm_wd_b = d;
    end else begin
`ifndef SYNTHESIS
      $error("globals_mem: third access in one cycle (state %s)", state.name());
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

  always_ff @(posedge clk) begin
    // No memory requests unless a state makes them this cycle.
    st_re_a = 1'b0;
    st_we_a = 1'b0;
    st_re_b = 1'b0;
    st_we_b = 1'b0;
    st_addr_a = '0;
    st_addr_b = '0;
    st_wd_a = '0;
    st_wd_b = '0;
    hm_re_a = 1'b0;
    hm_we_a = 1'b0;
    hm_re_b = 1'b0;
    hm_we_b = 1'b0;
    hm_addr_a = '0;
    hm_addr_b = '0;
    hm_wd_a = '0;
    hm_wd_b = '0;
    gm_re_a = 1'b0;
    gm_we_a = 1'b0;
    gm_re_b = 1'b0;
    gm_we_b = 1'b0;
    gm_addr_a = '0;
    gm_addr_b = '0;
    gm_wd_a = '0;
    gm_wd_b = '0;
    putc_valid <= 1'b0;

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
      closurerec_push       <= 1'b0;
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
      field_write_idx       <= '0;
      total_fields_to_write <= '0;
      temp_stack_addr       <= '0;
      temp_heap_addr        <= '0;
      temp_globals_addr     <= '0;


      sp                    <= (1 << STACK_AW) - 1;
      trapsp                <= (1 << STACK_AW) - 1;


      hp                    <= hp_after_image;
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
              stack_write(sp - 2, st_rd_b);
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


            SWITCH: begin

              $display("SWITCH needs RTL conversion");
              state <= S_DONE;
            end


            GRAB: begin
              if (extra_args >= imm) begin
                extra_args <= extra_args - imm;
              end else begin


                $display("GRAB partial application TBD");
              end
            end


            RESTART: begin


              $display("RESTART TBD");
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



            MAKEBLOCK: begin
              $display("MAKEBLOCK %d,%d", alloc_wosize, alloc_tag);
              state <= S_HEAP_ALLOC_HDR;
            end



            MAKEBLOCK1: begin
              alloc_base <= hp;
              alloc_wosize <= 1;
              alloc_tag <= imm;
              heap_write(hp, Make_header(1, imm));
              hp <= hp + 1;
              state <= S_MAKEBLOCK1_FIELD;
            end













            MAKEBLOCK2: begin
              alloc_base <= hp;
              alloc_wosize <= 2;
              alloc_tag <= imm;
              temp_stack_addr <= sp;
              state <= S_STACK_READ;
              next_state_after_mem <= S_MAKEBLOCK2_HDR;
            end































            MAKEBLOCK3: begin
              alloc_base <= hp;
              alloc_wosize <= 3;
              alloc_tag <= imm;
              temp_stack_addr <= sp;
              op_cycle_count <= 0;
              state <= S_MAKEBLOCK3_READ_STACK;
            end


















































            OFFSETCLOSURE: begin
              temp_heap_addr <= Heap_index_of_ptr(env) + offset;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_OFFSETCLOSURE_CALC;
            end











            OFFSETREF: begin
              temp_stack_addr <= sp + imm;
              state <= S_STACK_READ;
              next_state_after_mem <= S_OFFSETREF_ADD;
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
              temp_heap_addr <= Heap_index_of_ptr(env) + offset;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_OFFSETCLOSURE_CALC;
            end





            RETURN: begin
              temp_stack_addr <= sp + imm - 3;
              op_cycle_count <= 0;
              state <= S_RETURN_READ_FRAME;
            end

































            SETFIELD0:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + 0, st_rd_a);
              state <= S_DONE;
            end

            SETFIELD1:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + 1, st_rd_a);
              state <= S_DONE;
            end

            SETFIELD2:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + 2, st_rd_a);
              state <= S_DONE;
            end

            SETFIELD3:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + 3, st_rd_a);
              state <= S_DONE;
            end

            SETFIELD:
            if (!rd_phase) begin
              stack_read_a(sp);  // tos
              hold_for_read();
            end else begin
              heap_write(Heap_index_of_ptr(accu) + 1 + imm, st_rd_a);
              state <= S_DONE;
            end

            VECTLENGTH: begin
              temp_heap_addr <= Heap_index_of_ptr(accu);
              state <= S_HEAP_READ;
              next_state_after_mem <= S_VECTLENGTH_CALC;
            end

            S_VECTLENGTH_CALC: begin
              // temp_heap_val now contains the header
              // Header format: [31:10] = wosize, [9:2] = color, [1:0] = tag low bits
              accu  <= Val_long(Wosize_hd(temp_heap_val));
              state <= S_DONE;
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
                16'h116: begin  // caml_ml_string_length: header, then last word
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
                16'h15b: caml_string_get();
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

            C_CALL3: begin

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

            CLOSURE: begin
              closure_nvars   <= nvars;
              closure_codeptr <= $signed(pc) + $signed(offset) - 1;

              alloc_wosize <= 2 + nvars;
              alloc_tag    <= TAG_CLOSURE;

              alloc_result_ptr <= Ptr_of_heap_index(hp);

              closure_i <= 0;


              if (nvars > 0) begin
                sp <= sp - 1;
                stack_write(sp-1, accu);
              end

              state <= S_CLOSURE_ALLOC_HDR;
            end





            CLOSUREREC: begin
              $display("CLOSUREREC (nfuncs = %d, nvars = %d)", imm, nvars);
              if (imm == 1) begin



                offset <= code_rdata;
                pc <= pc + 1;


                closure_nvars <= nvars;


                if (nvars > 0) begin
                  sp <= sp - 1;
                  stack_write(sp-1, accu);
                end


                closurerec_push <= 1'b1;


                alloc_wosize <= 2 + nvars;
                alloc_tag    <= TAG_CLOSURE;
                alloc_fields_left <= 2 + nvars;
                alloc_result_ptr <= Ptr_of_heap_index(hp);


                state <= S_CLOSUREREC_CALC;
              end else begin
                $display("Multi-function CLOSUREREC (nfuncs > 1) not yet implemented");
                trap_valid <= 1'b1;
                trap_prim <= 8'hF0;
                state <= S_TRAP_WAIT;
              end
            end



            OFFSETCLOSURE0:  accu <= env;
            OFFSETCLOSURE3:  read_acc_from_heap(env, 1 + 3);
            OFFSETCLOSUREM3: read_acc_from_heap(env, 1 - 3);


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
              accu <= env;
            end

            PUSHOFFSETCLOSUREM3: begin
              logic [31:0] old_sp;
              old_sp = sp;
              sp <= sp - 1;
              stack_write(old_sp-1, accu);
              accu <= env;
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





        S_HEAP_ALLOC_HDR: begin
          accu <= Ptr_of_heap_index(hp);
          heap_write(hp, Make_header(alloc_wosize, alloc_tag));
          hp <= hp + 1;


          alloc_fields_left <= alloc_wosize;
          state <= S_HEAP_ALLOC_FIELDS;
        end

        S_HEAP_ALLOC_FIELDS: begin
          logic is_first_field, is_env_field, is_later_field;
          logic is_closurerec_var_field, field_from_stack;
          is_first_field = (alloc_fields_left == alloc_wosize);
          is_env_field = !is_first_field && (alloc_fields_left == alloc_wosize - 1);
          is_later_field = !is_first_field && !is_env_field && (alloc_fields_left > 0);
          is_closurerec_var_field = is_later_field && opcode == CLOSUREREC &&
              closure_nvars > 0 && closure_i < closure_nvars;
          field_from_stack = (is_first_field && opcode != CLOSUREREC && opcode != CLOSURE) ||
              (is_later_field && opcode != CLOSURE);

          if (field_from_stack && !rd_phase) begin
            stack_read_a(is_closurerec_var_field ? sp + closure_i : sp);
            hold_for_read();
          end else if (alloc_fields_left == alloc_wosize) begin

            if (opcode == CLOSUREREC) begin
              heap_write(hp, pending_field);
            end else if (opcode == CLOSURE) begin
              heap_write(hp, pending_field);
            end else begin
              heap_write(hp, st_rd_a);  // tos
              sp <= sp + 1;
            end
            hp <= hp + 1;
            alloc_fields_left <= alloc_fields_left - 1;

          end else if (alloc_fields_left == alloc_wosize - 1) begin

            if (opcode == CLOSUREREC) begin
              heap_write(hp, Val_int(2));
            end else if (opcode == CLOSURE) begin
              heap_write(hp, env);
            end else begin
              heap_write(hp, Val_int(0));
            end
            hp <= hp + 1;
            alloc_fields_left <= alloc_fields_left - 1;


            closure_i <= 0;

          end else if (alloc_fields_left > 0) begin


            if (opcode == CLOSUREREC && closure_nvars > 0 && closure_i < closure_nvars) begin
              heap_write(hp, st_rd_a);  // stack[sp+closure_i]
              hp <= hp + 1;
              closure_i <= closure_i + 1;
              alloc_fields_left <= alloc_fields_left - 1;
            end else if (opcode == CLOSURE) begin

              alloc_fields_left <= 0;
            end else begin
              heap_write(hp, st_rd_a);  // tos
              sp <= sp + 1;
              alloc_fields_left <= alloc_fields_left - 1;
            end

          end else begin

            if (opcode == CLOSUREREC) begin
              if (closure_nvars > 0) begin

                sp <= sp + closure_nvars - 1;
                stack_write(sp+closure_nvars-1, accu);
              end else begin

                sp <= sp - 1;
                stack_write(sp-1, accu);
              end
              closurerec_push <= 1'b0;
            end else if (closurerec_push) begin

              stack_write(sp-1, accu);
              sp <= sp - 1;
              closurerec_push <= 1'b0;
            end

            state <= S_HEAP_DONE;
          end
        end

        S_HEAP_DONE: begin
          heap_write(hp, 32'hDEADBEEF);
          hp <= hp + 1;
          state <= S_DONE;
        end

        S_CLOSURE_ALLOC_HDR: begin
          heap_write(hp, Make_header(2 + closure_nvars, TAG_CLOSURE));
          hp <= hp + 1;
          state <= S_CLOSURE_WRITE_CODE;
        end

        S_CLOSURE_WRITE_CODE: begin
          $display("CLOSURE: creating closure at heap[%0d] with code=%0d", hp, closure_codeptr);
          heap_write(hp, Make_codeptr(closure_codeptr));
          hp <= hp + 1;
          state <= S_CLOSURE_WRITE_CLOSINFO;
        end

        S_CLOSURE_WRITE_CLOSINFO: begin
          heap_write(hp, 32'd0);
          hp <= hp + 1;
          closure_i <= 0;
          state <= (closure_nvars == 0) ? S_CLOSURE_DONE : S_CLOSURE_WRITE_ENV;
        end

        S_CLOSURE_WRITE_ENV:
        if (!rd_phase) begin
          stack_read_a(sp + closure_i);
          hold_for_read();
        end else begin
          heap_write(hp, st_rd_a);
          hp <= hp + 1;
          closure_i <= closure_i + 1;

          if (closure_i + 1 == closure_nvars) state <= S_CLOSURE_DONE;
        end

        S_CLOSURE_DONE: begin
          accu <= alloc_result_ptr;
          sp <= sp + closure_nvars;
          heap_write(hp, 32'hDEADBEEF);
          hp <= hp + 1;
          state <= S_DONE;
        end

        S_CLOSUREREC_CALC: begin
          logic [PCW-1:0] tgt;
          tgt = $signed(pc) + $signed(offset) - 1;
          pending_field <= Make_codeptr(tgt);
          state <= S_HEAP_ALLOC_HDR;
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

        S_OFFSETREF_ADD: begin
          accu  <= accu + Int_val(temp_stack_val) * 2;
          state <= S_DONE;
        end

        S_OFFSETCLOSURE_CALC: begin
          accu  <= Ptr_of_heap_index(Heap_index_of_ptr(temp_heap_val) + offset);
          state <= S_DONE;
        end





        S_MAKEBLOCK1_FIELD: begin
          heap_write(hp, accu);
          hp <= hp + 1;
          accu <= Ptr_of_heap_index(alloc_base);
          state <= S_DONE;
        end





        S_MAKEBLOCK2_HDR: begin
          temp_field1 <= temp_heap_val;
          heap_write(hp, Make_header(2, alloc_tag));
          hp <= hp + 1;
          field_write_idx <= 0;
          state <= S_MAKEBLOCK2_FIELDS;
        end

        S_MAKEBLOCK2_FIELDS: begin
          case (field_write_idx)
            0: begin
              heap_write(hp, accu);
              hp <= hp + 1;
              field_write_idx <= 1;
            end
            1: begin
              heap_write(hp, temp_field1);
              hp <= hp + 1;
              sp <= sp + 1;
              accu <= Ptr_of_heap_index(alloc_base);
              state <= S_DONE;
            end
          endcase
        end





        S_MAKEBLOCK3_READ_STACK:
        if (!rd_phase) begin
          stack_read_a(sp + op_cycle_count);  // sp, sp+1
          hold_for_read();
        end else begin
          case (op_cycle_count)
            0: begin
              temp_field1 <= st_rd_a;
              op_cycle_count <= 1;
            end
            1: begin
              temp_field2 <= st_rd_a;
              state <= S_MAKEBLOCK3_HDR;
            end
          endcase
        end

        S_MAKEBLOCK3_HDR: begin
          heap_write(hp, Make_header(3, alloc_tag));
          hp <= hp + 1;
          field_write_idx <= 0;
          state <= S_MAKEBLOCK3_FIELDS;
        end

        S_MAKEBLOCK3_FIELDS: begin
          case (field_write_idx)
            0: begin
              heap_write(hp, accu);
              hp <= hp + 1;
              field_write_idx <= 1;
            end
            1: begin
              heap_write(hp, temp_field1);
              hp <= hp + 1;
              field_write_idx <= 2;
            end
            2: begin
              heap_write(hp, temp_field2);
              hp <= hp + 1;
              sp <= sp + 2;
              accu <= Ptr_of_heap_index(alloc_base);
              state <= S_DONE;
            end
          endcase
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
              stack_write(sp+imm-3, temp_arg1);
              op_cycle_count <= 1;
            end
            1: begin
              stack_write(sp+imm-2, temp_arg2);
              op_cycle_count <= 2;
            end
            2: begin
              stack_write(sp+imm-1, temp_arg3);
              extra_args <= extra_args + 2;
              temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
              state <= S_HEAP_READ;
              next_state_after_mem <= S_APPTERM3_SETPC;
            end
          endcase
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





        S_APPLY2_WRITE_FRAME: begin  // args already at old sp-3, sp-2
          case (op_cycle_count)
            0: begin
              stack_write(sp - 1, Make_codeptr(pc));
              stack_write(sp, env);
              op_cycle_count <= 1;
            end
            1: begin
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





        S_APPLY3_WRITE_FRAME: begin  // args 1-2 already at old sp-3, sp-2
          case (op_cycle_count)
            0:
            if (!rd_phase) begin
              stack_read_a(sp + 2);  // arg 3
              hold_for_read();
            end else begin
              stack_write(sp - 1, st_rd_a);
              stack_write(sp, Make_codeptr(pc));
              op_cycle_count <= 1;
            end
            1: begin
              stack_write(sp + 1, env);
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
    if (st_we_b) stack_mem[st_addr_b] <= st_wd_b;
    if (st_re_b) st_rd_b <= stack_mem[st_addr_b];
    if (hm_we_a) heap_mem[hm_addr_a] <= hm_wd_a;
    if (hm_re_a) hm_rd_a <= heap_mem[hm_addr_a];
    if (hm_we_b) heap_mem[hm_addr_b] <= hm_wd_b;
    if (hm_re_b) hm_rd_b <= heap_mem[hm_addr_b];
    if (gm_we_a) globals_mem[gm_addr_a] <= gm_wd_a;
    if (gm_re_a) gm_rd_a <= globals_mem[gm_addr_a];
    if (gm_we_b) globals_mem[gm_addr_b] <= gm_wd_b;
    if (gm_re_b) gm_rd_b <= globals_mem[gm_addr_b];

    // tos follows stack port A's reads of stack[sp], a cycle later.
    st_a_was_tos <= st_re_a && (st_addr_a == sp);
    if (st_a_was_tos) tos_q <= st_rd_a;
  end

endmodule

