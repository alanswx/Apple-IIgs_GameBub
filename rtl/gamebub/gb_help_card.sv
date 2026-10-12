// ============================================================================
// gb_help_card.sv: the controls card -- what each Game Bub button does in
// the game that is running -- drawn over the picture.
//
// 26 x 12 characters of the on-screen keyboard's font (rtl/osk/osk_rom.sv:
// osk_help_template for the fixed text, osk_key_name for the key each button
// types). Cells are 4 font pixels wide, each drawn 2 VGC pixels wide (one
// output pixel after gb_video_out's pair averaging), and 12 lines tall, so
// the card is 208 x 144 VGC pixels, centred near the top of the kept area.
//
// Same stream as gb_osk's keyboard (VGC, one pixel per clock, real
// blanking); 4 clocks of delay.
// ============================================================================
`default_nettype none

module gb_help_card #(
	parameter integer CROP_X = 44,
	parameter integer CROP_Y = 19,
	parameter integer CARD_X = 216,       // left edge, within the kept 640 (even)
	parameter integer CARD_Y = 12         // top line, within the kept 200
)(
	input  wire        clk,
	input  wire        show,
	input  wire        ptr_mode,          // 1: d-pad = mouse, A = click
	input  wire [62:0] keymap,            // {start, r, l, y, x, b, a}, 9 bits each

	input  wire [7:0]  in_r,
	input  wire [7:0]  in_g,
	input  wire [7:0]  in_b,
	input  wire        in_hblank,
	input  wire        in_vblank,
	output reg  [7:0]  out_r,
	output reg  [7:0]  out_g,
	output reg  [7:0]  out_b,
	output reg         out_hblank,
	output reg         out_vblank
);

	localparam integer W = 26, H = 12;
	localparam integer X0 = CROP_X + CARD_X, Y0 = CROP_Y + CARD_Y;

	// ---- stage 0: the pixel and where it is ----
	reg  [7:0]  r0, g0, b0;
	reg         hb0 = 1'b1, vb0 = 1'b1, hb_d = 1'b1;
	reg  [10:0] x = 11'd0;
	reg  [9:0]  y = 10'd0;
	always @(posedge clk) begin
		r0 <= in_r; g0 <= in_g; b0 <= in_b;
		hb0 <= in_hblank; vb0 <= in_vblank; hb_d <= hb0;
		if (vb0)                y <= 10'd0;
		else if (hb0 && !hb_d)  y <= y + 10'd1;
		if (hb0) x <= 11'd0;
		else     x <= x + 11'd1;
	end

	wire [10:0] cx = x - X0[10:0];
	wire [9:0]  cy = y - Y0[9:0];
	wire        in_card = show && (x >= X0) && (x < X0 + W * 8) && (y >= Y0) && (y < Y0 + H * 12);
	wire [4:0]  col  = cx[7:3];                 // 8 VGC pixels a cell
	wire [1:0]  px   = cx[2:1];                 // 2 VGC pixels a font pixel
	// row / line: y within the card, 12 lines a row
	wire [3:0]  row  = (cy < 10'd12) ? 4'd0 : (cy < 10'd24) ? 4'd1 : (cy < 10'd36) ? 4'd2 :
	                   (cy < 10'd48) ? 4'd3 : (cy < 10'd60) ? 4'd4 : (cy < 10'd72) ? 4'd5 :
	                   (cy < 10'd84) ? 4'd6 : (cy < 10'd96) ? 4'd7 : (cy < 10'd108) ? 4'd8 :
	                   (cy < 10'd120) ? 4'd9 : (cy < 10'd132) ? 4'd10 : 4'd11;
	wire [9:0]  line_full = cy - {row, 3'd0} - {1'b0, row, 2'd0};   // cy - 12 * row
	wire [3:0]  line = line_full[3:0];

	// row 1 is the d-pad line: its keyboard-mode text is template row 11;
	// row 11 itself is never shown
	wire [3:0]  trow = (row == 4'd1 && !ptr_mode) ? 4'd11 : (row == 4'd11) ? 4'd15 : row;
	wire [6:0]  t_glyph;
	osk_help_template tmpl (.row(trow), .col(col), .glyph(t_glyph));

	// rows 2..8, from column 8: the name of the key the button types
	wire        is_key = (row >= 4'd2) && (row <= 4'd8) && (col >= 5'd8) && (col < 5'd16);
	wire [2:0]  bidx   = row[2:0] - 3'd2;      // 0 a .. 6 start
	wire [8:0]  bcode  = (bidx == 3'd0 && ptr_mode) ? 9'h1FE : keymap[bidx * 9 +: 9];
	wire [6:0]  k_glyph;
	osk_key_name kname (.code(bcode), .pos(col[2:0]), .glyph(k_glyph));

	// ---- stage 1: the glyph ----
	reg  [7:0]  r1, g1, b1;
	reg         hb1, vb1, in1, edge1;
	reg  [6:0]  glyph1;
	reg  [3:0]  line1;
	reg  [1:0]  px1;
	always @(posedge clk) begin
		{r1, g1, b1, hb1, vb1} <= {r0, g0, b0, hb0, vb0};
		in1    <= in_card;
		edge1  <= (x == X0) || (x == X0 + W * 8 - 1) || (cy == 10'd0) || (cy == H * 12 - 1);
		glyph1 <= is_key ? k_glyph : t_glyph;
		line1  <= line;
		px1    <= px;
	end

	// ---- stage 2: the font row ----
	wire [3:0] font_q;
	osk_font_rom font (.clk(clk), .addr({glyph1, line1}), .q(font_q));
	reg  [7:0] r2, g2, b2;
	reg        hb2, vb2, in2, edge2;
	reg  [1:0] px2;
	always @(posedge clk) begin
		{r2, g2, b2, hb2, vb2} <= {r1, g1, b1, hb1, vb1};
		{in2, edge2, px2} <= {in1, edge1, px1};
	end

	// ---- stage 3: draw (an opaque dark panel, light rim, white text) ----
	wire text = font_q[~px2];                  // [3] is the cell's leftmost pixel
	always @(posedge clk) begin
		out_hblank <= hb2;
		out_vblank <= vb2;
		if (in2 && edge2)
			{out_r, out_g, out_b} <= {8'hB0, 8'hB0, 8'hB0};
		else if (in2 && text)
			{out_r, out_g, out_b} <= {8'hF8, 8'hF8, 8'hF8};
		else if (in2)
			{out_r, out_g, out_b} <= {8'h18, 8'h20, 8'h40};
		else
			{out_r, out_g, out_b} <= {r2, g2, b2};
	end

endmodule

`default_nettype wire
