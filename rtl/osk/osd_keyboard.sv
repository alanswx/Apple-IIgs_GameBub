// Imported by scripts/import_osk.py from Marty_MiSTer rtl/osk (see that script) - do not edit.
// Copyright (c) 2026 Jamie Blanks
//
// On-screen keyboard. A mapped pad button opens it; while open both pads
// are taken from the machine and drive a cursor over a drawn US keyboard,
// and the chosen keys go into the PS/2 stream the keyboard controller
// already reads. The picture passes through delayed by three pixel ticks.
//
//   pads ──> cursor walk ──> key press ──> PS/2 merge ──> ps2_key_o
//               │ port B
//   video ─> counters ─> layout ROM ─> font ROM ─> pixel class ─> blend ─> video
//                └───────────────── delay line ───────────────────┘
//
// The keyboard is a 78 x 6 grid of 4 px cells, 12 lines a row (312 x 72),
// drawn at 1x or 2x on each axis from the measured active picture size.
// Layout ROM: address row*80 + cell, {glyph[5:0], ext, code[7:0]}; the
// set 2 make code is the key identity, 0 an empty cell. Font ROM: address
// {glyph, line}, one 4-bit cell row.
//
// Pad while open: d-pad moves (with repeat), A holds the chosen key, B is
// Backspace, X Space, Y Enter, Select moves the keyboard top/bottom.
// Shift, Ctrl and Alt are sticky: chosen once they stay down until the
// next ordinary key is released.
//
// Row 6 of the layout ROM is a strip of drive icons (floppy, CD, hard
// disk) drawn in the top left corner while that drive's light is on; an
// image transfer lights it for at least 100 ms.

module osd_keyboard #(
	parameter CLK_HZ      = 57272727,
	parameter LAYOUT_INIT = "osk_layout.mif",
	parameter FONT_INIT   = "osk_font.mif",
	parameter LAYOUT_SIM  = "rtl/osk/osk_layout.hex",
	parameter FONT_SIM    = "rtl/osk/osk_font.hex"
)
(
	input             clk,
	input             reset,

	input             toggle,        // mapped button, either pad
	input             lights_en,
	input       [2:0] activity,      // {hdd, cd, fdd}
	input      [12:0] pad1_i,        // {Z, Y, X, C, zoom, select, run, B, A, up, down, left, right}
	input      [12:0] pad2_i,
	output     [12:0] pad1_o,
	output     [12:0] pad2_o,
	output reg        open,

	input      [10:0] ps2_key_i,     // hps_io: [10] toggles per event, [9] pressed, [8] extended, [7:0] code
	output reg [10:0] ps2_key_o,

	input             ce_pix,
	input       [7:0] r_i,
	input       [7:0] g_i,
	input       [7:0] b_i,
	input             hs_i,
	input             vs_i,
	input             hb_i,
	input             vb_i,
	input             field_i,
	output reg  [7:0] r_o,
	output reg  [7:0] g_o,
	output reg  [7:0] b_o,
	output reg        hs_o,
	output reg        vs_o,
	output reg        hb_o,
	output reg        vb_o,
	output reg        field_o
);

localparam CELLS   = 78;           // the last cell is empty and closes the right edge
localparam ROWS    = 6;
localparam [6:0] LAST = CELLS - 2;  // last cell the cursor may rest on
localparam [31:0] PACE_CLKS = CLK_HZ / 500;          // 2 ms between events
localparam [31:0] REP_FIRST = CLK_HZ / 10 * 3;       // 300 ms
localparam [31:0] REP_NEXT  = CLK_HZ / 100 * 6;      // 60 ms
localparam [31:0] MS_CLKS   = CLK_HZ / 1000;
localparam        STRIP_ROW = 6;
localparam [6:0]  STRIP_END = 10;    // last strip cell

// ---- pad view ----
wire [12:0] pad = pad1_i | pad2_i;
assign pad1_o = open ? 13'd0 : pad1_i;
assign pad2_o = open ? 13'd0 : pad2_i;

