// Multi-block read and write through sd_data_serial_host (4-bit bus) against a behavioural card.
// iverilog -g2012 -I.. -o tb tb_multi.sv ../sd_data_serial_host.sv ../sd_crc_16.v && vvp tb
`timescale 1ns/1ps
module tb_multi;
	localparam NB = 3;
	parameter ZERO = 0;                      // 1: all-zero data, whose CRC is zero too                       // blocks per transfer
	reg sd_clk = 0, rst = 1;
	always #5 sd_clk = ~sd_clk;
	reg  [31:0] mem [0:1023];                // the 4 KB buffer as the wrapper has it: address steps on rd|we at the falling edge
	reg  [9:0]  addr = 0;
	reg  [31:0] dq;
	wire [31:0] data_out; wire we, rd;
	wire [3:0]  dat_o; wire dat_oe;
	reg  [3:0]  card_dat = 4'hF;                // what the card drives (0 = pulled up when nobody drives)
	parameter LAT = 5;                      // pad + synchroniser delay of the board, in SD clocks, on everything the host sees
	wire [3:0] bus = dat_oe ? dat_o : card_dat;
	reg  [3:0] bus_d [0:LAT-1];
	integer q;
	always @(posedge sd_clk) begin bus_d[0] <= bus; for (q = 1; q < LAT; q = q + 1) bus_d[q] <= bus_d[q-1]; end
	wire [3:0] dat_i = bus_d[LAT-1];
	reg  [1:0]  start = 0;
	wire        crc_ok, finish, busy, dbusy;
	wire [31:0] wait_o; wire [15:0] cnt;
	sd_data_serial_host dut(.sd_clk(sd_clk), .rst(rst), .data_in(dq), .rd(rd), .data_out(data_out), .we(we),
		.DAT_oe_o(dat_oe), .DAT_dat_o(dat_o), .DAT_dat_i(dat_i), .blksize(12'd512), .bus_4bit(1'b1), .blkcnt(16'(NB)),
		.start(start), .byte_alignment(2'b00), .timeout_i(32'd100000), .sd_data_busy(dbusy), .busy(busy), .crc_ok(crc_ok),
		.finish_o(finish), .wait_reg_o(wait_o), .transf_cnt_o(cnt));
	always @(negedge sd_clk) begin
		if (we) mem[addr] <= data_out;
		if (rd | we) begin dq <= mem[addr]; addr <= addr + 1; end
	end

	function [15:0] crc16(input [15:0] c, input b);
		reg inv; begin inv = b ^ c[15]; crc16 = {c[14:0], 1'b0} ^ (inv ? 16'h1021 : 16'h0); end
	endfunction

	reg [7:0] ref_data [0:512*NB-1];
	integer i, b, errors = 0;

	// ---- the card sends NB blocks back to back ----
	reg [15:0] cc [0:3];
	task send_nibble(input [3:0] n); begin @(negedge sd_clk); card_dat = n; end endtask
	task card_read_blocks;
		integer blk, j, l;
		reg [3:0] nib;
		begin
			repeat (12) @(negedge sd_clk);               // the command's response comes first
			for (blk = 0; blk < NB; blk = blk + 1) begin
				for (l = 0; l < 4; l = l + 1) cc[l] = 0;
				send_nibble(4'h0);
				for (j = 0; j < 512; j = j + 1) begin
					nib = ref_data[blk*512 + j][7:4]; for (l = 0; l < 4; l = l + 1) cc[l] = crc16(cc[l], nib[l]); send_nibble(nib);
					nib = ref_data[blk*512 + j][3:0]; for (l = 0; l < 4; l = l + 1) cc[l] = crc16(cc[l], nib[l]); send_nibble(nib);
				end
				for (j = 15; j >= 0; j = j - 1) send_nibble({cc[3][j], cc[2][j], cc[1][j], cc[0][j]});
				send_nibble(4'hF);                           // end bit; the next block's start bit follows at once
			end
			card_dat = 4'hF;
		end
	endtask

	// ---- the card receives NB blocks, checks them and their CRC, acks and goes busy ----
	reg [7:0] got [0:512*NB-1];
	integer crc_errs = 0;
	task card_write_blocks;
		integer blk, j, l;
		reg [3:0] nib; reg [15:0] rc [0:3];
		begin
			for (blk = 0; blk < NB; blk = blk + 1) begin
				for (l = 0; l < 4; l = l + 1) cc[l] = 0;
				@(negedge sd_clk); while (!(dat_oe && dat_o[0] == 0)) @(negedge sd_clk);       // start bit
				for (j = 0; j < 512; j = j + 1) begin
					@(negedge sd_clk); nib = dat_o; got[blk*512 + j][7:4] = nib; for (l = 0; l < 4; l = l + 1) cc[l] = crc16(cc[l], nib[l]);
					@(negedge sd_clk); nib = dat_o; got[blk*512 + j][3:0] = nib; for (l = 0; l < 4; l = l + 1) cc[l] = crc16(cc[l], nib[l]);
				end
				for (l = 0; l < 4; l = l + 1) rc[l] = 0;
				for (j = 15; j >= 0; j = j - 1) begin @(negedge sd_clk); for (l = 0; l < 4; l = l + 1) rc[l][j] = dat_o[l]; end
				for (l = 0; l < 4; l = l + 1) if (rc[l] != cc[l]) crc_errs = crc_errs + 1;
				@(negedge sd_clk);                           // end bit
				@(negedge sd_clk); card_dat = 4'hE;             // status token: start 0, 010, end 1, then busy
				@(negedge sd_clk); card_dat = 4'hE;
				@(negedge sd_clk); card_dat = 4'hF;
				@(negedge sd_clk); card_dat = 4'hE;
				@(negedge sd_clk); card_dat = 4'hF;
				repeat (20) begin @(negedge sd_clk); card_dat = 4'hE; end
				@(negedge sd_clk); card_dat = 4'hF;
			end
		end
	endtask

	integer w; reg fin, ok;
	initial begin
		for (i = 0; i < 512*NB; i = i + 1) ref_data[i] = ZERO ? 8'h00 : (i * 7 + (i >> 8) * 13 + 5) & 255;
		repeat (4) @(negedge sd_clk); rst = 0; repeat (4) @(negedge sd_clk);

		// read
		for (i = 0; i < 1024; i = i + 1) mem[i] = 0;
		addr = 0; @(negedge sd_clk); start = 2'b10;
		fork card_read_blocks; join_none
		w = 0; while (!finish && w < 40000) begin @(posedge sd_clk); w = w + 1; end
		fin = finish; ok = crc_ok;
		@(negedge sd_clk); start = 0; repeat (4) @(posedge sd_clk);
		$display("read: finish=%b crc_ok=%b after %0d clocks", fin, ok, w);
		if (!fin || !ok) errors = errors + 1;
		for (i = 0; i < 128*NB; i = i + 1)
			if (mem[i] !== {ref_data[4*i], ref_data[4*i+1], ref_data[4*i+2], ref_data[4*i+3]}) begin
				if (errors < 10) $display("read word %0d: %h want %h", i, mem[i], {ref_data[4*i], ref_data[4*i+1], ref_data[4*i+2], ref_data[4*i+3]});
				errors = errors + 1;
			end
		repeat (50) @(posedge sd_clk);
		disable fork;

		// write
		for (i = 0; i < 128*NB; i = i + 1) mem[i] = {ref_data[4*i], ref_data[4*i+1], ref_data[4*i+2], ref_data[4*i+3]};
		rst = 1; repeat (3) @(negedge sd_clk); rst = 0; card_dat = 4'hF; addr = 0; dq = mem[0];
		repeat (3) @(negedge sd_clk);
		start = 2'b01;
		fork card_write_blocks; join_none
		w = 0; while (!finish && w < 80000) begin @(posedge sd_clk); w = w + 1; end
		fin = finish;
		@(negedge sd_clk); start = 0; repeat (4) @(posedge sd_clk);
		$display("write: finish=%b after %0d clocks, card CRC errors %0d", fin, w, crc_errs);
		if (!fin || crc_errs != 0) errors = errors + 1;
		for (i = 0; i < 512*NB; i = i + 1)
			if (got[i] !== ref_data[i]) begin
				if (errors < 10) $display("write byte %0d: %h want %h", i, got[i], ref_data[i]);
				errors = errors + 1;
			end
		if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
		$finish;
	end
	initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
