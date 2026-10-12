// ============================================================================
// gb_video_out.sv: IIgs VGC scanout -> framework VideoV0 frame stream.
//
// The framework writes one pixel into its frame buffer for every system
// clock that video_dataEnable is high, advances a line on each hblank pulse
// and closes the frame on vblank (MacLC_GameBub gb_video_out.sv).
//
// INPUT. The VGC runs on clk_vid (28.6 MHz) with ce_pix every other clock, so
// each pixel is held for exactly one clk_sys (14.3 MHz) period: sampled on
// clk_sys, every clock is one pixel. HBlank/VBlank bound the 744 x 240 picture
// including the border; CROP_X/CROP_Y place the 640 x 200 Super Hi-Res area in
// it: rtl/iigs/vgc.sv draws SHR at H = 44..683 (BL..BR) and lines 19..218
// (video_timing.sv: top border 19), and the testbench's raw capture puts
// 40-column text at x = 84.. (BLE), so x = H. Apple II modes (560 x 192) sit
// inside that window with a little border round them.
//
// HALVE = 1 (the default) emits 320 x 200: each pair of pixels is averaged.
// Super Hi-Res 320 mode, which almost every IIgs game uses, sends every pixel
// twice, so this is lossless there; 640 mode and 80-column text blend pairs.
// The framework then scales 320 x 200 by 2 to 640 x 400 on the 720 x 480
// panel, at the right aspect ratio, and its double-buffered frame store is
// half the size of a 640 x 200 one (docs/PORT_PLAN.md, sections 4 and 5).
//
// COLOUR. 9 bits per pixel are stored. An ordered 4x4 Bayer dither (from
// MacLC_GameBub) takes the IIgs's 4-bit channels to 3 bits; values within 16
// of either end snap to black/white.
// ============================================================================
`default_nettype none

module gb_video_out #(
	parameter integer CROP_X = 44,
	parameter integer CROP_Y = 19,
	parameter integer ACTIVE_W = 640,
	parameter integer ACTIVE_H = 200,
	parameter bit     HALVE  = 1'b1,
	parameter bit     DITHER = 1'b1
)(
	input  wire       clk,             // clk_sys: one pixel per clock
	input  wire       reset,

	input  wire [7:0] in_r,
	input  wire [7:0] in_g,
	input  wire [7:0] in_b,
	input  wire       in_hblank,
	input  wire       in_vblank,

	output reg  [2:0] out_r,
	output reg  [2:0] out_g,
	output reg  [2:0] out_b,
	output reg        out_de,          // framework video_dataEnable
	output reg        out_hblank,      // one-cycle pulse after each line
	output reg        out_vblank       // level, high between frames
);

	// Retime from clk_vid (related clock, timed by Vivado).
	reg [7:0] r, g, b;
	reg       hb = 1'b1, vb = 1'b1, hb_d = 1'b1;
	always @(posedge clk) begin
		r <= in_r; g <= in_g; b <= in_b;
		hb <= in_hblank; vb <= in_vblank; hb_d <= hb;
	end

	reg [10:0] x = 11'd0;              // pixel within the visible line
	reg [9:0]  y = 10'd0;              // visible line within the frame
	reg        synced = 1'b0;          // seen a vblank since reset
	reg [7:0]  r0, g0, b0;             // first pixel of a pair
	reg [1:0]  x4 = 2'd0;              // output column mod 4 (dither)

	wire row_in  = (y >= CROP_Y) && (y < CROP_Y + ACTIVE_H);
	wire col_in  = (x >= CROP_X) && (x < CROP_X + ACTIVE_W);
	wire pair_lo = HALVE && !(x[0] ^ CROP_X[0]);   // first of a pair
	wire [1:0] y4 = y[1:0] - CROP_Y[1:0];

	function [3:0] bayer(input [1:0] xx, input [1:0] yy);
		case ({yy, xx})
			4'b00_00: bayer = 4'd0;  4'b00_01: bayer = 4'd8;  4'b00_10: bayer = 4'd2;  4'b00_11: bayer = 4'd10;
			4'b01_00: bayer = 4'd12; 4'b01_01: bayer = 4'd4;  4'b01_10: bayer = 4'd14; 4'b01_11: bayer = 4'd6;
			4'b10_00: bayer = 4'd3;  4'b10_01: bayer = 4'd11; 4'b10_10: bayer = 4'd1;  4'b10_11: bayer = 4'd9;
			default:  bayer = (xx == 2'd0) ? 4'd15 : (xx == 2'd1) ? 4'd7 : (xx == 2'd2) ? 4'd13 : 4'd5;
		endcase
	endfunction

	function [2:0] quant(input [7:0] v, input [3:0] d);
		reg [11:0] s;
		begin
			s = v * 12'd7 + (DITHER ? {4'd0, d, 4'd0} : 12'd127);
			quant = (v < 8'd16)     ? 3'd0 :
			        (v > 8'd239)    ? 3'd7 :
			        (s >= 12'd1785) ? 3'd7 :
			        (s >= 12'd1530) ? 3'd6 :
			        (s >= 12'd1275) ? 3'd5 :
			        (s >= 12'd1020) ? 3'd4 :
			        (s >= 12'd765)  ? 3'd3 :
			        (s >= 12'd510)  ? 3'd2 :
			        (s >= 12'd255)  ? 3'd1 : 3'd0;
		end
	endfunction

	function [7:0] avg(input [7:0] a, input [7:0] c);
		reg [8:0] s;
		begin
			s   = {1'b0, a} + {1'b0, c} + 9'd1;
			avg = s[8:1];
		end
	endfunction

	wire [7:0] pr = HALVE ? avg(r0, r) : r;
	wire [7:0] pg = HALVE ? avg(g0, g) : g;
	wire [7:0] pb = HALVE ? avg(b0, b) : b;
	wire [3:0] d  = bayer(x4, y4);

	always @(posedge clk) begin
		out_de     <= 1'b0;
		out_hblank <= 1'b0;
		if (reset) begin
			x          <= 11'd0;
			y          <= 10'd0;
			x4         <= 2'd0;
			synced     <= 1'b0;
			out_vblank <= 1'b1;
		end else begin
			if (vb) begin
				y      <= 10'd0;
				synced <= 1'b1;
			end else if (hb && !hb_d) begin
				y <= y + 10'd1;            // end of a visible line
			end

			if (hb) begin
				x  <= 11'd0;
				x4 <= 2'd0;
			end else begin
				x <= x + 11'd1;
			end

			out_vblank <= !(synced && !vb && row_in);

			if (synced && !vb && !hb && row_in) begin
				if (col_in) begin
					if (pair_lo) begin
						r0 <= r; g0 <= g; b0 <= b;
					end else begin
						out_r  <= quant(pr, d);
						out_g  <= quant(pg, d);
						out_b  <= quant(pb, d);
						out_de <= 1'b1;
						x4     <= x4 + 2'd1;
					end
				end else if (x == CROP_X + ACTIVE_W) begin
					out_hblank <= 1'b1;    // first pixel after the active area
				end
			end
		end
	end

endmodule

`default_nettype wire
