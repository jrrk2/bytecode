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
  output logic [PCW-1:0]      code_addr,
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
  output logic [31:0]	      closure_codeptr,
  output logic [7:0]	      closure_nvars,
  output logic [7:0]	      closure_i,
  output logic [31:0]	      tos,
  output logic		      halted
);

  // Bring your opcode enum in from the header.
  `include "ocaml_4142_opcodes.svh"
  // Must define: typedef enum logic [7:0] opcode_t;

  // For completeness here, assume it's already included externally.
  opcode_t opcode;

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

  function automatic logic [VALUEW-1:0] Ptr_of_heap_index(input logic [HEAP_AW-1:0] idx);
    Ptr_of_heap_index = { {(VALUEW-1-HEAP_AW){1'b0}}, idx, 2'b00 };
  endfunction

  function automatic logic [HEAP_AW-1:0] Heap_index_of_ptr(input logic [VALUEW-1:0] ptr);
    Heap_index_of_ptr = ptr[HEAP_AW:2];
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
  logic [PCW-1:0]       pc;
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
  int alloc_wosize;
  int alloc_tag;
  int alloc_fields_left;
  logic [HEAP_AW-1:0] alloc_base;        // heap index of header
  logic [VALUEW-1:0]  alloc_result_ptr;  // returned pointer

  // For MAKEBLOCK / CLOSURE etc: store pending field source list
  // We’ll pop fields from stack in order and write them.
  logic [VALUEW-1:0] pending_field;

  function automatic bit needs_imm(opcode_t op);
    unique case (op)
      BRANCH, BRANCHIF, BRANCHIFNOT,
      CLOSURE, CLOSUREREC,
      APPLY, APPTERM, RETURN, GRAB, // in 4.14 listing appterm has 2 immediates; treat specially (imm8 + imm8/16) as needed
      CONSTINT, PUSHCONSTINT, PUSHACC, OFFSETINT, 
      C_CALL1, C_CALLN, PUSHTRAP, POPTRAP, SWITCH,
      BEQ, BNEQ, BLTINT, BLEINT, BGTINT, BGEINT,
      BULTINT, BUGEINT, POP, GETGLOBAL, PUSHGETGLOBAL, SETGLOBAL, 
      MAKEBLOCK, MAKEBLOCK2, MAKEBLOCK3
        : needs_imm = 1'b1;
      default
        : needs_imm = 1'b0;
    endcase
  endfunction

  // For APPTERM in OCaml: APPTERM n, framesize (both are immediates).
  // We'll treat framesize as imm8 for now (common in listings like "appterm 2, 4").
  // If you see larger frames, widen.
  logic [7:0] imm_b;  // second imm for APPTERM

  // Globals
  logic [VALUEW-1:0] globals_mem [0:(1<<GLOBALS_AW)-1];

  // Code ROM address
  assign code_addr = pc;

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
	 $display("PUSHACC4: sp=%04x", sp);
	 stack_mem[old_sp - 1] <= accu;               // push
	 sp <= old_sp - 1;
	 accu <= stack_mem[(old_sp - 1) + imm];       // read from *new* sp
      end
   endtask; // push_acc

   task push_const;
      input [31:0] imm;
      begin
	 logic [31:0] old_sp;
	 old_sp = sp;
	 sp <= old_sp - 1;
	 stack_mem[old_sp - 1] <= Val_int($signed(imm));               // push
	 accu <= stack_mem[(old_sp - 1) + $signed(imm)];       // read from *new* sp
      end
   endtask; // push_acc

   task push_env;
      input [31:0] imm;
      begin
	 logic [31:0] old_sp;
	 old_sp = sp;
	 sp <= old_sp - 1;
	 stack_mem[old_sp - 1] <= accu;               // push
	 accu <= heap_mem[Heap_index_of_ptr(env)+1 + $signed(imm)];
      end
   endtask; // push_acc
   
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

      accu       <= VAL_UNIT;
      env        <= '0;
      extra_args <= 8'd0;

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
          pc     <= pc + 1;
          state  <= S_DECIDE_IMM;
	  $display("  after fetch, acc=%08x", accu);
	  $display("  stack[sp+0]=%08x", stack_mem[sp+0]);
	  $display("  stack[sp+1]=%08x", stack_mem[sp+1]);
	  $display("  stack[sp+2]=%08x", stack_mem[sp+2]);
	  $display("  stack[sp+3]=%08x", stack_mem[sp+3]);
	  $display("  stack[sp+4]=%08x", stack_mem[sp+4]);
	   
        end

        // ----------------------------
        // Decide how many immediates
        // ----------------------------
        S_DECIDE_IMM: begin
	   if (needs_imm(opcode)) begin
	     if (opcode == CLOSURE) begin
		nvars   <= code_rdata;
		pc <= pc + 1;
	     end else if (opcode == BEQ || opcode == BNEQ || 
	                  opcode == BLTINT || opcode == BLEINT ||
	                  opcode == BGTINT || opcode == BGEINT ||
	                  opcode == BULTINT || opcode == BUGEINT) begin
		// These branch instructions have two immediates: const and offset
		imm <= code_rdata;  // First immediate is the constant
		pc <= pc + 1;
	     end
            state <= S_FETCH_IMM;
          end else begin
            state <= S_EXEC;
          end
        end

        // ----------------------------
        // Fetch imm
        // ----------------------------
        S_FETCH_IMM: begin
          if (opcode == CLOSUREREC) begin
            // first imm
	    pc <= pc + 2 + code_rdata;
            state <= S_EXEC;
          end else if (opcode == CLOSURE) begin
            // second imm (offset) - sign extend from byte
	    offset <= {{24{code_rdata[7]}}, code_rdata[7:0]};  // Sign-extend byte to 32 bits
	    pc <= pc + 1;
            state <= S_EXEC;
          end else if (opcode == BEQ || opcode == BNEQ || 
                       opcode == BLTINT || opcode == BLEINT ||
                       opcode == BGTINT || opcode == BGEINT ||
                       opcode == BULTINT || opcode == BUGEINT) begin
            // Second immediate is the offset - sign extend from byte
	    offset <= {{24{code_rdata[7]}}, code_rdata[7:0]};  // Sign-extend byte to 32 bits
	    pc <= pc + 1;
            state <= S_EXEC;
          end else if (opcode == MAKEBLOCK) begin
            // first imm
	    pc <= pc + 2;
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
              accu <= heap_mem[Heap_index_of_ptr(env) + 1 + 1];
            end
            ENVACC2: begin
              accu <= heap_mem[Heap_index_of_ptr(env) + 1 + 2];
            end
            ENVACC3: begin
              accu <= heap_mem[Heap_index_of_ptr(env) + 1 + 3];
            end
            ENVACC4: begin
              accu <= heap_mem[Heap_index_of_ptr(env) + 1 + 4];
            end
            ENVACC: begin
              accu <= heap_mem[Heap_index_of_ptr(env) + 1 + imm];
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
            ADDINT:  accu <= Val_int(Int_val(tos) + Int_val(accu)); // expects arg on stack
            SUBINT:  accu <= Val_int(Int_val(tos) - Int_val(accu));
            MULINT:  accu <= Val_int(Int_val(tos) * Int_val(accu));
            DIVINT:  accu <= Val_int(Int_val(tos) / Int_val(accu));
            MODINT:  accu <= Val_int(Int_val(tos) % Int_val(accu));
            ANDINT:  accu <= Val_int(Int_val(tos) & Int_val(accu));
            ORINT:   accu <= Val_int(Int_val(tos) | Int_val(accu));
            XORINT:  accu <= Val_int(Int_val(tos) ^ Int_val(accu));
            LSLINT:  accu <= Val_int(Int_val(tos) <<< Int_val(accu));
            LSRINT:  accu <= Val_int((Int_val(tos) >>> 0) >> Int_val(accu));
            ASRINT:  accu <= Val_int(Int_val(tos) >>> Int_val(accu));

            OFFSETINT: accu <= Val_int(Int_val(accu) + $signed(imm));

            EQ:    accu <= (tos == accu) ? VAL_TRUE : VAL_FALSE;
            NEQ:   accu <= (tos != accu) ? VAL_TRUE : VAL_FALSE;
            LTINT: accu <= (Int_val(tos) <  Int_val(accu)) ? VAL_TRUE : VAL_FALSE;
            LEINT: accu <= (Int_val(tos) <= Int_val(accu)) ? VAL_TRUE : VAL_FALSE;
            GTINT: accu <= (Int_val(tos) >  Int_val(accu)) ? VAL_TRUE : VAL_FALSE;
            GEINT: accu <= (Int_val(tos) >= Int_val(accu)) ? VAL_TRUE : VAL_FALSE;

            BOOLNOT: accu <= (accu == VAL_FALSE) ? VAL_TRUE : VAL_FALSE;

            // ---- Branching (imm signed) ----
            BRANCH: begin
              pc <= pc + $signed(imm) - 1;
            end

            BRANCHIF: begin
              if (accu != VAL_FALSE) pc <= pc + $signed(imm) - 1;
            end

            BRANCHIFNOT: begin
              if (accu == VAL_FALSE) pc <= pc + $signed(imm) - 1;
            end
            
            // Integer comparison branches
            // These compare accu with tos and branch on condition
            // Format: BEQ offset, const - branches if accu == const
            BEQ: begin
              if (Int_val(accu) == $signed(imm)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end
            
            BNEQ: begin
              if (Int_val(accu) != $signed(imm)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end
            
            BLTINT: begin
              if (Int_val(accu) < $signed(imm)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end
            
            BLEINT: begin
              if (Int_val(accu) <= $signed(imm)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end
            
            BGTINT: begin
              if (Int_val(accu) > $signed(imm)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end
            
            BGEINT: begin
              if (Int_val(accu) >= $signed(imm)) begin
                pc <= pc + $signed(offset) - 1;
              end
            end
            
            BULTINT: begin
              if ($unsigned(Int_val(accu)) < $unsigned($signed(imm))) begin
                pc <= pc + $signed(offset) - 1;
              end
            end
            
            BUGEINT: begin
              if ($unsigned(Int_val(accu)) >= $unsigned($signed(imm))) begin
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
            SETGLOBAL: globals_mem[imm] <= accu;

            // ---- Field ops ----
            GETFIELD0: accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + 0];
            GETFIELD1: accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
            GETFIELD2: accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + 2];
            GETFIELD3: accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + 3];
            GETFIELD:  accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + imm];

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
	      closure_codeptr <= $signed(pc) + $signed(offset) - 1;  // Fix: subtract 1

	      alloc_wosize <= 1 + nvars;
	      alloc_tag    <= TAG_CLOSURE;

	      alloc_result_ptr <= Ptr_of_heap_index(hp);

	      closure_i <= 0;
	      state <= S_CLOSURE_ALLOC_HDR;
	    end

            // CLOSUREREC nvars, offset
            // Creates nvars mutually recursive closures
            // For factorial: CLOSUREREC 1, 0 creates single self-referential closure
            CLOSUREREC: begin
              if (nvars == 1) begin
                // Simple case: single recursive function
                // Create one closure that points to itself as its environment
                alloc_wosize <= 2;
                alloc_tag    <= TAG_CLOSURE;
                alloc_fields_left <= 2;
                alloc_result_ptr <= Ptr_of_heap_index(hp);
                state <= S_HEAP_ALLOC_HDR;
                
                // field0: code pointer (pc + offset - 1, like BRANCH and CLOSURE)
                pending_field <= Val_int($signed(pc) + $signed(offset) - 1);
                // field1 will be set to point to the closure itself in S_HEAP_ALLOC_FIELDS
              end else begin
                // Multi-function recursion not yet implemented
                trap_valid <= 1'b1;
                trap_prim  <= 8'hF0; // "multi-CLOSUREREC not implemented"
                state <= S_TRAP_WAIT;
              end
            end

            // OFFSETCLOSURE0 / OFFSETCLOSURE etc:
            // In real OCaml closures are blocks; OFFSETCLOSUREk loads env[k] / closure pointer arithmetic.
            // Here we interpret OFFSETCLOSURE0 as "accu := env"
            OFFSETCLOSURE0: accu <= env;
            OFFSETCLOSURE3: accu <= heap_mem[Heap_index_of_ptr(env) + 1 + 3];
            OFFSETCLOSUREM3: accu <= heap_mem[Heap_index_of_ptr(env) + 1 + ( -3 )]; // likely invalid; keep placeholder
            OFFSETCLOSURE: accu <= heap_mem[Heap_index_of_ptr(env) + 1 + imm];
            
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
	       old_sp = sp;
               sp <= sp - 1;
               stack_mem[old_sp - 1] <= Val_int(pc); // store as int for now
            end

            APPLY: begin
              // nargs = imm
              // calling convention: accu is closure
              // push return pc, env, extra_args
              stack_mem[sp]   <= Val_int(pc);
              stack_mem[sp-1] <= env;
              stack_mem[sp-2] <= Val_int(extra_args);
              sp <= sp - 3;

              // set up callee
              // closure fields: [0]=code(int), [1]=env(value)
              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1]);
              extra_args <= imm - 1;
            end

	    APPLY1: begin
	      logic [31:0] base;
	      logic [31:0] arg1;

	      // 1) Save argument
	      arg1 = tos;

	      // 2) Build new frame (after sp -= 3)
	      stack_mem[sp-3] <= arg1;               // sp[0]
	      stack_mem[sp-2] <= Val_int(pc);        // sp[1] return pc
	      stack_mem[sp-1] <= env;                // sp[2] old env (closure)
	      stack_mem[sp-0] <= Val_int(extra_args);// sp[3]

	      sp <= sp - 3;

	      // 3) Jump to closure
	      base = Heap_index_of_ptr(accu);
	      pc  <= Int_val(heap_mem[base + 1]);    // Field(accu,0)
	      env <= accu;                           // NOT heap_mem[base+2]
	      extra_args <= 0;
	    end

            APPLY2: begin
              stack_mem[sp]   <= Val_int(pc);
              stack_mem[sp-1] <= env;
              stack_mem[sp-2] <= Val_int(extra_args);
              sp <= sp - 3;
              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1]);
              extra_args <= 8'd1;
            end

            APPLY3: begin
              stack_mem[sp]   <= Val_int(pc);
              stack_mem[sp-1] <= env;
              stack_mem[sp-2] <= Val_int(extra_args);
              sp <= sp - 3;
              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1]);
              extra_args <= 8'd2;
            end

            APPTERM: begin
              // imm = nargs, imm_b = framesize
              // pop framesize slots, tailcall to closure in accu
              sp <= sp + imm_b;

              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1]);
              extra_args <= imm - 1;
            end

            APPTERM1: begin
              // framesize is encoded in opcode variant? In OCaml, APPTERM1 n? is specialized; simplify:
              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1]);
              extra_args <= 8'd0;
            end
            APPTERM2: begin
              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1]);
              extra_args <= 8'd1;
            end
            APPTERM3: begin
              env <= heap_mem[Heap_index_of_ptr(accu) + 2];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1]);
              extra_args <= 8'd2;
            end

            RETURN: begin
              // if extra_args > 0, treat as "restart" with decremented extra_args
              if (extra_args != 0) begin
                extra_args <= extra_args - 1;
                // For partial application, reload closure from accu
                env <= heap_mem[Heap_index_of_ptr(accu) + 2];
                pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1]);
              end else begin
                // pop n locals, then restore extra_args, env, pc from stack
                // Stack layout after pop: [...][extra_args at sp+imm+1][env at sp+imm+2][pc at sp+imm+3]
                extra_args <= stack_mem[sp + imm + 1][7:0];
                env        <= stack_mem[sp + imm + 2];
                pc         <= Int_val(stack_mem[sp + imm + 3]);
                sp         <= sp + imm + 3;
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
                // partial application: trap for now
                trap_valid <= 1'b1;
                trap_prim  <= 8'hF1; // "partial apply not implemented"
                state <= S_TRAP_WAIT;
              end
            end

            // ---- Exceptions (minimal) ----
            PUSHTRAP: begin
              // push current trapsp + handler pc
              stack_mem[sp] <= Val_int(trapsp); sp <= sp - 1;
              stack_mem[sp] <= Val_int(pc + $signed(imm)); sp <= sp - 1;
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
            C_CALL1: begin
              // Return a dummy file descriptor value (3 = stdout equivalent)
              accu <= Val_int(1);  // Simple success value
            end
            
            C_CALL2, C_CALL3, C_CALL4, C_CALL5: begin
              // Return unit value for other C calls
              accu <= VAL_UNIT;
            end
            
            C_CALLN: begin
              // Return unit value for CALLN
              accu <= VAL_UNIT;
            end

            STOP: begin
              // halted is set outside
            end

            default: begin
              // For “almost complete”, unhandled ops go to trap instead of silently wrong behavior.
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
          alloc_base <= hp;
          heap_mem[hp] <= Make_header(alloc_wosize, alloc_tag);
          hp <= hp + 1;

          // first field to write is pending_field (field0), then env (field1) for closure
          alloc_fields_left <= alloc_wosize;
          state <= S_HEAP_ALLOC_FIELDS;
        end

        S_HEAP_ALLOC_FIELDS: begin
          // For the closure case: write field0 then field1.
          if (alloc_fields_left == alloc_wosize) begin
            heap_mem[hp] <= pending_field; // field0 (code pointer)
            hp <= hp + 1;
            alloc_fields_left <= alloc_fields_left - 1;
          end else if (alloc_fields_left == alloc_wosize - 1) begin
            // field1: for CLOSUREREC, point to self; for CLOSURE, use env
            if (opcode == CLOSUREREC) begin
              heap_mem[hp] <= Ptr_of_heap_index(alloc_base);
            end else begin
              heap_mem[hp] <= env; // normal CLOSURE case
            end
            hp <= hp + 1;
            alloc_fields_left <= alloc_fields_left - 1;
          end else begin
            // done
            accu <= Ptr_of_heap_index(alloc_base);
            state <= S_DONE;
          end
        end

	S_CLOSURE_ALLOC_HDR: begin
	   heap_mem[hp] <= Make_header(1 + closure_nvars, TAG_CLOSURE);
	   hp <= hp + 1;
	   state <= S_CLOSURE_WRITE_CODE;
	end

	S_CLOSURE_WRITE_CODE: begin
	   $display("CLOSURE: creating closure at heap[%0d] with code=%0d", 
		    hp, closure_codeptr);
	   heap_mem[hp] <= Val_int(closure_codeptr);
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
	   state <= S_DONE;
	end
	
        // ----------------------------
        // Trap wait: handshake to external
        // ----------------------------
        S_TRAP_WAIT: begin
          // keep trap_valid asserted via comb in real design; simplified here:
          if (trap_ready) begin
            accu <= trap_result;
            state <= S_DONE;
          end
        end

	S_DONE:
	  begin
	     $display("  instruction done, acc=%08x", accu);
	     $display("  stack[sp+0]=%08x", stack_mem[sp+0]);
	     $display("  stack[sp+1]=%08x", stack_mem[sp+1]);
	     $display("  stack[sp+2]=%08x", stack_mem[sp+2]);
	     $display("  stack[sp+3]=%08x", stack_mem[sp+3]);
	     $display("  stack[sp+4]=%08x", stack_mem[sp+4]);
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
