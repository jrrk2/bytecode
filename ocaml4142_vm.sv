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
  output logic [23:0]	      imm,
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
    Ptr_of_heap_index = { {(VALUEW-1-HEAP_AW){1'b0}}, idx, 1'b0 };
  endfunction

  function automatic logic [HEAP_AW-1:0] Heap_index_of_ptr(input logic [VALUEW-1:0] ptr);
    Heap_index_of_ptr = ptr[HEAP_AW:1];
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
  typedef enum logic [3:0] {
    S_FETCH      = 4'd0,
    S_DECIDE_IMM = 4'd1,
    S_FETCH_IMM  = 4'd2,
    S_EXEC       = 4'd5,

    // heap write micro-ops
    S_HEAP_ALLOC_HDR = 4'd6,
    S_HEAP_ALLOC_FIELDS = 4'd7,

    // trap / ccall
    S_TRAP_WAIT  = 4'd8
  } state_t;

  state_t state;
  assign state_out = state;
  
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
          imm <= code_rdata[31:8];
          pc     <= pc + 1;
          state  <= S_DECIDE_IMM;
        end

        // ----------------------------
        // Decide how many immediates
        // ----------------------------
        S_DECIDE_IMM: begin
	   if (needs_imm(opcode)) begin
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
            // first imm
	    pc <= pc + 2;
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
              stack_mem[sp] <= accu;
              sp <= sp - 1;
            end

            PUSHACC0: begin stack_mem[sp] <= stack_mem[sp+0]; sp <= sp - 1; accu <= stack_mem[sp+0]; end
            PUSHACC1: begin stack_mem[sp] <= stack_mem[sp+1]; sp <= sp - 1; accu <= stack_mem[sp+1]; end
            PUSHACC2: begin stack_mem[sp] <= stack_mem[sp+2]; sp <= sp - 1; accu <= stack_mem[sp+2]; end
            PUSHACC3: begin stack_mem[sp] <= stack_mem[sp+3]; sp <= sp - 1; accu <= stack_mem[sp+3]; end
            PUSHACC4: begin stack_mem[sp] <= stack_mem[sp+4]; sp <= sp - 1; accu <= stack_mem[sp+4]; end
            PUSHACC5: begin stack_mem[sp] <= stack_mem[sp+5]; sp <= sp - 1; accu <= stack_mem[sp+5]; end
            PUSHACC6: begin stack_mem[sp] <= stack_mem[sp+6]; sp <= sp - 1; accu <= stack_mem[sp+6]; end
            PUSHACC7: begin stack_mem[sp] <= stack_mem[sp+7]; sp <= sp - 1; accu <= stack_mem[sp+7]; end

            PUSHACC: begin
              stack_mem[sp] <= stack_mem[sp + imm];
              sp <= sp - 1;
              accu <= stack_mem[sp + imm];
            end

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

            PUSHENVACC1: begin stack_mem[sp] <= heap_mem[Heap_index_of_ptr(env)+1+1]; sp <= sp-1; accu <= heap_mem[Heap_index_of_ptr(env)+1+1]; end
            PUSHENVACC2: begin stack_mem[sp] <= heap_mem[Heap_index_of_ptr(env)+1+2]; sp <= sp-1; accu <= heap_mem[Heap_index_of_ptr(env)+1+2]; end
            PUSHENVACC3: begin stack_mem[sp] <= heap_mem[Heap_index_of_ptr(env)+1+3]; sp <= sp-1; accu <= heap_mem[Heap_index_of_ptr(env)+1+3]; end
            PUSHENVACC4: begin stack_mem[sp] <= heap_mem[Heap_index_of_ptr(env)+1+4]; sp <= sp-1; accu <= heap_mem[Heap_index_of_ptr(env)+1+4]; end
            PUSHENVACC:  begin stack_mem[sp] <= heap_mem[Heap_index_of_ptr(env)+1+imm]; sp <= sp-1; accu <= heap_mem[Heap_index_of_ptr(env)+1+imm]; end

            // ---- Constants ----
            CONST0: accu <= Val_int(0);
            CONST1: accu <= Val_int(1);
            CONST2: accu <= Val_int(2);
            CONST3: accu <= Val_int(3);

            CONSTINT: accu <= Val_int($signed(imm)); // sign extend imm as small int

            PUSHCONST0: begin stack_mem[sp] <= Val_int(0); sp <= sp-1; accu <= Val_int(0); end
            PUSHCONST1: begin stack_mem[sp] <= Val_int(1); sp <= sp-1; accu <= Val_int(1); end
            PUSHCONST2: begin stack_mem[sp] <= Val_int(2); sp <= sp-1; accu <= Val_int(2); end
            PUSHCONST3: begin stack_mem[sp] <= Val_int(3); sp <= sp-1; accu <= Val_int(3); end
            PUSHCONSTINT: begin stack_mem[sp] <= Val_int($signed(imm)); sp <= sp-1; accu <= Val_int($signed(imm)); end

            // ---- Integer ops ----
            NEGINT:  accu <= Val_int(-Int_val(accu));
            ADDINT:  accu <= Val_int(Int_val(stack_mem[sp+0]) + Int_val(accu)); // expects arg on stack
            SUBINT:  accu <= Val_int(Int_val(stack_mem[sp+0]) - Int_val(accu));
            MULINT:  accu <= Val_int(Int_val(stack_mem[sp+0]) * Int_val(accu));
            DIVINT:  accu <= Val_int(Int_val(stack_mem[sp+0]) / Int_val(accu));
            MODINT:  accu <= Val_int(Int_val(stack_mem[sp+0]) % Int_val(accu));
            ANDINT:  accu <= Val_int(Int_val(stack_mem[sp+0]) & Int_val(accu));
            ORINT:   accu <= Val_int(Int_val(stack_mem[sp+0]) | Int_val(accu));
            XORINT:  accu <= Val_int(Int_val(stack_mem[sp+0]) ^ Int_val(accu));
            LSLINT:  accu <= Val_int(Int_val(stack_mem[sp+0]) <<< Int_val(accu));
            LSRINT:  accu <= Val_int((Int_val(stack_mem[sp+0]) >>> 0) >> Int_val(accu));
            ASRINT:  accu <= Val_int(Int_val(stack_mem[sp+0]) >>> Int_val(accu));

            OFFSETINT: accu <= Val_int(Int_val(accu) + $signed(imm));

            EQ:    accu <= (stack_mem[sp+0] == accu) ? VAL_TRUE : VAL_FALSE;
            NEQ:   accu <= (stack_mem[sp+0] != accu) ? VAL_TRUE : VAL_FALSE;
            LTINT: accu <= (Int_val(stack_mem[sp+0]) <  Int_val(accu)) ? VAL_TRUE : VAL_FALSE;
            LEINT: accu <= (Int_val(stack_mem[sp+0]) <= Int_val(accu)) ? VAL_TRUE : VAL_FALSE;
            GTINT: accu <= (Int_val(stack_mem[sp+0]) >  Int_val(accu)) ? VAL_TRUE : VAL_FALSE;
            GEINT: accu <= (Int_val(stack_mem[sp+0]) >= Int_val(accu)) ? VAL_TRUE : VAL_FALSE;

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

            // ---- Globals ----
            GETGLOBAL: accu <= globals_mem[imm];
            PUSHGETGLOBAL: begin
              stack_mem[sp] <= globals_mem[imm];
              sp <= sp - 1;
              accu <= globals_mem[imm];
            end
            SETGLOBAL: globals_mem[imm] <= accu;

            // ---- Field ops ----
            GETFIELD0: accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + 0];
            GETFIELD1: accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
            GETFIELD2: accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + 2];
            GETFIELD3: accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + 3];
            GETFIELD:  accu <= heap_mem[Heap_index_of_ptr(accu) + 1 + imm];

            SETFIELD0: heap_mem[Heap_index_of_ptr(accu) + 1 + 0] <= stack_mem[sp+0];
            SETFIELD1: heap_mem[Heap_index_of_ptr(accu) + 1 + 1] <= stack_mem[sp+0];
            SETFIELD2: heap_mem[Heap_index_of_ptr(accu) + 1 + 2] <= stack_mem[sp+0];
            SETFIELD3: heap_mem[Heap_index_of_ptr(accu) + 1 + 3] <= stack_mem[sp+0];
            SETFIELD:  heap_mem[Heap_index_of_ptr(accu) + 1 + imm] <= stack_mem[sp+0];

            // ---- Closures ----
            // CLOSURE lbl, nfree:
            // listing provides a label, bytecode provides a relative offset; we treat imm as rel offset in bytes.
            CLOSURE: begin
              // allocate closure block with 2 fields: codeptr + env
              alloc_wosize <= 2;
              alloc_tag    <= TAG_CLOSURE;
              alloc_fields_left <= 2;
              // result pointer becomes accu later
              // store intended fields: field0=pc+imm, field1=env
              // We'll perform in S_HEAP_ALLOC_* using a small protocol.
              alloc_result_ptr <= Ptr_of_heap_index(hp);
              state <= S_HEAP_ALLOC_HDR;

              // stash "pending fields" via regs:
              // field0: code pointer (absolute byte address)
              // NOTE: pc currently points AFTER immediates; for CLOSURE, imm already fetched and pc advanced.
              // In OCaml it uses PC-relative; this is close enough for bring-up if you use same encoding.
              pending_field <= Val_int(pc + $signed(imm)); // store code as int for now
            end

            // CLOSUREREC is complex; for now, treat as TRAP until you implement exact encoding tables.
            CLOSUREREC: begin
              // You can implement later by following interp.c exactly.
              // For factorial you WILL need it; simplest approach: special-case your expected form.
              // For "almost complete", we trap.
              trap_valid <= 1'b1;
              trap_prim  <= 8'hF0; // "unimplemented CLOSUREREC"
              state <= S_TRAP_WAIT;
            end

            // OFFSETCLOSURE0 / OFFSETCLOSURE etc:
            // In real OCaml closures are blocks; OFFSETCLOSUREk loads env[k] / closure pointer arithmetic.
            // Here we interpret OFFSETCLOSURE0 as "accu := env"
            OFFSETCLOSURE0: accu <= env;
            OFFSETCLOSURE3: accu <= heap_mem[Heap_index_of_ptr(env) + 1 + 3];
            OFFSETCLOSUREM3: accu <= heap_mem[Heap_index_of_ptr(env) + 1 + ( -3 )]; // likely invalid; keep placeholder
            OFFSETCLOSURE: accu <= heap_mem[Heap_index_of_ptr(env) + 1 + imm];

            // ---- Calls ----
            // PUSH_RETADDR: push current pc as return addr
            PUSH_RETADDR: begin
              stack_mem[sp] <= Val_int(pc); // store as int for now
              sp <= sp - 1;
            end

            APPLY: begin
              // nargs = imm
              // calling convention: accu is closure
              // push return pc, env, extra_args
              stack_mem[sp] <= Val_int(pc); sp <= sp - 1;
              stack_mem[sp] <= env;         sp <= sp - 1;
              stack_mem[sp] <= Val_int(extra_args); sp <= sp - 1;

              // set up callee
              // closure fields: [0]=code(int), [1]=env(value)
              env <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1 + 0]);
              extra_args <= imm - 1;
            end

            APPLY1: begin
              // like APPLY 1 without immediate
              stack_mem[sp] <= Val_int(pc); sp <= sp - 1;
              stack_mem[sp] <= env;         sp <= sp - 1;
              stack_mem[sp] <= Val_int(extra_args); sp <= sp - 1;
              env <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1 + 0]);
              extra_args <= 8'd0;
            end

            APPLY2: begin
              stack_mem[sp] <= Val_int(pc); sp <= sp - 1;
              stack_mem[sp] <= env;         sp <= sp - 1;
              stack_mem[sp] <= Val_int(extra_args); sp <= sp - 1;
              env <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1 + 0]);
              extra_args <= 8'd1;
            end

            APPLY3: begin
              stack_mem[sp] <= Val_int(pc); sp <= sp - 1;
              stack_mem[sp] <= env;         sp <= sp - 1;
              stack_mem[sp] <= Val_int(extra_args); sp <= sp - 1;
              env <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1 + 0]);
              extra_args <= 8'd2;
            end

            APPTERM: begin
              // imm = nargs, imm_b = framesize
              // pop framesize slots, tailcall to closure in accu
              sp <= sp + imm_b;

              env <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1 + 0]);
              extra_args <= imm - 1;
            end

            APPTERM1: begin
              // framesize is encoded in opcode variant? In OCaml, APPTERM1 n? is specialized; simplify:
              env <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1 + 0]);
              extra_args <= 8'd0;
            end
            APPTERM2: begin
              env <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1 + 0]);
              extra_args <= 8'd1;
            end
            APPTERM3: begin
              env <= heap_mem[Heap_index_of_ptr(accu) + 1 + 1];
              pc  <= Int_val(heap_mem[Heap_index_of_ptr(accu) + 1 + 0]);
              extra_args <= 8'd2;
            end

            RETURN: begin
              // if extra_args > 0, treat as "restart" with decremented extra_args
              if (extra_args != 0) begin
                extra_args <= extra_args - 1;
                // return to function code in accu? (real OCaml uses closure in stack)
                // For now: restore as normal return.
              end else begin
                // pop n locals
                sp <= sp + imm;

                // restore extra_args, env, pc from stack
                // NOTE: with downward-growing stack, adjust indices carefully
                extra_args <= stack_mem[sp + 1][7:0];
                env        <= stack_mem[sp + 2];
                pc         <= Int_val(stack_mem[sp + 3]);
                sp         <= sp + 3;
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
            C_CALL1, C_CALL2, C_CALL3, C_CALL4, C_CALL5, C_CALLN: begin
              // Route to external primitive handler. You can encode "which primitive"
              // using imm for C_CALLN or fixed numbers for C_CALL1..5.
              trap_valid <= 1'b1;
              trap_prim  <= (opcode == C_CALLN) ? imm : 8'hE0; // choose your mapping
              trap_arg0  <= accu;
              trap_arg1  <= stack_mem[sp+0];
              state      <= S_TRAP_WAIT;
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

          // advance to next instruction unless state overridden
          if (state == S_EXEC) state <= S_FETCH;
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
            heap_mem[hp] <= pending_field; // field0
            hp <= hp + 1;
            alloc_fields_left <= alloc_fields_left - 1;
          end else if (alloc_fields_left == alloc_wosize - 1) begin
            heap_mem[hp] <= env; // field1
            hp <= hp + 1;
            alloc_fields_left <= alloc_fields_left - 1;
          end else begin
            // done
            accu <= Ptr_of_heap_index(alloc_base);
            state <= S_FETCH;
          end
        end

        // ----------------------------
        // Trap wait: handshake to external
        // ----------------------------
        S_TRAP_WAIT: begin
          // keep trap_valid asserted via comb in real design; simplified here:
          if (trap_ready) begin
            accu <= trap_result;
            state <= S_FETCH;
          end
        end

        default: state <= S_FETCH;

      endcase
    end
  end

endmodule // ocaml4142_vm
