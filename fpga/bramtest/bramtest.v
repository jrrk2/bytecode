// Does a block RAM read back what was put in it?
//
// The VM design says no, somewhere, in the open flow: its heap holds the right
// bytes (the bitstream's contents are proved equal to synthesis's) and every
// cell proves equivalent, yet the program reads wrong pointers out of it.  A
// design with a VM, an Ethernet stack and a netboot loader in it cannot say
// which memory shape is at fault, and each experiment costs a 20-minute build.
//
// So: one memory shape per instance, filled with a pattern that makes bit and
// address order visible, read back and compared against the same pattern
// recomputed in logic.  Every shape reports one bit -- did every word match --
// and the UART prints the lot.  What is deliberately included:
//
//   - WIDTHS: 1, 2, 4, 9, 18 and 36 bits, which is where the x1 bug lived and
//     where x2 and x4 have never been tested.
//   - PORTS: read through port B while writing through port A, the shape every
//     memory in the VM has and the one whose width markers nextpnr omits when
//     a port is unused.
//   - ROM: initialised contents never written at run time, read through B --
//     the shape of the VM's code and constant memories.
//
// Build it with Vivado and with the open flow and compare: a shape that fails
// in one and passes in the other is a toolchain bug, named.
`default_nettype none

module bram_case #(
	parameter integer WIDTH = 1,       // bits per word
	parameter integer AW    = 15,      // address bits (depth = 1 << AW)
	parameter integer ROM   = 0        // 1: initialised, never written
) (
	input  wire clk,
	input  wire rst,
	output reg  done,
	output reg  ok,
	// Which bit positions ever came back wrong: x9 puts bit 8 in the parity
	// memory, so "only bit 8" and "the whole word" are different faults.
	output reg [WIDTH-1:0] badbits
);
	localparam integer DEPTH = 1 << AW;

	// The pattern: address in the low bits, its complement above, so a word
	// read from the wrong address or with its bits reordered cannot look
	// right by accident.
	function [WIDTH-1:0] pattern(input [AW-1:0] a);
		reg [63:0] w;
		begin
			w = {~{32'd0, a}, {32'd0, a}} ^ {2{WIDTH[31:0], 32'h9e3779b9}};
			pattern = w[WIDTH-1:0];
		end
	endfunction

	(* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
	integer i;
	initial
		if (ROM)
			for (i = 0; i < DEPTH; i = i + 1) mem[i] = pattern(i[AW-1:0]);

	// Port A writes (unless this is a ROM), port B reads.  Port A never
	// reads, so its READ_WIDTH is unset, and port B never writes, so its
	// WRITE_WIDTH is unset: the shape whose width markers are the question.
	reg [AW-1:0]    a_addr, b_addr;
	reg             a_we;
	reg [WIDTH-1:0] a_data;
	reg [WIDTH-1:0] b_q;

	always @(posedge clk) begin
		if (a_we) mem[a_addr] <= a_data;
		b_q <= mem[b_addr];
	end

	// Fill, then sweep: b_q lags the address by a cycle, so the check runs
	// one behind.
	localparam [1:0] S_FILL = 2'd0, S_READ = 2'd1, S_DONE = 2'd2;
	reg [1:0]       state;
	reg [AW:0]      idx;
	// b_q and addr_d1 are written on the same edge from the same b_addr, so
	// the word and the address it came from stay aligned without counting
	// cycles by hand.
	reg [AW-1:0]    addr_d1;
	reg             presenting, valid_d1;

	always @(posedge clk) begin
		if (rst) begin
			state      <= ROM ? S_READ : S_FILL;
			idx        <= 0;
			a_we       <= 1'b0;
			presenting <= 1'b0;
			valid_d1   <= 1'b0;
			done       <= 1'b0;
			ok         <= 1'b1;
			badbits    <= {WIDTH{1'b0}};
		end else begin
			a_we       <= 1'b0;
			presenting <= 1'b0;
			// What b_q will hold after this edge, and where it came from.
			addr_d1  <= b_addr;
			valid_d1 <= presenting;
			case (state)
				S_FILL: begin
					a_addr <= idx[AW-1:0];
					a_data <= pattern(idx[AW-1:0]);
					a_we   <= 1'b1;
					if (idx == DEPTH - 1) begin
						idx   <= 0;
						state <= S_READ;
					end else idx <= idx + 1'b1;
				end
				S_READ: begin
					b_addr     <= idx[AW-1:0];
					presenting <= 1'b1;
					if (idx == DEPTH - 1) begin
						idx   <= DEPTH;
						state <= S_DONE;
					end else idx <= idx + 1'b1;
				end
				// The last two reads are still in flight when the sweep ends.
				default:
					if (!valid_d1 && !presenting) done <= 1'b1;
			endcase
			if (valid_d1 && b_q !== pattern(addr_d1)) begin
				ok      <= 1'b0;
				badbits <= badbits | (b_q ^ pattern(addr_d1));
			end
		end
	end
endmodule

// simpleuart and friends rely on implicit nets; do not impose this on them.
`default_nettype wire
