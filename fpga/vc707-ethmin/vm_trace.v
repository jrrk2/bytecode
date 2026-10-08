// vm_trace: a ring buffer of the VM's recent history, kept by hardware so that it is there when the VM is not
// answering.  A record is written whenever the VM's state or pc changes; the buffer is frozen when the VM
// halts or a dump is asked for, and a dump prints the records oldest first, one line each, as 18 hex digits
//
//   [71:64] state number   [63:56] opcode   [55:32] pc   [31:16] sp   [15:0] accu (low 16 bits)
//
// through the byte stream the core puts on the UART (tools/decode_trace.py names the states and opcodes from
// the VM's own enumerations).  Debug RAM: inferred block RAM, on purpose -- it is not part of the machine and
// nothing patches its contents.
`default_nettype none
module vm_trace #(
	parameter integer DEPTH_LOG2 = 12
) (
	input  wire        clk,
	input  wire        resetn,
	input  wire [6:0]  state,
	input  wire [23:0] pc,
	input  wire [14:0] sp,
	input  wire [35:0] accu,
	input  wire [7:0]  opcode,
	input  wire        halted,
	input  wire        freeze,         // a pulse: stop recording now (the first fetch outside the program, say)
	input  wire        dump_req,       // a pulse: freeze, then print everything
	output wire [7:0]  out_byte,
	output wire        out_valid,      // out_byte is a character to send
	input  wire        out_ready       // and it is taken in a cycle when both are high
);
	localparam integer DEPTH = 1 << DEPTH_LOG2;
	(* ram_style = "block" *) reg [71:0] mem [0:DEPTH-1];
	reg [DEPTH_LOG2-1:0] wp;
	reg        wrapped, frozen;
	reg [6:0]  last_state;
	reg [23:0] last_pc;
	reg [71:0] rec_q;

	wire [71:0] rec_in = {1'b0, state, opcode, pc, 1'b0, sp, accu[15:0]};
	wire changed = (state != last_state) || (pc != last_pc);

	// dump
	localparam [2:0] D_IDLE = 3'd0, D_READ = 3'd1, D_WAIT = 3'd2, D_HEX = 3'd3, D_CR = 3'd4, D_LF = 3'd5;
	reg [2:0] d;
	reg [DEPTH_LOG2:0] left;           // records still to print
	reg [DEPTH_LOG2-1:0] ra;           // the one being read
	reg [4:0] digit;                   // 0..17

	always @(posedge clk) begin
		last_state <= state;
		last_pc    <= pc;
		if (!resetn) begin
			wp <= 0; wrapped <= 1'b0; frozen <= 1'b0; d <= D_IDLE;
		end else begin
			if (halted || freeze) frozen <= 1'b1;
			if (!frozen && changed) begin
				mem[wp] <= rec_in;
				wp <= wp + 1'b1;
				if (wp == DEPTH - 1) wrapped <= 1'b1;
			end
			rec_q <= mem[ra];
			case (d)
				D_IDLE: if (dump_req) begin
					frozen <= 1'b1;
					ra     <= wrapped ? wp : {DEPTH_LOG2{1'b0}};
					left   <= wrapped ? DEPTH : {1'b0, wp};
					d      <= (wrapped || wp != 0) ? D_READ : D_IDLE;
				end
				D_READ: d <= D_WAIT;
				D_WAIT: begin digit <= 5'd0; d <= D_HEX; end
				D_HEX: if (out_ready) begin
					if (digit == 5'd17) d <= D_CR; else digit <= digit + 5'd1;
				end
				D_CR: if (out_ready) d <= D_LF;
				D_LF: if (out_ready) begin
					ra   <= ra + 1'b1;
					left <= left - 1'b1;
					d    <= (left == 1) ? D_IDLE : D_READ;
				end
				default: d <= D_IDLE;
			endcase
		end
	end

	assign out_valid = (d == D_HEX) || (d == D_CR) || (d == D_LF);
	assign out_byte  = (d == D_CR) ? 8'h0D : (d == D_LF) ? 8'h0A : hexchar(rec_q[71 - 4 * digit -: 4]);

	function [7:0] hexchar(input [3:0] n);
		hexchar = (n < 10) ? 8'h30 + n : 8'h41 + n - 10;
	endfunction
endmodule
`default_nettype wire
