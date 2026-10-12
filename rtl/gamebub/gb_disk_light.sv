// ============================================================================
// gb_disk_light.sv: a drive "in use" light drawn into the picture.
//
// The Game Bub has no LED a core can drive, so while the 3.5" drive's motor
// runs (as the real drive's light shows) a small red lamp with a black rim
// is drawn in the top-right corner of the 320x200 frame. One register stage
// between gb_video_out and the framework; the stream's shape is unchanged.
// ============================================================================
`default_nettype none

module gb_disk_light #(
	parameter integer X0 = 309,      // lamp box, rim included: x X0..X0+7
	parameter integer Y0 = 2         //                         y Y0..Y0+4
)(
	input  wire       clk,
	input  wire       enable,        // the "Disk Light" setting
	input  wire       lit,           // drive motor on

	input  wire [2:0] in_r,
	input  wire [2:0] in_g,
	input  wire [2:0] in_b,
	input  wire       in_de,
	input  wire       in_hblank,     // one-cycle pulse after each line
	input  wire       in_vblank,     // level, high between frames

	output reg  [2:0] out_r,
	output reg  [2:0] out_g,
	output reg  [2:0] out_b,
	output reg        out_de,
	output reg        out_hblank,
	output reg        out_vblank
);

	reg [8:0] x = 9'd0;              // column of the pixel on in_* now
	reg [7:0] y = 8'd0;              // its line
	reg       show = 1'b0;           // sampled once per frame: no half-drawn lamp

	wire in_box  = (x >= X0) && (x <= X0 + 7) && (y >= Y0) && (y <= Y0 + 4);
	wire in_lamp = (x >= X0 + 1) && (x <= X0 + 6) && (y >= Y0 + 1) && (y <= Y0 + 3);

	always @(posedge clk) begin
		if (in_vblank) begin
			x    <= 9'd0;
			y    <= 8'd0;
			show <= enable && lit;
		end else if (in_hblank) begin
			x <= 9'd0;
			y <= y + 8'd1;
		end else if (in_de)
			x <= x + 9'd1;

		out_de     <= in_de;
		out_hblank <= in_hblank;
		out_vblank <= in_vblank;
		if (in_de && show && in_box)
			{out_r, out_g, out_b} <= in_lamp ? {3'd7, 3'd1, 3'd1} : 9'd0;
		else
			{out_r, out_g, out_b} <= {in_r, in_g, in_b};
	end

endmodule

`default_nettype wire
