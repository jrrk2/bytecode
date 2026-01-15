module ocaml4142_vm_rtl #(
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
  output logic [6:0]	      state_out,
  output logic [31:0]	      imm,
  output logic [31:0]	      nvars,
  output logic [31:0]	      offset,
  output logic [31:0]	      alloc_wosize,
  output logic [31:0]	      alloc_base,
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
  typedef enum logic [6:0] 
`include "state_rtl_complete.h"

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
  // Temporary storage for multi-cycle operations
  logic [VALUEW-1:0] temp_arg1, temp_arg2, temp_arg3;
  logic [VALUEW-1:0] temp_field1, temp_field2, temp_field3;
  logic [VALUEW-1:0] temp_stack_val;
  logic [VALUEW-1:0] temp_heap_val;
  logic [VALUEW-1:0] temp_return_pc, temp_return_env;
  logic [7:0] temp_extra_args;
  
  // Multi-cycle operation tracking
  logic [7:0] op_cycle_count;
  state_t next_state_after_mem;
  logic [7:0] field_write_idx;
  logic [7:0] total_fields_to_write;
  
  // Memory addresses for multi-cycle ops
  logic [STACK_AW-1:0] temp_stack_addr;
  logic [HEAP_AW-1:0] temp_heap_addr;
  logic [GLOBALS_AW-1:0] temp_globals_addr;

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
      temp_arg1 <= '0;
      temp_arg2 <= '0;
      temp_arg3 <= '0;
      temp_field1 <= '0;
      temp_field2 <= '0;
      temp_field3 <= '0;
      temp_stack_val <= '0;
      temp_heap_val <= '0;
      temp_return_pc <= '0;
      temp_return_env <= '0;
      temp_extra_args <= '0;
      op_cycle_count <= '0;
      next_state_after_mem <= S_DONE;
      field_write_idx <= '0;
      total_fields_to_write <= '0;
      temp_stack_addr <= '0;
      temp_heap_addr <= '0;
      temp_globals_addr <= '0;

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

	 `include "acc0.svh"
	 `include "acc1_7.svh"
	 `include "apply1.svh"
	 `include "apply23.svh"
	 `include "appterm1.svh"
	 `include "appterm2.svh"
	 `include "appterm3.svh"
	 `include "arithmetic_unchanged.svh"
	 `include "assign.svh"
	 `include "control_flow.svh"
	 `include "envacc.svh"
	 `include "getfield.svh"
	 `include "globals.svh"
	 `include "makeblock1.svh"
	 `include "makeblock2.svh"
	 `include "makeblock3.svh"
	 `include "offsetclosure.svh"
	 `include "offsetref.svh"
	 `include "pop.svh"
	 `include "push.svh"
	 `include "pushacc.svh"
	 `include "pushenvacc.svh"
	 `include "pushoffsetclosure.svh"
	 `include "return.svh"
	 `include "setfield.svh"
	    
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

	    ATOM0:
	      begin
	      end

	    PUSH_RETADDR:
	      begin
	      end
	    
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
              $display("CLOSUREREC (nfuncs = %d, nvars = %d)", imm, nvars);
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
            
            // PUSHOFFSETCLOSURE0: push accu, then load env to accu
            PUSHOFFSETCLOSURE0: begin
               logic [31:0] old_sp;
               old_sp = sp;
               sp <= sp - 1;
               stack_mem[old_sp - 1] <= accu;
               accu <= env;
            end

            PUSHOFFSETCLOSURE3: begin
               logic [31:0] old_sp;
               old_sp = sp;
               sp <= sp - 1;
               stack_mem[old_sp - 1] <= accu;
               accu <= env;
            end

            PUSHOFFSETCLOSUREM3: begin
               logic [31:0] old_sp;
               old_sp = sp;
               sp <= sp - 1;
               stack_mem[old_sp - 1] <= accu;
               accu <= env;
            end

            PUSHGETGLOBAL: begin
               logic [31:0] old_sp;
               old_sp = sp;
               sp <= sp - 1;
               stack_mem[old_sp - 1] <= globals_mem[imm];
               accu <= globals_mem[imm];
            end
	    
            GETGLOBALFIELD: accu <= globals_mem[imm];
	    
            PUSHGETGLOBALFIELD: accu <= globals_mem[imm];
