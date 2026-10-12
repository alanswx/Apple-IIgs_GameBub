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
// TRANSFER SHAPE, after sys/hps_io.sv (WIDE=0):
//   read  : sd_ack=1; per byte: sd_buff_dout and sd_buff_addr, with a
//           one-cycle sd_buff_wr; finally sd_ack=0
//   write : sd_ack=1, sd_buff_addr=0; per byte: wait, sample sd_buff_din,
//           sd_buff_addr+1; finally sd_ack=0
//   mount : one-cycle img_mounted with img_size/img_readonly valid
// SDRAM word n holds image bytes 2n (bits 7:0) and 2n+1 (bits 15:8).
//
// READ SPEED. A track change makes the floppy controller load both sides,
// ~38 sectors, after a 3.5 ms settle, and the ROM's seeks step on before a
// slow load finishes (sim: one word per SDRAM round trip took ~10 ms per
// track and the boot ran off the end of the disk). So reads fetch 8-word
// lines (a burst read on SDRAM ch2, iigs_core pm_line) one line ahead while
// the bytes of the current one go out, one every 2 clocks: ~1.1k clocks
// (75 us) per sector, about what MiSTer's HPS delivers.
// ============================================================================
`default_nettype none

module gb_blockdev (
	input  wire        clk,
	input  wire        reset,

	// ---- the image (gb_host / iigs_core) ----
	input  wire [23:0] img_base,       // SDRAM word address of byte 0 (8-word aligned)
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
	input  wire [15:0] mem_dout,       // (unused: reads come back as lines)
	input  wire [127:0] mem_line,      // a read's 8-word line, valid with mem_ack

	output wire [31:0] dbg
);

	assign img_readonly = 1'b0;   // writable: some games refuse a protected disk

	localparam [2:0] S_IDLE = 3'd0, S_READ = 3'd1, S_WR_WAIT = 3'd2, S_WR_SAMPLE = 3'd3,
	                 S_WR_ACK = 3'd4, S_WR_DROP = 3'd5, S_DONE = 3'd6;
	reg  [2:0]  s = S_IDLE;
	reg  [31:0] lba;
	reg  [7:0]  w;            // write: word within the sector
	reg         hi;           // write: byte within the word
	reg  [1:0]  wait_cnt;
	reg  [15:0] data;
	reg         mount_pend = 1'b0;
	reg  [15:0] n_reads = 16'd0, n_writes = 16'd0;

	wire [31:0] n_blocks = (img_bytes + 32'd511) >> 9;
	wire        in_image = (lba < n_blocks);
	wire [23:0] sector_base = img_base + {lba[15:0], 8'd0};

	// ---- read: line fetcher, one line ahead of the byte emitter ----
	localparam [1:0] F_IDLE = 2'd0, F_REQ = 2'd1, F_DROP = 2'd2;
	reg  [1:0]   f = F_IDLE;
	reg  [5:0]   f_line;      // next line to fetch, 0..32
	reg  [127:0] nbuf;        // fetched, not yet being sent
	reg          nvalid;
	reg  [127:0] cbuf;        // being sent
	reg          cvalid;
	reg  [9:0]   nbyte;       // bytes sent, 0..512
	reg          ph;          // 0: present a byte, 1: advance

	always @(posedge clk) begin
		if (reset) begin
			s           <= S_IDLE;
			f           <= F_IDLE;
			sd_ack      <= 1'b0;
			sd_buff_wr  <= 1'b0;
			img_mounted <= 1'b0;
			img_size    <= 64'd0;
			mem_req     <= 1'b0;
			mount_pend  <= 1'b0;
			n_reads     <= 16'd0;
			n_writes    <= 16'd0;
			nvalid      <= 1'b0;
			cvalid      <= 1'b0;
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
					n_reads      <= n_reads + 16'd1;
					f_line       <= 6'd0;
					nvalid       <= 1'b0;
					cvalid       <= 1'b0;
					nbyte        <= 10'd0;
					ph           <= 1'b0;
					s            <= S_READ;
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

			// ---- read ----
			S_READ: begin
				// fetcher
				case (f)
				F_IDLE: if (f_line != 6'd32 && !nvalid) begin
					if (in_image) begin
						mem_addr <= sector_base + {f_line[4:0], 3'b000};
						mem_we   <= 1'b0;
						mem_req  <= 1'b1;
						f        <= F_REQ;
					end else begin
						nbuf   <= 128'd0;     // past the end of the image
						nvalid <= 1'b1;
						f_line <= f_line + 6'd1;
					end
				end
				F_REQ: if (mem_ack) begin
					nbuf    <= mem_line;
					nvalid  <= 1'b1;
					mem_req <= 1'b0;
					f_line  <= f_line + 6'd1;
					f       <= F_DROP;
				end
				// the arbiter releases on the edge where the ack falls
				F_DROP: if (!mem_ack) f <= F_IDLE;
				default: f <= F_IDLE;
				endcase

				// emitter
				if (!cvalid) begin
					if (nvalid) begin
						cbuf   <= nbuf;
						cvalid <= 1'b1;
						nvalid <= 1'b0;      // (the fetcher never sets it while it is high)
					end
				end else if (!ph) begin
					sd_buff_addr <= nbyte[8:0];
					sd_buff_dout <= cbuf[{nbyte[3:0], 3'b000} +: 8];
					sd_buff_wr   <= 1'b1;
					ph           <= 1'b1;
				end else begin
					ph    <= 1'b0;
					nbyte <= nbyte + 10'd1;
					if (nbyte[3:0] == 4'hF) cvalid <= 1'b0;
				end

				if (nbyte == 10'd512 && f == F_IDLE) s <= S_DONE;
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
						mem_addr <= sector_base + {16'd0, w};
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
