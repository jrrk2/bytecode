// sd_wrap: the lowRISC SD host (../sd-lowrisc, unmodified) for this machine.
//
// What lowRISC's periph_soc.sv does around sd_top, redone for a byte-wide I/O space: a register file the processor writes and
// reads, a 4 KB dual-port buffer in which each 512-byte block waits to be read or has been written, the pads, and the SD clock.
// The meaning of the registers is the Linux driver's (drivers/mmc/host/lowrisc_sd.c) and the bare-metal one's
// (bare_metal/examples/drivers/mmc/lowrisc_mmc.c).
//
// Registers: 32 bits each, visible as two 16-bit halves (an OCaml int here has 31 bits): the register with index n is at I/O
// 0x1100 + 2n (bits 15:0) and 0x1100 + 2n + 1 (bits 31:16).  Writes:
//    0 align  1 clock divider (8 bits; SD clock = clk / (2 * (n + 1)))  2 argument  3 command index  4 {data_start, setting}
//    5 start  6 {sd_reset, clk_en, data_run, cmd_run}  7 block count  8 block size  9 timeout (SD clocks)
// Reads:
//    0-3 response words 0..3  4 command wait count  5 status  6,7 packet  8 data wait count  9 transfer count
//    12 card detect (1: no card)  13 buffer transfer address  14 {finish_data, finish_cmd}   (the same index as the write)
// reg 6 bits are "not in reset": the command engine runs when bit 0 is 1, the data engine when bit 1 is 1, the SD clock pad
// drives when bit 2 is 1.  The 4 KB buffer is at I/O 0x2000, a byte per address.
`default_nettype none
module sd_wrap (
	input  wire        clk,            // clk_sys
	input  wire        resetn,
	// processor side
	input  wire        reg_write,      // a write to 0x1100.. (reg_addr valid)
	input  wire [6:0]  reg_addr,       // io_addr[6:0] - 0x00: bit 0 selects the half
	input  wire [15:0] reg_wdata,
	output reg  [15:0] reg_rdata,      // combinational in reg_addr
	input  wire        buf_en,
	input  wire        buf_write,
	input  wire [11:0] buf_addr,       // byte address in the 4 KB buffer
	input  wire [7:0]  buf_wdata,
	output wire [7:0]  buf_rdata,      // the cycle after buf_en
	// pads
	output wire        sd_sclk,
	inout  wire        sd_cmd,
	inout  wire [3:0]  sd_dat,
	input  wire        sd_detect
);
	// ---- registers, clk domain ----
	reg [31:0] r_align, r_arg, r_cmd, r_setting, r_blkcnt, r_blksize, r_timeout;
	reg [7:0]  r_div;
	reg [31:0] r_start;
	reg [3:0]  r_reset;               // {sd_reset, clk_en, data_run, cmd_run}
	wire [4:0] widx = reg_addr[5:1];
	wire       hi   = reg_addr[0];

	function [31:0] upd(input [31:0] old, input h, input [15:0] d);
		upd = h ? {d, old[15:0]} : {old[31:16], d};
	endfunction

	always @(posedge clk) begin
		if (!resetn) begin
			r_align <= 0; r_arg <= 0; r_cmd <= 0; r_setting <= 0; r_blkcnt <= 0; r_blksize <= 0;
			r_timeout <= 32'd15; r_div <= 8'd77; r_start <= 0; r_reset <= 4'd0;
		end else if (reg_write) begin
			case (widx)
				5'd0:  r_align   <= upd(r_align, hi, reg_wdata);
				5'd1:  if (!hi) r_div <= reg_wdata[7:0];      // 8-bit and 4-bit registers: only the low half
				5'd2:  r_arg     <= upd(r_arg, hi, reg_wdata);
				5'd3:  r_cmd     <= upd(r_cmd, hi, reg_wdata);
				5'd4:  r_setting <= upd(r_setting, hi, reg_wdata);
				5'd5:  r_start   <= upd(r_start, hi, reg_wdata);
				5'd6:  if (!hi) r_reset <= reg_wdata[3:0];
				5'd7:  r_blkcnt  <= upd(r_blkcnt, hi, reg_wdata);
				5'd8:  r_blksize <= upd(r_blksize, hi, reg_wdata);
				5'd9:  r_timeout <= upd(r_timeout, hi, reg_wdata);
				default: ;
			endcase
		end
	end

	// ---- the SD clock: the divided clock of lowRISC's sd_clock_divider, running only while clk_en is set ----
	wire sd_clk;
	sd_clock_divider sdclk_div (.CLK(clk), .DIVIDER(r_div), .RST(!resetn || !r_reset[2]), .SD_CLK(sd_clk));

	// ---- registers into the SD clock domain (quasi-static: software writes them, then starts) ----
	reg [31:0] s_align, s_arg, s_cmd, s_setting, s_start, s_blkcnt, s_blksize, s_timeout;
	always @(posedge sd_clk) begin
		s_align <= r_align; s_arg <= r_arg; s_cmd <= r_cmd; s_setting <= r_setting;
		s_start <= r_start; s_blkcnt <= r_blkcnt; s_blksize <= r_blksize; s_timeout <= r_timeout;
	end

	// ---- pad inputs, two flops on clk (the SD clock is much slower), into the SD clock domain ----
	wire cmd_in_pad, dat_in_pad0, dat_in_pad1, dat_in_pad2, dat_in_pad3;
	reg [1:0] cmd_sync;
	reg [3:0] dat_sync0, dat_sync1;
	always @(posedge clk) begin
		cmd_sync  <= {cmd_sync[0], cmd_in_pad};
		dat_sync0 <= {dat_in_pad3, dat_in_pad2, dat_in_pad1, dat_in_pad0};
		dat_sync1 <= dat_sync0;
	end
	wire       sd_cmd_to_host = cmd_sync[1];
	wire [3:0] sd_dat_to_host = dat_sync1;

	// ---- the controller ----
	wire        tx_rd, rx_wr_en, sd_cmd_oe, sd_dat_oe, sd_cmd_to_mem;
	wire [3:0]  sd_dat_to_mem;
	wire [31:0] data_in_rx, data_out_tx;
	wire [9:0]  sd_xfr_addr;
	wire [31:0] response0, wait_o, wait_data_o, packet0;
	wire [63:32] response1;
	wire [95:64] response2;
	wire [126:96] response3;
	wire [31:4] status_o;
	wire [15:0] packet1, transf_cnt;
	wire [6:0]  crc_val, crc_actual;
	wire        finish_cmd, finish_data, crc_ok, index_ok;

	sd_top sdtop (
		.sd_clk(sd_clk),
		.cmd_rst(~(r_reset[0] & resetn)),
		.data_rst(~(r_reset[1] & resetn)),
		.setting_i(s_setting[2:0]),
		.start_i(s_start[0]),
		.arg_i(s_arg),
		.cmd_i(s_cmd[5:0]),
		.timeout_i(s_timeout),
		.sd_data_start_i(s_setting[5:3]),
		.sd_align_i(s_align[1:0]),
		.sd_blkcnt_i(s_blkcnt[15:0]),
		.sd_blksize_i(s_blksize[11:0]),
		.sd_data_i(data_out_tx),
		.sd_dat_to_host(sd_dat_to_host),
		.sd_cmd_to_host(sd_cmd_to_host),
		.response0_o(response0), .response1_o(response1), .response2_o(response2), .response3_o(response3),
		.wait_o(wait_o), .wait_data_o(wait_data_o), .status_o(status_o),
		.packet0_o(packet0), .packet1_o(packet1),
		.crc_val_o(crc_val), .crc_actual_o(crc_actual),
		.finish_cmd_o(finish_cmd), .finish_data_o(finish_data), .crc_ok_o(crc_ok), .index_ok_o(index_ok),
		.sd_rd_o(tx_rd), .sd_we_o(rx_wr_en), .sd_data_o(data_in_rx), .transf_cnt_o(transf_cnt),
		.sd_dat_to_mem(sd_dat_to_mem), .sd_cmd_to_mem(sd_cmd_to_mem),
		.sd_cmd_oe(sd_cmd_oe), .sd_dat_oe(sd_dat_oe), .sd_xfr_addr(sd_xfr_addr));

	// ---- pads: open-drain command and data lines, the clock driven only while enabled ----
	IOBUF #(.IOSTANDARD("LVCMOS18"), .SLEW("FAST")) cmd_iobuf (.IO(sd_cmd), .I(sd_cmd_to_mem), .O(cmd_in_pad), .T(~sd_cmd_oe));
	IOBUF #(.IOSTANDARD("LVCMOS18"), .SLEW("FAST")) dat0_iobuf (.IO(sd_dat[0]), .I(sd_dat_to_mem[0]), .O(dat_in_pad0), .T(~sd_dat_oe));
	IOBUF #(.IOSTANDARD("LVCMOS18"), .SLEW("FAST")) dat1_iobuf (.IO(sd_dat[1]), .I(sd_dat_to_mem[1]), .O(dat_in_pad1), .T(~sd_dat_oe));
	IOBUF #(.IOSTANDARD("LVCMOS18"), .SLEW("FAST")) dat2_iobuf (.IO(sd_dat[2]), .I(sd_dat_to_mem[2]), .O(dat_in_pad2), .T(~sd_dat_oe));
	IOBUF #(.IOSTANDARD("LVCMOS18"), .SLEW("FAST")) dat3_iobuf (.IO(sd_dat[3]), .I(sd_dat_to_mem[3]), .O(dat_in_pad3), .T(~sd_dat_oe));
	OBUFT #(.IOSTANDARD("LVCMOS18"), .SLEW("FAST")) sclk_obuf (.O(sd_sclk), .I(~sd_clk), .T(~r_reset[2]));

	// ---- the 4 KB buffer, 64 bits wide: the SD side (negedge of the SD clock) and the processor side (clk, byte writes) ----
	reg        xfr_prev;
	always @(negedge sd_clk) if (tx_rd) xfr_prev <= sd_xfr_addr[0];
	wire [63:0] douta, doutb;
	wire [31:0] swapbein = {data_in_rx[7:0], data_in_rx[15:8], data_in_rx[23:16], data_in_rx[31:24]};
	wire [63:0] dina = {swapbein, swapbein};
	wire [7:0]  rx_wr = rx_wr_en ? (sd_xfr_addr[0] ? 8'hF0 : 8'h0F) : 8'h00;
	assign data_out_tx = xfr_prev ? {douta[39:32], douta[47:40], douta[55:48], douta[63:56]}
	                              : {douta[7:0], douta[15:8], douta[23:16], douta[31:24]};
	// Explicit RAMB36E1, as the retarget wrappers (Vivado's RAMB36.v) build them: two true-dual-port blocks at x36 (32 data bits, the
	// parity bits unused), the low and high halves of each 64-bit word, 512 of the 1024 words.  The buffer holds scratch data only,
	// nothing that a bitstream patch would ever replace.  Port A is the SD side, on the falling edge of the SD clock (the block
	// inverts its clock); port B is the processor side.  Both READ_FIRST with registered output, which is what the always blocks
	// this replaces did.  Inference could not do it: yosys finds no mapping for a true-dual-port RAM whose ports are on two clocks
	// (unless the write/read collision check is waived), and a byte-write-enabled one is two blocks wide anyway.
	wire [63:0] doutb_w;
	reg [2:0]  lane_q;
	wire [7:0] web = (buf_en && buf_write) ? (8'd1 << buf_addr[2:0]) : 8'd0;
	wire [63:0] dinb = {8{buf_wdata}};
	wire [8:0]  addra = sd_xfr_addr[9:1], addrb = buf_addr[11:3];
	wire        ena = tx_rd | rx_wr_en;
	genvar half;
	generate for (half = 0; half < 2; half = half + 1) begin : bufmem
		wire [3:0] dpa, dpb;
		RAMB36E1 #(
			.RAM_MODE("TDP"),
			.READ_WIDTH_A(36), .READ_WIDTH_B(36), .WRITE_WIDTH_A(36), .WRITE_WIDTH_B(36),
			.WRITE_MODE_A("READ_FIRST"), .WRITE_MODE_B("READ_FIRST"),
			.DOA_REG(0), .DOB_REG(0),
			.IS_CLKARDCLK_INVERTED(1'b1),
			.SIM_DEVICE("7SERIES")
		) ram (
			.CLKARDCLK(sd_clk), .CLKBWRCLK(clk),
			.ENARDEN(ena), .ENBWREN(buf_en),
			.REGCEAREGCE(1'b0), .REGCEB(1'b0),
			.RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0), .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
			// x36: the word address is bits [14:5]; the low five are unused
			.ADDRARDADDR({1'b0, 1'b0, addra, 5'b00000}),
			.ADDRBWRADDR({1'b0, 1'b0, addrb, 5'b00000}),
			.WEA(rx_wr[4*half +: 4]), .WEBWE({4'b0000, web[4*half +: 4]}),
			.DIADI(dina[32*half +: 32]), .DIPADIP(4'b0000),
			.DIBDI(dinb[32*half +: 32]), .DIPBDIP(4'b0000),
			.DOADO(douta[32*half +: 32]), .DOPADOP(dpa),
			.DOBDO(doutb_w[32*half +: 32]), .DOPBDOP(dpb),
			.CASCADEINA(1'b0), .CASCADEINB(1'b0), .CASCADEOUTA(), .CASCADEOUTB(),
			.INJECTSBITERR(1'b0), .INJECTDBITERR(1'b0),
			.DBITERR(), .SBITERR(), .ECCPARITY(), .RDADDRECC());
	end endgenerate
	always @(posedge clk) if (buf_en) lane_q <= buf_addr[2:0];
	assign doutb = doutb_w;
	assign buf_rdata = doutb_w[8*lane_q +: 8];

	// ---- status and responses back into clk ----
	reg [31:0] q_resp0, q_resp1, q_resp2, q_resp3, q_wait, q_status, q_pk0, q_pk1, q_dwait, q_cnt;
	reg [9:0]  q_xfr;
	reg        q_detect;
	always @(posedge clk) begin
		q_resp0 <= response0; q_resp1 <= response1; q_resp2 <= response2; q_resp3 <= {1'b0, response3};
		q_wait <= wait_o; q_status <= {status_o, 4'b0}; q_pk0 <= packet0; q_pk1 <= {16'b0, packet1};
		q_dwait <= wait_data_o; q_cnt <= {16'b0, transf_cnt}; q_xfr <= sd_xfr_addr; q_detect <= sd_detect;
	end
	reg [31:0] rsel;
	always @(*) begin
		case (widx)
			5'd0:  rsel = q_resp0;   5'd1:  rsel = q_resp1;  5'd2:  rsel = q_resp2;  5'd3:  rsel = q_resp3;
			5'd4:  rsel = q_wait;    5'd5:  rsel = q_status; 5'd6:  rsel = q_pk0;    5'd7:  rsel = q_pk1;
			5'd8:  rsel = q_dwait;   5'd9:  rsel = q_cnt;
			5'd12: rsel = {31'b0, q_detect};
			5'd13: rsel = {22'b0, q_xfr};
			5'd14: rsel = {30'b0, q_status[10], q_status[8]};
			// echo of what was written, at the 16+n indices, to read a register back
			5'd16: rsel = r_align;   5'd17: rsel = {24'b0, r_div};  5'd18: rsel = r_arg;  5'd19: rsel = r_cmd;
			5'd20: rsel = r_setting; 5'd21: rsel = r_start;  5'd22: rsel = {28'b0, r_reset};
			5'd23: rsel = r_blkcnt;  5'd24: rsel = r_blksize; 5'd25: rsel = r_timeout;
			default: rsel = 32'hDEADBEEF;
		endcase
		reg_rdata = hi ? rsel[31:16] : rsel[15:0];
	end
endmodule
`default_nettype wire
