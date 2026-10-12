// ============================================================================
// gb_osk.sv: the on-screen keyboard (rtl/osk, from Marty_MiSTer) in the Game
// Bub picture and button path.
//
// BUTTONS. Select is shared:
//   tap  (< 0.5 s): released as a short Select press -- gb_pad_input's
//                   mouse / keyboard toggle, or, while the keyboard is open,
//                   its own top / bottom move;
//   hold (0.5 s):   open or close the keyboard (Start closes it too).
// While it is open every button belongs to it (d-pad moves, A types, B
// delete, X space, Y return) and the pad and joystick see nothing, so
// gb_pad_input releases whatever it held.
//
// VIDEO. The keyboard sits in front of gb_video_out on the VGC's 8-bit,
// one-pixel-per-clk_sys stream, as on MiSTer. It is given the 640 x 200 area
// gb_video_out keeps (CROP_X/CROP_Y, same counting) as its picture, so it
// sizes itself 2x across (624 px, which the pair averaging takes back to
// 312) and 1x down, inside what reaches the panel. The real blanking rides
// through its hs/vs delay line so the picture keeps its shape.
//
// STATUS STRIP (top left, "Status Icons" setting): floppy while the drive
// runs; a mouse or keyboard icon for 2 s after the input mode changes.
// ============================================================================
`default_nettype none

module gb_osk #(
	parameter integer CLK_HZ = 14_318_181,
	parameter integer CROP_X = 44,
	parameter integer CROP_Y = 19
)(
	input  wire        clk,
	input  wire        reset,

	input  wire [15:0] keys_in,       // cont1_key layout (gb_pad_input)
	output wire [15:0] keys_out,      // to gb_pad_input / joystick
	output wire        open,

	input  wire [10:0] ps2_in,        // gb_pad_input's keyboard stream
	output wire [10:0] ps2_out,       // ... with the on-screen keyboard's keys

	input  wire        lights_en,
	input  wire        card_at_start, // show the controls card when the IIgs starts
	input  wire [62:0] keymap,        // {start, r, l, y, x, b, a} PS/2 codes (card text)
	input  wire        disk_active,
	input  wire        ptr_mode,      // gb_pad_input: 1 = mouse mode

	input  wire [7:0]  in_r,
	input  wire [7:0]  in_g,
	input  wire [7:0]  in_b,
	input  wire        in_hblank,
	input  wire        in_vblank,
	output wire [7:0]  out_r,
	output wire [7:0]  out_g,
	output wire [7:0]  out_b,
	output wire        out_hblank,
	output wire        out_vblank
);

	localparam integer B_UP = 0, B_DOWN = 1, B_LEFT = 2, B_RIGHT = 3, B_A = 4, B_B = 5,
	                   B_X = 6, B_Y = 7, B_L = 8, B_R = 9, B_SELECT = 14, B_START = 15;
	localparam integer HOLD_CLKS  = CLK_HZ / 2;          // 0.5 s
	localparam integer TAP_CLKS   = CLK_HZ / 100;        // 10 ms Select pulse
	localparam integer FLASH_CLKS = CLK_HZ * 2;          // mode icon: 2 s
	localparam integer CARD_CLKS  = CLK_HZ * 10;         // controls card: 10 s
	localparam integer GRACE_CLKS = CLK_HZ;              // ... not dismissed in its first 1 s

	// ---- Select: tap or hold ----
	reg  [23:0] sel_cnt = 24'd0;
	reg         sel_q = 1'b0, sel_long = 1'b0, toggle = 1'b0;
	reg  [17:0] tap_cnt = 18'd0;
	reg         start_q = 1'b0;
	wire        sel = keys_in[B_SELECT];
	wire        tap = (tap_cnt != 18'd0);
	always @(posedge clk) begin
		sel_q   <= sel;
		start_q <= keys_in[B_START];
		toggle  <= 1'b0;
		if (tap_cnt != 18'd0) tap_cnt <= tap_cnt - 18'd1;
		if (reset) begin
			sel_cnt <= 24'd0; sel_long <= 1'b0; tap_cnt <= 18'd0;
		end else if (sel) begin
			if (sel_cnt == HOLD_CLKS[23:0]) begin
				if (!sel_long) toggle <= 1'b1;               // held: open / close
				sel_long <= 1'b1;
			end else
				sel_cnt <= sel_cnt + 24'd1;
		end else begin
			if (sel_q && !sel_long) tap_cnt <= TAP_CLKS[17:0];   // released early: a tap
			sel_cnt  <= 24'd0;
			sel_long <= 1'b0;
		end
		if (open && keys_in[B_START] && !start_q) toggle <= 1'b1;
	end

	// Select as the rest of the core sees it: the tap pulse only. After the
	// keyboard closes, nothing passes until every button is up (the Start or
	// Select that closed it must not reach the game).
	reg         open_q = 1'b0, mute = 1'b0;
	always @(posedge clk) begin
		open_q <= open;
		if (reset)                mute <= 1'b0;
		else if (open_q && !open) mute <= 1'b1;
		else if (keys_in == 16'd0) mute <= 1'b0;
	end
	wire [15:0] keys_tap = {keys_in[15], tap, keys_in[13:0]};
	assign keys_out = (open || open_q || mute) ? 16'd0 : keys_tap;

	// Marty pad: {Z, Y, X, C, zoom, select, run, B, A, up, down, left, right}
	wire [12:0] pad = {1'b0, keys_in[B_Y], keys_in[B_X], 1'b0, 1'b0, tap, keys_in[B_START],
	                   keys_in[B_B], keys_in[B_A], keys_in[B_UP], keys_in[B_DOWN],
	                   keys_in[B_LEFT], keys_in[B_RIGHT]};

	// ---- status lights ----
	reg        ptr_q = 1'b0;
	reg [25:0] flash = 26'd0;
	always @(posedge clk) begin
		ptr_q <= ptr_mode;
		if (reset || ptr_mode != ptr_q) flash <= FLASH_CLKS[25:0];
		else if (flash != 26'd0)        flash <= flash - 26'd1;
	end
	wire flash_on = (flash != 26'd0);

	// ---- the kept area, counted as gb_video_out counts it ----
	reg  [7:0]  r, g, b;
	reg         hb = 1'b1, vb = 1'b1, hb_d = 1'b1;
	reg  [10:0] x = 11'd0;
	reg  [9:0]  y = 10'd0;
	always @(posedge clk) begin
		r <= in_r; g <= in_g; b <= in_b;
		hb <= in_hblank; vb <= in_vblank; hb_d <= hb;
		if (vb)              y <= 10'd0;
		else if (hb && !hb_d) y <= y + 10'd1;
		if (hb) x <= 11'd0;
		else    x <= x + 11'd1;
	end
	wire col_in = (x >= CROP_X) && (x < CROP_X + 640);
	wire row_in = (y >= CROP_Y) && (y < CROP_Y + 200);

	wire [10:0] osk_ps2;
	wire [7:0]  k_r, k_g, k_b;
	wire        k_hblank, k_vblank;

	osd_keyboard #(.CLK_HZ(CLK_HZ)) kbd (
		.clk       (clk),
		.reset     (reset),
		.toggle    (toggle),
		.lights_en (lights_en),
		.activity  ({ptr_mode ? 1'b0 : flash_on, ptr_mode ? flash_on : 1'b0, disk_active}),
		.pad1_i    (pad),
		.pad2_i    (13'd0),
		.pad1_o    (),
		.pad2_o    (),
		.open      (open),
		.ps2_key_i (ps2_in),
		.ps2_key_o (osk_ps2),
		.ce_pix    (1'b1),
		.r_i       (r),
		.g_i       (g),
		.b_i       (b),
		.hs_i      (hb),                 // the real blanking, delayed with the picture
		.vs_i      (vb),
		.hb_i      (!col_in || vb),      // the kept area, for sizing and placement
		.vb_i      (vb || !row_in),
		.field_i   (1'b0),
		.r_o       (k_r),
		.g_o       (k_g),
		.b_o       (k_b),
		.hs_o      (k_hblank),
		.vs_o      (k_vblank),
		.hb_o      (),
		.vb_o      (),
		.field_o   ()
	);

	// ---- HELP (0x1FF, the keyboard's top row) never reaches the IIgs ----
	reg  [10:0] ps2_f = 11'd0;
	reg         osk_tog = 1'b0, help_req = 1'b0;
	always @(posedge clk) begin
		osk_tog  <= osk_ps2[10];
		help_req <= 1'b0;
		if (reset) ps2_f <= 11'd0;
		else if (osk_ps2[10] != osk_tog) begin
			if (osk_ps2[8:0] == 9'h1FF) help_req <= osk_ps2[9];
			else ps2_f <= {~ps2_f[10], osk_ps2[9:0]};
		end
	end
	assign ps2_out = ps2_f;

	// ---- the controls card: at start (setting) and on HELP ----
	reg  [27:0] card_cnt = 28'd0;
	reg         card = 1'b0, started = 1'b0;
	reg  [15:0] keys_q = 16'd0;
	wire        any_press = |(keys_in & ~keys_q);
	always @(posedge clk) begin
		keys_q <= keys_in;
		if (reset) begin
			card <= 1'b0; started <= 1'b0; card_cnt <= 28'd0;
		end else if (!started) begin
			started  <= 1'b1;
			card     <= card_at_start;
			card_cnt <= CARD_CLKS[27:0];
		end else if (help_req) begin
			card     <= 1'b1;
			card_cnt <= CARD_CLKS[27:0];
		end else if (card) begin
			card_cnt <= card_cnt - 28'd1;
			if (card_cnt == 28'd0 ||
			    (any_press && !open && card_cnt < CARD_CLKS[27:0] - GRACE_CLKS[27:0]))
				card <= 1'b0;
		end
	end

	gb_help_card #(.CROP_X(CROP_X), .CROP_Y(CROP_Y)) help (
		.clk        (clk),
		.show       (card),
		.ptr_mode   (ptr_mode),
		.keymap     (keymap),
		.in_r       (k_r),
		.in_g       (k_g),
		.in_b       (k_b),
		.in_hblank  (k_hblank),
		.in_vblank  (k_vblank),
		.out_r      (out_r),
		.out_g      (out_g),
		.out_b      (out_b),
		.out_hblank (out_hblank),
		.out_vblank (out_vblank)
	);

endmodule

`default_nettype wire
