// ============================================================================
// gb_gamedb.sv: finds the loaded disk in gamedb.bin (files.json file 4).
//
// Runs once the MCU has sent SetupComplete, before gb_host reports the core
// ready (the firmware polls GetStatus for up to 100 ms). The key is the WOZ
// header CRC32 (disk bytes 8..11); gamedb.bin holds 16-byte lines, so each
// record is one 8-word burst read on SDRAM ch2 (iigs_core pm_line). Format:
// tools/mkgamedb.py. A linear scan of the 4095 records a 64 KiB file can hold
// takes a few ms.
//
// SDRAM word n holds image bytes 2n (bits 7:0) and 2n+1 (bits 15:8), so line
// byte k is line[8k +: 8] and a little-endian u32 at byte k is line[8k +: 32].
// ============================================================================
`default_nettype none

module gb_gamedb (
	input  wire        clk,
	input  wire        reset,

	input  wire        start,          // pulse: look the disk up
	input  wire        disk_present,
	input  wire        db_present,
	input  wire [23:0] disk_word,      // SDRAM word address of disk byte 0 (line aligned)
	input  wire [23:0] db_word,        // ... and of gamedb.bin byte 0
	input  wire [31:0] db_bytes,       // gamedb.bin size

	// ---- SDRAM client (gb_eth_arb protocol), reads only ----
	output reg         mem_req,
	output reg  [23:0] mem_addr,
	input  wire        mem_ack,
	input  wire [127:0] mem_line,      // the read's 8-word line, valid with mem_ack

	// ---- result, valid while done ----
	output reg         done,
	output reg         found,
	output reg  [31:0] crc,            // the disk's key (0 if not a WOZ)
	output reg  [1:0]  rom,            // 0 auto, 1 ROM 3, 2 ROM 01
	output reg  [7:0]  speed,          // 0..4, 0xFF no preference
	output reg  [7:0]  input_mode,     // 0 keyboard, 1 mouse, 0xFF no preference
	output reg  [62:0] keymap          // 7 x 9-bit scancodes: start r l y x b a
);

	localparam [31:0] MAGIC_WOZ1 = 32'h315A4F57;   // "WOZ1"
	localparam [31:0] MAGIC_WOZ2 = 32'h325A4F57;   // "WOZ2"
	localparam [31:0] MAGIC_DB   = 32'h42445347;   // "GSDB"

	localparam [2:0] S_IDLE = 3'd0, S_WOZ = 3'd1, S_HDR = 3'd2, S_REC = 3'd3,
	                 S_DROP = 3'd4, S_DONE = 3'd5;
	reg  [2:0]  s = S_IDLE;
	reg  [2:0]  next;           // state after S_DROP
	reg  [11:0] idx;            // record (line) being read, 1..count
	reg  [11:0] count;

	// lines the file really holds, less the header
	wire [27:0] lines_in_file = db_bytes[31:4];
	wire        rec_in_file   = ({16'd0, idx} < lines_in_file);

	task automatic read_line(input [23:0] a, input [2:0] st);
		mem_addr <= a;
		mem_req  <= 1'b1;
		s        <= st;
	endtask

	always @(posedge clk) begin
		if (reset) begin
			s       <= S_IDLE;
			mem_req <= 1'b0;
			done    <= 1'b0;
			found   <= 1'b0;
			crc     <= 32'd0;
		end else begin
			case (s)
			S_IDLE: if (start) begin
				done  <= 1'b0;
				found <= 1'b0;
				crc   <= 32'd0;
				if (disk_present) read_line(disk_word, S_WOZ);
				else              s <= S_DONE;
			end

			S_WOZ: if (mem_ack) begin
				mem_req <= 1'b0;
				s       <= S_DROP;
				if (mem_line[31:0] == MAGIC_WOZ1 || mem_line[31:0] == MAGIC_WOZ2) begin
					crc  <= mem_line[95:64];
					next <= db_present ? S_HDR : S_DONE;
				end else
					next <= S_DONE;
			end

			S_HDR: if (mem_ack) begin
				mem_req <= 1'b0;
				s       <= S_DROP;
				idx     <= 12'd1;
				count   <= (mem_line[63:60] == 4'd0) ? mem_line[59:48] : 12'hFFF;
				next    <= (mem_line[31:0] == MAGIC_DB && mem_line[39:32] == 8'd1 &&
				            mem_line[63:48] != 16'd0) ? S_REC : S_DONE;
			end

			S_REC: if (mem_ack) begin
				mem_req <= 1'b0;
				s       <= S_DROP;
				if (mem_line[31:0] == crc) begin
					found      <= 1'b1;
					rom        <= mem_line[33:32];
					speed      <= mem_line[47:40];
					input_mode <= mem_line[55:48];
					keymap     <= mem_line[126:64];
					next       <= S_DONE;
				end else begin
					idx  <= idx + 12'd1;
					next <= (idx == count) ? S_DONE : S_REC;
				end
			end

			// The arbiter releases on the edge where the ack falls.
			S_DROP: if (!mem_ack) begin
				if (next == S_REC && rec_in_file)
					read_line(db_word + {8'd0, idx, 3'b000}, S_REC);
				else if (next == S_HDR)
					read_line(db_word, S_HDR);
				else
					s <= S_DONE;
			end

			S_DONE: begin
				done <= 1'b1;
				s    <= S_IDLE;
			end
			default: s <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
