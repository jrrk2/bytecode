module ocaml4142_vm #(
  parameter int PCW        = 24,   // program counter width (bytes)
  parameter int VALUEW     = 32,   // runtime "value" width (tagged)
  parameter int STACK_AW   = 16,   // stack depth = 2^STACK_AW
  parameter int HEAP_AW    = 18,   // heap words = 2^HEAP_AW
  parameter int GLOBALS_AW = 12    // globals entries = 2^GLOBALS_AW
)(
  input logic		      clk,
  input logic		      reset,

  // Bytecode ROM interface
  output logic [PCW-1:0]      pc,
  input logic [31:0]	      code_rdata,

  // (Optional) external "C_CALL"/primitive trap interface
  output logic		      trap_valid,
  output logic [7:0]	      trap_prim, // which primitive / ccall index
  output logic [VALUEW-1:0]   trap_arg0,
  output logic [VALUEW-1:0]   trap_arg1,
  input logic		      trap_ready,
  input logic [VALUEW-1:0]    trap_result,
  output logic [VALUEW-1:0]   accu,
  output logic [STACK_AW-1:0] sp, // points to next free BELOW top (downward)
  output logic [3:0]	      state_out,
  output logic [31:0]	      imm,
  output logic [31:0]	      nvars,
  output logic [31:0]	      offset,
  output logic [31:0]	      alloc_wosize,
  output logic [31:0]	      alloc_tag,
  output logic [31:0]	      closure_codeptr,
  output logic [7:0]	      closure_nvars,
  output logic [7:0]	      closure_i,
  output logic [7:0]	      opcode_out,
  output logic [31:0]	      tos,
  output logic		      halted
);

  // Bring your opcode enum in from the header.
  `include "ocaml_4142_opcodes.svh"
  // Must define: typedef enum logic [7:0] opcode_t;

  // For completeness here, assume it's already included externally.
  opcode_t opcode;
  assign opcode_out = opcode;
   
  // ----------------------------
  // Tagged integer conventions (OCaml style)
  // - integers are (n << 1) | 1
  // - pointers/blocks are aligned (LSB=0)
  // ----------------------------
  function automatic logic [VALUEW-1:0] Val_int(input integer n);
    Val_int = ((n <<< 1) | 1);
  endfunction

  function automatic integer Int_val(input logic [VALUEW-1:0] v);
    // arithmetic right shift
    Int_val = $signed(v) >>> 1;
  endfunction

  function automatic bit Is_int(input logic [VALUEW-1:0] v);
    Is_int = v[0];
  endfunction

  localparam logic [VALUEW-1:0] VAL_FALSE = Val_int(0);
  localparam logic [VALUEW-1:0] VAL_TRUE  = Val_int(1);
  localparam logic [VALUEW-1:0] VAL_UNIT  = Val_int(0); // acceptable for now

  // ----------------------------
  // Stack RAM (word-addressed)
  // sp is an index; stack grows downward:
  //  push: stack[sp] = x; sp--;
  //  pop:  sp += n;
  // ----------------------------
  logic [VALUEW-1:0] stack_mem [0:(1<<STACK_AW)-1];
  logic [STACK_AW-1:0] trapsp;    // trap frame pointer (stack index)

  // ----------------------------
  // Heap RAM (word-addressed)
  // Simple bump allocator; no GC.
  // Layout for a block:
  //   word0: header (size, tag) [you can pack however you like]
  //   word1..wordN: fields
  // We'll store "value pointers" as (heap_index << 1) with LSB=0.
  // ----------------------------
  logic [VALUEW-1:0] heap_mem [0:(1<<HEAP_AW)-1];
  logic [HEAP_AW-1:0] hp;         // next free heap word

  function automatic logic [VALUEW-1:0] Make_codeptr(input logic [PCW-1:0] pc);
     Make_codeptr = {pc, 2'b00}; // or whatever alignment you use
  endfunction // Make_codeptr
   
  function automatic logic [VALUEW-1:0] Ptr_of_heap_index(input logic [HEAP_AW-1:0] idx);
    // idx goes in bits [HEAP_AW+1:2], so padding is VALUEW-2-HEAP_AW bits
    Ptr_of_heap_index = { {(VALUEW-2-HEAP_AW){1'b0}}, idx, 2'b00 };
  endfunction

  function automatic logic [HEAP_AW-1:0] Heap_index_of_ptr(input logic [VALUEW-1:0] ptr);
    // idx is in bits [HEAP_AW+1:2], extract all of it
    Heap_index_of_ptr = ptr[HEAP_AW+1:2];
  endfunction

  function automatic logic [PCW-1:0] Codeptr_val(input logic [VALUEW-1:0] ptr);
    Codeptr_val = ptr[PCW+1:2];
  endfunction

  // Header pack: [31:16]=wosize, [7:0]=tag (simple)
  function automatic logic [VALUEW-1:0] Make_header(input int wosize, input int tag);
     logic [7:0]      tag8 = tag;
     logic [15:0]     wosize16 = wosize;
     
    Make_header = { wosize16, 8'd0, tag8 };
  endfunction

  // Closure representation (simplified):
  // block tag = 247 (Closure_tag in OCaml runtimes; value not critical if consistent)
  // fields:
  //   field0 = codeptr (bytecode address as an int/pointer-ish)
  //   field1 = env pointer (value)
  localparam int TAG_CLOSURE = 247;

  // ----------------------------
  // VM registers
  // ----------------------------
  logic [VALUEW-1:0]    env;
  logic [7:0]           extra_args;

  // immediates

  // ----------------------------
  // FSM
  // ----------------------------
  typedef enum logic [3:0] 
`include "state.h"

  state_t state;
  assign state_out = state;
  assign tos = stack_mem[sp];
  // For heap allocation micro-ops
  int alloc_fields_left;
  logic [VALUEW-1:0]  alloc_result_ptr;  // returned pointer
  logic               closurerec_push;   // flag to push closure for CLOSUREREC

  // For MAKEBLOCK / CLOSURE etc: store pending field source list
  // We’ll pop fields from stack in order and write them.
  logic [VALUEW-1:0] pending_field;

  // For APPTERM in OCaml: APPTERM n, framesize (both are immediates).
  // We'll treat framesize as imm8 for now (common in listings like "appterm 2, 4").
  // If you see larger frames, widen.
  logic [7:0] imm_b;  // second imm for APPTERM

  // Globals
  logic [VALUEW-1:0] globals_mem [0:(1<<GLOBALS_AW)-1];

  // Trap interface defaults
  always_comb begin
    trap_valid = 1'b0;
    trap_prim  = 8'd0;
    trap_arg0  = '0;
    trap_arg1  = '0;
  end

  // Halted
  always_ff @(posedge clk) begin
    if (reset) halted <= 1'b0;
    else if (opcode == STOP && state == S_EXEC) halted <= 1'b1;
  end

   task push_acc;
      input [31:0] imm;
      begin
	 logic [31:0] old_sp;
	 old_sp = sp;
	 $display("PUSHACC %d: sp=%04x", imm, sp);
	 stack_mem[old_sp - 1] <= accu;               // push
	 sp <= old_sp - 1;
	 if (imm > 0) accu <= stack_mem[(old_sp - 1) + imm];       // read from new_sp + imm
      end
   endtask;

   task push_const;
      input [31:0] imm;
      begin
	 logic [31:0] old_sp;
	 old_sp = sp;
	 sp <= old_sp - 1;
	 stack_mem[old_sp - 1] <= accu;  // Push OLD accu value!
         accu <= Val_int($signed(imm));  // Then set NEW constant
      end
   endtask;

   task read_acc_from_heap;
      input [31:0] ptr_value, offset_used;
      begin
      logic [VALUEW-1:0] read_value;
      // Before the read
      $display("  [HEAP_READ] op=%s ptr=0x%08x heap_idx=%d offset=%d", 
	       opcode.name(), ptr_value, Heap_index_of_ptr(ptr_value), offset_used);

      // After the read
      read_value = heap_mem[Heap_index_of_ptr(ptr_value) + offset_used];
      $display("  [HEAP_READ] addr=%d value=0x%08x is_header=%b", 
	       Heap_index_of_ptr(ptr_value) + offset_used,
	       read_value,
	       (offset_used == 0));
      accu <= read_value;
      end
   endtask // read_acc_from_heap

   task read_pc_from_heap;
      input [31:0] ptr_value, offset_used;
      begin
      logic [VALUEW-1:0] read_value;
      // Before the read
      $display("  [HEAP_READ] op=%s ptr=0x%08x heap_idx=%d offset=%d", 
	       opcode.name(), ptr_value, Heap_index_of_ptr(ptr_value), offset_used);

      // After the read
      read_value = heap_mem[Heap_index_of_ptr(ptr_value) + offset_used];
      $display("  [HEAP_READ] addr=%d value=0x%08x is_header=%b", 
	       Heap_index_of_ptr(ptr_value) + offset_used,
	       read_value,
	       (offset_used == 0));
      pc <= Codeptr_val(read_value);
      end
   endtask // read_acc_from_heap
   
   task push_env;
      input [31:0] imm;
      begin
	 logic [31:0] old_sp;
	 old_sp = sp;
	 sp <= old_sp - 1;
	 stack_mem[old_sp - 1] <= accu;               // push
	 read_acc_from_heap(env, 1 + $signed(imm));
      end
   endtask;

   task caml_ml_open_descriptor_in;
      begin
	 $display("caml_ml_open_descriptor_in");
	 accu <= 32'hC0010000;  // Opaque pointer
      end
   endtask // caml_ml_open_descriptor_in

   task caml_ml_open_descriptor_out;
      begin
	 $display("caml_ml_open_descriptor_out");
	 accu <= 32'hF00D0000;  // Opaque pointer
      end
   endtask // caml_ml_open_descriptor_out
   
   task caml_ml_output_char;
      begin
	 $display("caml_ml_output_char %c (%d)", Int_val(tos), Int_val(tos));
	 accu <= Val_int(0);  // Unit value
      end
   endtask // caml_ml_output_char
   
   task caml_ml_flush;
      begin
	 $display("caml_ml_flush");
	 accu <= Val_int(0);  // Unit value
      end
   endtask // caml_ml_output_char
      
   task caml_string_get;
      begin
	 $display("caml_string_get %x %x", accu, Int_val(tos));
	 accu <= Val_int(1);  // Simple success value
      end
   endtask // caml_ml_output_char
   
   
  // ----------------------------
  // Main FSM
  // ----------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state      <= S_FETCH;
      pc         <= '0;
      opcode     <= STOP;
      imm        <= '0;
      imm_b      <= '0;
      nvars      <= '0;
      offset     <= '0;
      alloc_wosize     <= '0;
      alloc_tag  <= '0;
      accu       <= VAL_UNIT;
      env        <= '0;
      extra_args <= 8'd0;
      closurerec_push <= 1'b0;

      // stack init: sp starts at top of RAM (downward growth)
      sp         <= (1<<STACK_AW) - 1;
      trapsp     <= (1<<STACK_AW) - 1;

      // heap init
      hp         <= '0;
    end else if (!halted) begin
      unique case (state)

        // ----------------------------
        // FETCH opcode
        // ----------------------------
        S_FETCH: begin
          opcode <= opcode_t'(code_rdata[7:0]);
          imm <= '0;
          nvars <= '0;
          offset <= '0;
	  alloc_wosize <= '0;
	  alloc_tag <= '0;
	   
	  $display("  at fetch, acc=0x%08x, pc=%d, bytecode=%d", accu, pc, code_rdata);
	  $display("  stack[sp+0]=0x%08x", stack_mem[sp+0]);
	  $display("  stack[sp+1]=0x%08x", stack_mem[sp+1]);
	  $display("  stack[sp+2]=0x%08x", stack_mem[sp+2]);
	  $display("  stack[sp+3]=0x%08x", stack_mem[sp+3]);
	  $display("  stack[sp+4]=0x%08x", stack_mem[sp+4]);
	  $display("  heap[hp-1]=0x%08x", heap_mem[hp-1]);
	  $display("  heap[hp-2]=0x%08x", heap_mem[hp-2]);
	  $display("  heap[hp-3]=0x%08x", heap_mem[hp-3]);
	  $display("  heap[hp-4]=0x%08x", heap_mem[hp-4]);
          pc     <= pc + 1;
          state  <= S_DECIDE_IMM;	   
        end

        // ----------------------------
        // Decide how many immediates
        // ----------------------------
        S_DECIDE_IMM: begin
	   if (opcode_has_imm8(opcode)) begin
            state <= S_FETCH_IMM;
	   end else if (opcode_has_imm16(opcode) || opcode == CLOSUREREC) begin
              state <= S_FETCH_IMM;
	      if (opcode == CLOSURE) begin
		 nvars   <= code_rdata;
		 pc <= pc + 1;
	      end else if (opcode == CLOSUREREC) begin
		 // CLOSUREREC has nfuncs and nvars
		 imm <= code_rdata;  // nfuncs
		 pc <= pc + 1;
	      end else if (opcode == MAKEBLOCK) begin
		 // MAKEBLOCK has wosize and tag
		 alloc_wosize <= code_rdata;  // wosize
		 pc <= pc + 1;
	      end else if (opcode == BEQ || opcode == BNEQ || 
                           opcode == BLTINT || opcode == BLEINT ||
                           opcode == BGTINT || opcode == BGEINT ||
                           opcode == BULTINT || opcode == BUGEINT) begin
		 // Branch instructions: read first immediate (const)
		 imm <= code_rdata;
		 pc <= pc + 1;
	      end
           end else begin
              state <= S_EXEC;
           end
        end

        // ----------------------------
        // Fetch imm
        // ----------------------------
        S_FETCH_IMM: begin
          if (opcode == CLOSUREREC) begin
            // Read nvars (second immediate)
            nvars <= code_rdata;
	    pc <= pc + 1;  // Advance to offset byte (don't skip it!)
            state <= S_EXEC;
          end else if (opcode == CLOSURE) begin
            // second imm (offset) - sign extend from byte
	    offset <= code_rdata;
	    pc <= pc + 1;
            state <= S_EXEC;
          end else if (opcode == MAKEBLOCK) begin
            // second imm (tag)
	    alloc_tag <= code_rdata;
	    pc <= pc + 1;
            state <= S_EXEC;
          end else if (opcode == BEQ || opcode == BNEQ || opcode == BRANCHIF ||
                       opcode == BLTINT || opcode == BLEINT || opcode == BRANCHIFNOT ||
                       opcode == BGTINT || opcode == BGEINT || opcode == BRANCH ||
                       opcode == BULTINT || opcode == BUGEINT) begin
            // Second immediate is the offset - sign extend from byte
	    offset <= code_rdata;
	    pc <= pc + 1;
            state <= S_EXEC;
          end else begin
            imm   <= code_rdata;
            pc    <= pc + 1;
            state <= S_EXEC;
          end
        end
	
        // ----------------------------
        // EXECUTE one opcode
        // ----------------------------
        S_EXEC: begin
          // Default: return to FETCH after this instruction
          // Opcodes that need multi-cycle operations will override this
          state <= S_DONE;
          
          unique case (opcode)

            // ---- Accumulator loads ----
            ACC0: accu <= stack_mem[sp + 0];
            ACC1: accu <= stack_mem[sp + 1];
            ACC2: accu <= stack_mem[sp + 2];
            ACC3: accu <= stack_mem[sp + 3];
            ACC4: accu <= stack_mem[sp + 4];
            ACC5: accu <= stack_mem[sp + 5];
            ACC6: accu <= stack_mem[sp + 6];
            ACC7: accu <= stack_mem[sp + 7];

            ACC:  accu <= stack_mem[sp + imm];

            // ---- PUSH / PUSHACC ----
            PUSH: begin
              sp <= sp - 1;
              stack_mem[sp - 1] <= accu;
            end

	    PUSHACC0: push_acc(0);
	    PUSHACC1: push_acc(1);
	    PUSHACC2: push_acc(2);
	    PUSHACC3: push_acc(3);
	    PUSHACC4: push_acc(4);
	    PUSHACC5: push_acc(5);
	    PUSHACC6: push_acc(6);
	    PUSHACC7: push_acc(7);
	    PUSHACC: push_acc(imm);
	    
            POP: sp <= sp + imm;

            ASSIGN: begin
              // assign i: store accu into stack slot sp+i (i is local var slot)
              stack_mem[sp + imm] <= accu;
            end

            // ---- ENVACC ----
            // env is a pointer to a block: field[k] is at heap[base+1+k]
            ENVACC1: begin
	       read_acc_from_heap(env, 1 + 1);
            end
            ENVACC2: begin
	       read_acc_from_heap(env, 1 + 2);
            end
            ENVACC3: begin
	       read_acc_from_heap(env, 1 + 3);
            end
            ENVACC4: begin
	       read_acc_from_heap(env, 1 + 4);
            end
            ENVACC: begin
	       read_acc_from_heap(env, 1 + imm);
            end

            PUSHENVACC1: push_env(1);
            PUSHENVACC2: push_env(2);
            PUSHENVACC3: push_env(3);
            PUSHENVACC4: push_env(4);
            PUSHENVACC: push_env(imm);

            // ---- Constants ----
            CONST0: accu <= Val_int(0);
            CONST1: accu <= Val_int(1);
            CONST2: accu <= Val_int(2);
            CONST3: accu <= Val_int(3);

            CONSTINT: accu <= Val_int($signed(imm)); // sign extend imm as small int

            PUSHCONST0: push_const(0);
            PUSHCONST1: push_const(1);
            PUSHCONST2: push_const(2);
            PUSHCONST3: push_const(3);
            PUSHCONSTINT: push_const(imm);

            // ---- Integer ops ----
            NEGINT:  accu <= Val_int(-Int_val(accu));
            
            // Binary operations - all pop the stack after reading TOS
            // C semantics: accu = accu OP tos (then pop tos)
            ADDINT: begin
              accu <= Val_int(Int_val(accu) + Int_val(tos));
              sp <= sp + 1;
            end
            
            SUBINT: begin
              accu <= Val_int(Int_val(accu) - Int_val(tos));
              sp <= sp + 1;
            end
            
            MULINT: begin
              accu <= Val_int(Int_val(accu) * Int_val(tos));
              sp <= sp + 1;
            end
            
            DIVINT: begin
              accu <= Val_int(Int_val(accu) / Int_val(tos));
              sp <= sp + 1;
            end
            
            MODINT: begin
              accu <= Val_int(Int_val(accu) % Int_val(tos));
              sp <= sp + 1;
            end
            
            ANDINT: begin
              accu <= Val_int(Int_val(accu) & Int_val(tos));
              sp <= sp + 1;
            end
            
            ORINT: begin
              accu <= Val_int(Int_val(accu) | Int_val(tos));
              sp <= sp + 1;
            end
            
            XORINT: begin
              accu <= Val_int(Int_val(accu) ^ Int_val(tos));
              sp <= sp + 1;
            end
            
            LSLINT: begin
              accu <= Val_int(Int_val(accu) <<< Int_val(tos));
              sp <= sp + 1;
            end
            
            LSRINT: begin
              accu <= Val_int((Int_val(accu) >>> 0) >> Int_val(tos));
              sp <= sp + 1;
            end
            
            ASRINT: begin
              accu <= Val_int(Int_val(accu) >>> Int_val(tos));
              sp <= sp + 1;
            end

            OFFSETINT: accu <= Val_int(Int_val(accu) + $signed(imm));

            EQ:    begin accu <= (accu == tos) ? VAL_TRUE : VAL_FALSE; sp <= sp + 1; end
            NEQ:   begin accu <= (accu != tos) ? VAL_TRUE : VAL_FALSE; sp <= sp + 1; end
            LTINT: begin accu <= (Int_val(accu) <  Int_val(tos)) ? VAL_TRUE : VAL_FALSE; sp <= sp + 1; end
            LEINT: begin accu <= (Int_val(accu) <= Int_val(tos)) ? VAL_TRUE : VAL_FALSE; sp <= sp + 1; end
            GTINT: begin accu <= (Int_val(accu) >  Int_val(tos)) ? VAL_TRUE : VAL_FALSE; sp <= sp + 1; end
            GEINT: begin accu <= (Int_val(accu) >= Int_val(tos)) ? VAL_TRUE : VAL_FALSE; sp <= sp + 1; end

            BOOLNOT: accu <= (accu == VAL_FALSE) ? VAL_TRUE : VAL_FALSE;

            // ---- Branching (imm signed) ----
            BRANCH: begin
              pc <= pc + $signed(offset) - 1;
            end

            BRANCHIF: begin
              if (accu != VAL_FALSE) pc <= pc + $signed(offset) - 1;
            end

            BRANCHIFNOT: begin
              if (accu == VAL_FALSE) pc <= pc + $signed(offset) - 1;
            end
            
            // Integer comparison branches
            // These compare accu with tos and branch on condition
            // Format: BEQ offset, const - branches if accu == const
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

            // ---- Globals ----
            GETGLOBAL: accu <= globals_mem[imm];
            PUSHGETGLOBAL: begin
	       logic [31:0] old_sp;
	       old_sp = sp;
               sp <= sp - 1;
               stack_mem[old_sp - 1] <= globals_mem[imm];
               accu <= globals_mem[imm];
            end
            SETGLOBAL:
	      begin
		 globals_mem[imm] <= accu;
		 accu = Val_int(0);
	      end

            // ---- Field ops ----
            GETFIELD0: read_acc_from_heap(accu, 1 + 0);
            GETFIELD1: read_acc_from_heap(accu, 1 + 1);
            GETFIELD2: read_acc_from_heap(accu, 1 + 2);
            GETFIELD3: read_acc_from_heap(accu, 1 + 3);
            GETFIELD:  read_acc_from_heap(accu, 1 + imm);

            SETFIELD0: heap_mem[Heap_index_of_ptr(accu) + 1 + 0] <= tos;
            SETFIELD1: heap_mem[Heap_index_of_ptr(accu) + 1 + 1] <= tos;
            SETFIELD2: heap_mem[Heap_index_of_ptr(accu) + 1 + 2] <= tos;
            SETFIELD3: heap_mem[Heap_index_of_ptr(accu) + 1 + 3] <= tos;
            SETFIELD:  heap_mem[Heap_index_of_ptr(accu) + 1 + imm] <= tos;

            // ---- Closures ----
            // CLOSURE lbl, nfree:
            // listing provides a label, bytecode provides a relative offset; we treat imm as rel offset in bytes.
	    CLOSURE: begin
	      closure_nvars   <= nvars;
	      closure_codeptr <= $signed(pc) + $signed(offset) - 1;

	      alloc_wosize <= 2 + nvars;
	      alloc_tag    <= TAG_CLOSURE;

	      alloc_result_ptr <= Ptr_of_heap_index(hp);

	      closure_i <= 0;
	      
	      // If nvars > 0, push accu to stack first (C code: if (nvars > 0) *--sp = accu;)
	      if (nvars > 0) begin
	        sp <= sp - 1;
	        stack_mem[sp - 1] <= accu;
	      end
	      
	      state <= S_CLOSURE_ALLOC_HDR;
	    end

            // CLOSUREREC nvars, offset
            // Creates nvars mutually recursive closures
            // Example: CLOSUREREC 1, 0 creates single self-referential closure with no free vars
            // Example: CLOSUREREC 1, 1 creates single self-referential closure with 1 free var
            CLOSUREREC: begin
              if (imm == 1) begin
                // Single recursive function (nfuncs=1) with nvars free variables
                // S_FETCH_IMM left pc pointing at offset byte
                // Read offset from current bytecode position
                offset <= code_rdata;
                pc <= pc + 1;  // Advance past offset byte
                
                // Save nvars for later use in field writing
                closure_nvars <= nvars;
                
                // If nvars > 0, push accu to stack to save it as captured variable
                if (nvars > 0) begin
                  sp <= sp - 1;
                  stack_mem[sp - 1] <= accu;
                end
                
                // Set flag to push closure after allocation
                closurerec_push <= 1'b1;
                
                // Allocate closure block: size = (nfuncs * 3 - 1) + nvars = 2 + nvars
                alloc_wosize <= 2 + nvars;
                alloc_tag    <= TAG_CLOSURE;
                alloc_fields_left <= 2 + nvars;
                alloc_result_ptr <= Ptr_of_heap_index(hp);
                
                // Will calculate code pointer in next state
                state <= S_CLOSUREREC_CALC;
              end else begin
                $display("Multi-function CLOSUREREC (nfuncs > 1) not yet implemented");
                trap_valid <= 1'b1;
                trap_prim  <= 8'hF0; // "complex CLOSUREREC not implemented"
                state <= S_TRAP_WAIT;
              end
            end

            // OFFSETCLOSURE0 / OFFSETCLOSURE etc:
            // In real OCaml closures are blocks; OFFSETCLOSUREk loads env[k] / closure pointer arithmetic.
            // Here we interpret OFFSETCLOSURE0 as "accu := env"
            OFFSETCLOSURE0: accu <= env;
            OFFSETCLOSURE3: read_acc_from_heap(env, 1 + 3);
            OFFSETCLOSUREM3: read_acc_from_heap(env, 1 - 3); // likely invalid; keep placeholder
            OFFSETCLOSURE: read_acc_from_heap(env, 1 + imm);
            
            // PUSHOFFSETCLOSURE0: push accu, then load env to accu
            PUSHOFFSETCLOSURE0: begin
	       logic [31:0] old_sp;
	       old_sp = sp;
               sp <= sp - 1;
               stack_mem[old_sp - 1] <= accu;
               accu <= env;
            end

            // ---- Calls ----
            // PUSH_RETADDR: push current pc as return addr
	    PUSH_RETADDR: begin
	      logic [31:0] old_sp;
	      logic [PCW-1:0] retpc;

	      old_sp = sp;

	      // NOTE: choose the correct base for retpc depending on where `pc` points in your pipeline.
	      // If `pc` is already advanced past the immediate, retpc = pc + signext(imm).
	      // If `pc` still points at the immediate byte, retpc = (pc + 1) + signext(imm).
	      retpc = $signed(pc-1) + $signed(imm);

	      stack_mem[old_sp - 3] <= Make_codeptr(retpc);   // sp[0]
	      stack_mem[old_sp - 2] <= env;                   // sp[1]
	      stack_mem[old_sp - 1] <= Val_int(extra_args);   // sp[2]   (Val_long)

	      sp <= old_sp - 3;
	    end // case: PUSH_RETADDR
	    
            APPLY: begin
              // APPLY just jumps to the closure with nargs already on stack
              // No stack frame is saved!
              
              // Set up callee
              env <= accu;  // Field(accu, 1)
               read_pc_from_heap(accu, 1 + 0); // Field(accu, 0)
              extra_args <= imm - 1;
            end

	    APPLY1: begin
	      logic [31:0] base, arg1, code_ptr, target_pc;

	      // C code: arg1 = sp[0]; sp -= 3; sp[0]=arg1; sp[1]=pc; sp[2]=env; sp[3]=extra_args
	      // Reads argument from sp, moves sp down by 3, then writes 4 values
	      // The 4th value (sp[3]) goes to old sp position (overwrites argument location)
	      
	      arg1 = tos;  // Read argument from current top

	      // After sp -= 3, write frame:
	      $display("Write frame, arg1=0x%x, pc=%d, env=0x%x, extra=%d", arg1, pc, env, extra_args);
	      stack_mem[sp-3] <= arg1;               // new sp[0]
	      stack_mem[sp-2] <= Make_codeptr(pc);   // new sp[1] 
	      stack_mem[sp-1] <= env;                // new sp[2]
	      stack_mem[sp-0] <= Val_int(extra_args);// new sp[3] = old sp[0]
	      sp <= sp - 3;

	      // Jump to closure
	      read_pc_from_heap(accu, 1);
	      env <= accu;
	      extra_args <= 0;
	    end

            APPLY2: begin
              stack_mem[sp-1]   <= Make_codeptr(pc);
              stack_mem[sp-2] <= env;
              stack_mem[sp-3] <= Val_int(extra_args);
              sp <= sp - 3;
              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
	      read_pc_from_heap(accu, 1);
              extra_args <= 8'd1;
            end

            APPLY3: begin
              stack_mem[sp-1]   <= Make_codeptr(pc);
              stack_mem[sp-2] <= env;
              stack_mem[sp-3] <= Val_int(extra_args);
              sp <= sp - 3;
              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
	      read_pc_from_heap(accu, 1);
              extra_args <= 8'd2;
            end

            APPTERM: begin
	       $display("APPTERM is TBD");
	       $finish;
	       
              // imm = nargs, imm_b = framesize
              // pop framesize slots, tailcall to closure in accu
              sp <= sp + imm_b;

              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
	      read_pc_from_heap(accu, 1);
              extra_args <= imm - 1;
            end

            APPTERM1: begin
              // C code: value arg1 = sp[0]; sp = sp + imm - 1; sp[0] = arg1;
              // Save arg, adjust sp, restore arg
              logic [31:0] arg1;
              arg1 = stack_mem[sp];
              sp <= sp + imm - 1;
              stack_mem[sp + imm - 1] <= arg1;
              
              env <= accu;
	      read_pc_from_heap(accu, 1);
            end // case: APPTERM1
	    
            APPTERM2: begin
              // C code: value arg1 = sp[0]; value arg2 = sp[1]; sp = sp + imm - 2; sp[0] = arg1; sp[1] = arg2;
              logic [31:0] arg1, arg2;
              arg1 = stack_mem[sp];
              arg2 = stack_mem[sp + 1];
              sp <= sp + imm - 2;
              stack_mem[sp + imm - 2] <= arg1;
              stack_mem[sp + imm - 1] <= arg2;
              
              env <= accu;
	      read_pc_from_heap(accu, 1);
              extra_args <= extra_args + 8'd1;
            end // case: APPTERM2
	    
            APPTERM3: begin
              // C code: sp = sp + imm - 3; (with arg shuffling)
              logic [31:0] arg1, arg2, arg3;
              arg1 = stack_mem[sp];
              arg2 = stack_mem[sp + 1];
              arg3 = stack_mem[sp + 2];
              sp <= sp + imm - 3;
              stack_mem[sp + imm - 3] <= arg1;
              stack_mem[sp + imm - 2] <= arg2;
              stack_mem[sp + imm - 1] <= arg3;
              
              env <= accu;
	      read_pc_from_heap(accu, 1);
              extra_args <= extra_args + 8'd2;
            end

            RETURN: begin
              // C code: sp += *pc++; (happens first, always)
              // Then check extra_args
              if (extra_args != 0) begin
                extra_args <= extra_args - 1;
                // For partial application, reload closure from accu
                env <= heap_mem[Heap_index_of_ptr(accu) + 2];
		read_pc_from_heap(accu, 1);
                sp  <= sp + imm;  // Pop locals
              end else begin
                // Normal return: pop locals, then restore frame
                pc         <= Codeptr_val(stack_mem[sp + imm]);
                env        <= stack_mem[sp + imm + 1];
                extra_args <= Int_val(stack_mem[sp + imm + 2])[7:0];
                sp         <= sp + imm + 3;  // Pop locals + frame
              end
            end

            RESTART: begin
              // Real OCaml: rebuild env from closure & args; for now, noop placeholder.
              // Needed for currying/partial applications; factorial often includes it.
              // You should implement from interp.c once core runs.
            end

            GRAB: begin
              // grab n: if extra_args >= n then extra_args -= n else build closure for partial application.
              if (extra_args >= imm) begin
                extra_args <= extra_args - imm;
              end else begin
                $display("partial application: trap for now");
                trap_valid <= 1'b1;
                trap_prim  <= 8'hF1; // "partial apply not implemented"
                state <= S_TRAP_WAIT;
              end
            end

            // ---- Exceptions (minimal) ----
            PUSHTRAP: begin
              // push current trapsp + handler pc
              stack_mem[sp-1] <= Val_int(trapsp);
              stack_mem[sp-2] <= Val_int(pc + $signed(imm));
	      sp <= sp - 2;
              trapsp <= sp; // new trapsp points at this frame (approx)
            end

            POPTRAP: begin
              // restore previous trapsp
              trapsp <= stack_mem[trapsp][STACK_AW-1:0];
            end

            RAISE: begin
              // jump to handler pc saved at trapsp+1
              pc <= Int_val(stack_mem[trapsp + 1]);
              // restore trapsp saved at trapsp
              trapsp <= stack_mem[trapsp][STACK_AW-1:0];
            end

            // ---- C calls / primitives ----
            // For now, C primitives just return dummy values
            // In a real implementation, these would call external C functions
            C_CALL1:
	      begin
		 unique case (imm)
		      16'h0fd: caml_ml_flush();
		      16'h103: caml_ml_open_descriptor_in();
		      16'h104: caml_ml_open_descriptor_out();
		   default: $display("Unsupported C_CALL1: 0x%x", imm);
		   endcase
              end
            
            C_CALL2:
	      begin
		 unique case (imm)
		      16'h108: caml_ml_output_char();
		      16'h15b: caml_string_get();
		   default: $display("Unsupported C_CALL2: 0x%x", imm);
		   endcase
		 sp += 1;
	      end
            
            C_CALL3:
	      begin
              // Return unit value for other C calls
		 accu <= VAL_UNIT;
		 sp += 2;
	      end
            
            C_CALL4:
	      begin
              // Return unit value for other C calls
		 accu <= VAL_UNIT;
		 sp += 3;
	      end
            
            C_CALL5:
	      begin
              // Return unit value for other C calls
		 accu <= VAL_UNIT;
		 sp += 4;
	      end
            
            C_CALLN: begin
              // Return unit value for CALLN
              accu <= VAL_UNIT;
		 sp += imm;
            end

	    MAKEBLOCK:
	      begin
		 $display("MAKEBLOCK %d,%d", alloc_wosize, alloc_tag);
		 state <= S_HEAP_ALLOC_HDR;
	      end

	    MAKEBLOCK1:
	      begin
		 accu <= Ptr_of_heap_index(hp);
		 heap_mem[hp] <= Make_header(1, imm);
		 heap_mem[hp+1] <= accu;
		 heap_mem[hp+2] <= 32'hDEADBEEF;
		 hp <= hp + 3;
	      end

	    MAKEBLOCK2:
	      begin
		 accu <= Ptr_of_heap_index(hp);
		 heap_mem[hp] <= Make_header(2, imm);
		 heap_mem[hp+1] <= accu;
		 heap_mem[hp+2] <= stack_mem[sp + 0];
		 heap_mem[hp+3] <= 32'hDEADBEEF;
		 hp <= hp + 4;
		 sp <= sp + 1;
	      end

	    MAKEBLOCK3:
	      begin
		 accu <= Ptr_of_heap_index(hp);
		 heap_mem[hp] <= Make_header(3, imm);
		 heap_mem[hp+1] <= accu;
		 heap_mem[hp+2] <= stack_mem[sp + 0];
		 heap_mem[hp+3] <= stack_mem[sp + 1];
		 heap_mem[hp+4] <= 32'hDEADBEEF;
		 hp <= hp + 5;
		 sp <= sp + 2;
	      end

	    ATOM0:
	      begin
	      end

	    CHECK_SIGNALS:
	      begin
	      end
		   
            STOP: begin
              // halted is set outside
            end

            default: begin
              $display("almost complete, unhandled ops go to trap instead of silently wrong behavior.");
              trap_valid <= 1'b1;
              trap_prim  <= 8'hFF; // illegal/unimplemented
              trap_arg0  <= Val_int(opcode);
              state      <= S_TRAP_WAIT;
            end

          endcase
        end

        // ----------------------------
        // Heap allocation micro-ops
        // Used for CLOSURE / MAKEBLOCK etc.
        // ----------------------------
        S_HEAP_ALLOC_HDR: begin
          accu <= Ptr_of_heap_index(hp);
          heap_mem[hp] <= Make_header(alloc_wosize, alloc_tag);
          hp <= hp + 1;

          // first field to write is pending_field (field0), then env (field1) for closure
          alloc_fields_left <= alloc_wosize;
          state <= S_HEAP_ALLOC_FIELDS;
        end

        S_HEAP_ALLOC_FIELDS: begin