/*
	    ATOM:
	      begin
	      end

	    APPTERM:
	      begin
	      end

	    APPLY:
	      begin
	      end
*/
	    CHECK_SIGNALS:
	      begin
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

        // =================================================================
        // SINGLE MEMORY OPERATION STATES
        // =================================================================
/*        
        S_STACK_READ: begin
          // Cycle 1: Address asserted in previous state
          // Cycle 2: Capture data
          accu <= stack_mem[temp_stack_addr];
          state <= next_state_after_mem;
        end

        S_HEAP_READ: begin
          // Cycle 1: Address asserted in previous state
          // Cycle 2: Capture data
          temp_heap_val <= heap_mem[temp_heap_addr];
          state <= next_state_after_mem;
        end
        
        S_GLOBALS_READ: begin
          // Cycle 1: Address asserted in previous state
          // Cycle 2: Capture data
          accu <= globals_mem[temp_stack_addr[GLOBALS_AW-1:0]];
          state <= next_state_after_mem;
        end

        // =================================================================
        // PUSHACC MULTI-CYCLE STATES
        // =================================================================
        
        S_PUSHACC_WRITE: begin
          // Write old accu to stack
          stack_mem[sp - 1] <= accu;
          sp <= sp - 1;
          
          // If this is just PUSH (no read), we're done
          if (temp_stack_addr == 16'hFFFF) begin  // Marker for "no read"
            state <= S_DONE;
          end else begin
            // Otherwise read new accu
            state <= S_PUSHACC_READ;
          end
        end
        
        S_PUSHACC_READ: begin
          // Read new accu from stack
          accu <= stack_mem[temp_stack_addr];
          state <= S_DONE;
        end

        // =================================================================
        // APPTERM MULTI-CYCLE STATES
        // =================================================================
        
        S_APPTERM_READ_ARGS: begin
          // Read arguments from current stack position
          case (op_cycle_count)
            0: begin
              temp_arg1 <= stack_mem[sp];
              if (imm_b == 1) begin
                // Only 1 arg, move to write phase
                op_cycle_count <= 0;
                state <= S_APPTERM_WRITE_ARGS;
              end else begin
                op_cycle_count <= 1;
                // Stay in this state to read more args
              end
            end
            
            1: begin
              temp_arg2 <= stack_mem[sp + 1];
              if (imm_b == 2) begin
                op_cycle_count <= 0;
                state <= S_APPTERM_WRITE_ARGS;
              end else begin
                op_cycle_count <= 2;
              end
            end
            
            2: begin
              temp_arg3 <= stack_mem[sp + 2];
              op_cycle_count <= 0;
              state <= S_APPTERM_WRITE_ARGS;
            end
          endcase
        end
        
        S_APPTERM_WRITE_ARGS: begin
          // Adjust stack pointer first (this was done in EXEC)
          // Now write args back to new positions
          case (op_cycle_count)
            0: begin
              stack_mem[sp + imm - imm_b] <= temp_arg1;
              if (imm_b == 1) begin
                state <= S_APPTERM_READ_CODE;
              end else begin
                op_cycle_count <= 1;
              end
            end
            
            1: begin
              stack_mem[sp + imm - imm_b + 1] <= temp_arg2;
              if (imm_b == 2) begin
                state <= S_APPTERM_READ_CODE;
              end else begin
                op_cycle_count <= 2;
              end
            end
            
            2: begin
              stack_mem[sp + imm - imm_b + 2] <= temp_arg3;
              state <= S_APPTERM_READ_CODE;
            end
          endcase
        end
        
        S_APPTERM_READ_CODE: begin
          // Read code pointer from closure
          temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
          state <= S_HEAP_READ;
          next_state_after_mem <= S_APPTERM_SET_PC;
        end
        
        S_APPTERM_SET_PC: begin
          // Set PC from closure code pointer
          pc <= Codeptr_val(temp_heap_val);
          env <= accu;
          state <= S_DONE;
        end

        // =================================================================
        // APPLY MULTI-CYCLE STATES  
        // =================================================================
        
        S_APPLY_WRITE_FRAME: begin
          // Write return frame: (pc, env, extra_args)
          case (op_cycle_count)
            0: begin
              stack_mem[sp - 1] <= Make_codeptr(pc);
              sp <= sp - 1;
              op_cycle_count <= 1;
            end
            
            1: begin
              stack_mem[sp - 1] <= env;
              sp <= sp - 1;
              op_cycle_count <= 2;
            end
            
            2: begin
              stack_mem[sp - 1] <= Val_int(extra_args);
              sp <= sp - 1;
              op_cycle_count <= 0;
              state <= S_APPLY_READ_CODE;
            end
          endcase
        end
        
        S_APPLY_READ_CODE: begin
          // Read code pointer from closure
          temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
          state <= S_HEAP_READ;
          next_state_after_mem <= S_APPLY_SET_PC;
        end
        
        S_APPLY_SET_PC: begin
          // Set PC and env from closure
          pc <= Codeptr_val(temp_heap_val);
          env <= accu;
          extra_args <= temp_extra_args;  // Set earlier
          accu <= temp_arg1;  // First argument
          state <= S_DONE;
        end

        // =================================================================
        // RETURN MULTI-CYCLE STATES
        // =================================================================
        
        S_RETURN_READ_PC: begin
          temp_return_pc <= stack_mem[sp + imm - 3];
          state <= S_RETURN_READ_ENV;
        end
        
        S_RETURN_READ_ENV: begin
          temp_return_env <= stack_mem[sp + imm - 2];
          state <= S_RETURN_READ_EXTRA;
        end
        
        S_RETURN_READ_EXTRA: begin
          temp_extra_args <= Int_val(stack_mem[sp + imm - 1]);
          sp <= sp + imm;
          state <= S_RETURN_SET_STATE;
        end
        
        S_RETURN_SET_STATE: begin
          pc <= Codeptr_val(temp_return_pc);
          env <= temp_return_env;
          extra_args <= temp_extra_args;
          state <= S_DONE;
        end

        // =================================================================
        // MAKEBLOCK MULTI-CYCLE STATES
        // =================================================================
        
        S_MAKEBLOCK_READ_STACK: begin
          // Read values from stack based on block size
          case (op_cycle_count)
            0: begin
              if (alloc_wosize >= 2) begin
                temp_field1 <= stack_mem[sp];
                if (alloc_wosize >= 3) begin
                  op_cycle_count <= 1;
                end else begin
                  state <= S_MAKEBLOCK_WRITE_HDR;
                end
              end else begin
                // No stack reads needed (MAKEBLOCK1)
                state <= S_MAKEBLOCK_WRITE_HDR;
              end
            end
            
            1: begin
              temp_field2 <= stack_mem[sp + 1];
              if (alloc_wosize >= 4) begin
                op_cycle_count <= 2;
              end else begin
                op_cycle_count <= 0;
                state <= S_MAKEBLOCK_WRITE_HDR;
              end
            end
            
            2: begin
              temp_field3 <= stack_mem[sp + 2];
              op_cycle_count <= 0;
              state <= S_MAKEBLOCK_WRITE_HDR;
            end
          endcase
        end
        
        S_MAKEBLOCK_WRITE_HDR: begin
          // Write header
          heap_mem[alloc_base] <= Make_header(alloc_wosize, alloc_tag);
          field_write_idx <= 0;
          state <= S_MAKEBLOCK_WRITE_FIELD;
        end
        
        S_MAKEBLOCK_WRITE_FIELD: begin
          // Write fields one per cycle
          case (field_write_idx)
            0: heap_mem[alloc_base + 1] <= accu;
            1: heap_mem[alloc_base + 2] <= temp_field1;
            2: heap_mem[alloc_base + 3] <= temp_field2;
            3: heap_mem[alloc_base + 4] <= temp_field3;
          endcase
          
          if (field_write_idx == alloc_wosize - 1) begin
            // All fields written
            hp <= alloc_base + 1 + alloc_wosize;
            accu <= Ptr_of_heap_index(alloc_base);
            sp <= sp + (alloc_wosize - 1);  // Pop stack args
            state <= S_DONE;
          end else begin
            field_write_idx <= field_write_idx + 1;
            // Stay in this state to write next field
          end
        end

        // =================================================================
        // OFFSETCLOSURE
        // =================================================================
        
        S_OFFSETCLOSURE_READ: begin
          temp_heap_val <= heap_mem[Heap_index_of_ptr(env) + offset];
          state <= S_OFFSETCLOSURE_ADD;
        end
        
        S_OFFSETCLOSURE_ADD: begin
          accu <= Ptr_of_heap_index(Heap_index_of_ptr(temp_heap_val) + offset);
          state <= S_DONE;
        end
*/
	 `include "rtl_state_handlers.svh"
	
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
