module ocaml4142_top #(
  parameter int PCW      = 24,
  parameter int VALUEW   = 32,
  parameter int STACK_AW = 16
)(
  input  logic               clk,
  input  logic               reset,

  // Bytecode fetch
  output logic [PCW-1:0]     code_addr,
  input  logic [7:0]         code_rdata,

  // Primitive / trap interface
  output logic               trap_valid,
  output logic [7:0]         trap_prim,
  output logic [VALUEW-1:0]  trap_arg0,
  output logic [VALUEW-1:0]  trap_arg1,
  input  logic               trap_ready,
  input  logic [VALUEW-1:0]  trap_result,

  // Status
  output logic               halted,

  // ---- Debug (for Verilator only) ----
  output logic [PCW-1:0]     dbg_pc,
  output logic [7:0]         dbg_opcode,
  output logic [VALUEW-1:0]  dbg_accu,
  output logic [STACK_AW-1:0] dbg_sp
);

  // Internal registers
  logic [PCW-1:0]     pc;
  logic [7:0]         opcode;
  logic [VALUEW-1:0]  accu;
  logic [STACK_AW-1:0] sp;

  // FSM state, env, etc. omitted here for brevity

  // ----------------------------
  // Fetch
  // ----------------------------
  assign code_addr = pc;

  always_ff @(posedge clk) begin
    if (reset) begin
      pc     <= '0;
      halted <= 1'b0;
    end else if (!halted) begin
      opcode <= code_rdata;
      pc     <= pc + 1;
    end
  end

  // ----------------------------
  // Execute (sketch)
  // ----------------------------
  always_ff @(posedge clk) begin
    if (!reset && !halted) begin
      case (opcode)
        STOP: halted <= 1'b1;
        default: ;
      endcase
    end
  end

  // ----------------------------
  // Debug taps
  // ----------------------------
  assign dbg_pc     = pc;
  assign dbg_opcode = opcode;
  assign dbg_accu   = accu;
  assign dbg_sp     = sp;

endmodule // ocaml4142_top
