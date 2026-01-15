module ocaml4142_vm_rtl #(
  parameter int PCW        = 24,    
  parameter int VALUEW     = 32,    
  parameter int STACK_AW   = 16,    
  parameter int HEAP_AW    = 18,    
  parameter int GLOBALS_AW = 12     
)(
  input logic		      clk,
  input logic		      reset,

   
  output logic [PCW-1:0]      pc,
  input logic [31:0]	      code_rdata,

   
  output logic		      trap_valid,
  output logic [7:0]	      trap_prim,  
  output logic [VALUEW-1:0]   trap_arg0,
  output logic [VALUEW-1:0]   trap_arg1,
  input logic		      trap_ready,
  input logic [VALUEW-1:0]    trap_result,
  output logic [VALUEW-1:0]   accu,
  output logic [STACK_AW-1:0] sp,  
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

   
   
 
 
 

 
 

typedef enum logic [7:0] {
   
  ACC0, ACC1, ACC2, ACC3, ACC4, ACC5, ACC6, ACC7,
  ACC, PUSH,
  PUSHACC0, PUSHACC1, PUSHACC2, PUSHACC3,
  PUSHACC4, PUSHACC5, PUSHACC6, PUSHACC7,
  PUSHACC, POP, ASSIGN,
  ENVACC1, ENVACC2, ENVACC3, ENVACC4, ENVACC,
  PUSHENVACC1, PUSHENVACC2, PUSHENVACC3, PUSHENVACC4, PUSHENVACC,
  PUSH_RETADDR, APPLY, APPLY1, APPLY2, APPLY3,
  APPTERM, APPTERM1, APPTERM2, APPTERM3,
  RETURN, RESTART, GRAB,
  CLOSURE, CLOSUREREC,
  OFFSETCLOSUREM3, OFFSETCLOSURE0, OFFSETCLOSURE3, OFFSETCLOSURE,
  PUSHOFFSETCLOSUREM3, PUSHOFFSETCLOSURE0,
  PUSHOFFSETCLOSURE3, PUSHOFFSETCLOSURE,
  GETGLOBAL, PUSHGETGLOBAL, GETGLOBALFIELD, PUSHGETGLOBALFIELD, SETGLOBAL,
  ATOM0, ATOM, PUSHATOM0, PUSHATOM,
  MAKEBLOCK, MAKEBLOCK1, MAKEBLOCK2, MAKEBLOCK3, MAKEFLOATBLOCK,
  GETFIELD0, GETFIELD1, GETFIELD2, GETFIELD3, GETFIELD, GETFLOATFIELD,
  SETFIELD0, SETFIELD1, SETFIELD2, SETFIELD3, SETFIELD, SETFLOATFIELD,
  VECTLENGTH, GETVECTITEM, SETVECTITEM,
  GETBYTESCHAR, SETBYTESCHAR,
  BRANCH, BRANCHIF, BRANCHIFNOT, SWITCH, BOOLNOT,
  PUSHTRAP, POPTRAP, RAISE,
  CHECK_SIGNALS,
  C_CALL1, C_CALL2, C_CALL3, C_CALL4, C_CALL5, C_CALLN,
  CONST0, CONST1, CONST2, CONST3, CONSTINT,
  PUSHCONST0, PUSHCONST1, PUSHCONST2, PUSHCONST3, PUSHCONSTINT,
  NEGINT, ADDINT, SUBINT, MULINT, DIVINT, MODINT,
  ANDINT, ORINT, XORINT, LSLINT, LSRINT, ASRINT,
  EQ, NEQ, LTINT, LEINT, GTINT, GEINT,
  OFFSETINT, OFFSETREF, ISINT,
  GETMETHOD,
  BEQ, BNEQ, BLTINT, BLEINT, BGTINT, BGEINT,
  ULTINT, UGEINT,
  BULTINT, BUGEINT,
  GETPUBMET, GETDYNMET,
  STOP,
  EVENT, BREAK,
  RERAISE, RAISE_NOTRACE,
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
      : opcode_has_imm8 = 1'b1;
    default
      : opcode_has_imm8 = 1'b0;
  endcase
endfunction

function automatic bit opcode_has_imm16(opcode_t op);
  unique case (op)
    APPTERM, CLOSURE, PUSHGETGLOBALFIELD,
      GETGLOBALFIELD, MAKEBLOCK, C_CALLN,
      BEQ, BNEQ, BLTINT, BLEINT, BGTINT, BGEINT,
      BULTINT, BUGEINT, GETPUBMET
      : opcode_has_imm16 = 1'b1;
    default
      : opcode_has_imm16 = 1'b0;
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

  localparam logic [VALUEW-1:0] VAL_FALSE = Val_int(0);
  localparam logic [VALUEW-1:0] VAL_TRUE  = Val_int(1);
  localparam logic [VALUEW-1:0] VAL_UNIT  = Val_int(0);  

   
   
   
   
   
   
  logic [VALUEW-1:0] stack_mem [0:(1<<STACK_AW)-1];
  logic [STACK_AW-1:0] trapsp;     

   
   
   
   
   
   
   
   
  logic [VALUEW-1:0] heap_mem [0:(1<<HEAP_AW)-1];
  logic [HEAP_AW-1:0] hp;          

  function automatic logic [VALUEW-1:0] Make_codeptr(input logic [PCW-1:0] pc);
     Make_codeptr = {pc, 2'b00};  
  endfunction  
   
  function automatic logic [VALUEW-1:0] Ptr_of_heap_index(input logic [HEAP_AW-1:0] idx);
     
    Ptr_of_heap_index = { {(VALUEW-2-HEAP_AW){1'b0}}, idx, 2'b00 };
  endfunction

  function automatic logic [HEAP_AW-1:0] Heap_index_of_ptr(input logic [VALUEW-1:0] ptr);
     
    Heap_index_of_ptr = ptr[HEAP_AW+1:2];
  endfunction

  function automatic logic [PCW-1:0] Codeptr_val(input logic [VALUEW-1:0] ptr);
    Codeptr_val = ptr[PCW+1:2];
  endfunction

   
  function automatic logic [VALUEW-1:0] Make_header(input int wosize, input int tag);
     logic [7:0]      tag8 = tag;
     logic [15:0]     wosize16 = wosize;
     
    Make_header = { wosize16, 8'd0, tag8 };
  endfunction

   
   
   
   
   
  localparam int TAG_CLOSURE = 247;

   
   
   
  logic [VALUEW-1:0]    env;
  logic [7:0]           extra_args;

   

   
   
   
  typedef enum logic [6:0] 
 
{
     
    S_FETCH,
    S_DECIDE_IMM,
    S_FETCH_IMM,
    S_EXEC,
    S_DONE,

     
    S_STACK_READ,            
    S_HEAP_READ,             
    S_GLOBALS_READ,          

     
    S_PUSHACC_WRITE,         
    S_PUSHACC_READ,          
    
     
    S_ENVACC_DONE,           
    S_GETFIELD_DONE,         
    S_OFFSETREF_ADD,         
    S_OFFSETCLOSURE_CALC,    
    
     
    S_MAKEBLOCK_READ_STACK,  
    S_MAKEBLOCK_WRITE_HDR,        
    S_MAKEBLOCK_WRITE_FIELD,     
    
     
    S_MAKEBLOCK1_FIELD,      
    
     
    S_MAKEBLOCK2_HDR,        
    S_MAKEBLOCK2_FIELDS,     
    
     
    S_MAKEBLOCK3_READ_STACK,  
    S_MAKEBLOCK3_HDR,        
    S_MAKEBLOCK3_FIELDS,     
    
     
    S_APPTERM_READ_CODE,     
    S_APPTERM_READ_ARGS,     
    S_APPTERM_WRITE_ARGS,    
    S_APPTERM_SET_PC,        
    
     
    S_APPTERM1_ADJUST,       
    S_APPTERM1_WRITE,        
    S_APPTERM1_SETPC,        
    
     
    S_APPTERM2_READ_ARGS,    
    S_APPTERM2_WRITE_ARGS,   
    S_APPTERM2_SETPC,        
    
     
    S_APPTERM3_READ_ARGS,    
    S_APPTERM3_WRITE_ARGS,   
    S_APPTERM3_SETPC,        
    
     
    S_APPLY_READ_CODE,       
    S_APPLY_WRITE_FRAME,     
    S_APPLY_SET_PC,          
    
     
    S_APPLY1_WRITE_FRAME,    
    S_APPLY1_SETPC,          
    
     
    S_APPLY2_WRITE_FRAME,    
    S_APPLY2_SETPC,          
    
     
    S_APPLY3_WRITE_FRAME,    
    S_APPLY3_SETPC,          
    
     
    S_RETURN_READ_FRAME,     
    S_RETURN_RESTORE,        
    S_RETURN_READ_PC,        
    S_RETURN_READ_ENV,       
    S_RETURN_READ_EXTRA,       
    S_RETURN_SET_STATE,      
    
     
    S_HEAP_ALLOC_HDR,        
    S_HEAP_ALLOC_FIELDS,     
    
     
    S_CLOSURE_ALLOC_HDR,
    S_CLOSURE_WRITE_CODE,
    S_CLOSURE_WRITE_CLOSINFO,
    S_CLOSURE_WRITE_ENV,
    S_CLOSURE_DONE,
    S_CLOSUREREC_CALC,

     
    S_TRAP_WAIT,

     
    S_HEAP_DONE,
    S_OFFSETCLOSURE_READ,
    S_OFFSETCLOSURE_ADD,
     
    S_UNKNOWN
} state_t;

  state_t state;
  assign state_out = state;
  assign tos = stack_mem[sp];
   
  int alloc_fields_left;
  logic [VALUEW-1:0]  alloc_result_ptr;   
  logic               closurerec_push;    

   
   
  logic [VALUEW-1:0] pending_field;

   
   
   
  logic [7:0] imm_b;   
   
  logic [VALUEW-1:0] temp_arg1, temp_arg2, temp_arg3;
  logic [VALUEW-1:0] temp_field1, temp_field2, temp_field3;
  logic [VALUEW-1:0] temp_stack_val;
  logic [VALUEW-1:0] temp_heap_val;
  logic [VALUEW-1:0] temp_return_pc, temp_return_env;
  logic [7:0] temp_extra_args;
  
   
  logic [7:0] op_cycle_count;
  state_t next_state_after_mem;
  logic [7:0] field_write_idx;
  logic [7:0] total_fields_to_write;
  
   
  logic [STACK_AW-1:0] temp_stack_addr;
  logic [HEAP_AW-1:0] temp_heap_addr;
  logic [GLOBALS_AW-1:0] temp_globals_addr;

   
  logic [VALUEW-1:0] globals_mem [0:(1<<GLOBALS_AW)-1];

   
  always_comb begin
    trap_valid = 1'b0;
    trap_prim  = 8'd0;
    trap_arg0  = '0;
    trap_arg1  = '0;
  end

   
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
	 stack_mem[old_sp - 1] <= accu;                
	 sp <= old_sp - 1;
	 if (imm > 0) accu <= stack_mem[(old_sp - 1) + imm];        
      end
   endtask;

   task push_const;
      input [31:0] imm;
      begin
	 logic [31:0] old_sp;
	 old_sp = sp;
	 sp <= old_sp - 1;
	 stack_mem[old_sp - 1] <= accu;   
         accu <= Val_int($signed(imm));   
      end
   endtask;

   task read_acc_from_heap;
      input [31:0] ptr_value, offset_used;
      begin
      logic [VALUEW-1:0] read_value;
       
      $display("  [HEAP_READ] op=%s ptr=0x%08x heap_idx=%d offset=%d", 
	       opcode.name(), ptr_value, Heap_index_of_ptr(ptr_value), offset_used);

       
      read_value = heap_mem[Heap_index_of_ptr(ptr_value) + offset_used];
      $display("  [HEAP_READ] addr=%d value=0x%08x is_header=%b", 
	       Heap_index_of_ptr(ptr_value) + offset_used,
	       read_value,
	       (offset_used == 0));
      accu <= read_value;
      end
   endtask  

   task read_pc_from_heap;
      input [31:0] ptr_value, offset_used;
      begin
      logic [VALUEW-1:0] read_value;
       
      $display("  [HEAP_READ] op=%s ptr=0x%08x heap_idx=%d offset=%d", 
	       opcode.name(), ptr_value, Heap_index_of_ptr(ptr_value), offset_used);

       
      read_value = heap_mem[Heap_index_of_ptr(ptr_value) + offset_used];
      $display("  [HEAP_READ] addr=%d value=0x%08x is_header=%b", 
	       Heap_index_of_ptr(ptr_value) + offset_used,
	       read_value,
	       (offset_used == 0));
      pc <= Codeptr_val(read_value);
      end
   endtask  
   
   task push_env;
      input [31:0] imm;
      begin
	 logic [31:0] old_sp;
	 old_sp = sp;
	 sp <= old_sp - 1;
	 stack_mem[old_sp - 1] <= accu;                
	 read_acc_from_heap(env, 1 + $signed(imm));
      end
   endtask;

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
	 $display("caml_ml_output_char %c (%d)", Int_val(tos), Int_val(tos));
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
	 $display("caml_string_get %x %x", accu, Int_val(tos));
	 accu <= Val_int(1);   
      end
   endtask  
   
   
   
   
   
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

       
      sp         <= (1<<STACK_AW) - 1;
      trapsp     <= (1<<STACK_AW) - 1;

       
      hp         <= '0;
    end else if (!halted) begin
      unique case (state)

         
         
         
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

         
         
         
        S_DECIDE_IMM: begin
	   if (opcode_has_imm8(opcode)) begin
            state <= S_FETCH_IMM;
	   end else if (opcode_has_imm16(opcode) || opcode == CLOSUREREC) begin
              state <= S_FETCH_IMM;
	      if (opcode == CLOSURE) begin
		 nvars   <= code_rdata;
		 pc <= pc + 1;
	      end else if (opcode == CLOSUREREC) begin
		  
		 imm <= code_rdata;   
		 pc <= pc + 1;
	      end else if (opcode == MAKEBLOCK) begin
		  
		 alloc_wosize <= code_rdata;   
		 pc <= pc + 1;
	      end else if (opcode == BEQ || opcode == BNEQ || 
                           opcode == BLTINT || opcode == BLEINT ||
                           opcode == BGTINT || opcode == BGEINT ||
                           opcode == BULTINT || opcode == BUGEINT) begin
		  
		 imm <= code_rdata;
		 pc <= pc + 1;
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

	  
 
 

APPLY1: begin
   stack_mem[sp - 3] <= tos;
   op_cycle_count <= 0;
   state <= S_APPLY1_WRITE_FRAME;
end

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 

 
 
 
 
 
 

	  
 
 

APPLY2: begin
  op_cycle_count <= 0;
  state <= S_APPLY2_WRITE_FRAME;
end

 
APPLY3: begin
  op_cycle_count <= 0;
  state <= S_APPLY3_WRITE_FRAME;
end

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 

 
 
 
 
 
 

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 

 
 
 
 
 
 

	  
 
 

APPTERM1: begin
  temp_arg1 <= tos;
  sp <= sp + imm - 1;
  state <= S_APPTERM1_WRITE;
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
  accu <= Val_int(Int_val(accu) << Int_val(tos));
  sp <= sp + 1;
end

LSRINT: begin
  accu <= Val_int(Int_val(accu) >>> Int_val(tos));
  sp <= sp + 1;
end

ASRINT: begin
  accu <= Val_int($signed(Int_val(accu)) >>> Int_val(tos));
  sp <= sp + 1;
end

 
EQ: begin
  accu <= (accu == tos) ? VAL_TRUE : VAL_FALSE;
  sp <= sp + 1;
end

NEQ: begin
  accu <= (accu != tos) ? VAL_TRUE : VAL_FALSE;
  sp <= sp + 1;
end

LTINT: begin
  accu <= (Int_val(accu) < Int_val(tos)) ? VAL_TRUE : VAL_FALSE;
  sp <= sp + 1;
end

LEINT: begin
  accu <= (Int_val(accu) <= Int_val(tos)) ? VAL_TRUE : VAL_FALSE;
  sp <= sp + 1;
end

GTINT: begin
  accu <= (Int_val(accu) > Int_val(tos)) ? VAL_TRUE : VAL_FALSE;
  sp <= sp + 1;
end

GEINT: begin
  accu <= (Int_val(accu) >= Int_val(tos)) ? VAL_TRUE : VAL_FALSE;
  sp <= sp + 1;
end

 
CONST0: accu <= Val_int(0);
CONST1: accu <= Val_int(1);
CONST2: accu <= Val_int(2);
CONST3: accu <= Val_int(3);
CONSTINT: accu <= Val_int($signed(imm));

 
OFFSETINT: accu <= Val_int(Int_val(accu) + $signed(imm));

 
PUSHCONST0: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  accu <= Val_int(0);
end

PUSHCONST1: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  accu <= Val_int(1);
end

PUSHCONST2: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  accu <= Val_int(2);
end

PUSHCONST3: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  accu <= Val_int(3);
end

PUSHCONSTINT: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  accu <= Val_int($signed(imm));
end

	  
 
 

ASSIGN: begin
  stack_mem[sp + imm] <= accu;
  state <= S_DONE;
end

	  
 

 
BRANCH: begin
  pc <= pc + $signed(offset) - 1;
end

BRANCHIF: begin
  if (accu != VAL_FALSE) begin
    pc <= pc + $signed(offset) - 1;
  end
  accu <= VAL_UNIT;
end

BRANCHIFNOT: begin
  if (accu == VAL_FALSE) begin
    pc <= pc + $signed(offset) - 1;
  end
  accu <= VAL_UNIT;
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
  globals_mem[imm[GLOBALS_AW-1:0]] <= accu;
  accu <= VAL_UNIT;
  state <= S_DONE;
end

	  
 
	    MAKEBLOCK:
	      begin
		 $display("MAKEBLOCK %d,%d", alloc_wosize, alloc_tag);
		 state <= S_HEAP_ALLOC_HDR;
	      end

 

MAKEBLOCK1: begin
  alloc_base <= hp;
  alloc_wosize <= 1;
  alloc_tag <= imm;
  heap_mem[hp] <= Make_header(1, imm);
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
  stack_mem[sp - 1] <= accu;
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
  stack_mem[sp - 1] <= accu;
  temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 1;
  state <= S_HEAP_READ;
  next_state_after_mem <= S_ENVACC_DONE;
end

PUSHENVACC2: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 2;
  state <= S_HEAP_READ;
  next_state_after_mem <= S_ENVACC_DONE;
end

PUSHENVACC3: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 3;
  state <= S_HEAP_READ;
  next_state_after_mem <= S_ENVACC_DONE;
end

PUSHENVACC4: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  temp_heap_addr <= Heap_index_of_ptr(env) + 1 + 4;
  state <= S_HEAP_READ;
  next_state_after_mem <= S_ENVACC_DONE;
end

PUSHENVACC: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  temp_heap_addr <= Heap_index_of_ptr(env) + 1 + imm;
  state <= S_HEAP_READ;
  next_state_after_mem <= S_ENVACC_DONE;
end

	  
 
 

PUSHOFFSETCLOSURE: begin
  sp <= sp - 1;
  stack_mem[sp - 1] <= accu;
  temp_heap_addr <= Heap_index_of_ptr(env) + offset;
  state <= S_HEAP_READ;
  next_state_after_mem <= S_OFFSETCLOSURE_CALC;
end

	  
 
 

RETURN: begin
  temp_stack_addr <= sp + imm - 3;
  op_cycle_count <= 0;
  state <= S_RETURN_READ_FRAME;
end

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 

 
 
 
 
 
 

	  
 
 

SETFIELD0: begin
  heap_mem[Heap_index_of_ptr(accu) + 1 + 0] <= tos;
  state <= S_DONE;
end

SETFIELD1: begin
  heap_mem[Heap_index_of_ptr(accu) + 1 + 1] <= tos;
  state <= S_DONE;
end

SETFIELD2: begin
  heap_mem[Heap_index_of_ptr(accu) + 1 + 2] <= tos;
  state <= S_DONE;
end

SETFIELD3: begin
  heap_mem[Heap_index_of_ptr(accu) + 1 + 3] <= tos;
  state <= S_DONE;
end

SETFIELD: begin
  heap_mem[Heap_index_of_ptr(accu) + 1 + imm] <= tos;
  state <= S_DONE;
end

	    
             
             
             
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
               
		 accu <= VAL_UNIT;
		 sp += 2;
	      end
            
            C_CALL4:
	      begin
               
		 accu <= VAL_UNIT;
		 sp += 3;
	      end
            
            C_CALL5:
	      begin
               
		 accu <= VAL_UNIT;
		 sp += 4;
	      end
            
            C_CALLN: begin
               
              accu <= VAL_UNIT;
		 sp += imm;
            end

	    ATOM0:
	      begin
	      end

	    PUSH_RETADDR:
	      begin
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
                stack_mem[sp - 1] <= accu;
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
                  stack_mem[sp - 1] <= accu;
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
                trap_prim  <= 8'hF0;  
                state <= S_TRAP_WAIT;
              end
            end
             
             
             
            OFFSETCLOSURE0: accu <= env;
            OFFSETCLOSURE3: read_acc_from_heap(env, 1 + 3);
            OFFSETCLOSUREM3: read_acc_from_heap(env, 1 - 3);  
            
             
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

 
	    CHECK_SIGNALS:
	      begin
	      end

            default: begin
              $display("almost complete, unhandled ops go to trap instead of silently wrong behavior.");
              trap_valid <= 1'b1;
              trap_prim  <= 8'hFF;  
              trap_arg0  <= Val_int(opcode);
              state      <= S_TRAP_WAIT;
            end
          endcase
        end

         
         
         
         
        S_HEAP_ALLOC_HDR: begin
          accu <= Ptr_of_heap_index(hp);
          heap_mem[hp] <= Make_header(alloc_wosize, alloc_tag);
          hp <= hp + 1;

           
          alloc_fields_left <= alloc_wosize;
          state <= S_HEAP_ALLOC_FIELDS;
        end

        S_HEAP_ALLOC_FIELDS: begin
 
           
          if (alloc_fields_left == alloc_wosize) begin
             
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
             
            if (opcode == CLOSUREREC) begin
              heap_mem[hp] <= Val_int(2);
            end else if (opcode == CLOSURE) begin
              heap_mem[hp] <= env;  
            end else begin  
	       heap_mem[hp] <= Val_int(0);  
	    end
            hp <= hp + 1;
            alloc_fields_left <= alloc_fields_left - 1;
            
             
            closure_i <= 0;
            
          end else if (alloc_fields_left > 0) begin
             
             
            if (opcode == CLOSUREREC && closure_nvars > 0 && closure_i < closure_nvars) begin
              heap_mem[hp] <= stack_mem[sp + closure_i];
              hp <= hp + 1;
              closure_i <= closure_i + 1;
              alloc_fields_left <= alloc_fields_left - 1;
            end else if (opcode == CLOSURE) begin
               
              alloc_fields_left <= 0;
            end else begin
	       heap_mem[hp] <= tos;
	       sp <= sp + 1;
               alloc_fields_left <= alloc_fields_left - 1;
	    end
            
          end else begin
             
            if (opcode == CLOSUREREC) begin
              if (closure_nvars > 0) begin
                 
                sp <= sp + closure_nvars - 1;
                stack_mem[sp + closure_nvars - 1] <= (accu);
              end else begin
                 
                sp <= sp - 1;
                stack_mem[sp - 1] <= (accu);
              end
              closurerec_push <= 1'b0;
            end else if (closurerec_push) begin
               
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
	   sp <= sp + closure_nvars;   
	   heap_mem[hp] <= 32'hDEADBEEF;
	   hp <= hp + 1;
	   state <= S_DONE;
	end

	S_CLOSUREREC_CALC: begin
	   logic [PCW-1:0] tgt;
	   tgt = $signed(pc) + $signed(offset) - 1;   
	   pending_field <= Make_codeptr(tgt);        
	   state <= S_HEAP_ALLOC_HDR;
	end
	
         
         
         
        S_TRAP_WAIT: begin
	   $finish;
           
          if (trap_ready) begin
            accu <= trap_result;
            state <= S_DONE;
          end
        end

         
         
         

 
	  
 
 
 

 
 
 

S_STACK_READ: begin
   
  accu <= stack_mem[temp_stack_addr];
  state <= next_state_after_mem;
end

S_HEAP_READ: begin
   
  temp_heap_val <= heap_mem[temp_heap_addr];
  state <= next_state_after_mem;
end

S_GLOBALS_READ: begin
   
  accu <= globals_mem[temp_globals_addr];
  state <= next_state_after_mem;
end

 
 
 

S_PUSHACC_WRITE: begin
   
  stack_mem[sp - 1] <= accu;
  sp <= sp - 1;
  state <= S_PUSHACC_READ;
end

S_PUSHACC_READ: begin
   
  accu <= stack_mem[temp_stack_addr];
  state <= S_DONE;
end

 
 
 

S_ENVACC_DONE: begin
  accu <= temp_heap_val;
  state <= S_DONE;
end

S_GETFIELD_DONE: begin
  accu <= temp_heap_val;
  state <= S_DONE;
end

S_OFFSETREF_ADD: begin
  accu <= accu + Int_val(temp_stack_val) * 2;
  state <= S_DONE;
end

S_OFFSETCLOSURE_CALC: begin
  accu <= Ptr_of_heap_index(Heap_index_of_ptr(temp_heap_val) + offset);
  state <= S_DONE;
end

 
 
 

S_MAKEBLOCK1_FIELD: begin
  heap_mem[hp] <= accu;
  hp <= hp + 1;
  accu <= Ptr_of_heap_index(alloc_base);
  state <= S_DONE;
end

 
 
 

S_MAKEBLOCK2_HDR: begin
  temp_field1 <= temp_heap_val;   
  heap_mem[hp] <= Make_header(2, alloc_tag);
  hp <= hp + 1;
  field_write_idx <= 0;
  state <= S_MAKEBLOCK2_FIELDS;
end

S_MAKEBLOCK2_FIELDS: begin
  case (field_write_idx)
    0: begin
      heap_mem[hp] <= accu;
      hp <= hp + 1;
      field_write_idx <= 1;
    end
    1: begin
      heap_mem[hp] <= temp_field1;
      hp <= hp + 1;
      sp <= sp + 1;
      accu <= Ptr_of_heap_index(alloc_base);
      state <= S_DONE;
    end
  endcase
end

 
 
 

S_MAKEBLOCK3_READ_STACK: begin
  case (op_cycle_count)
    0: begin
      temp_field1 <= stack_mem[sp];
      op_cycle_count <= 1;
    end
    1: begin
      temp_field2 <= stack_mem[sp + 1];
      state <= S_MAKEBLOCK3_HDR;
    end
  endcase
end

S_MAKEBLOCK3_HDR: begin
  heap_mem[hp] <= Make_header(3, alloc_tag);
  hp <= hp + 1;
  field_write_idx <= 0;
  state <= S_MAKEBLOCK3_FIELDS;
end

S_MAKEBLOCK3_FIELDS: begin
  case (field_write_idx)
    0: begin
      heap_mem[hp] <= accu;
      hp <= hp + 1;
      field_write_idx <= 1;
    end
    1: begin
      heap_mem[hp] <= temp_field1;
      hp <= hp + 1;
      field_write_idx <= 2;
    end
    2: begin
      heap_mem[hp] <= temp_field2;
      hp <= hp + 1;
      sp <= sp + 2;
      accu <= Ptr_of_heap_index(alloc_base);
      state <= S_DONE;
    end
  endcase
end

 
 
S_APPTERM1_WRITE: begin
  stack_mem[sp] <= temp_arg1;
  temp_heap_addr <= Heap_index_of_ptr(accu) + 1;
  state <= S_HEAP_READ;
  next_state_after_mem <= S_APPTERM1_SETPC;
end

S_APPTERM1_SETPC: begin
  pc <= Codeptr_val(temp_heap_val);
  env <= accu;
  state <= S_DONE;
end

 
 
 

S_APPTERM2_READ_ARGS: begin
  case (op_cycle_count)
    0: begin
      temp_arg1 <= stack_mem[sp];
      op_cycle_count <= 1;
    end
    1: begin
      temp_arg2 <= stack_mem[sp + 1];
      sp <= sp + imm - 2;
      op_cycle_count <= 0;
      state <= S_APPTERM2_WRITE_ARGS;
    end
  endcase
end

S_APPTERM2_WRITE_ARGS: begin
  case (op_cycle_count)
    0: begin
      stack_mem[sp] <= temp_arg1;
      op_cycle_count <= 1;
    end
    1: begin
      stack_mem[sp + 1] <= temp_arg2;
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

 
 
 

S_APPTERM3_READ_ARGS: begin
  case (op_cycle_count)
    0: begin
      temp_arg1 <= stack_mem[sp];
      op_cycle_count <= 1;
    end
    1: begin
      temp_arg2 <= stack_mem[sp + 1];
      op_cycle_count <= 2;
    end
    2: begin
      temp_arg3 <= stack_mem[sp + 2];
      sp <= sp + imm - 3;
      op_cycle_count <= 0;
      state <= S_APPTERM3_WRITE_ARGS;
    end
  endcase
end

S_APPTERM3_WRITE_ARGS: begin
  case (op_cycle_count)
    0: begin
      stack_mem[sp + imm - 3] <= temp_arg1;
      op_cycle_count <= 1;
    end
    1: begin
      stack_mem[sp + imm - 2] <= temp_arg2;
      op_cycle_count <= 2;
    end
    2: begin
      stack_mem[sp + imm - 1] <= temp_arg3;
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
      stack_mem[sp - 2] <= Make_codeptr(pc);
      op_cycle_count <= 1;
    end
    1: begin
      stack_mem[sp - 1] <= env;
      op_cycle_count <= 2;
    end
    2: begin
      stack_mem[sp - 0] <= Val_int(extra_args);
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

 
 
 

S_APPLY2_WRITE_FRAME: begin
  case (op_cycle_count)
    0: begin
      sp <= sp - 1;
      stack_mem[sp - 1] <= Make_codeptr(pc);
      op_cycle_count <= 1;
    end
    1: begin
      sp <= sp - 1;
      stack_mem[sp - 1] <= env;
      op_cycle_count <= 2;
    end
    2: begin
      sp <= sp - 1;
      stack_mem[sp - 1] <= Val_int(extra_args);
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

 
 
 

S_APPLY3_WRITE_FRAME: begin
  case (op_cycle_count)
    0: begin
      sp <= sp - 1;
      stack_mem[sp - 1] <= Make_codeptr(pc);
      op_cycle_count <= 1;
    end
    1: begin
      sp <= sp - 1;
      stack_mem[sp - 1] <= env;
      op_cycle_count <= 2;
    end
    2: begin
      sp <= sp - 1;
      stack_mem[sp - 1] <= Val_int(extra_args);
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

 
 
 

S_RETURN_READ_FRAME: begin
  case (op_cycle_count)
    0: begin
      temp_return_pc <= stack_mem[sp + imm];
      op_cycle_count <= 1;
    end
    1: begin
      temp_return_env <= stack_mem[sp + imm + 1];
      op_cycle_count <= 2;
    end
    2: begin
      temp_extra_args <= Int_val(stack_mem[sp + imm + 2]);
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

endmodule  