//	  $display("Alloc fields left = %d/%d", alloc_fields_left, alloc_wosize);
          // For the closure case: write field0, then field1, then optional env vars.
          if (alloc_fields_left == alloc_wosize) begin
            // field0: code pointer
            if (opcode == CLOSUREREC) begin
               heap_mem[hp] <= pending_field;
            end else if (opcode == CLOSURE) begin
               heap_mem[hp] <= pending_field;
            end else begin
	       heap_mem[hp] <= tos;
	       sp <= sp + 1;
	    end	     
            hp <= hp + 1;
            alloc_fields_left <= alloc_fields_left - 1;
            
          end else if (alloc_fields_left == alloc_wosize - 1) begin
            // field1: for CLOSUREREC, point to self; for CLOSURE, use env
            if (opcode == CLOSUREREC) begin
              heap_mem[hp] <= Val_int(2);
            end else if (opcode == CLOSURE) begin
              heap_mem[hp] <= env; // normal CLOSURE case
            end else begin // MAKEBLOCK and friends
	       heap_mem[hp] <= Val_int(0); // TBD
	    end
            hp <= hp + 1;
            alloc_fields_left <= alloc_fields_left - 1;
            
            // Initialize closure_i for environment variable copying
            closure_i <= 0;
            
          end else if (alloc_fields_left > 0) begin
            // Remaining fields: environment variables (if any)
            // For CLOSUREREC with nvars > 0, copy from stack
            if (opcode == CLOSUREREC && closure_nvars > 0 && closure_i < closure_nvars) begin
              heap_mem[hp] <= stack_mem[sp + closure_i];
              hp <= hp + 1;
              closure_i <= closure_i + 1;
              alloc_fields_left <= alloc_fields_left - 1;
            end else if (opcode == CLOSURE) begin
              // No more fields to write, we're done
              alloc_fields_left <= 0;
            end else begin
	       heap_mem[hp] <= tos;
	       sp <= sp + 1;
               alloc_fields_left <= alloc_fields_left - 1;
	    end
            
          end else begin
            // For CLOSUREREC: pop captured variables first, then push new closure
            if (opcode == CLOSUREREC) begin
              if (closure_nvars > 0) begin
                // Pop captured variables, then push closure: net effect is sp = sp + nvars - 1
                sp <= sp + closure_nvars - 1;
                stack_mem[sp + closure_nvars - 1] <= (accu);
              end else begin
                // No captured vars, just push closure
                sp <= sp - 1;
                stack_mem[sp - 1] <= (accu);
              end
              closurerec_push <= 1'b0;
            end else if (closurerec_push) begin
              // Regular CLOSUREREC push (should not happen, but keep for safety)
              stack_mem[sp - 1] <= (accu);
              sp <= sp - 1;
              closurerec_push <= 1'b0;
            end
            
            state <= S_HEAP_DONE;
          end
        end

	S_HEAP_DONE: begin
	   heap_mem[hp] <= 32'hDEADBEEF;
	   hp <= hp + 1;
	   state <= S_DONE;
	end

	S_CLOSURE_ALLOC_HDR: begin
	   heap_mem[hp] <= Make_header(2 + closure_nvars, TAG_CLOSURE);
	   hp <= hp + 1;
	   state <= S_CLOSURE_WRITE_CODE;
	end

	S_CLOSURE_WRITE_CODE: begin
	   $display("CLOSURE: creating closure at heap[%0d] with code=%0d", 
		    hp, closure_codeptr);
	   heap_mem[hp] <= Make_codeptr(closure_codeptr);
	   hp <= hp + 1;
	   state <= S_CLOSURE_WRITE_CLOSINFO;
	end

	S_CLOSURE_WRITE_CLOSINFO: begin
	   heap_mem[hp] <= 32'd0;
	   hp <= hp + 1;
	   closure_i <= 0;
	   state <= (closure_nvars == 0) ? S_CLOSURE_DONE
                    : S_CLOSURE_WRITE_ENV;
	end

	S_CLOSURE_WRITE_ENV: begin
	   heap_mem[hp] <= stack_mem[sp + closure_i];
	   hp <= hp + 1;
	   closure_i <= closure_i + 1;
	   
	   if (closure_i + 1 == closure_nvars)
	     state <= S_CLOSURE_DONE;
	end

	S_CLOSURE_DONE: begin
	   accu <= alloc_result_ptr;
	   sp <= sp + closure_nvars;  // Pop the captured variables (C code: sp += nvars;)
	   heap_mem[hp] <= 32'hDEADBEEF;
	   hp <= hp + 1;
	   state <= S_DONE;
	end

	S_CLOSUREREC_CALC: begin
	   logic [PCW-1:0] tgt;
	   tgt = $signed(pc) + $signed(offset) - 1;  // Need -1 correction
	   pending_field <= Make_codeptr(tgt);       // NOT Val_int(...)
	   state <= S_HEAP_ALLOC_HDR;
	end
	
        // ----------------------------
        // Trap wait: handshake to external
        // ----------------------------
        S_TRAP_WAIT: begin
	   $finish;
          // keep trap_valid asserted via comb in real design; simplified here:
          if (trap_ready) begin
            accu <= trap_result;
            state <= S_DONE;
          end
        end

	S_DONE:
	  begin
	     $display("  instruction done, acc=0x%08x, pc=%d", accu, pc);
	     $display("  stack[sp+0]=0x%08x", stack_mem[sp+0]);
	     $display("  stack[sp+1]=0x%08x", stack_mem[sp+1]);
	     $display("  stack[sp+2]=0x%08x", stack_mem[sp+2]);
	     $display("  stack[sp+3]=0x%08x", stack_mem[sp+3]);
	     $display("  stack[sp+4]=0x%08x", stack_mem[sp+4]);
	     $display("  heap[hp-1]=0x%08x", heap_mem[hp-1]);
	     $display("  heap[hp-2]=0x%08x", heap_mem[hp-2]);
	     $display("  heap[hp-3]=0x%08x", heap_mem[hp-3]);
	     $display("  heap[hp-4]=0x%08x", heap_mem[hp-4]);
	     if (accu == 32'h00000043) begin
		$display("[TRACK] accu=0x43 set by %s at PC=%d", opcode.name(), pc);
	     end
	     state <= S_FETCH;
	  end
	
        default: 
	  begin
	     $display("Invalid state %d", state);
	     $finish;
	  end
      endcase
    end
  end

endmodule // ocaml4142_vm
