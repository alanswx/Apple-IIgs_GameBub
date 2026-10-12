// ============================================================================
// gb_blockdev.sv: a MiSTer hps_io block device (8-bit, one drive), served
// from a disk image in SDRAM. After MacLC_GameBub's gb_blockdev.sv.
//
// On MiSTer the ARM side answers sd_rd/sd_wr by moving 512-byte sectors
// between the SD card and the core. Game Bub's host copies whole files into
// core memory at setup and cannot do random access, so the WOZ images live
// in SDRAM (placed by files.json, see gb_host.sv) and this module answers the
// same requests from there. woz_floppy_controller is unchanged. Writes land in
// the SDRAM copy and are lost at exit (the files are read-only on the card).
//
// TRANSFER SHAPE, copied from sys/hps_io.sv (WIDE=0):
//   read  : sd_ack=1, sd_buff_addr=0; per byte: dout, then a one-cycle
//           sd_buff_wr, then sd_buff_addr+1; finally sd_ack=0
//   write : sd_ack=1, sd_buff_addr=0; per byte: wait, sample sd_buff_din,
//           sd_buff_addr+1; finally sd_ack=0
//   mount : one-cycle img_mounted with img_size/img_readonly valid
// SDRAM word n holds image bytes 2n (bits 7:0) and 2n+1 (bits 15:8).
// ============================================================================
`default_nettype none

module gb_blockdev (
	input  wire        clk,
	input  wire        reset,

	// ---- the image (gb_host / iigs_core) ----
	input  wire [23:0] img_base,       // SDRAM word address of byte 0
	input  wire [31:0] img_bytes,      // 0 = no image
	input  wire        mount_req,      // pulse: (re)present the image

	// ---- hps_io-shaped block device (woz_floppy_controller) ----
	input  wire [31:0] sd_lba,
	input  wire        sd_rd,
	input  wire        sd_wr,
	output reg         sd_ack,
	output reg  [8:0]  sd_buff_addr,
	output reg  [7:0]  sd_buff_dout,
	input  wire [7:0]  sd_buff_din,
	output reg         sd_buff_wr,
	output reg         img_mounted,
	output reg  [63:0] img_size,
	output wire        img_readonly,

	// ---- SDRAM client (gb_eth_arb protocol) ----
	output reg         mem_req,
	output reg         mem_we,
	output reg  [23:0] mem_addr,
	output reg  [15:0] mem_din,
	input  wire        mem_ack,
	input  wire [15:0] mem_dout,

	output wire [31:0] dbg
);

	assign img_readonly = 1'b0;   // writable: some games refuse a protected disk

	localparam [3:0] S_IDLE = 4'd0, S_RD_REQ = 4'd1, S_RD_ACK = 4'd2, S_RD_DROP = 4'd3,
	                 S_RD_BYTE = 4'd4, S_RD_WR = 4'd5, S_RD_NEXT = 4'd6,
	                 S_WR_WAIT = 4'd7, S_WR_SAMPLE = 4'd8, S_WR_ACK = 4'd9,
	                 S_WR_DROP = 4'd10, S_DONE = 4'd11;
	reg  [3:0]  s = S_IDLE;
	reg  [31:0] lba;
	reg  [7:0]  w;            // word within the sector
	reg         hi;           // byte within the word
	reg  [1:0]  wait_cnt;
	reg  [15:0] data;
	reg         mount_pend = 1'b0;
	reg  [15:0] n_reads = 16'd0, n_writes = 16'd0;

	wire [31:0] n_blocks = (img_bytes + 32'd511) >> 9;
	wire        in_image = (lba < n_blocks);
	wire [23:0] word_addr = img_base + {lba[15:0], w};

	always @(posedge clk) begin
		if (reset) begin
			s           <= S_IDLE;
			sd_ack      <= 1'b0;
			sd_buff_wr  <= 1'b0;
			img_mounted <= 1'b0;
			img_size    <= 64'd0;
			mem_req     <= 1'b0;
			mount_pend  <= 1'b0;
			n_reads     <= 16'd0;
			n_writes    <= 16'd0;
		end else begin
			img_mounted <= 1'b0;
			sd_buff_wr  <= 1'b0;
			if (mount_req) mount_pend <= 1'b1;

			case (s)
			S_IDLE: begin
				if (mount_pend) begin
					mount_pend  <= 1'b0;
					img_size    <= {32'd0, img_bytes};
					img_mounted <= 1'b1;
				end else if (sd_rd) begin
					lba          <= sd_lba;
					sd_ack       <= 1'b1;
					sd_buff_addr <= 9'd0;
					w            <= 8'd0;
					n_reads      <= n_reads + 16'd1;
					s            <= S_RD_REQ;
				end else if (sd_wr) begin
					lba          <= sd_lba;
					sd_ack       <= 1'b1;
					sd_buff_addr <= 9'd0;
					w            <= 8'd0;
					hi           <= 1'b0;
					wait_cnt     <= 2'd0;
					n_writes     <= n_writes + 16'd1;
					s            <= S_WR_WAIT;
				end
			end

			// ---- read: one SDRAM word -> two buffer bytes ----
			S_RD_REQ: begin
				hi <= 1'b0;
				if (in_image) begin
					mem_addr <= word_addr;
					mem_we   <= 1'b0;
					mem_req  <= 1'b1;
					s        <= S_RD_ACK;
				end else begin
					data <= 16'd0;
					s    <= S_RD_BYTE;
				end
			end
			S_RD_ACK: if (mem_ack) begin
				data    <= mem_dout;
				mem_req <= 1'b0;
				s       <= S_RD_DROP;
			end
			S_RD_DROP: if (!mem_ack) s <= S_RD_BYTE;
			S_RD_BYTE: begin
				sd_buff_dout <= hi ? data[15:8] : data[7:0];
				s            <= S_RD_WR;
			end
			S_RD_WR: begin
				sd_buff_wr <= 1'b1;
				s          <= S_RD_NEXT;
			end
			S_RD_NEXT: begin
				if (sd_buff_addr != 9'h1FF) sd_buff_addr <= sd_buff_addr + 9'd1;
				if (!hi) begin
					hi <= 1'b1;
					s  <= S_RD_BYTE;
				end else if (w == 8'hFF) begin
					s <= S_DONE;
				end else begin
					w <= w + 8'd1;
					s <= S_RD_REQ;
				end
			end

			// ---- write: two buffer bytes -> one SDRAM word ----
			// sd_buff_din is a registered BRAM read of sd_buff_addr: wait
			// two cycles after each address change.
			S_WR_WAIT: begin
				wait_cnt <= wait_cnt + 2'd1;
				if (wait_cnt == 2'd2) s <= S_WR_SAMPLE;
			end
			S_WR_SAMPLE: begin
				wait_cnt <= 2'd0;
				if (sd_buff_addr != 9'h1FF) sd_buff_addr <= sd_buff_addr + 9'd1;
				if (!hi) begin
					data[7:0] <= sd_buff_din;
					hi        <= 1'b1;
					s         <= S_WR_WAIT;
				end else begin
					data[15:8] <= sd_buff_din;
					hi         <= 1'b0;
					if (in_image) begin
						mem_addr <= word_addr;
						mem_din  <= {sd_buff_din, data[7:0]};
						mem_we   <= 1'b1;
						mem_req  <= 1'b1;
						s        <= S_WR_ACK;
					end else begin
						s <= S_WR_DROP;
					end
				end
			end
			S_WR_ACK: if (mem_ack) begin
				mem_req <= 1'b0;
				s       <= S_WR_DROP;
			end
			S_WR_DROP: if (!mem_ack) begin
				if (w == 8'hFF) s <= S_DONE;
				else begin
					w <= w + 8'd1;
					s <= S_WR_WAIT;
				end
			end

			S_DONE: begin
				sd_ack <= 1'b0;
				s      <= S_IDLE;
			end
			default: s <= S_IDLE;
			endcase
		end
	end

	assign dbg = {n_writes, n_reads};

endmodule

`default_nettype wire