reg toggle_q, open_q, top, sel_q;
always @(posedge clk) begin
	toggle_q <= toggle;
	open_q   <= open;
	sel_q    <= pad[7];
	if (reset) begin open <= 0; top <= 0; end
	else begin
		if (toggle & ~toggle_q) open <= ~open;
		if (open && pad[7] && !sel_q) top <= ~top;
	end
end

// ---- layout ROM: port A for the raster, port B for the cursor ----
reg   [2:0] krow, crow;
reg   [6:0] kcell, ccell;
wire  [8:0] lay_a = {krow, 6'd0} + {2'd0, krow, 4'd0} + {2'd0, kcell};
wire  [8:0] lay_b = {crow, 6'd0} + {2'd0, crow, 4'd0} + {2'd0, ccell};
wire [19:0] lay_qa, lay_qb;

// [gamebub] generated ROM (scripts/import_osk.py), same timing
osk_layout_rom layout
(
	.clk(clk),
	.addr_a(lay_a), .q_a(lay_qa),
	.addr_b(lay_b), .q_b(lay_qb)
);

// ---- cursor walk ----
// A move steps one cell or row per two clocks until it lands on a key
// other than the one it left (sideways) or any key (up/down); the grid
// wraps, so the walk always ends, and a step budget guards it anyway.
localparam D_LEFT = 3'd0, D_RIGHT = 3'd1, D_UP = 3'd2, D_DOWN = 3'd3, D_NONE = 3'd4;
reg        cbusy;
reg  [2:0] cdir;
reg  [1:0] cwait;
reg  [6:0] csteps;
reg  [8:0] cur_code, from_code;
reg  [3:0] dpad_q;
reg [24:0] rep;
reg        nav_req;
reg  [2:0] nav_dir;
wire [8:0] code_b = lay_qb[8:0];
wire       cstop  = (cdir == D_NONE) || (code_b != 0 && (cdir[2:1] != 2'd0 || code_b != from_code)) || (csteps == 0);

always @(posedge clk) begin
	// d-pad edges and repeat; up, down, left, right in that priority
	dpad_q  <= pad[3:0];
	nav_req <= 0;
	if (!open) rep <= 0;
	else if (pad[3:0] != dpad_q) begin
		if (pad[3:0] != 0) begin nav_req <= 1; rep <= REP_FIRST[24:0]; end
	end
	else if (pad[3:0] != 0) begin
		if (rep == 0) begin nav_req <= 1; rep <= REP_NEXT[24:0]; end
		else rep <= rep - 1'd1;
	end
	nav_dir <= pad[3] ? D_UP : pad[2] ? D_DOWN : pad[1] ? D_LEFT : D_RIGHT;

	if (reset) begin
		cbusy <= 0; crow <= 3'd3; ccell <= 7'd7; cur_code <= 0; cdir <= D_NONE; cwait <= 0; csteps <= 0; from_code <= 0;
	end
	else if (!cbusy) begin
		if (open && !open_q) begin cbusy <= 1; cdir <= D_NONE; cwait <= 2'd2; end
		else if (open && nav_req) begin
			cbusy <= 1; cdir <= nav_dir; from_code <= cur_code; csteps <= 7'd127; cwait <= 2'd2;
			case (nav_dir)
			D_LEFT:  ccell <= (ccell == 0) ? LAST : ccell - 1'd1;
			D_RIGHT: ccell <= (ccell == LAST) ? 7'd0 : ccell + 1'd1;
			D_UP:    crow  <= (crow == 0) ? 3'd5 : crow - 1'd1;
			default: crow  <= (crow == 3'd5) ? 3'd0 : crow + 1'd1;
			endcase
		end
	end
	else if (cwait != 0) cwait <= cwait - 1'd1;
	else if (cstop) begin cbusy <= 0; cur_code <= code_b; end
	else begin
		csteps <= csteps - 1'd1;
		cwait <= 2'd2;
		case (cdir)
		D_LEFT:  ccell <= (ccell == 0) ? LAST : ccell - 1'd1;
		D_RIGHT: ccell <= (ccell == LAST) ? 7'd0 : ccell + 1'd1;
		D_UP:    crow  <= (crow == 0) ? 3'd5 : crow - 1'd1;
		default: crow  <= (crow == 3'd5) ? 3'd0 : crow + 1'd1;
		endcase
	end
end

// ---- key press ----
localparam [8:0] C_LSHIFT = 9'h012, C_RSHIFT = 9'h059, C_CTRL = 9'h014, C_ALT = 9'h011;
localparam [8:0] C_OPT = 9'h11F;   // [gamebub] Option, sticky too
localparam [8:0] C_BKSP = 9'h066, C_SPACE = 9'h029, C_ENTER = 9'h05A;
localparam S_IDLE = 2'd0, S_SEND = 2'd1, S_MODS = 2'd2;
reg  [1:0] st, st_after;
reg  [3:0] btn_q;
reg        held;
reg  [1:0] held_src;
reg  [8:0] held_code;
reg        sh_on, sh_right, ct_on, al_on, op_on;
reg        ev_req, ev_press, ev_ack;
reg  [8:0] ev_code;
wire [3:0] btn      = {pad[11], pad[10], pad[5], pad[4]};   // Y, X, B, A
wire [3:0] btn_edge = btn & ~btn_q;
wire       cur_shift = (cur_code == C_LSHIFT) || (cur_code == C_RSHIFT);
wire       cur_mod   = cur_shift || (cur_code == C_CTRL) || (cur_code == C_ALT) || (cur_code == C_OPT);

always @(posedge clk) begin
	btn_q <= btn;
	if (reset) begin
		st <= S_IDLE; st_after <= S_IDLE; held <= 0; held_src <= 0; held_code <= 0;
		sh_on <= 0; sh_right <= 0; ct_on <= 0; al_on <= 0; op_on <= 0; ev_req <= 0; ev_press <= 0; ev_code <= 0;
	end
	else case (st)
	S_IDLE:
		if (held) begin
			if (!open || !btn[held_src]) begin
				held <= 0; ev_req <= 1; ev_press <= 0; ev_code <= held_code; st <= S_SEND; st_after <= S_MODS;
			end
		end
		else if (!open) begin
			if (sh_on | ct_on | al_on | op_on) st <= S_MODS;
		end
		else if (btn_edge[0] && cur_code != 0) begin
			if (cur_mod) begin
				// sticky modifier: on with its own code, off with the one held
				ev_req <= 1; st <= S_SEND; st_after <= S_IDLE;
				if (cur_shift) begin
					ev_press <= ~sh_on; ev_code <= sh_on ? (sh_right ? C_RSHIFT : C_LSHIFT) : cur_code;
					sh_on <= ~sh_on; sh_right <= (cur_code == C_RSHIFT);
				end
				else if (cur_code == C_CTRL) begin ev_press <= ~ct_on; ev_code <= C_CTRL; ct_on <= ~ct_on; end
				else if (cur_code == C_OPT)  begin ev_press <= ~op_on; ev_code <= C_OPT;  op_on <= ~op_on; end
				else begin ev_press <= ~al_on; ev_code <= C_ALT; al_on <= ~al_on; end
			end
			else begin
				held <= 1; held_src <= 2'd0; held_code <= cur_code;
				ev_req <= 1; ev_press <= 1; ev_code <= cur_code; st <= S_SEND; st_after <= S_IDLE;
			end
		end
		else if (btn_edge[3:1] != 0) begin
			held <= 1;
			held_src  <= btn_edge[1] ? 2'd1 : btn_edge[2] ? 2'd2 : 2'd3;
			held_code <= btn_edge[1] ? C_BKSP : btn_edge[2] ? C_SPACE : C_ENTER;
			ev_req <= 1; ev_press <= 1; ev_code <= btn_edge[1] ? C_BKSP : btn_edge[2] ? C_SPACE : C_ENTER;
			st <= S_SEND; st_after <= S_IDLE;
		end
	S_SEND:
		if (ev_ack) begin ev_req <= 0; st <= st_after; end
	default: begin
		// release the sticky modifiers one at a time
		ev_press <= 0; st_after <= S_MODS;
		if (sh_on)      begin sh_on <= 0; ev_req <= 1; ev_code <= sh_right ? C_RSHIFT : C_LSHIFT; st <= S_SEND; end
		else if (ct_on) begin ct_on <= 0; ev_req <= 1; ev_code <= C_CTRL; st <= S_SEND; end
		else if (al_on) begin al_on <= 0; ev_req <= 1; ev_code <= C_ALT;  st <= S_SEND; end
		else if (op_on) begin op_on <= 0; ev_req <= 1; ev_code <= C_OPT;  st <= S_SEND; end
		else st <= S_IDLE;
	end
	endcase
end

// ---- PS/2 merge: the HPS stream first, our events paced 2 ms apart ----
reg        hps_tog_q;
reg [16:0] pace;
always @(posedge clk) begin
	hps_tog_q <= ps2_key_i[10];
	ev_ack <= 0;
	if (pace != 0) pace <= pace - 1'd1;
	if (reset) begin ps2_key_o <= 0; pace <= 0; end
	else if (ps2_key_i[10] != hps_tog_q) ps2_key_o <= {~ps2_key_o[10], ps2_key_i[9:0]};
	else if (ev_req && !ev_ack && pace == 0) begin
		ps2_key_o <= {~ps2_key_o[10], ev_press, ev_code};
		ev_ack <= 1;
		pace <= PACE_CLKS[16:0];
	end
end

// ---- drive lights: an access holds the light for 100 ms ----
reg [16:0] ms_cnt;
reg  [6:0] hold [0:2];
reg  [2:0] lit;
always @(posedge clk) begin
	ms_cnt <= (ms_cnt == 0) ? MS_CLKS[16:0] - 1'd1 : ms_cnt - 1'd1;
	for (int i = 0; i < 3; i++) begin
		if (activity[i]) hold[i] <= 7'd100;
		else if (ms_cnt == 0 && hold[i] != 0) hold[i] <= hold[i] - 1'd1;
		lit[i] <= (hold[i] != 0);
	end
end

// ---- picture measure and placement, once a frame ----
reg  [10:0] x, y, w_meas, x0, y0;
reg         hb_q, vb_q, sx2, sy2, ksub, ksubl;
wire        line_end = hb_i & ~hb_q;
wire [10:0] x_n   = hb_i ? 11'd0 : x + 1'd1;
wire [10:0] y_n   = vb_i ? 11'd0 : line_end ? y + 1'd1 : y;
wire [10:0] h_now = line_end ? y + 1'd1 : y;
wire        w2_n  = (w_meas >= 11'd624);
wire        h2_n  = (h_now  >= 11'd400);
wire [10:0] kbw   = w2_n ? 11'd624 : 11'd312;
wire [10:0] kbh_m = h2_n ? 11'd156 : 11'd78;     // height plus the edge margin
wire [10:0] marg  = h2_n ? 11'd12  : 11'd6;
wire [10:0] xdiff = w_meas - kbw;
wire [10:0] ydiff = h_now - kbh_m;
wire [10:0] x0_n  = (w_meas <= kbw || xdiff[10:1] == 0) ? 11'd1 : {1'b0, xdiff[10:1]};
wire [10:0] y0_n  = top ? (h2_n ? 11'd48 : 11'd24) : (h_now <= kbh_m) ? 11'd1 : ydiff;   // top: under the light strip
wire [10:0] xs0   = sx2 ? 11'd32 : 11'd16;          // light strip corner
wire [10:0] ys0   = sy2 ? 11'd12 : 11'd6;

// ---- keyboard cell walk, one step ahead of the pixel it describes ----
reg         kon_h, ky_on, kstart;
reg   [1:0] kpx;
reg   [3:0] kline;
wire        kon   = kon_h & ky_on;
wire        strip = (krow == STRIP_ROW);

always @(posedge clk) begin
	if (reset) begin
		x <= 0; y <= 0; w_meas <= 0; x0 <= 1; y0 <= 1; hb_q <= 1; sx2 <= 0; sy2 <= 0;
		kon_h <= 0; ky_on <= 0; kstart <= 0; kpx <= 0; ksub <= 0; kcell <= 0; kline <= 0; ksubl <= 0; krow <= 0;
	end
	else if (ce_pix) begin
		hb_q <= hb_i;
		vb_q <= vb_i;
		x <= x_n;
		y <= y_n;
		if (line_end & ~vb_i) w_meas <= x;
		if (vb_i & ~vb_q) begin
			sx2 <= w2_n; sy2 <= h2_n; x0 <= x0_n; y0 <= y0_n;
		end

		// horizontal: state for the next pixel
		kstart <= 0;
		if (hb_i) kon_h <= 0;
		else if (x_n == (strip ? xs0 : x0) && ky_on) begin
			kon_h <= 1; kcell <= 0; kpx <= 0; ksub <= 0; kstart <= 1;
		end
		else if (kon_h) begin
			if (ksub != sx2) ksub <= ksub + 1'd1;
			else begin
				ksub <= 0;
				if (kpx != 2'd3) kpx <= kpx + 1'd1;
				else begin
					kpx <= 0; kstart <= 1;
					if (kcell == (strip ? STRIP_END : 7'(CELLS - 1))) kon_h <= 0;
					else kcell <= kcell + 1'd1;
				end
			end
		end

		// vertical: state for the next line
		if (vb_i) ky_on <= 0;
		else if (line_end) begin
			if (y_n == ys0) begin ky_on <= 1; krow <= STRIP_ROW; kline <= 0; ksubl <= 0; end
			else if (y_n == y0) begin ky_on <= 1; krow <= 0; kline <= 0; ksubl <= 0; end
			else if (ky_on) begin
				if (ksubl != sy2) ksubl <= ksubl + 1'd1;
				else begin
					ksubl <= 0;
					if (kline != 4'd11) kline <= kline + 1'd1;
					else begin
						kline <= 0;
						if (krow == ROWS - 1 || strip) ky_on <= 0;
						else krow <= krow + 1'd1;
					end
				end
			end
		end
	end
end

// ---- font ROM ----
reg   [6:0] glyph1;   // [gamebub] 7-bit glyph index
reg   [3:0] kline1;
wire  [3:0] font_q;

// [gamebub] generated ROM (scripts/import_osk.py), 128 glyphs
osk_font_rom font
(
	.clk(clk), .addr({glyph1, kline1}), .q(font_q)
);

// ---- pixel pipeline, one stage per tick ----
// 1: layout data and cell edge   2: font row and key flags
// 3: pixel class                 4: blend
reg  [28:0] v0, v1, v2;         // {r, g, b, hs, vs, hb, vb, field}
reg   [8:0] code1;
reg         kon1, edge1, top1, bot1, strip1;
reg   [1:0] kpx1, kpx2;
reg         kon2, edge2, top2, bot2, nz2, sel2, prs2, strip2, lit2;
reg   [1:0] drv2, drv3;
reg   [3:0] font2;
reg   [2:0] cls3;               // 0 none, 1 gap, 2 key, 3 chosen, 4 pressed, 5 edge, 6 text, 7 drive light
wire  [8:0] code_a = lay_qa[8:0];
wire        held_here = held && (code1 == held_code);
wire        mod_here  = (sh_on && (code1 == (sh_right ? C_RSHIFT : C_LSHIFT))) || (ct_on && code1 == C_CTRL) || (al_on && code1 == C_ALT) || (op_on && code1 == C_OPT);
wire        text2 = font2[~kpx2];       // [3] is pixel 0 of the cell

always @(posedge clk) begin
	if (ce_pix) begin
		v0 <= {r_i, g_i, b_i, hs_i, vs_i, hb_i, vb_i, field_i};
		v1 <= v0;
		v2 <= v1;

		// stage 1: the pixel just latched into v0
		code1  <= kon ? code_a : 9'd0;
		glyph1 <= lay_qa[15:9];
		kline1 <= kline;
		kpx1   <= kpx;
		kon1   <= kon & (strip ? lights_en : open);
		strip1 <= strip;
		top1   <= (kline == 0);
		bot1   <= (kline == 4'd11);
		if (kstart) edge1 <= (code_a != code1);   // a key edge where the code changes between cells
		else if (kpx != 0) edge1 <= 0;

		// stage 2
		font2 <= font_q;
		kpx2  <= kpx1;
		kon2  <= kon1;
		edge2 <= edge1;
		top2  <= top1;
		bot2  <= bot1;
		nz2   <= (code1 != 0);
		sel2  <= (code1 == cur_code);
		prs2  <= held_here | mod_here;
		strip2 <= strip1;
		drv2  <= code1[1:0];
		lit2  <= (code1[1:0] == 2'd1) ? lit[0] : (code1[1:0] == 2'd2) ? lit[1] : lit[2];

		// stage 3
		drv3 <= drv2;
		cls3 <= !kon2 ? 3'd0 :
		        strip2 ? ((nz2 & text2 & lit2) ? 3'd7 : 3'd0) :
		        (nz2 & text2) ? 3'd6 :
		        (edge2 | (nz2 & (top2 | bot2))) ? 3'd5 :
		        !nz2 ? 3'd1 :
		        prs2 ? 3'd4 :
		        sel2 ? 3'd3 : 3'd2;

		// stage 4: translucent fills add a tint to a quarter of the picture
		{hs_o, vs_o, hb_o, vb_o, field_o} <= v2[4:0];
		case (cls3)
		3'd1:    begin r_o <= {1'b0, v2[28:22]};         g_o <= {1'b0, v2[20:14]};         b_o <= {1'b0, v2[12:6]};         end
		3'd2:    begin r_o <= {2'b0, v2[28:23]} + 8'h30; g_o <= {2'b0, v2[20:15]} + 8'h30; b_o <= {2'b0, v2[12:7]} + 8'h38; end
		3'd3:    begin r_o <= {2'b0, v2[28:23]} + 8'h20; g_o <= {2'b0, v2[20:15]} + 8'h58; b_o <= {2'b0, v2[12:7]} + 8'hA8; end
		3'd4:    begin r_o <= {2'b0, v2[28:23]} + 8'hA8; g_o <= {2'b0, v2[20:15]} + 8'h70; b_o <= {2'b0, v2[12:7]} + 8'h18; end
		3'd5:    begin r_o <= {2'b0, v2[28:23]} + 8'h98; g_o <= {2'b0, v2[20:15]} + 8'h98; b_o <= {2'b0, v2[12:7]} + 8'h98; end
		3'd6:    begin r_o <= 8'hF8;                     g_o <= 8'hF8;                     b_o <= 8'hF8;                     end
		3'd7:    begin r_o <= (drv3 == 2'd1) ? 8'h40 : 8'hF8; g_o <= (drv3 == 2'd3) ? 8'h40 : (drv3 == 2'd2) ? 8'hB0 : 8'hF0; b_o <= 8'h30; end
		default: begin r_o <= v2[28:21];                 g_o <= v2[20:13];                 b_o <= v2[12:5];                  end
		endcase
	end
end

endmodule
