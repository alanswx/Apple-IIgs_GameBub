//============================================================================
//  VGC -- Video Graphics Controller (Apple II modes + Super Hi-Res)
//
//  Copyright (c) Pierre Cornier
//  Copyright (c) Steven A. Wilson
//  Copyright (c) Alan Steremberg
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program. If not, see <https://www.gnu.org/licenses/>.
//============================================================================

/* verilator lint_off TIMESCALEMOD */
module vgc (
input CLK_28M,
input CLK_14M,
input clk_vid,
input ce_pix,
input[9:0] H,
input[8:0] V,
output reg scanline_irq,

output vbl_irq,
output reg [7:0] R,
output reg [7:0] G,
output reg [7:0] B,
output [22:0] video_addr,
input [7:0] video_data,
input [7:0] TEXTCOLOR, // 7:4 text color 3:0 background
input [3:0] BORDERCOLOR,
input HIRES_MODE,
input AN3,
input STORE80,
input ALTCHARSET,
input EIGHTYCOL,
input PAGE2,
input TEXTG,
input MIXG,
input SHRG,
input DHRG_MONO,
// SHR pixel byte on the real Mega II fetch schedule (floating-bus view;
// see the shr_line buffer below)
output [7:0] shr_bus_byte
);

// Counter values for the border boundaries

// NB: Top border range is non-monotonic due to the legacy counter reset.
// It spans counts 499 to 511, then 250 to 255.
// See comments in video_timing.v for more information.
localparam HTOTAL = 10'd911;      // count 911, 912 total pixel clocks
localparam V_SCAN_PRE = 9'd255;   // Line before buffer scan
localparam V_SCAN = 9'd256;       // Buffer line 0
localparam BBE = V_SCAN + 9'd192; // bottom border (IIe)
localparam BB = V_SCAN + 9'd200;  // bottom border (SHRG)
localparam BT = 9'd499;           // top border start

// Horizontal layout, derived from the Mega II horizontal counter (TN.IIGS.039).
// Active video = chars $58..$7F (40 columns). The Apple II active region is the
// Mega II active area itself (40 chars * 14 px = 560 px); SHRG widens it by 40 px
// each side (to 640 px), borrowing from the border. Single anchor: HACTIVE = the
// pixel where char $58 (active video) begins -- matches video_timing.v HACTIVE_PIX.
localparam HACTIVE = 10'd84;          // active display start (char $58)
localparam BLE = HACTIVE;             // IIe active start  (= 84)
localparam BRE = BLE + 10'd560;       // IIe active end    (= 644)
localparam BL  = BLE - 10'd40;        // SHRG active start (= 44)
localparam BR  = BL + 10'd640;        // SHRG active end   (= 684)

assign video_addr = SHRG ? video_addr_shrg : video_addr_ii;
// NEWVIDEO[6] controls CPU memory mapping for Double Hi-Res, but per the IIgs Hardware Reference,
// when NEWVIDEO[7]=1 (SHR mode), bit 6 is overridden and VGC always uses linear addressing.
// The video buffer is $E1/2000-$9CFF with SCBs at $9D00 and palettes at $9E00.

/* SHRG */
reg [22:0] video_addr_shrg_1;
reg [22:0] video_addr_shrg;
reg [3:0] r_shrg[16];
reg [3:0] g_shrg[16];
reg [3:0] b_shrg[16];

// --- SHR floating-bus schedule (FLOATBUS modes A/B, spots #5/#7/#8) --------
// The real VGC fetches the 160 pixel bytes during the 40 active Mega II
// chars (4 per 1MHz slot, H 84..644) and the NEXT line's SCB + 32 palette
// bytes in LATE HBL (palette visible at capture col 16 ~H872, SCB at col 17
// ~H886). Our display pipeline fetches on its own earlier schedule; to keep
// the display byte-identical, pixel bytes are captured into a line buffer
// during the display walk and replayed for the bus on the real schedule,
// and the SCB/palette get an ADDITIONAL bus-visible address walk in late
// HBL -- the display still latches from its existing HTOTAL-4/H<32 pass, so
// scanline-IRQ timing and palette latching are unchanged.
reg [7:0] shr_line [0:159];
reg [7:0] shr_wr_idx;
reg [22:0] shr_pal_base;   // late-HBL palette base ($9E00 + SCB[3:0]*32)
reg [2:0]  shr_pal_slot;   // palette slot 0..7 (4 bytes each)
reg [5:0] shr_rd_char;   // active Mega II char 0..39
reg [3:0] shr_rd_sub;    // pixel within char 0..13
always @(posedge clk_vid) if (ce_pix) begin
    if (H == BLE-1) begin
        shr_rd_char <= 6'd0;
        shr_rd_sub  <= 4'd0;
    end else if (shr_rd_sub == 4'd13) begin
        shr_rd_sub  <= 4'd0;
        shr_rd_char <= shr_rd_char + 6'd1;
    end else
        shr_rd_sub <= shr_rd_sub + 4'd1;
end
// The VGC completes the slot's 4 fetches early in the slot, so the byte on
// the bus at the CPU sample point is the LAST of the group (4k+3) -- verified
// against FLOATBUS spot #5 (expected $0F = byte 3 of its row, not byte 0).
assign shr_bus_byte = shr_line[{shr_rd_char, 2'b11}];
// ---------------------------------------------------------------------------


// debug with a fixed palette
/*
initial begin
r_shrg[0]=0;
g_shrg[0]=0;
b_shrg[0]=0;
r_shrg[1]=4'hd;
g_shrg[1]=4'h0;
b_shrg[1]=4'h3;
r_shrg[2]=4'h0;
g_shrg[2]=4'h0;
b_shrg[2]=4'h9;
r_shrg[3]=4'hd;
g_shrg[3]=4'h0;
b_shrg[3]=4'hd;
r_shrg[4]=4'h0;
g_shrg[4]=4'h7;
b_shrg[4]=4'h0;
r_shrg[5]=0;
g_shrg[5]=0;
b_shrg[5]=0;
r_shrg[6]=4'hd;
g_shrg[6]=4'h0;
b_shrg[6]=4'h3;
r_shrg[7]=4'h0;
g_shrg[7]=4'h0;
b_shrg[7]=4'h9;
r_shrg[8]=4'hd;
g_shrg[8]=4'h0;
b_shrg[8]=4'hd;
r_shrg[9]=4'hf;
g_shrg[9]=4'hf;
b_shrg[9]=4'hf;
r_shrg[10]=4'h5;
g_shrg[10]=4'h5;
b_shrg[10]=4'h5;
r_shrg[11]=0;
g_shrg[11]=0;
b_shrg[11]=0;
r_shrg[12]=4'hd;
g_shrg[12]=4'h0;
b_shrg[12]=4'h3;
r_shrg[13]=4'h0;
g_shrg[13]=4'h0;
b_shrg[13]=4'h9;
r_shrg[14]=4'hd;
g_shrg[14]=4'h0;
b_shrg[14]=4'hd;
r_shrg[15]=4'h7;
g_shrg[15]=4'h7;
b_shrg[15]=4'h0;
end
*/

reg [3:0] shrg_r_pix;
reg [3:0] shrg_g_pix;
reg [3:0] shrg_b_pix;

// First pixel combinational computation - bypasses pipeline latency for H=32
// At H=32, video_data has first pixel byte, compute color combinationally
wire [3:0] first_pix_idx_320 = video_data[7:4];  // 320 mode: high nibble is first pixel
wire [3:0] first_pix_idx_640 = {2'b10, video_data[7:6]};  // 640 mode: bits 7:6, palette colors 8-11
wire [3:0] first_pix_r = scb[7] ? r_shrg[first_pix_idx_640] : r_shrg[first_pix_idx_320];
wire [3:0] first_pix_g = scb[7] ? g_shrg[first_pix_idx_640] : g_shrg[first_pix_idx_320];
wire [3:0] first_pix_b = scb[7] ? b_shrg[first_pix_idx_640] : b_shrg[first_pix_idx_320];

// Latched border color - sampled at start of each scanline for consistent raster effects
reg [3:0] bordercolor_latched;
// one cycle before the end of the left border, pull down the scp
reg [7:0] scb;
reg [1:0] h_counter;
reg [3:0] last_pixel;
reg [3:0] pal_counter;
always @(posedge clk_vid) if(ce_pix)
begin
//$display("video_data = %x video_addr = %x video_addr_shrg %x video_addr_ii %x  H %x V %x NEWVIDEO[6] %x NEWVIDEO[7]",video_data,video_addr,video_addr_shrg,video_addr_ii,H,V,NEWVIDEO[6],NEWVIDEO[7]);
	// Latch border color at start of each scanline for consistent raster effects
	// This ensures games that cycle BORDERCOLOR mid-scanline get straight horizontal lines
	if (H == 0)
		bordercolor_latched <= BORDERCOLOR;
	// Pre-fetch SCB during HBLANK for next scanline's display
	if (H==(HTOTAL-4)) begin
		video_addr_shrg <= 23'h19D00+{14'b0,  (V[7:0]+1'b1)};
	end
	else if (H==(HTOTAL-2)) begin
		scb <= video_data;
		// Check for scanline interrupt: SCB bit 6, SHR mode enabled, valid scanline range
		// V >= 15 allows SCB[0] interrupt to fire at V=15 (just before scanline 0 displays at V=16)
`ifdef VGC_DEBUG
		if (V >= (BT-1) && V < 'd206 && V[4:0] == 5'd0)  // Debug every 32nd line in valid range
			$display("VGC_SCANIRQ_CHECK: V=%d H=%03x SCB=%02x SCB[6]=%d NEWVIDEO[7]=%d -> fire=%d",
			         V, H, video_data, video_data[6], SHRG, (video_data[6] && SHRG));
`endif
		if (video_data[6] && SHRG && V >= V_SCAN_PRE && V < BB)
			scanline_irq<=1;
		// Setup palette base address from SCB palette selector (bits 3:0)
		// Each palette is 32 bytes at $9E00 + (palette * 32)
		video_addr_shrg_1 <= 23'h19E00 + {14'b0, video_data[3:0], 5'b00000};
		video_addr_shrg <= 23'h19E00 + {14'b0, video_data[3:0], 5'b00000};
	end else if (H==HTOTAL) begin
		pal_counter<=0;
		scanline_irq<=0;
		video_addr_shrg <= video_addr_shrg + 1'b1;
		video_addr_shrg_1 <= video_addr_shrg_1 + 1'b1;
	end else if (H < 32) begin // 32 = 2 bytes * 16 palette entries, not a border width
		// Read palette data - due to address pre-increment at H=0x390, first read is at ODD address
		// Palette format: odd addresses have G[7:4],B[3:0]; even addresses have 0,R[3:0]
		if (video_addr_shrg[0]) begin
			b_shrg[pal_counter]<=video_data[3:0];
			g_shrg[pal_counter]<=video_data[7:4];
		end else begin
			r_shrg[pal_counter]<=video_data[3:0];
			pal_counter<=pal_counter+1'd1;
		end
		video_addr_shrg <= video_addr_shrg + 1'b1;
		video_addr_shrg_1 <= video_addr_shrg_1 + 1'b1;
	end else if (H==(BL-1)) begin
	   // Setup pixel data address: $2000 + (scanline * 160 bytes/line)
	   video_addr_shrg_1 <= 23'h12000 + ({15'd0, V[7:0]} * 23'd160);
	   video_addr_shrg <= 23'h12000 + ({15'd0, V[7:0]} * 23'd160);
	   h_counter<=0;
	   shr_wr_idx<=0;
	end else if (H < BR) begin
		h_counter<=h_counter+1'b1;
		// Only advance address for first 159 advances (byte 0->159), skip the 160th
		// With 1-cycle display shift, advance #159 happens at H=667, so skip advance at H>=668
		if (h_counter==2'd2 && H < (BR-4)) begin
			video_addr_shrg <= video_addr_shrg + 1'b1;
			video_addr_shrg_1 <= video_addr_shrg_1 + 1'b1;
		end
		// Capture each pixel byte for the floating-bus replay (h_counter=='b01:
		// video_data holds byte shr_wr_idx, one tick after the address settled)
		if (h_counter==2'b01 && shr_wr_idx < 8'd160) begin
			shr_line[shr_wr_idx] <= video_data;
			shr_wr_idx <= shr_wr_idx + 8'd1;
		end
		if (scb[7]) begin
			case(h_counter)
				'b00: 
				begin
					shrg_r_pix <= r_shrg[ {2'b10,video_data[7:6]}];
					shrg_g_pix <= g_shrg[ {2'b10,video_data[7:6]}];
					shrg_b_pix <= b_shrg[ {2'b10,video_data[7:6]}];
				end
				'b01:
				begin
					shrg_r_pix <= r_shrg[ {2'b11,video_data[5:4]}];
					shrg_g_pix <= g_shrg[ {2'b11,video_data[5:4]}];
					shrg_b_pix <= b_shrg[ {2'b11,video_data[5:4]}];
				end
				'b10:
				begin
					shrg_r_pix <= r_shrg[ {2'b00,video_data[3:2]}];
					shrg_g_pix <= g_shrg[ {2'b00,video_data[3:2]}];
					shrg_b_pix <= b_shrg[ {2'b00,video_data[3:2]}];
				end
				'b11:
				begin
					shrg_r_pix <= r_shrg[ {2'b01,video_data[1:0]}];
					shrg_g_pix <= g_shrg[ {2'b01,video_data[1:0]}];
					shrg_b_pix <= b_shrg[ {2'b01,video_data[1:0]}];
				end
			endcase
		end else begin
			case(h_counter)
				'b00: 
				begin
					if (video_data[7:4]==4'b0 && scb[5]) begin
					//$display("scb[5] %x use last_pixel %x",scb[5],last_pixel);
						shrg_r_pix <= r_shrg[ last_pixel ];
						shrg_g_pix <= g_shrg[ last_pixel ];
						shrg_b_pix <= b_shrg[ last_pixel ];
					end else begin
					    //$display("scb[5] %x  set last_pixel %x",scb[5],video_data[7:4]);
						last_pixel<=video_data[7:4];
						shrg_r_pix <= r_shrg[  video_data[7:4]];
						shrg_g_pix <= g_shrg[  video_data[7:4]];
						shrg_b_pix <= b_shrg[  video_data[7:4]];
					end
				end
				'b10:
				begin
					if (video_data[3:0]==4'b0 && scb[5]) begin
						shrg_r_pix <= r_shrg[ last_pixel ];
						shrg_g_pix <= g_shrg[ last_pixel ];
						shrg_b_pix <= b_shrg[ last_pixel ];
					end else begin
						last_pixel<=video_data[3:0];
						shrg_r_pix <= r_shrg[  video_data[3:0]];
						shrg_g_pix <= g_shrg[  video_data[3:0]];
						shrg_b_pix <= b_shrg[  video_data[3:0]];
					end
				end
			endcase
		end

	end else if (H == 10'd750) begin
		// --- bus-visible late-HBL prefetch (real VGC bus schedule; the
		// display keeps latching from the existing HTOTAL-4 / H<32 pass).
		// Everything on this bus shows the LAST byte of its fetch group
		// (like the pixel slots' byte 4k+3): the palette moves 4 bytes per
		// 1MHz slot (samples at capture cols 9-16 = bytes 3,7,...,31), and
		// the SCB is fetched as an even/odd pair for the CURRENT row, the
		// odd byte visible at col 17 ($9D00 + (nextrow|1)). Palette select
		// keys off the NEXT row's SCB -- these fetches prepare the row about
		// to be displayed (capture cells for row r read at the end of line
		// r-1). Verified against FLOATBUS expct7/expct8 with the test's own
		// SCB table. ---
		video_addr_shrg <= 23'h19D00 + {14'b0, (V[7:0]+8'd1)};      // SCB(next row)
	end else if (H == 10'd752) begin
		shr_pal_base <= 23'h19E00 + {14'b0, video_data[3:0], 5'b00000};
		shr_pal_slot <= 3'd0;
	end else if (H == 10'd758 || H == 10'd772 || H == 10'd786 || H == 10'd800
	          || H == 10'd814 || H == 10'd828 || H == 10'd842 || H == 10'd856) begin
		video_addr_shrg <= shr_pal_base + {18'b0, shr_pal_slot, 2'b11};  // byte 4m+3
		shr_pal_slot <= shr_pal_slot + 3'd1;
	end else if (H == 10'd870) begin
		// SCB even/odd pair for the NEXT row; the odd byte is what the CPU
		// samples at capture col 17
		video_addr_shrg <= 23'h19D00 + {14'b0, (V[7:0]+8'd1) | 8'd1};
	end

	// Clear SHRG pixel registers during left border to ensure clean start
	// Also clear at right border for completeness
	if (SHRG && (H < BL || H >= BR)) begin
		shrg_r_pix <= 4'b0;
		shrg_g_pix <= 4'b0;
		shrg_b_pix <= 4'b0;
	end

end





/* APPLE IIe */

// Flash counter for blinking text (~2Hz, toggles every ~0.25 seconds)
reg [22:0] flash_cnt;
always @(posedge clk_vid) if (ce_pix) flash_cnt <= flash_cnt + 1'b1;
wire flash_state = flash_cnt[21];

// Apple IIgs color palette (16 colors) - matches KEGS g_lores_colors
reg [11:0] palette_rgb_r[0:15] = '{
    12'h000, // 0   Black
    12'hd03, // 1   Deep Red
    12'h009, // 2   Dark Blue
    12'hd0d, // 3   Purple
    12'h070, // 4   Dark Green
    12'h555, // 5   Dark Gray
    12'h22f, // 6   Medium Blue
    12'h6af, // 7   Light Blue
    12'h852, // 8   Brown
    12'hf60, // 9   Orange
    12'haaa, // 10  Light Gray
    12'hf98, // 11  Pink
    12'h0d0, // 12  Light Green
    12'hff0, // 13  Yellow
    12'h0f9, // 14  Aquamarine
    12'hfff  // 15  White
};

// Color lookup functions using IIgs palette
// Use latched border color for consistent horizontal lines during raster effects
wire [11:0] BORGB = palette_rgb_r[bordercolor_latched];
wire [11:0] TRGB = palette_rgb_r[TEXTCOLOR[7:4]];
wire [11:0] BRGB = palette_rgb_r[TEXTCOLOR[3:0]];
// Authentic Apple II NTSC Color Artifacting Algorithm  
// Based on apple2hack reference implementation
// Uses 6-pixel shift register and color basis vectors

// Apple II color basis vectors (RGB values from reference)
reg [7:0] basis_r[0:3];
reg [7:0] basis_g[0:3]; 
reg [7:0] basis_b[0:3];

// Initialize color basis vectors for Apple II NTSC colors
initial begin
    basis_r[0] = 8'h88; basis_g[0] = 8'h22; basis_b[0] = 8'h2C; // Color 0
    basis_r[1] = 8'h38; basis_g[1] = 8'h24; basis_b[1] = 8'hA0; // Color 1  
    basis_r[2] = 8'h07; basis_g[2] = 8'h67; basis_b[2] = 8'h2C; // Color 2
    basis_r[3] = 8'h38; basis_g[3] = 8'h52; basis_b[3] = 8'h07; // Color 3
end

// 6-pixel shift register for authentic Apple II color detection
reg [5:0] apple2_shift_reg;

// Horizontal pixel counter for authentic Apple II color phase (modulo 4)
// Use H counter with offset to maintain proper phase relationship
reg [10:0] pixel_counter;
// Color phase for NTSC artifact colors - needs to be aligned with actual Apple II timing
// The base phase comes from H position with an offset for correct alignment.
// Bit 7 of the hires byte (stored in graphics_color[0]) shifts the phase by 1,
// selecting between violet/green (bit7=0) and blue/orange (bit7=1) palettes.
wire [1:0] color_phase_base = (H[1:0] + 2'b11) & 2'b11; // Offset by 3 for base alignment
wire [1:0] color_phase = (color_phase_base + {1'b0, graphics_color[0]}) & 2'b11;

// Authentic Apple II tint consistency check
wire consistent_tint = (apple2_shift_reg[0] == apple2_shift_reg[4]) & 
                       (apple2_shift_reg[5] == apple2_shift_reg[1]);

// --- Double hi-res 16-color decode (AppleColor RGB card behavior) ----------
// Ported from gssquared displaypp (VideoScanGenerator_RGB + HiresColorTable):
// an 11-bit sliding window over the 560-bit DHR pixel stream (oldest bit at
// [10], matching the reference's shiftreg<<1) indexes a 2048x16 LUT that
// yields four 4-bit colors per 4 pixels consumed (MSB nibble = leftmost).
// A group lookup latches every 4th pixel; the decoded image therefore trails
// the bit stream by 6 pixels and the dhires-color display window is shifted
// to match. NEWVIDEO[5] (DHRG_MONO) = 1 keeps the raw 1bpp mono rendering.
reg [15:0] dhr_lut [0:2047];
// [gamebub] begin inlined dhr_lut.vh
// Generated from gssquared displaypp/render/GSRGB_LUT.hpp HiresColorTable[2048]
// (AppleColor RGB-card DHR/hires decode: 11-bit pixel window -> four 4-bit
// color indices into the GSHGR palette, MSB nibble = leftmost pixel).
// Do not edit by hand -- regenerate from the reference emulator.
initial begin
  dhr_lut[0] = 16'hFFFF;
  dhr_lut[1] = 16'hFFFF;
  dhr_lut[2] = 16'hFFFF;
  dhr_lut[3] = 16'hFFFF;
  dhr_lut[4] = 16'hFFFF;
  dhr_lut[5] = 16'hFFFF;
  dhr_lut[6] = 16'hFFFF;
  dhr_lut[7] = 16'hFFFF;
  dhr_lut[8] = 16'hFFFA;
  dhr_lut[9] = 16'hFFF8;
  dhr_lut[10] = 16'hFFFE;
  dhr_lut[11] = 16'hFFFB;
  dhr_lut[12] = 16'hFFF2;
  dhr_lut[13] = 16'hFFF1;
  dhr_lut[14] = 16'hFFF4;
  dhr_lut[15] = 16'hFFF0;
  dhr_lut[16] = 16'hFF99;
  dhr_lut[17] = 16'hFF99;
  dhr_lut[18] = 16'hFFDD;
  dhr_lut[19] = 16'hFFDD;
  dhr_lut[20] = 16'hFFCC;
  dhr_lut[21] = 16'hFFCC;
  dhr_lut[22] = 16'hFF77;
  dhr_lut[23] = 16'hFF77;
  dhr_lut[24] = 16'hFF88;
  dhr_lut[25] = 16'hFF88;
  dhr_lut[26] = 16'hFFBB;
  dhr_lut[27] = 16'hFFBB;
  dhr_lut[28] = 16'hFF11;
  dhr_lut[29] = 16'hFF11;
  dhr_lut[30] = 16'hFF00;
  dhr_lut[31] = 16'hFF00;
  dhr_lut[32] = 16'hF66F;
  dhr_lut[33] = 16'hF666;
  dhr_lut[34] = 16'hF666;
  dhr_lut[35] = 16'hF666;
  dhr_lut[36] = 16'hF553;
  dhr_lut[37] = 16'hF555;
  dhr_lut[38] = 16'hF555;
  dhr_lut[39] = 16'hF555;
  dhr_lut[40] = 16'hFEEE;
  dhr_lut[41] = 16'hFEEE;
  dhr_lut[42] = 16'hFEEE;
  dhr_lut[43] = 16'hFEEE;
  dhr_lut[44] = 16'hF444;
  dhr_lut[45] = 16'hF444;
  dhr_lut[46] = 16'hF444;
  dhr_lut[47] = 16'hF444;
  dhr_lut[48] = 16'hFDDF;
  dhr_lut[49] = 16'hFDD9;
  dhr_lut[50] = 16'hFDDD;
  dhr_lut[51] = 16'hFDDD;
  dhr_lut[52] = 16'hF773;
  dhr_lut[53] = 16'hF77C;
  dhr_lut[54] = 16'hF777;
  dhr_lut[55] = 16'hF777;
  dhr_lut[56] = 16'hFBBB;
  dhr_lut[57] = 16'hFBBB;
  dhr_lut[58] = 16'hFBBB;
  dhr_lut[59] = 16'hFBBB;
  dhr_lut[60] = 16'hF000;
  dhr_lut[61] = 16'hF000;
  dhr_lut[62] = 16'hF000;
  dhr_lut[63] = 16'hF000;
  dhr_lut[64] = 16'h33FF;
  dhr_lut[65] = 16'h33FF;
  dhr_lut[66] = 16'h3333;
  dhr_lut[67] = 16'h3333;
  dhr_lut[68] = 16'h3333;
  dhr_lut[69] = 16'h3333;
  dhr_lut[70] = 16'h3333;
  dhr_lut[71] = 16'h3333;
  dhr_lut[72] = 16'h22AA;
  dhr_lut[73] = 16'h22AA;
  dhr_lut[74] = 16'h222E;
  dhr_lut[75] = 16'h222B;
  dhr_lut[76] = 16'h2222;
  dhr_lut[77] = 16'h2222;
  dhr_lut[78] = 16'h2224;
  dhr_lut[79] = 16'h2220;
  dhr_lut[80] = 16'hCCCF;
  dhr_lut[81] = 16'hCCC9;
  dhr_lut[82] = 16'hCCC6;
  dhr_lut[83] = 16'hCCCD;
  dhr_lut[84] = 16'hCCCC;
  dhr_lut[85] = 16'hCCCC;
  dhr_lut[86] = 16'hCCCC;
  dhr_lut[87] = 16'hCCCC;
  dhr_lut[88] = 16'h1111;
  dhr_lut[89] = 16'h1111;
  dhr_lut[90] = 16'h1111;
  dhr_lut[91] = 16'h1111;
  dhr_lut[92] = 16'h1111;
  dhr_lut[93] = 16'h1111;
  dhr_lut[94] = 16'h1111;
  dhr_lut[95] = 16'h1110;
  dhr_lut[96] = 16'h55FF;
  dhr_lut[97] = 16'h55FF;
  dhr_lut[98] = 16'h5566;
  dhr_lut[99] = 16'h5566;
  dhr_lut[100] = 16'h5553;
  dhr_lut[101] = 16'h5555;
  dhr_lut[102] = 16'h5555;
  dhr_lut[103] = 16'h5555;
  dhr_lut[104] = 16'h44AA;
  dhr_lut[105] = 16'h44AA;
  dhr_lut[106] = 16'h44EE;
  dhr_lut[107] = 16'h44EE;
  dhr_lut[108] = 16'h4444;
  dhr_lut[109] = 16'h4444;
  dhr_lut[110] = 16'h4444;
  dhr_lut[111] = 16'h4444;
  dhr_lut[112] = 16'h777F;
  dhr_lut[113] = 16'h7779;
  dhr_lut[114] = 16'h7776;
  dhr_lut[115] = 16'h777D;
  dhr_lut[116] = 16'h7773;
  dhr_lut[117] = 16'h777C;
  dhr_lut[118] = 16'h7777;
  dhr_lut[119] = 16'h7777;
  dhr_lut[120] = 16'h0000;
  dhr_lut[121] = 16'h0000;
  dhr_lut[122] = 16'h0000;
  dhr_lut[123] = 16'h0000;
  dhr_lut[124] = 16'h0000;
  dhr_lut[125] = 16'h0000;
  dhr_lut[126] = 16'h0000;
  dhr_lut[127] = 16'h0000;
  dhr_lut[128] = 16'hAFFF;
  dhr_lut[129] = 16'hAFFF;
  dhr_lut[130] = 16'hAFFF;
  dhr_lut[131] = 16'hAFFF;
  dhr_lut[132] = 16'hAAAA;
  dhr_lut[133] = 16'hAAAA;
  dhr_lut[134] = 16'hAAAA;
  dhr_lut[135] = 16'hAAAA;
  dhr_lut[136] = 16'hAAAA;
  dhr_lut[137] = 16'hAAAA;
  dhr_lut[138] = 16'hAAAE;
  dhr_lut[139] = 16'hAAAB;
  dhr_lut[140] = 16'hAAA2;
  dhr_lut[141] = 16'hAAA1;
  dhr_lut[142] = 16'hAAA4;
  dhr_lut[143] = 16'hAAA0;
  dhr_lut[144] = 16'h8999;
  dhr_lut[145] = 16'h8999;
  dhr_lut[146] = 16'h8999;
  dhr_lut[147] = 16'h8999;
  dhr_lut[148] = 16'h88CC;
  dhr_lut[149] = 16'h88CC;
  dhr_lut[150] = 16'h8877;
  dhr_lut[151] = 16'h8877;
  dhr_lut[152] = 16'h8888;
  dhr_lut[153] = 16'h8888;
  dhr_lut[154] = 16'h8888;
  dhr_lut[155] = 16'h888B;
  dhr_lut[156] = 16'h8811;
  dhr_lut[157] = 16'h8811;
  dhr_lut[158] = 16'h8800;
  dhr_lut[159] = 16'h8800;
  dhr_lut[160] = 16'hEEFF;
  dhr_lut[161] = 16'hEEFF;
  dhr_lut[162] = 16'hEE66;
  dhr_lut[163] = 16'hEE66;
  dhr_lut[164] = 16'hEE33;
  dhr_lut[165] = 16'hEE33;
  dhr_lut[166] = 16'hEE55;
  dhr_lut[167] = 16'hEE55;
  dhr_lut[168] = 16'hEEEE;
  dhr_lut[169] = 16'hEEEE;
  dhr_lut[170] = 16'hEEEE;
  dhr_lut[171] = 16'hEEEE;
  dhr_lut[172] = 16'hEEE2;
  dhr_lut[173] = 16'hEEE1;
  dhr_lut[174] = 16'hEEE4;
  dhr_lut[175] = 16'hEEE0;
  dhr_lut[176] = 16'hBBBF;
  dhr_lut[177] = 16'hBBB9;
  dhr_lut[178] = 16'hBBB6;
  dhr_lut[179] = 16'hBBBD;
  dhr_lut[180] = 16'hBBB3;
  dhr_lut[181] = 16'hBBBC;
  dhr_lut[182] = 16'hBBB5;
  dhr_lut[183] = 16'hBBB7;
  dhr_lut[184] = 16'hBBBB;
  dhr_lut[185] = 16'hBBBB;
  dhr_lut[186] = 16'hBBBB;
  dhr_lut[187] = 16'hBBBB;
  dhr_lut[188] = 16'hBBBB;
  dhr_lut[189] = 16'hBBBB;
  dhr_lut[190] = 16'hBB00;
  dhr_lut[191] = 16'hBB00;
  dhr_lut[192] = 16'h2FFF;
  dhr_lut[193] = 16'h2FFF;
  dhr_lut[194] = 16'h2FFF;
  dhr_lut[195] = 16'h2FFF;
  dhr_lut[196] = 16'h2333;
  dhr_lut[197] = 16'h2333;
  dhr_lut[198] = 16'h2333;
  dhr_lut[199] = 16'h2333;
  dhr_lut[200] = 16'h22AA;
  dhr_lut[201] = 16'h22AA;
  dhr_lut[202] = 16'h222E;
  dhr_lut[203] = 16'h222B;
  dhr_lut[204] = 16'h2222;
  dhr_lut[205] = 16'h2222;
  dhr_lut[206] = 16'h2224;
  dhr_lut[207] = 16'h2220;
  dhr_lut[208] = 16'h1999;
  dhr_lut[209] = 16'h1999;
  dhr_lut[210] = 16'h1999;
  dhr_lut[211] = 16'h1999;
  dhr_lut[212] = 16'h1CCC;
  dhr_lut[213] = 16'h1CCC;
  dhr_lut[214] = 16'h1CCC;
  dhr_lut[215] = 16'h1CCC;
  dhr_lut[216] = 16'h1111;
  dhr_lut[217] = 16'h1111;
  dhr_lut[218] = 16'h1111;
  dhr_lut[219] = 16'h1111;
  dhr_lut[220] = 16'h1111;
  dhr_lut[221] = 16'h1111;
  dhr_lut[222] = 16'h1111;
  dhr_lut[223] = 16'h1110;
  dhr_lut[224] = 16'h44FF;
  dhr_lut[225] = 16'h44FF;
  dhr_lut[226] = 16'h4466;
  dhr_lut[227] = 16'h4466;
  dhr_lut[228] = 16'h4433;
  dhr_lut[229] = 16'h4433;
  dhr_lut[230] = 16'h4455;
  dhr_lut[231] = 16'h4455;
  dhr_lut[232] = 16'h44AA;
  dhr_lut[233] = 16'h44AA;
  dhr_lut[234] = 16'h44EE;
  dhr_lut[235] = 16'h44EE;
  dhr_lut[236] = 16'h4444;
  dhr_lut[237] = 16'h4444;
  dhr_lut[238] = 16'h4444;
  dhr_lut[239] = 16'h4444;
  dhr_lut[240] = 16'h000F;
  dhr_lut[241] = 16'h0009;
  dhr_lut[242] = 16'h0006;
  dhr_lut[243] = 16'h000D;
  dhr_lut[244] = 16'h0003;
  dhr_lut[245] = 16'h000C;
  dhr_lut[246] = 16'h0005;
  dhr_lut[247] = 16'h0007;
  dhr_lut[248] = 16'h0000;
  dhr_lut[249] = 16'h0000;
  dhr_lut[250] = 16'h0000;
  dhr_lut[251] = 16'h0000;
  dhr_lut[252] = 16'h0000;
  dhr_lut[253] = 16'h0000;
  dhr_lut[254] = 16'h0000;
  dhr_lut[255] = 16'h0000;
  dhr_lut[256] = 16'hFFFF;
  dhr_lut[257] = 16'hFFFF;
  dhr_lut[258] = 16'hFFFF;
  dhr_lut[259] = 16'hFFFF;
  dhr_lut[260] = 16'hFFFF;
  dhr_lut[261] = 16'hFFFF;
  dhr_lut[262] = 16'hFFFF;
  dhr_lut[263] = 16'hFFFF;
  dhr_lut[264] = 16'h999A;
  dhr_lut[265] = 16'h9998;
  dhr_lut[266] = 16'h999E;
  dhr_lut[267] = 16'h999B;
  dhr_lut[268] = 16'h9992;
  dhr_lut[269] = 16'h9991;
  dhr_lut[270] = 16'h9994;
  dhr_lut[271] = 16'h9990;
  dhr_lut[272] = 16'h9999;
  dhr_lut[273] = 16'h9999;
  dhr_lut[274] = 16'h9999;
  dhr_lut[275] = 16'h9999;
  dhr_lut[276] = 16'h99CC;
  dhr_lut[277] = 16'h99CC;
  dhr_lut[278] = 16'h9977;
  dhr_lut[279] = 16'h9977;
  dhr_lut[280] = 16'h9988;
  dhr_lut[281] = 16'h9988;
  dhr_lut[282] = 16'h99BB;
  dhr_lut[283] = 16'h99BB;
  dhr_lut[284] = 16'h9911;
  dhr_lut[285] = 16'h9911;
  dhr_lut[286] = 16'h9900;
  dhr_lut[287] = 16'h9900;
  dhr_lut[288] = 16'h666F;
  dhr_lut[289] = 16'h6666;
  dhr_lut[290] = 16'h6666;
  dhr_lut[291] = 16'h6666;
  dhr_lut[292] = 16'h6666;
  dhr_lut[293] = 16'h6666;
  dhr_lut[294] = 16'h6666;
  dhr_lut[295] = 16'h6666;
  dhr_lut[296] = 16'hDEEE;
  dhr_lut[297] = 16'hDEEE;
  dhr_lut[298] = 16'hDEEE;
  dhr_lut[299] = 16'hDEEE;
  dhr_lut[300] = 16'hD444;
  dhr_lut[301] = 16'hD444;
  dhr_lut[302] = 16'hD444;
  dhr_lut[303] = 16'hD444;
  dhr_lut[304] = 16'hDDDF;
  dhr_lut[305] = 16'hDDD9;
  dhr_lut[306] = 16'hDDDD;
  dhr_lut[307] = 16'hDDDD;
  dhr_lut[308] = 16'hDDD3;
  dhr_lut[309] = 16'hDDDC;
  dhr_lut[310] = 16'hDD77;
  dhr_lut[311] = 16'hDD77;
  dhr_lut[312] = 16'hDBBB;
  dhr_lut[313] = 16'hDBBB;
  dhr_lut[314] = 16'hDBBB;
  dhr_lut[315] = 16'hDBBB;
  dhr_lut[316] = 16'hD000;
  dhr_lut[317] = 16'hD000;
  dhr_lut[318] = 16'hD000;
  dhr_lut[319] = 16'hD000;
  dhr_lut[320] = 16'hCFFF;
  dhr_lut[321] = 16'hCFFF;
  dhr_lut[322] = 16'hCFFF;
  dhr_lut[323] = 16'hCFFF;
  dhr_lut[324] = 16'hC333;
  dhr_lut[325] = 16'hC333;
  dhr_lut[326] = 16'hC333;
  dhr_lut[327] = 16'hC333;
  dhr_lut[328] = 16'hCAAA;
  dhr_lut[329] = 16'hCAAA;
  dhr_lut[330] = 16'hCAAE;
  dhr_lut[331] = 16'hCAAB;
  dhr_lut[332] = 16'hC222;
  dhr_lut[333] = 16'hC222;
  dhr_lut[334] = 16'hC224;
  dhr_lut[335] = 16'hC220;
  dhr_lut[336] = 16'hCCCF;
  dhr_lut[337] = 16'hCCC9;
  dhr_lut[338] = 16'hCCC6;
  dhr_lut[339] = 16'hCCCD;
  dhr_lut[340] = 16'hCCCC;
  dhr_lut[341] = 16'hCCCC;
  dhr_lut[342] = 16'hCCCC;
  dhr_lut[343] = 16'hCCCC;
  dhr_lut[344] = 16'hCC88;
  dhr_lut[345] = 16'hCC88;
  dhr_lut[346] = 16'hCCBB;
  dhr_lut[347] = 16'hCCBB;
  dhr_lut[348] = 16'hCC11;
  dhr_lut[349] = 16'hCC11;
  dhr_lut[350] = 16'hCC00;
  dhr_lut[351] = 16'hCC00;
  dhr_lut[352] = 16'h77FF;
  dhr_lut[353] = 16'h77FF;
  dhr_lut[354] = 16'h7766;
  dhr_lut[355] = 16'h7766;
  dhr_lut[356] = 16'h7733;
  dhr_lut[357] = 16'h7733;
  dhr_lut[358] = 16'h7755;
  dhr_lut[359] = 16'h7755;
  dhr_lut[360] = 16'h77AA;
  dhr_lut[361] = 16'h77AA;
  dhr_lut[362] = 16'h77EE;
  dhr_lut[363] = 16'h77EE;
  dhr_lut[364] = 16'h7722;
  dhr_lut[365] = 16'h7722;
  dhr_lut[366] = 16'h7744;
  dhr_lut[367] = 16'h7744;
  dhr_lut[368] = 16'h777F;
  dhr_lut[369] = 16'h7779;
  dhr_lut[370] = 16'h7776;
  dhr_lut[371] = 16'h777D;
  dhr_lut[372] = 16'h7773;
  dhr_lut[373] = 16'h777C;
  dhr_lut[374] = 16'h7777;
  dhr_lut[375] = 16'h7777;
  dhr_lut[376] = 16'h7777;
  dhr_lut[377] = 16'h7777;
  dhr_lut[378] = 16'h7777;
  dhr_lut[379] = 16'h7777;
  dhr_lut[380] = 16'h7000;
  dhr_lut[381] = 16'h7000;
  dhr_lut[382] = 16'h7000;
  dhr_lut[383] = 16'h7000;
  dhr_lut[384] = 16'hFFFF;
  dhr_lut[385] = 16'hFFFF;
  dhr_lut[386] = 16'hFFFF;
  dhr_lut[387] = 16'hFFFF;
  dhr_lut[388] = 16'hFFFF;
  dhr_lut[389] = 16'hFFFF;
  dhr_lut[390] = 16'hFFFF;
  dhr_lut[391] = 16'hFFFF;
  dhr_lut[392] = 16'hAAAA;
  dhr_lut[393] = 16'hAAAA;
  dhr_lut[394] = 16'hAAAE;
  dhr_lut[395] = 16'hAAAB;
  dhr_lut[396] = 16'hAAA2;
  dhr_lut[397] = 16'hAAA1;
  dhr_lut[398] = 16'hAAA4;
  dhr_lut[399] = 16'hAAA0;
  dhr_lut[400] = 16'h8999;
  dhr_lut[401] = 16'h8999;
  dhr_lut[402] = 16'h8999;
  dhr_lut[403] = 16'h8999;
  dhr_lut[404] = 16'h88CC;
  dhr_lut[405] = 16'h88CC;
  dhr_lut[406] = 16'h8877;
  dhr_lut[407] = 16'h8877;
  dhr_lut[408] = 16'h8888;
  dhr_lut[409] = 16'h8888;
  dhr_lut[410] = 16'h8888;
  dhr_lut[411] = 16'h888B;
  dhr_lut[412] = 16'h8811;
  dhr_lut[413] = 16'h8811;
  dhr_lut[414] = 16'h8800;
  dhr_lut[415] = 16'h8800;
  dhr_lut[416] = 16'h666F;
  dhr_lut[417] = 16'h6666;
  dhr_lut[418] = 16'h6666;
  dhr_lut[419] = 16'h6666;
  dhr_lut[420] = 16'h6666;
  dhr_lut[421] = 16'h6666;
  dhr_lut[422] = 16'h6666;
  dhr_lut[423] = 16'h6666;
  dhr_lut[424] = 16'hEEEE;
  dhr_lut[425] = 16'hEEEE;
  dhr_lut[426] = 16'hEEEE;
  dhr_lut[427] = 16'hEEEE;
  dhr_lut[428] = 16'hEEE2;
  dhr_lut[429] = 16'hEEE1;
  dhr_lut[430] = 16'hEEE4;
  dhr_lut[431] = 16'hEEE0;
  dhr_lut[432] = 16'hBBBF;
  dhr_lut[433] = 16'hBBB9;
  dhr_lut[434] = 16'hBBB6;
  dhr_lut[435] = 16'hBBBD;
  dhr_lut[436] = 16'hBBB3;
  dhr_lut[437] = 16'hBBBC;
  dhr_lut[438] = 16'hBBB5;
  dhr_lut[439] = 16'hBBB7;
  dhr_lut[440] = 16'hBBBB;
  dhr_lut[441] = 16'hBBBB;
  dhr_lut[442] = 16'hBBBB;
  dhr_lut[443] = 16'hBBBB;
  dhr_lut[444] = 16'hBBBB;
  dhr_lut[445] = 16'hBBBB;
  dhr_lut[446] = 16'hBB00;
  dhr_lut[447] = 16'hBB00;
  dhr_lut[448] = 16'h1FFF;
  dhr_lut[449] = 16'h1FFF;
  dhr_lut[450] = 16'h1FFF;
  dhr_lut[451] = 16'h1FFF;
  dhr_lut[452] = 16'h1333;
  dhr_lut[453] = 16'h1333;
  dhr_lut[454] = 16'h1333;
  dhr_lut[455] = 16'h1333;
  dhr_lut[456] = 16'h1AAA;
  dhr_lut[457] = 16'h1AAA;
  dhr_lut[458] = 16'h1AAE;
  dhr_lut[459] = 16'h1AAB;
  dhr_lut[460] = 16'h1222;
  dhr_lut[461] = 16'h1222;
  dhr_lut[462] = 16'h1224;
  dhr_lut[463] = 16'h1220;
  dhr_lut[464] = 16'h1999;
  dhr_lut[465] = 16'h1999;
  dhr_lut[466] = 16'h1999;
  dhr_lut[467] = 16'h1999;
  dhr_lut[468] = 16'h1CCC;
  dhr_lut[469] = 16'h1CCC;
  dhr_lut[470] = 16'h1CCC;
  dhr_lut[471] = 16'h1CCC;
  dhr_lut[472] = 16'h1111;
  dhr_lut[473] = 16'h1111;
  dhr_lut[474] = 16'h1111;
  dhr_lut[475] = 16'h1111;
  dhr_lut[476] = 16'h1111;
  dhr_lut[477] = 16'h1111;
  dhr_lut[478] = 16'h1111;
  dhr_lut[479] = 16'h1110;
  dhr_lut[480] = 16'h00FF;
  dhr_lut[481] = 16'h00FF;
  dhr_lut[482] = 16'h0066;
  dhr_lut[483] = 16'h0066;
  dhr_lut[484] = 16'h0033;
  dhr_lut[485] = 16'h0033;
  dhr_lut[486] = 16'h0055;
  dhr_lut[487] = 16'h0055;
  dhr_lut[488] = 16'h00AA;
  dhr_lut[489] = 16'h00AA;
  dhr_lut[490] = 16'h00EE;
  dhr_lut[491] = 16'h00EE;
  dhr_lut[492] = 16'h0022;
  dhr_lut[493] = 16'h0022;
  dhr_lut[494] = 16'h0044;
  dhr_lut[495] = 16'h0044;
  dhr_lut[496] = 16'h000F;
  dhr_lut[497] = 16'h0009;
  dhr_lut[498] = 16'h0006;
  dhr_lut[499] = 16'h000D;
  dhr_lut[500] = 16'h0003;
  dhr_lut[501] = 16'h000C;
  dhr_lut[502] = 16'h0005;
  dhr_lut[503] = 16'h0007;
  dhr_lut[504] = 16'h0000;
  dhr_lut[505] = 16'h0000;
  dhr_lut[506] = 16'h0000;
  dhr_lut[507] = 16'h0000;
  dhr_lut[508] = 16'h0000;
  dhr_lut[509] = 16'h0000;
  dhr_lut[510] = 16'h0000;
  dhr_lut[511] = 16'h0000;
  dhr_lut[512] = 16'hFFFF;
  dhr_lut[513] = 16'hFFFF;
  dhr_lut[514] = 16'hFFFF;
  dhr_lut[515] = 16'hFFFF;
  dhr_lut[516] = 16'hFFFF;
  dhr_lut[517] = 16'hFFFF;
  dhr_lut[518] = 16'hFFFF;
  dhr_lut[519] = 16'hFFFF;
  dhr_lut[520] = 16'hFFFA;
  dhr_lut[521] = 16'hFFF8;
  dhr_lut[522] = 16'hFFFE;
  dhr_lut[523] = 16'hFFFB;
  dhr_lut[524] = 16'hFFF2;
  dhr_lut[525] = 16'hFFF1;
  dhr_lut[526] = 16'hFFF4;
  dhr_lut[527] = 16'hFFF0;
  dhr_lut[528] = 16'h6699;
  dhr_lut[529] = 16'h6699;
  dhr_lut[530] = 16'h66DD;
  dhr_lut[531] = 16'h66DD;
  dhr_lut[532] = 16'h66CC;
  dhr_lut[533] = 16'h66CC;
  dhr_lut[534] = 16'h6677;
  dhr_lut[535] = 16'h6677;
  dhr_lut[536] = 16'h6688;
  dhr_lut[537] = 16'h6688;
  dhr_lut[538] = 16'h66BB;
  dhr_lut[539] = 16'h66BB;
  dhr_lut[540] = 16'h6611;
  dhr_lut[541] = 16'h6611;
  dhr_lut[542] = 16'h6600;
  dhr_lut[543] = 16'h6600;
  dhr_lut[544] = 16'h666F;
  dhr_lut[545] = 16'h6666;
  dhr_lut[546] = 16'h6666;
  dhr_lut[547] = 16'h6666;
  dhr_lut[548] = 16'h6666;
  dhr_lut[549] = 16'h6666;
  dhr_lut[550] = 16'h6666;
  dhr_lut[551] = 16'h6666;
  dhr_lut[552] = 16'h6EEE;
  dhr_lut[553] = 16'h6EEE;
  dhr_lut[554] = 16'h6EEE;
  dhr_lut[555] = 16'h6EEE;
  dhr_lut[556] = 16'h6444;
  dhr_lut[557] = 16'h6444;
  dhr_lut[558] = 16'h6444;
  dhr_lut[559] = 16'h6444;
  dhr_lut[560] = 16'h6DDF;
  dhr_lut[561] = 16'h6DD9;
  dhr_lut[562] = 16'h6DDD;
  dhr_lut[563] = 16'h6DDD;
  dhr_lut[564] = 16'h6773;
  dhr_lut[565] = 16'h677C;
  dhr_lut[566] = 16'h6777;
  dhr_lut[567] = 16'h6777;
  dhr_lut[568] = 16'h6BBB;
  dhr_lut[569] = 16'h6BBB;
  dhr_lut[570] = 16'h6BBB;
  dhr_lut[571] = 16'h6BBB;
  dhr_lut[572] = 16'h6000;
  dhr_lut[573] = 16'h6000;
  dhr_lut[574] = 16'h6000;
  dhr_lut[575] = 16'h6000;
  dhr_lut[576] = 16'h33FF;
  dhr_lut[577] = 16'h33FF;
  dhr_lut[578] = 16'h3333;
  dhr_lut[579] = 16'h3333;
  dhr_lut[580] = 16'h3333;
  dhr_lut[581] = 16'h3333;
  dhr_lut[582] = 16'h3333;
  dhr_lut[583] = 16'h3333;
  dhr_lut[584] = 16'h333A;
  dhr_lut[585] = 16'h3338;
  dhr_lut[586] = 16'h333E;
  dhr_lut[587] = 16'h333B;
  dhr_lut[588] = 16'h3332;
  dhr_lut[589] = 16'h3331;
  dhr_lut[590] = 16'h3334;
  dhr_lut[591] = 16'h3330;
  dhr_lut[592] = 16'hCCCF;
  dhr_lut[593] = 16'hCCC9;
  dhr_lut[594] = 16'hCCC6;
  dhr_lut[595] = 16'hCCCD;
  dhr_lut[596] = 16'hCCCC;
  dhr_lut[597] = 16'hCCCC;
  dhr_lut[598] = 16'hCCCC;
  dhr_lut[599] = 16'hCCCC;
  dhr_lut[600] = 16'h1111;
  dhr_lut[601] = 16'h1111;
  dhr_lut[602] = 16'h1111;
  dhr_lut[603] = 16'h1111;
  dhr_lut[604] = 16'h1111;
  dhr_lut[605] = 16'h1111;
  dhr_lut[606] = 16'h1111;
  dhr_lut[607] = 16'h1110;
  dhr_lut[608] = 16'h55FF;
  dhr_lut[609] = 16'h55FF;
  dhr_lut[610] = 16'h5566;
  dhr_lut[611] = 16'h5566;
  dhr_lut[612] = 16'h5553;
  dhr_lut[613] = 16'h5555;
  dhr_lut[614] = 16'h5555;
  dhr_lut[615] = 16'h5555;
  dhr_lut[616] = 16'h55AA;
  dhr_lut[617] = 16'h55AA;
  dhr_lut[618] = 16'h55EE;
  dhr_lut[619] = 16'h55EE;
  dhr_lut[620] = 16'h5444;
  dhr_lut[621] = 16'h5444;
  dhr_lut[622] = 16'h5444;
  dhr_lut[623] = 16'h5444;
  dhr_lut[624] = 16'h777F;
  dhr_lut[625] = 16'h7779;
  dhr_lut[626] = 16'h7776;
  dhr_lut[627] = 16'h777D;
  dhr_lut[628] = 16'h7773;
  dhr_lut[629] = 16'h777C;
  dhr_lut[630] = 16'h7777;
  dhr_lut[631] = 16'h7777;
  dhr_lut[632] = 16'h0000;
  dhr_lut[633] = 16'h0000;
  dhr_lut[634] = 16'h0000;
  dhr_lut[635] = 16'h0000;
  dhr_lut[636] = 16'h0000;
  dhr_lut[637] = 16'h0000;
  dhr_lut[638] = 16'h0000;
  dhr_lut[639] = 16'h0000;
  dhr_lut[640] = 16'hFFFF;
  dhr_lut[641] = 16'hFFFF;
  dhr_lut[642] = 16'hFFFF;
  dhr_lut[643] = 16'hFFFF;
  dhr_lut[644] = 16'hFFFF;
  dhr_lut[645] = 16'hFFFF;
  dhr_lut[646] = 16'hFFFF;
  dhr_lut[647] = 16'hFFFF;
  dhr_lut[648] = 16'hAAAA;
  dhr_lut[649] = 16'hAAAA;
  dhr_lut[650] = 16'hAAAE;
  dhr_lut[651] = 16'hAAAB;
  dhr_lut[652] = 16'hAAA2;
  dhr_lut[653] = 16'hAAA1;
  dhr_lut[654] = 16'hAAA4;
  dhr_lut[655] = 16'hAAA0;
  dhr_lut[656] = 16'h9999;
  dhr_lut[657] = 16'h9999;
  dhr_lut[658] = 16'h9999;
  dhr_lut[659] = 16'h9999;
  dhr_lut[660] = 16'h99CC;
  dhr_lut[661] = 16'h99CC;
  dhr_lut[662] = 16'h9977;
  dhr_lut[663] = 16'h9977;
  dhr_lut[664] = 16'h8888;
  dhr_lut[665] = 16'h8888;
  dhr_lut[666] = 16'h8888;
  dhr_lut[667] = 16'h888B;
  dhr_lut[668] = 16'h8811;
  dhr_lut[669] = 16'h8811;
  dhr_lut[670] = 16'h8800;
  dhr_lut[671] = 16'h8800;
  dhr_lut[672] = 16'hEEFF;
  dhr_lut[673] = 16'hEEFF;
  dhr_lut[674] = 16'hEE66;
  dhr_lut[675] = 16'hEE66;
  dhr_lut[676] = 16'hEE33;
  dhr_lut[677] = 16'hEE33;
  dhr_lut[678] = 16'hEE55;
  dhr_lut[679] = 16'hEE55;
  dhr_lut[680] = 16'hEEEE;
  dhr_lut[681] = 16'hEEEE;
  dhr_lut[682] = 16'hEEEE;
  dhr_lut[683] = 16'hEEEE;
  dhr_lut[684] = 16'hEEE2;
  dhr_lut[685] = 16'hEEE1;
  dhr_lut[686] = 16'hEEE4;
  dhr_lut[687] = 16'hEEE0;
  dhr_lut[688] = 16'hEDDF;
  dhr_lut[689] = 16'hEDD9;
  dhr_lut[690] = 16'hEDDD;
  dhr_lut[691] = 16'hEDDD;
  dhr_lut[692] = 16'hE773;
  dhr_lut[693] = 16'hE77C;
  dhr_lut[694] = 16'hE777;
  dhr_lut[695] = 16'hE777;
  dhr_lut[696] = 16'hEBBB;
  dhr_lut[697] = 16'hEBBB;
  dhr_lut[698] = 16'hEBBB;
  dhr_lut[699] = 16'hEBBB;
  dhr_lut[700] = 16'hE000;
  dhr_lut[701] = 16'hE000;
  dhr_lut[702] = 16'hE000;
  dhr_lut[703] = 16'hE000;
  dhr_lut[704] = 16'h4FFF;
  dhr_lut[705] = 16'h4FFF;
  dhr_lut[706] = 16'h4FFF;
  dhr_lut[707] = 16'h4FFF;
  dhr_lut[708] = 16'h4333;
  dhr_lut[709] = 16'h4333;
  dhr_lut[710] = 16'h4333;
  dhr_lut[711] = 16'h4333;
  dhr_lut[712] = 16'h4AAA;
  dhr_lut[713] = 16'h4AAA;
  dhr_lut[714] = 16'h4AAE;
  dhr_lut[715] = 16'h4AAB;
  dhr_lut[716] = 16'h4222;
  dhr_lut[717] = 16'h4222;
  dhr_lut[718] = 16'h4224;
  dhr_lut[719] = 16'h4220;
  dhr_lut[720] = 16'h4999;
  dhr_lut[721] = 16'h4999;
  dhr_lut[722] = 16'h4999;
  dhr_lut[723] = 16'h4999;
  dhr_lut[724] = 16'h4CCC;
  dhr_lut[725] = 16'h4CCC;
  dhr_lut[726] = 16'h4CCC;
  dhr_lut[727] = 16'h4CCC;
  dhr_lut[728] = 16'h4888;
  dhr_lut[729] = 16'h4888;
  dhr_lut[730] = 16'h4888;
  dhr_lut[731] = 16'h488B;
  dhr_lut[732] = 16'h4111;
  dhr_lut[733] = 16'h4111;
  dhr_lut[734] = 16'h4111;
  dhr_lut[735] = 16'h4110;
  dhr_lut[736] = 16'h44FF;
  dhr_lut[737] = 16'h44FF;
  dhr_lut[738] = 16'h4466;
  dhr_lut[739] = 16'h4466;
  dhr_lut[740] = 16'h4433;
  dhr_lut[741] = 16'h4433;
  dhr_lut[742] = 16'h4455;
  dhr_lut[743] = 16'h4455;
  dhr_lut[744] = 16'h44AA;
  dhr_lut[745] = 16'h44AA;
  dhr_lut[746] = 16'h44EE;
  dhr_lut[747] = 16'h44EE;
  dhr_lut[748] = 16'h4444;
  dhr_lut[749] = 16'h4444;
  dhr_lut[750] = 16'h4444;
  dhr_lut[751] = 16'h4444;
  dhr_lut[752] = 16'h444F;
  dhr_lut[753] = 16'h4449;
  dhr_lut[754] = 16'h4446;
  dhr_lut[755] = 16'h444D;
  dhr_lut[756] = 16'h4443;
  dhr_lut[757] = 16'h444C;
  dhr_lut[758] = 16'h4445;
  dhr_lut[759] = 16'h4447;
  dhr_lut[760] = 16'h0000;
  dhr_lut[761] = 16'h0000;
  dhr_lut[762] = 16'h0000;
  dhr_lut[763] = 16'h0000;
  dhr_lut[764] = 16'h0000;
  dhr_lut[765] = 16'h0000;
  dhr_lut[766] = 16'h0000;
  dhr_lut[767] = 16'h0000;
  dhr_lut[768] = 16'hFFFF;
  dhr_lut[769] = 16'hFFFF;
  dhr_lut[770] = 16'hFFFF;
  dhr_lut[771] = 16'hFFFF;
  dhr_lut[772] = 16'hFFFF;
  dhr_lut[773] = 16'hFFFF;
  dhr_lut[774] = 16'hFFFF;
  dhr_lut[775] = 16'hFFFF;
  dhr_lut[776] = 16'hFFFA;
  dhr_lut[777] = 16'hFFF8;
  dhr_lut[778] = 16'hFFFE;
  dhr_lut[779] = 16'hFFFB;
  dhr_lut[780] = 16'hFFF2;
  dhr_lut[781] = 16'hFFF1;
  dhr_lut[782] = 16'hFFF4;
  dhr_lut[783] = 16'hFFF0;
  dhr_lut[784] = 16'h9999;
  dhr_lut[785] = 16'h9999;
  dhr_lut[786] = 16'h9999;
  dhr_lut[787] = 16'h9999;
  dhr_lut[788] = 16'h99CC;
  dhr_lut[789] = 16'h99CC;
  dhr_lut[790] = 16'h9977;
  dhr_lut[791] = 16'h9977;
  dhr_lut[792] = 16'h9988;
  dhr_lut[793] = 16'h9988;
  dhr_lut[794] = 16'h99BB;
  dhr_lut[795] = 16'h99BB;
  dhr_lut[796] = 16'h9911;
  dhr_lut[797] = 16'h9911;
  dhr_lut[798] = 16'h9900;
  dhr_lut[799] = 16'h9900;
  dhr_lut[800] = 16'h666F;
  dhr_lut[801] = 16'h6666;
  dhr_lut[802] = 16'h6666;
  dhr_lut[803] = 16'h6666;
  dhr_lut[804] = 16'h6666;
  dhr_lut[805] = 16'h6666;
  dhr_lut[806] = 16'h6666;
  dhr_lut[807] = 16'h6666;
  dhr_lut[808] = 16'hDEEE;
  dhr_lut[809] = 16'hDEEE;
  dhr_lut[810] = 16'hDEEE;
  dhr_lut[811] = 16'hDEEE;
  dhr_lut[812] = 16'hD444;
  dhr_lut[813] = 16'hD444;
  dhr_lut[814] = 16'hD444;
  dhr_lut[815] = 16'hD444;
  dhr_lut[816] = 16'hDDDF;
  dhr_lut[817] = 16'hDDD9;
  dhr_lut[818] = 16'hDDDD;
  dhr_lut[819] = 16'hDDDD;
  dhr_lut[820] = 16'hDDD3;
  dhr_lut[821] = 16'hDDDC;
  dhr_lut[822] = 16'hDD77;
  dhr_lut[823] = 16'hDD77;
  dhr_lut[824] = 16'hDBBB;
  dhr_lut[825] = 16'hDBBB;
  dhr_lut[826] = 16'hDBBB;
  dhr_lut[827] = 16'hDBBB;
  dhr_lut[828] = 16'hD000;
  dhr_lut[829] = 16'hD000;
  dhr_lut[830] = 16'hD000;
  dhr_lut[831] = 16'hD000;
  dhr_lut[832] = 16'h33FF;
  dhr_lut[833] = 16'h33FF;
  dhr_lut[834] = 16'h3333;
  dhr_lut[835] = 16'h3333;
  dhr_lut[836] = 16'h3333;
  dhr_lut[837] = 16'h3333;
  dhr_lut[838] = 16'h3333;
  dhr_lut[839] = 16'h3333;
  dhr_lut[840] = 16'h333A;
  dhr_lut[841] = 16'h3338;
  dhr_lut[842] = 16'h333E;
  dhr_lut[843] = 16'h333B;
  dhr_lut[844] = 16'h3332;
  dhr_lut[845] = 16'h3331;
  dhr_lut[846] = 16'h3334;
  dhr_lut[847] = 16'h3330;
  dhr_lut[848] = 16'hCCCF;
  dhr_lut[849] = 16'hCCC9;
  dhr_lut[850] = 16'hCCC6;
  dhr_lut[851] = 16'hCCCD;
  dhr_lut[852] = 16'hCCCC;
  dhr_lut[853] = 16'hCCCC;
  dhr_lut[854] = 16'hCCCC;
  dhr_lut[855] = 16'hCCCC;
  dhr_lut[856] = 16'hCC88;
  dhr_lut[857] = 16'hCC88;
  dhr_lut[858] = 16'hCCBB;
  dhr_lut[859] = 16'hCCBB;
  dhr_lut[860] = 16'hCC11;
  dhr_lut[861] = 16'hCC11;
  dhr_lut[862] = 16'hCC00;
  dhr_lut[863] = 16'hCC00;
  dhr_lut[864] = 16'h77FF;
  dhr_lut[865] = 16'h77FF;
  dhr_lut[866] = 16'h7766;
  dhr_lut[867] = 16'h7766;
  dhr_lut[868] = 16'h7733;
  dhr_lut[869] = 16'h7733;
  dhr_lut[870] = 16'h7755;
  dhr_lut[871] = 16'h7755;
  dhr_lut[872] = 16'h77AA;
  dhr_lut[873] = 16'h77AA;
  dhr_lut[874] = 16'h77EE;
  dhr_lut[875] = 16'h77EE;
  dhr_lut[876] = 16'h7722;
  dhr_lut[877] = 16'h7722;
  dhr_lut[878] = 16'h7744;
  dhr_lut[879] = 16'h7744;
  dhr_lut[880] = 16'h777F;
  dhr_lut[881] = 16'h7779;
  dhr_lut[882] = 16'h7776;
  dhr_lut[883] = 16'h777D;
  dhr_lut[884] = 16'h7773;
  dhr_lut[885] = 16'h777C;
  dhr_lut[886] = 16'h7777;
  dhr_lut[887] = 16'h7777;
  dhr_lut[888] = 16'h7777;
  dhr_lut[889] = 16'h7777;
  dhr_lut[890] = 16'h7777;
  dhr_lut[891] = 16'h7777;
  dhr_lut[892] = 16'h7000;
  dhr_lut[893] = 16'h7000;
  dhr_lut[894] = 16'h7000;
  dhr_lut[895] = 16'h7000;
  dhr_lut[896] = 16'hFFFF;
  dhr_lut[897] = 16'hFFFF;
  dhr_lut[898] = 16'hFFFF;
  dhr_lut[899] = 16'hFFFF;
  dhr_lut[900] = 16'hFFFF;
  dhr_lut[901] = 16'hFFFF;
  dhr_lut[902] = 16'hFFFF;
  dhr_lut[903] = 16'hFFFF;
  dhr_lut[904] = 16'hAAAA;
  dhr_lut[905] = 16'hAAAA;
  dhr_lut[906] = 16'hAAAE;
  dhr_lut[907] = 16'hAAAB;
  dhr_lut[908] = 16'hAAA2;
  dhr_lut[909] = 16'hAAA1;
  dhr_lut[910] = 16'hAAA4;
  dhr_lut[911] = 16'hAAA0;
  dhr_lut[912] = 16'h9999;
  dhr_lut[913] = 16'h9999;
  dhr_lut[914] = 16'h9999;
  dhr_lut[915] = 16'h9999;
  dhr_lut[916] = 16'h99CC;
  dhr_lut[917] = 16'h99CC;
  dhr_lut[918] = 16'h9977;
  dhr_lut[919] = 16'h9977;
  dhr_lut[920] = 16'h8888;
  dhr_lut[921] = 16'h8888;
  dhr_lut[922] = 16'h8888;
  dhr_lut[923] = 16'h888B;
  dhr_lut[924] = 16'h8811;
  dhr_lut[925] = 16'h8811;
  dhr_lut[926] = 16'h8800;
  dhr_lut[927] = 16'h8800;
  dhr_lut[928] = 16'h666F;
  dhr_lut[929] = 16'h6666;
  dhr_lut[930] = 16'h6666;
  dhr_lut[931] = 16'h6666;
  dhr_lut[932] = 16'h6666;
  dhr_lut[933] = 16'h6666;
  dhr_lut[934] = 16'h6666;
  dhr_lut[935] = 16'h6666;
  dhr_lut[936] = 16'hEEEE;
  dhr_lut[937] = 16'hEEEE;
  dhr_lut[938] = 16'hEEEE;
  dhr_lut[939] = 16'hEEEE;
  dhr_lut[940] = 16'hEEE2;
  dhr_lut[941] = 16'hEEE1;
  dhr_lut[942] = 16'hEEE4;
  dhr_lut[943] = 16'hEEE0;
  dhr_lut[944] = 16'hBBBF;
  dhr_lut[945] = 16'hBBB9;
  dhr_lut[946] = 16'hBBB6;
  dhr_lut[947] = 16'hBBBD;
  dhr_lut[948] = 16'hBBB3;
  dhr_lut[949] = 16'hBBBC;
  dhr_lut[950] = 16'hBBB5;
  dhr_lut[951] = 16'hBBB7;
  dhr_lut[952] = 16'hBBBB;
  dhr_lut[953] = 16'hBBBB;
  dhr_lut[954] = 16'hBBBB;
  dhr_lut[955] = 16'hBBBB;
  dhr_lut[956] = 16'hBBBB;
  dhr_lut[957] = 16'hBBBB;
  dhr_lut[958] = 16'hBB00;
  dhr_lut[959] = 16'hBB00;
  dhr_lut[960] = 16'h0FFF;
  dhr_lut[961] = 16'h0FFF;
  dhr_lut[962] = 16'h0FFF;
  dhr_lut[963] = 16'h0FFF;
  dhr_lut[964] = 16'h0333;
  dhr_lut[965] = 16'h0333;
  dhr_lut[966] = 16'h0333;
  dhr_lut[967] = 16'h0333;
  dhr_lut[968] = 16'h0AAA;
  dhr_lut[969] = 16'h0AAA;
  dhr_lut[970] = 16'h0AAE;
  dhr_lut[971] = 16'h0AAB;
  dhr_lut[972] = 16'h0222;
  dhr_lut[973] = 16'h0222;
  dhr_lut[974] = 16'h0224;
  dhr_lut[975] = 16'h0220;
  dhr_lut[976] = 16'h0999;
  dhr_lut[977] = 16'h0999;
  dhr_lut[978] = 16'h0999;
  dhr_lut[979] = 16'h0999;
  dhr_lut[980] = 16'h0CCC;
  dhr_lut[981] = 16'h0CCC;
  dhr_lut[982] = 16'h0CCC;
  dhr_lut[983] = 16'h0CCC;
  dhr_lut[984] = 16'h0888;
  dhr_lut[985] = 16'h0888;
  dhr_lut[986] = 16'h0888;
  dhr_lut[987] = 16'h088B;
  dhr_lut[988] = 16'h0111;
  dhr_lut[989] = 16'h0111;
  dhr_lut[990] = 16'h0111;
  dhr_lut[991] = 16'h0110;
  dhr_lut[992] = 16'h00FF;
  dhr_lut[993] = 16'h00FF;
  dhr_lut[994] = 16'h0066;
  dhr_lut[995] = 16'h0066;
  dhr_lut[996] = 16'h0033;
  dhr_lut[997] = 16'h0033;
  dhr_lut[998] = 16'h0055;
  dhr_lut[999] = 16'h0055;
  dhr_lut[1000] = 16'h00AA;
  dhr_lut[1001] = 16'h00AA;
  dhr_lut[1002] = 16'h00EE;
  dhr_lut[1003] = 16'h00EE;
  dhr_lut[1004] = 16'h0022;
  dhr_lut[1005] = 16'h0022;
  dhr_lut[1006] = 16'h0044;
  dhr_lut[1007] = 16'h0044;
  dhr_lut[1008] = 16'h000F;
  dhr_lut[1009] = 16'h0009;
  dhr_lut[1010] = 16'h0006;
  dhr_lut[1011] = 16'h000D;
  dhr_lut[1012] = 16'h0003;
  dhr_lut[1013] = 16'h000C;
  dhr_lut[1014] = 16'h0005;
  dhr_lut[1015] = 16'h0007;
  dhr_lut[1016] = 16'h0000;
  dhr_lut[1017] = 16'h0000;
  dhr_lut[1018] = 16'h0000;
  dhr_lut[1019] = 16'h0000;
  dhr_lut[1020] = 16'h0000;
  dhr_lut[1021] = 16'h0000;
  dhr_lut[1022] = 16'h0000;
  dhr_lut[1023] = 16'h0000;
  dhr_lut[1024] = 16'hFFFF;
  dhr_lut[1025] = 16'hFFFF;
  dhr_lut[1026] = 16'hFFFF;
  dhr_lut[1027] = 16'hFFFF;
  dhr_lut[1028] = 16'hFFFF;
  dhr_lut[1029] = 16'hFFFF;
  dhr_lut[1030] = 16'hFFFF;
  dhr_lut[1031] = 16'hFFFF;
  dhr_lut[1032] = 16'hFFFA;
  dhr_lut[1033] = 16'hFFF8;
  dhr_lut[1034] = 16'hFFFE;
  dhr_lut[1035] = 16'hFFFB;
  dhr_lut[1036] = 16'hFFF2;
  dhr_lut[1037] = 16'hFFF1;
  dhr_lut[1038] = 16'hFFF4;
  dhr_lut[1039] = 16'hFFF0;
  dhr_lut[1040] = 16'hFF99;
  dhr_lut[1041] = 16'hFF99;
  dhr_lut[1042] = 16'hFFDD;
  dhr_lut[1043] = 16'hFFDD;
  dhr_lut[1044] = 16'hFFCC;
  dhr_lut[1045] = 16'hFFCC;
  dhr_lut[1046] = 16'hFF77;
  dhr_lut[1047] = 16'hFF77;
  dhr_lut[1048] = 16'hFF88;
  dhr_lut[1049] = 16'hFF88;
  dhr_lut[1050] = 16'hFFBB;
  dhr_lut[1051] = 16'hFFBB;
  dhr_lut[1052] = 16'hFF11;
  dhr_lut[1053] = 16'hFF11;
  dhr_lut[1054] = 16'hFF00;
  dhr_lut[1055] = 16'hFF00;
  dhr_lut[1056] = 16'hF66F;
  dhr_lut[1057] = 16'hF666;
  dhr_lut[1058] = 16'hF666;
  dhr_lut[1059] = 16'hF666;
  dhr_lut[1060] = 16'hF553;
  dhr_lut[1061] = 16'hF555;
  dhr_lut[1062] = 16'hF555;
  dhr_lut[1063] = 16'hF555;
  dhr_lut[1064] = 16'hFEEE;
  dhr_lut[1065] = 16'hFEEE;
  dhr_lut[1066] = 16'hFEEE;
  dhr_lut[1067] = 16'hFEEE;
  dhr_lut[1068] = 16'hF444;
  dhr_lut[1069] = 16'hF444;
  dhr_lut[1070] = 16'hF444;
  dhr_lut[1071] = 16'hF444;
  dhr_lut[1072] = 16'hFDDF;
  dhr_lut[1073] = 16'hFDD9;
  dhr_lut[1074] = 16'hFDDD;
  dhr_lut[1075] = 16'hFDDD;
  dhr_lut[1076] = 16'hF773;
  dhr_lut[1077] = 16'hF77C;
  dhr_lut[1078] = 16'hF777;
  dhr_lut[1079] = 16'hF777;
  dhr_lut[1080] = 16'hFBBB;
  dhr_lut[1081] = 16'hFBBB;
  dhr_lut[1082] = 16'hFBBB;
  dhr_lut[1083] = 16'hFBBB;
  dhr_lut[1084] = 16'hF000;
  dhr_lut[1085] = 16'hF000;
  dhr_lut[1086] = 16'hF000;
  dhr_lut[1087] = 16'hF000;
  dhr_lut[1088] = 16'h33FF;
  dhr_lut[1089] = 16'h33FF;
  dhr_lut[1090] = 16'h3333;
  dhr_lut[1091] = 16'h3333;
  dhr_lut[1092] = 16'h3333;
  dhr_lut[1093] = 16'h3333;
  dhr_lut[1094] = 16'h3333;
  dhr_lut[1095] = 16'h3333;
  dhr_lut[1096] = 16'h333A;
  dhr_lut[1097] = 16'h3338;
  dhr_lut[1098] = 16'h333E;
  dhr_lut[1099] = 16'h333B;
  dhr_lut[1100] = 16'h3332;
  dhr_lut[1101] = 16'h3331;
  dhr_lut[1102] = 16'h3334;
  dhr_lut[1103] = 16'h3330;
  dhr_lut[1104] = 16'hCCCF;
  dhr_lut[1105] = 16'hCCC9;
  dhr_lut[1106] = 16'hCCC6;
  dhr_lut[1107] = 16'hCCCD;
  dhr_lut[1108] = 16'hCCCC;
  dhr_lut[1109] = 16'hCCCC;
  dhr_lut[1110] = 16'hCCCC;
  dhr_lut[1111] = 16'hCCCC;
  dhr_lut[1112] = 16'h1111;
  dhr_lut[1113] = 16'h1111;
  dhr_lut[1114] = 16'h1111;
  dhr_lut[1115] = 16'h1111;
  dhr_lut[1116] = 16'h1111;
  dhr_lut[1117] = 16'h1111;
  dhr_lut[1118] = 16'h1111;
  dhr_lut[1119] = 16'h1110;
  dhr_lut[1120] = 16'h55FF;
  dhr_lut[1121] = 16'h55FF;
  dhr_lut[1122] = 16'h5566;
  dhr_lut[1123] = 16'h5566;
  dhr_lut[1124] = 16'h5553;
  dhr_lut[1125] = 16'h5555;
  dhr_lut[1126] = 16'h5555;
  dhr_lut[1127] = 16'h5555;
  dhr_lut[1128] = 16'h44AA;
  dhr_lut[1129] = 16'h44AA;
  dhr_lut[1130] = 16'h44EE;
  dhr_lut[1131] = 16'h44EE;
  dhr_lut[1132] = 16'h4444;
  dhr_lut[1133] = 16'h4444;
  dhr_lut[1134] = 16'h4444;
  dhr_lut[1135] = 16'h4444;
  dhr_lut[1136] = 16'h777F;
  dhr_lut[1137] = 16'h7779;
  dhr_lut[1138] = 16'h7776;
  dhr_lut[1139] = 16'h777D;
  dhr_lut[1140] = 16'h7773;
  dhr_lut[1141] = 16'h777C;
  dhr_lut[1142] = 16'h7777;
  dhr_lut[1143] = 16'h7777;
  dhr_lut[1144] = 16'h0000;
  dhr_lut[1145] = 16'h0000;
  dhr_lut[1146] = 16'h0000;
  dhr_lut[1147] = 16'h0000;
  dhr_lut[1148] = 16'h0000;
  dhr_lut[1149] = 16'h0000;
  dhr_lut[1150] = 16'h0000;
  dhr_lut[1151] = 16'h0000;
  dhr_lut[1152] = 16'hAFFF;
  dhr_lut[1153] = 16'hAFFF;
  dhr_lut[1154] = 16'hAFFF;
  dhr_lut[1155] = 16'hAFFF;
  dhr_lut[1156] = 16'hAAAA;
  dhr_lut[1157] = 16'hAAAA;
  dhr_lut[1158] = 16'hAAAA;
  dhr_lut[1159] = 16'hAAAA;
  dhr_lut[1160] = 16'hAAAA;
  dhr_lut[1161] = 16'hAAAA;
  dhr_lut[1162] = 16'hAAAE;
  dhr_lut[1163] = 16'hAAAB;
  dhr_lut[1164] = 16'hAAA2;
  dhr_lut[1165] = 16'hAAA1;
  dhr_lut[1166] = 16'hAAA4;
  dhr_lut[1167] = 16'hAAA0;
  dhr_lut[1168] = 16'hAA99;
  dhr_lut[1169] = 16'hAA99;
  dhr_lut[1170] = 16'hAADD;
  dhr_lut[1171] = 16'hAADD;
  dhr_lut[1172] = 16'hAACC;
  dhr_lut[1173] = 16'hAACC;
  dhr_lut[1174] = 16'hAA77;
  dhr_lut[1175] = 16'hAA77;
  dhr_lut[1176] = 16'hAA88;
  dhr_lut[1177] = 16'hAA88;
  dhr_lut[1178] = 16'hAABB;
  dhr_lut[1179] = 16'hAABB;
  dhr_lut[1180] = 16'hAA11;
  dhr_lut[1181] = 16'hAA11;
  dhr_lut[1182] = 16'hAA00;
  dhr_lut[1183] = 16'hAA00;
  dhr_lut[1184] = 16'hEEFF;
  dhr_lut[1185] = 16'hEEFF;
  dhr_lut[1186] = 16'hEE66;
  dhr_lut[1187] = 16'hEE66;
  dhr_lut[1188] = 16'hEE33;
  dhr_lut[1189] = 16'hEE33;
  dhr_lut[1190] = 16'hEE55;
  dhr_lut[1191] = 16'hEE55;
  dhr_lut[1192] = 16'hEEEE;
  dhr_lut[1193] = 16'hEEEE;
  dhr_lut[1194] = 16'hEEEE;
  dhr_lut[1195] = 16'hEEEE;
  dhr_lut[1196] = 16'hEEE2;
  dhr_lut[1197] = 16'hEEE1;
  dhr_lut[1198] = 16'hEEE4;
  dhr_lut[1199] = 16'hEEE0;
  dhr_lut[1200] = 16'hBBBF;
  dhr_lut[1201] = 16'hBBB9;
  dhr_lut[1202] = 16'hBBB6;
  dhr_lut[1203] = 16'hBBBD;
  dhr_lut[1204] = 16'hBBB3;
  dhr_lut[1205] = 16'hBBBC;
  dhr_lut[1206] = 16'hBBB5;
  dhr_lut[1207] = 16'hBBB7;
  dhr_lut[1208] = 16'hBBBB;
  dhr_lut[1209] = 16'hBBBB;
  dhr_lut[1210] = 16'hBBBB;
  dhr_lut[1211] = 16'hBBBB;
  dhr_lut[1212] = 16'hBBBB;
  dhr_lut[1213] = 16'hBBBB;
  dhr_lut[1214] = 16'hBB00;
  dhr_lut[1215] = 16'hBB00;
  dhr_lut[1216] = 16'h2FFF;
  dhr_lut[1217] = 16'h2FFF;
  dhr_lut[1218] = 16'h2FFF;
  dhr_lut[1219] = 16'h2FFF;
  dhr_lut[1220] = 16'h2333;
  dhr_lut[1221] = 16'h2333;
  dhr_lut[1222] = 16'h2333;
  dhr_lut[1223] = 16'h2333;
  dhr_lut[1224] = 16'h22AA;
  dhr_lut[1225] = 16'h22AA;
  dhr_lut[1226] = 16'h222E;
  dhr_lut[1227] = 16'h222B;
  dhr_lut[1228] = 16'h2222;
  dhr_lut[1229] = 16'h2222;
  dhr_lut[1230] = 16'h2224;
  dhr_lut[1231] = 16'h2220;
  dhr_lut[1232] = 16'h2999;
  dhr_lut[1233] = 16'h2999;
  dhr_lut[1234] = 16'h2999;
  dhr_lut[1235] = 16'h2999;
  dhr_lut[1236] = 16'h2CCC;
  dhr_lut[1237] = 16'h2CCC;
  dhr_lut[1238] = 16'h2CCC;
  dhr_lut[1239] = 16'h2CCC;
  dhr_lut[1240] = 16'h1111;
  dhr_lut[1241] = 16'h1111;
  dhr_lut[1242] = 16'h1111;
  dhr_lut[1243] = 16'h1111;
  dhr_lut[1244] = 16'h1111;
  dhr_lut[1245] = 16'h1111;
  dhr_lut[1246] = 16'h1111;
  dhr_lut[1247] = 16'h1110;
  dhr_lut[1248] = 16'h44FF;
  dhr_lut[1249] = 16'h44FF;
  dhr_lut[1250] = 16'h4466;
  dhr_lut[1251] = 16'h4466;
  dhr_lut[1252] = 16'h4433;
  dhr_lut[1253] = 16'h4433;
  dhr_lut[1254] = 16'h4455;
  dhr_lut[1255] = 16'h4455;
  dhr_lut[1256] = 16'h44AA;
  dhr_lut[1257] = 16'h44AA;
  dhr_lut[1258] = 16'h44EE;
  dhr_lut[1259] = 16'h44EE;
  dhr_lut[1260] = 16'h4444;
  dhr_lut[1261] = 16'h4444;
  dhr_lut[1262] = 16'h4444;
  dhr_lut[1263] = 16'h4444;
  dhr_lut[1264] = 16'h000F;
  dhr_lut[1265] = 16'h0009;
  dhr_lut[1266] = 16'h0006;
  dhr_lut[1267] = 16'h000D;
  dhr_lut[1268] = 16'h0003;
  dhr_lut[1269] = 16'h000C;
  dhr_lut[1270] = 16'h0005;
  dhr_lut[1271] = 16'h0007;
  dhr_lut[1272] = 16'h0000;
  dhr_lut[1273] = 16'h0000;
  dhr_lut[1274] = 16'h0000;
  dhr_lut[1275] = 16'h0000;
  dhr_lut[1276] = 16'h0000;
  dhr_lut[1277] = 16'h0000;
  dhr_lut[1278] = 16'h0000;
  dhr_lut[1279] = 16'h0000;
  dhr_lut[1280] = 16'hFFFF;
  dhr_lut[1281] = 16'hFFFF;
  dhr_lut[1282] = 16'hFFFF;
  dhr_lut[1283] = 16'hFFFF;
  dhr_lut[1284] = 16'hFFFF;
  dhr_lut[1285] = 16'hFFFF;
  dhr_lut[1286] = 16'hFFFF;
  dhr_lut[1287] = 16'hFFFF;
  dhr_lut[1288] = 16'h999A;
  dhr_lut[1289] = 16'h9998;
  dhr_lut[1290] = 16'h999E;
  dhr_lut[1291] = 16'h999B;
  dhr_lut[1292] = 16'h9992;
  dhr_lut[1293] = 16'h9991;
  dhr_lut[1294] = 16'h9994;
  dhr_lut[1295] = 16'h9990;
  dhr_lut[1296] = 16'h9999;
  dhr_lut[1297] = 16'h9999;
  dhr_lut[1298] = 16'h9999;
  dhr_lut[1299] = 16'h9999;
  dhr_lut[1300] = 16'h99CC;
  dhr_lut[1301] = 16'h99CC;
  dhr_lut[1302] = 16'h9977;
  dhr_lut[1303] = 16'h9977;
  dhr_lut[1304] = 16'h9988;
  dhr_lut[1305] = 16'h9988;
  dhr_lut[1306] = 16'h99BB;
  dhr_lut[1307] = 16'h99BB;
  dhr_lut[1308] = 16'h9911;
  dhr_lut[1309] = 16'h9911;
  dhr_lut[1310] = 16'h9900;
  dhr_lut[1311] = 16'h9900;
  dhr_lut[1312] = 16'h966F;
  dhr_lut[1313] = 16'h9666;
  dhr_lut[1314] = 16'h9666;
  dhr_lut[1315] = 16'h9666;
  dhr_lut[1316] = 16'h9553;
  dhr_lut[1317] = 16'h9555;
  dhr_lut[1318] = 16'h9555;
  dhr_lut[1319] = 16'h9555;
  dhr_lut[1320] = 16'h9EEE;
  dhr_lut[1321] = 16'h9EEE;
  dhr_lut[1322] = 16'h9EEE;
  dhr_lut[1323] = 16'h9EEE;
  dhr_lut[1324] = 16'h9444;
  dhr_lut[1325] = 16'h9444;
  dhr_lut[1326] = 16'h9444;
  dhr_lut[1327] = 16'h9444;
  dhr_lut[1328] = 16'h9DDF;
  dhr_lut[1329] = 16'h9DD9;
  dhr_lut[1330] = 16'h9DDD;
  dhr_lut[1331] = 16'h9DDD;
  dhr_lut[1332] = 16'h9773;
  dhr_lut[1333] = 16'h977C;
  dhr_lut[1334] = 16'h9777;
  dhr_lut[1335] = 16'h9777;
  dhr_lut[1336] = 16'h9BBB;
  dhr_lut[1337] = 16'h9BBB;
  dhr_lut[1338] = 16'h9BBB;
  dhr_lut[1339] = 16'h9BBB;
  dhr_lut[1340] = 16'h9000;
  dhr_lut[1341] = 16'h9000;
  dhr_lut[1342] = 16'h9000;
  dhr_lut[1343] = 16'h9000;
  dhr_lut[1344] = 16'hCFFF;
  dhr_lut[1345] = 16'hCFFF;
  dhr_lut[1346] = 16'hCFFF;
  dhr_lut[1347] = 16'hCFFF;
  dhr_lut[1348] = 16'hC333;
  dhr_lut[1349] = 16'hC333;
  dhr_lut[1350] = 16'hC333;
  dhr_lut[1351] = 16'hC333;
  dhr_lut[1352] = 16'hCAAA;
  dhr_lut[1353] = 16'hCAAA;
  dhr_lut[1354] = 16'hCAAE;
  dhr_lut[1355] = 16'hCAAB;
  dhr_lut[1356] = 16'hC222;
  dhr_lut[1357] = 16'hC222;
  dhr_lut[1358] = 16'hC224;
  dhr_lut[1359] = 16'hC220;
  dhr_lut[1360] = 16'hCCCF;
  dhr_lut[1361] = 16'hCCC9;
  dhr_lut[1362] = 16'hCCC6;
  dhr_lut[1363] = 16'hCCCD;
  dhr_lut[1364] = 16'hCCCC;
  dhr_lut[1365] = 16'hCCCC;
  dhr_lut[1366] = 16'hCCCC;
  dhr_lut[1367] = 16'hCCCC;
  dhr_lut[1368] = 16'hCC88;
  dhr_lut[1369] = 16'hCC88;
  dhr_lut[1370] = 16'hCCBB;
  dhr_lut[1371] = 16'hCCBB;
  dhr_lut[1372] = 16'hCC11;
  dhr_lut[1373] = 16'hCC11;
  dhr_lut[1374] = 16'hCC00;
  dhr_lut[1375] = 16'hCC00;
  dhr_lut[1376] = 16'h55FF;
  dhr_lut[1377] = 16'h55FF;
  dhr_lut[1378] = 16'h5566;
  dhr_lut[1379] = 16'h5566;
  dhr_lut[1380] = 16'h5553;
  dhr_lut[1381] = 16'h5555;
  dhr_lut[1382] = 16'h5555;
  dhr_lut[1383] = 16'h5555;
  dhr_lut[1384] = 16'h44AA;
  dhr_lut[1385] = 16'h44AA;
  dhr_lut[1386] = 16'h44EE;
  dhr_lut[1387] = 16'h44EE;
  dhr_lut[1388] = 16'h4444;
  dhr_lut[1389] = 16'h4444;
  dhr_lut[1390] = 16'h4444;
  dhr_lut[1391] = 16'h4444;
  dhr_lut[1392] = 16'h777F;
  dhr_lut[1393] = 16'h7779;
  dhr_lut[1394] = 16'h7776;
  dhr_lut[1395] = 16'h777D;
  dhr_lut[1396] = 16'h7773;
  dhr_lut[1397] = 16'h777C;
  dhr_lut[1398] = 16'h7777;
  dhr_lut[1399] = 16'h7777;
  dhr_lut[1400] = 16'h0000;
  dhr_lut[1401] = 16'h0000;
  dhr_lut[1402] = 16'h0000;
  dhr_lut[1403] = 16'h0000;
  dhr_lut[1404] = 16'h0000;
  dhr_lut[1405] = 16'h0000;
  dhr_lut[1406] = 16'h0000;
  dhr_lut[1407] = 16'h0000;
  dhr_lut[1408] = 16'hFFFF;
  dhr_lut[1409] = 16'hFFFF;
  dhr_lut[1410] = 16'hFFFF;
  dhr_lut[1411] = 16'hFFFF;
  dhr_lut[1412] = 16'hFFFF;
  dhr_lut[1413] = 16'hFFFF;
  dhr_lut[1414] = 16'hFFFF;
  dhr_lut[1415] = 16'hFFFF;
  dhr_lut[1416] = 16'hAAAA;
  dhr_lut[1417] = 16'hAAAA;
  dhr_lut[1418] = 16'hAAAE;
  dhr_lut[1419] = 16'hAAAB;
  dhr_lut[1420] = 16'hAAA2;
  dhr_lut[1421] = 16'hAAA1;
  dhr_lut[1422] = 16'hAAA4;
  dhr_lut[1423] = 16'hAAA0;
  dhr_lut[1424] = 16'h8999;
  dhr_lut[1425] = 16'h8999;
  dhr_lut[1426] = 16'h8999;
  dhr_lut[1427] = 16'h8999;
  dhr_lut[1428] = 16'h88CC;
  dhr_lut[1429] = 16'h88CC;
  dhr_lut[1430] = 16'h8877;
  dhr_lut[1431] = 16'h8877;
  dhr_lut[1432] = 16'h8888;
  dhr_lut[1433] = 16'h8888;
  dhr_lut[1434] = 16'h8888;
  dhr_lut[1435] = 16'h888B;
  dhr_lut[1436] = 16'h8811;
  dhr_lut[1437] = 16'h8811;
  dhr_lut[1438] = 16'h8800;
  dhr_lut[1439] = 16'h8800;
  dhr_lut[1440] = 16'h666F;
  dhr_lut[1441] = 16'h6666;
  dhr_lut[1442] = 16'h6666;
  dhr_lut[1443] = 16'h6666;
  dhr_lut[1444] = 16'h6666;
  dhr_lut[1445] = 16'h6666;
  dhr_lut[1446] = 16'h6666;
  dhr_lut[1447] = 16'h6666;
  dhr_lut[1448] = 16'hEEEE;
  dhr_lut[1449] = 16'hEEEE;
  dhr_lut[1450] = 16'hEEEE;
  dhr_lut[1451] = 16'hEEEE;
  dhr_lut[1452] = 16'hEEE2;
  dhr_lut[1453] = 16'hEEE1;
  dhr_lut[1454] = 16'hEEE4;
  dhr_lut[1455] = 16'hEEE0;
  dhr_lut[1456] = 16'hBBBF;
  dhr_lut[1457] = 16'hBBB9;
  dhr_lut[1458] = 16'hBBB6;
  dhr_lut[1459] = 16'hBBBD;
  dhr_lut[1460] = 16'hBBB3;
  dhr_lut[1461] = 16'hBBBC;
  dhr_lut[1462] = 16'hBBB5;
  dhr_lut[1463] = 16'hBBB7;
  dhr_lut[1464] = 16'hBBBB;
  dhr_lut[1465] = 16'hBBBB;
  dhr_lut[1466] = 16'hBBBB;
  dhr_lut[1467] = 16'hBBBB;
  dhr_lut[1468] = 16'hBBBB;
  dhr_lut[1469] = 16'hBBBB;
  dhr_lut[1470] = 16'hBB00;
  dhr_lut[1471] = 16'hBB00;
  dhr_lut[1472] = 16'h1FFF;
  dhr_lut[1473] = 16'h1FFF;
  dhr_lut[1474] = 16'h1FFF;
  dhr_lut[1475] = 16'h1FFF;
  dhr_lut[1476] = 16'h1333;
  dhr_lut[1477] = 16'h1333;
  dhr_lut[1478] = 16'h1333;
  dhr_lut[1479] = 16'h1333;
  dhr_lut[1480] = 16'h1AAA;
  dhr_lut[1481] = 16'h1AAA;
  dhr_lut[1482] = 16'h1AAE;
  dhr_lut[1483] = 16'h1AAB;
  dhr_lut[1484] = 16'h1222;
  dhr_lut[1485] = 16'h1222;
  dhr_lut[1486] = 16'h1224;
  dhr_lut[1487] = 16'h1220;
  dhr_lut[1488] = 16'h1999;
  dhr_lut[1489] = 16'h1999;
  dhr_lut[1490] = 16'h1999;
  dhr_lut[1491] = 16'h1999;
  dhr_lut[1492] = 16'h1CCC;
  dhr_lut[1493] = 16'h1CCC;
  dhr_lut[1494] = 16'h1CCC;
  dhr_lut[1495] = 16'h1CCC;
  dhr_lut[1496] = 16'h1111;
  dhr_lut[1497] = 16'h1111;
  dhr_lut[1498] = 16'h1111;
  dhr_lut[1499] = 16'h1111;
  dhr_lut[1500] = 16'h1111;
  dhr_lut[1501] = 16'h1111;
  dhr_lut[1502] = 16'h1111;
  dhr_lut[1503] = 16'h1110;
  dhr_lut[1504] = 16'h11FF;
  dhr_lut[1505] = 16'h11FF;
  dhr_lut[1506] = 16'h1166;
  dhr_lut[1507] = 16'h1166;
  dhr_lut[1508] = 16'h1133;
  dhr_lut[1509] = 16'h1133;
  dhr_lut[1510] = 16'h1155;
  dhr_lut[1511] = 16'h1155;
  dhr_lut[1512] = 16'h11AA;
  dhr_lut[1513] = 16'h11AA;
  dhr_lut[1514] = 16'h11EE;
  dhr_lut[1515] = 16'h11EE;
  dhr_lut[1516] = 16'h1122;
  dhr_lut[1517] = 16'h1122;
  dhr_lut[1518] = 16'h1144;
  dhr_lut[1519] = 16'h1144;
  dhr_lut[1520] = 16'h000F;
  dhr_lut[1521] = 16'h0009;
  dhr_lut[1522] = 16'h0006;
  dhr_lut[1523] = 16'h000D;
  dhr_lut[1524] = 16'h0003;
  dhr_lut[1525] = 16'h000C;
  dhr_lut[1526] = 16'h0005;
  dhr_lut[1527] = 16'h0007;
  dhr_lut[1528] = 16'h0000;
  dhr_lut[1529] = 16'h0000;
  dhr_lut[1530] = 16'h0000;
  dhr_lut[1531] = 16'h0000;
  dhr_lut[1532] = 16'h0000;
  dhr_lut[1533] = 16'h0000;
  dhr_lut[1534] = 16'h0000;
  dhr_lut[1535] = 16'h0000;
  dhr_lut[1536] = 16'hFFFF;
  dhr_lut[1537] = 16'hFFFF;
  dhr_lut[1538] = 16'hFFFF;
  dhr_lut[1539] = 16'hFFFF;
  dhr_lut[1540] = 16'hFFFF;
  dhr_lut[1541] = 16'hFFFF;
  dhr_lut[1542] = 16'hFFFF;
  dhr_lut[1543] = 16'hFFFF;
  dhr_lut[1544] = 16'hFFFA;
  dhr_lut[1545] = 16'hFFF8;
  dhr_lut[1546] = 16'hFFFE;
  dhr_lut[1547] = 16'hFFFB;
  dhr_lut[1548] = 16'hFFF2;
  dhr_lut[1549] = 16'hFFF1;
  dhr_lut[1550] = 16'hFFF4;
  dhr_lut[1551] = 16'hFFF0;
  dhr_lut[1552] = 16'hFF99;
  dhr_lut[1553] = 16'hFF99;
  dhr_lut[1554] = 16'hFFDD;
  dhr_lut[1555] = 16'hFFDD;
  dhr_lut[1556] = 16'hFFCC;
  dhr_lut[1557] = 16'hFFCC;
  dhr_lut[1558] = 16'hFF77;
  dhr_lut[1559] = 16'hFF77;
  dhr_lut[1560] = 16'hFF88;
  dhr_lut[1561] = 16'hFF88;
  dhr_lut[1562] = 16'hFFBB;
  dhr_lut[1563] = 16'hFFBB;
  dhr_lut[1564] = 16'hFF11;
  dhr_lut[1565] = 16'hFF11;
  dhr_lut[1566] = 16'hFF00;
  dhr_lut[1567] = 16'hFF00;
  dhr_lut[1568] = 16'h666F;
  dhr_lut[1569] = 16'h6666;
  dhr_lut[1570] = 16'h6666;
  dhr_lut[1571] = 16'h6666;
  dhr_lut[1572] = 16'h6666;
  dhr_lut[1573] = 16'h6666;
  dhr_lut[1574] = 16'h6666;
  dhr_lut[1575] = 16'h6666;
  dhr_lut[1576] = 16'h6EEE;
  dhr_lut[1577] = 16'h6EEE;
  dhr_lut[1578] = 16'h6EEE;
  dhr_lut[1579] = 16'h6EEE;
  dhr_lut[1580] = 16'h6444;
  dhr_lut[1581] = 16'h6444;
  dhr_lut[1582] = 16'h6444;
  dhr_lut[1583] = 16'h6444;
  dhr_lut[1584] = 16'h6DDF;
  dhr_lut[1585] = 16'h6DD9;
  dhr_lut[1586] = 16'h6DDD;
  dhr_lut[1587] = 16'h6DDD;
  dhr_lut[1588] = 16'h6773;
  dhr_lut[1589] = 16'h677C;
  dhr_lut[1590] = 16'h6777;
  dhr_lut[1591] = 16'h6777;
  dhr_lut[1592] = 16'h6BBB;
  dhr_lut[1593] = 16'h6BBB;
  dhr_lut[1594] = 16'h6BBB;
  dhr_lut[1595] = 16'h6BBB;
  dhr_lut[1596] = 16'h6000;
  dhr_lut[1597] = 16'h6000;
  dhr_lut[1598] = 16'h6000;
  dhr_lut[1599] = 16'h6000;
  dhr_lut[1600] = 16'h33FF;
  dhr_lut[1601] = 16'h33FF;
  dhr_lut[1602] = 16'h3333;
  dhr_lut[1603] = 16'h3333;
  dhr_lut[1604] = 16'h3333;
  dhr_lut[1605] = 16'h3333;
  dhr_lut[1606] = 16'h3333;
  dhr_lut[1607] = 16'h3333;
  dhr_lut[1608] = 16'h333A;
  dhr_lut[1609] = 16'h3338;
  dhr_lut[1610] = 16'h333E;
  dhr_lut[1611] = 16'h333B;
  dhr_lut[1612] = 16'h3332;
  dhr_lut[1613] = 16'h3331;
  dhr_lut[1614] = 16'h3334;
  dhr_lut[1615] = 16'h3330;
  dhr_lut[1616] = 16'hCCCF;
  dhr_lut[1617] = 16'hCCC9;
  dhr_lut[1618] = 16'hCCC6;
  dhr_lut[1619] = 16'hCCCD;
  dhr_lut[1620] = 16'hCCCC;
  dhr_lut[1621] = 16'hCCCC;
  dhr_lut[1622] = 16'hCCCC;
  dhr_lut[1623] = 16'hCCCC;
  dhr_lut[1624] = 16'h1111;
  dhr_lut[1625] = 16'h1111;
  dhr_lut[1626] = 16'h1111;
  dhr_lut[1627] = 16'h1111;
  dhr_lut[1628] = 16'h1111;
  dhr_lut[1629] = 16'h1111;
  dhr_lut[1630] = 16'h1111;
  dhr_lut[1631] = 16'h1110;
  dhr_lut[1632] = 16'h55FF;
  dhr_lut[1633] = 16'h55FF;
  dhr_lut[1634] = 16'h5566;
  dhr_lut[1635] = 16'h5566;
  dhr_lut[1636] = 16'h5553;
  dhr_lut[1637] = 16'h5555;
  dhr_lut[1638] = 16'h5555;
  dhr_lut[1639] = 16'h5555;
  dhr_lut[1640] = 16'h55AA;
  dhr_lut[1641] = 16'h55AA;
  dhr_lut[1642] = 16'h55EE;
  dhr_lut[1643] = 16'h55EE;
  dhr_lut[1644] = 16'h5444;
  dhr_lut[1645] = 16'h5444;
  dhr_lut[1646] = 16'h5444;
  dhr_lut[1647] = 16'h5444;
  dhr_lut[1648] = 16'h777F;
  dhr_lut[1649] = 16'h7779;
  dhr_lut[1650] = 16'h7776;
  dhr_lut[1651] = 16'h777D;
  dhr_lut[1652] = 16'h7773;
  dhr_lut[1653] = 16'h777C;
  dhr_lut[1654] = 16'h7777;
  dhr_lut[1655] = 16'h7777;
  dhr_lut[1656] = 16'h0000;
  dhr_lut[1657] = 16'h0000;
  dhr_lut[1658] = 16'h0000;
  dhr_lut[1659] = 16'h0000;
  dhr_lut[1660] = 16'h0000;
  dhr_lut[1661] = 16'h0000;
  dhr_lut[1662] = 16'h0000;
  dhr_lut[1663] = 16'h0000;
  dhr_lut[1664] = 16'hAFFF;
  dhr_lut[1665] = 16'hAFFF;
  dhr_lut[1666] = 16'hAFFF;
  dhr_lut[1667] = 16'hAFFF;
  dhr_lut[1668] = 16'hAAAA;
  dhr_lut[1669] = 16'hAAAA;
  dhr_lut[1670] = 16'hAAAA;
  dhr_lut[1671] = 16'hAAAA;
  dhr_lut[1672] = 16'hAAAA;
  dhr_lut[1673] = 16'hAAAA;
  dhr_lut[1674] = 16'hAAAE;
  dhr_lut[1675] = 16'hAAAB;
  dhr_lut[1676] = 16'hAAA2;
  dhr_lut[1677] = 16'hAAA1;
  dhr_lut[1678] = 16'hAAA4;
  dhr_lut[1679] = 16'hAAA0;
  dhr_lut[1680] = 16'hAA99;
  dhr_lut[1681] = 16'hAA99;
  dhr_lut[1682] = 16'hAADD;
  dhr_lut[1683] = 16'hAADD;
  dhr_lut[1684] = 16'hAACC;
  dhr_lut[1685] = 16'hAACC;
  dhr_lut[1686] = 16'hAA77;
  dhr_lut[1687] = 16'hAA77;
  dhr_lut[1688] = 16'hAA88;
  dhr_lut[1689] = 16'hAA88;
  dhr_lut[1690] = 16'hAABB;
  dhr_lut[1691] = 16'hAABB;
  dhr_lut[1692] = 16'hAA11;
  dhr_lut[1693] = 16'hAA11;
  dhr_lut[1694] = 16'hAA00;
  dhr_lut[1695] = 16'hAA00;
  dhr_lut[1696] = 16'hEEFF;
  dhr_lut[1697] = 16'hEEFF;
  dhr_lut[1698] = 16'hEE66;
  dhr_lut[1699] = 16'hEE66;
  dhr_lut[1700] = 16'hEE33;
  dhr_lut[1701] = 16'hEE33;
  dhr_lut[1702] = 16'hEE55;
  dhr_lut[1703] = 16'hEE55;
  dhr_lut[1704] = 16'hEEEE;
  dhr_lut[1705] = 16'hEEEE;
  dhr_lut[1706] = 16'hEEEE;
  dhr_lut[1707] = 16'hEEEE;
  dhr_lut[1708] = 16'hEEE2;
  dhr_lut[1709] = 16'hEEE1;
  dhr_lut[1710] = 16'hEEE4;
  dhr_lut[1711] = 16'hEEE0;
  dhr_lut[1712] = 16'hEDDF;
  dhr_lut[1713] = 16'hEDD9;
  dhr_lut[1714] = 16'hEDDD;
  dhr_lut[1715] = 16'hEDDD;
  dhr_lut[1716] = 16'hE773;
  dhr_lut[1717] = 16'hE77C;
  dhr_lut[1718] = 16'hE777;
  dhr_lut[1719] = 16'hE777;
  dhr_lut[1720] = 16'hEBBB;
  dhr_lut[1721] = 16'hEBBB;
  dhr_lut[1722] = 16'hEBBB;
  dhr_lut[1723] = 16'hEBBB;
  dhr_lut[1724] = 16'hE000;
  dhr_lut[1725] = 16'hE000;
  dhr_lut[1726] = 16'hE000;
  dhr_lut[1727] = 16'hE000;
  dhr_lut[1728] = 16'h2FFF;
  dhr_lut[1729] = 16'h2FFF;
  dhr_lut[1730] = 16'h2FFF;
  dhr_lut[1731] = 16'h2FFF;
  dhr_lut[1732] = 16'h2333;
  dhr_lut[1733] = 16'h2333;
  dhr_lut[1734] = 16'h2333;
  dhr_lut[1735] = 16'h2333;
  dhr_lut[1736] = 16'h22AA;
  dhr_lut[1737] = 16'h22AA;
  dhr_lut[1738] = 16'h222E;
  dhr_lut[1739] = 16'h222B;
  dhr_lut[1740] = 16'h2222;
  dhr_lut[1741] = 16'h2222;
  dhr_lut[1742] = 16'h2224;
  dhr_lut[1743] = 16'h2220;
  dhr_lut[1744] = 16'h2999;
  dhr_lut[1745] = 16'h2999;
  dhr_lut[1746] = 16'h2999;
  dhr_lut[1747] = 16'h2999;
  dhr_lut[1748] = 16'h2CCC;
  dhr_lut[1749] = 16'h2CCC;
  dhr_lut[1750] = 16'h2CCC;
  dhr_lut[1751] = 16'h2CCC;
  dhr_lut[1752] = 16'h1111;
  dhr_lut[1753] = 16'h1111;
  dhr_lut[1754] = 16'h1111;
  dhr_lut[1755] = 16'h1111;
  dhr_lut[1756] = 16'h1111;
  dhr_lut[1757] = 16'h1111;
  dhr_lut[1758] = 16'h1111;
  dhr_lut[1759] = 16'h1110;
  dhr_lut[1760] = 16'h44FF;
  dhr_lut[1761] = 16'h44FF;
  dhr_lut[1762] = 16'h4466;
  dhr_lut[1763] = 16'h4466;
  dhr_lut[1764] = 16'h4433;
  dhr_lut[1765] = 16'h4433;
  dhr_lut[1766] = 16'h4455;
  dhr_lut[1767] = 16'h4455;
  dhr_lut[1768] = 16'h44AA;
  dhr_lut[1769] = 16'h44AA;
  dhr_lut[1770] = 16'h44EE;
  dhr_lut[1771] = 16'h44EE;
  dhr_lut[1772] = 16'h4444;
  dhr_lut[1773] = 16'h4444;
  dhr_lut[1774] = 16'h4444;
  dhr_lut[1775] = 16'h4444;
  dhr_lut[1776] = 16'h444F;
  dhr_lut[1777] = 16'h4449;
  dhr_lut[1778] = 16'h4446;
  dhr_lut[1779] = 16'h444D;
  dhr_lut[1780] = 16'h4443;
  dhr_lut[1781] = 16'h444C;
  dhr_lut[1782] = 16'h4445;
  dhr_lut[1783] = 16'h4447;
  dhr_lut[1784] = 16'h0000;
  dhr_lut[1785] = 16'h0000;
  dhr_lut[1786] = 16'h0000;
  dhr_lut[1787] = 16'h0000;
  dhr_lut[1788] = 16'h0000;
  dhr_lut[1789] = 16'h0000;
  dhr_lut[1790] = 16'h0000;
  dhr_lut[1791] = 16'h0000;
  dhr_lut[1792] = 16'hFFFF;
  dhr_lut[1793] = 16'hFFFF;
  dhr_lut[1794] = 16'hFFFF;
  dhr_lut[1795] = 16'hFFFF;
  dhr_lut[1796] = 16'hFFFF;
  dhr_lut[1797] = 16'hFFFF;
  dhr_lut[1798] = 16'hFFFF;
  dhr_lut[1799] = 16'hFFFF;
  dhr_lut[1800] = 16'hFFFA;
  dhr_lut[1801] = 16'hFFF8;
  dhr_lut[1802] = 16'hFFFE;
  dhr_lut[1803] = 16'hFFFB;
  dhr_lut[1804] = 16'hFFF2;
  dhr_lut[1805] = 16'hFFF1;
  dhr_lut[1806] = 16'hFFF4;
  dhr_lut[1807] = 16'hFFF0;
  dhr_lut[1808] = 16'h9999;
  dhr_lut[1809] = 16'h9999;
  dhr_lut[1810] = 16'h9999;
  dhr_lut[1811] = 16'h9999;
  dhr_lut[1812] = 16'h99CC;
  dhr_lut[1813] = 16'h99CC;
  dhr_lut[1814] = 16'h9977;
  dhr_lut[1815] = 16'h9977;
  dhr_lut[1816] = 16'h9988;
  dhr_lut[1817] = 16'h9988;
  dhr_lut[1818] = 16'h99BB;
  dhr_lut[1819] = 16'h99BB;
  dhr_lut[1820] = 16'h9911;
  dhr_lut[1821] = 16'h9911;
  dhr_lut[1822] = 16'h9900;
  dhr_lut[1823] = 16'h9900;
  dhr_lut[1824] = 16'h666F;
  dhr_lut[1825] = 16'h6666;
  dhr_lut[1826] = 16'h6666;
  dhr_lut[1827] = 16'h6666;
  dhr_lut[1828] = 16'h6666;
  dhr_lut[1829] = 16'h6666;
  dhr_lut[1830] = 16'h6666;
  dhr_lut[1831] = 16'h6666;
  dhr_lut[1832] = 16'h6EEE;
  dhr_lut[1833] = 16'h6EEE;
  dhr_lut[1834] = 16'h6EEE;
  dhr_lut[1835] = 16'h6EEE;
  dhr_lut[1836] = 16'h6444;
  dhr_lut[1837] = 16'h6444;
  dhr_lut[1838] = 16'h6444;
  dhr_lut[1839] = 16'h6444;
  dhr_lut[1840] = 16'hDDDF;
  dhr_lut[1841] = 16'hDDD9;
  dhr_lut[1842] = 16'hDDDD;
  dhr_lut[1843] = 16'hDDDD;
  dhr_lut[1844] = 16'hDDD3;
  dhr_lut[1845] = 16'hDDDC;
  dhr_lut[1846] = 16'hDD77;
  dhr_lut[1847] = 16'hDD77;
  dhr_lut[1848] = 16'hDBBB;
  dhr_lut[1849] = 16'hDBBB;
  dhr_lut[1850] = 16'hDBBB;
  dhr_lut[1851] = 16'hDBBB;
  dhr_lut[1852] = 16'hD000;
  dhr_lut[1853] = 16'hD000;
  dhr_lut[1854] = 16'hD000;
  dhr_lut[1855] = 16'hD000;
  dhr_lut[1856] = 16'h33FF;
  dhr_lut[1857] = 16'h33FF;
  dhr_lut[1858] = 16'h3333;
  dhr_lut[1859] = 16'h3333;
  dhr_lut[1860] = 16'h3333;
  dhr_lut[1861] = 16'h3333;
  dhr_lut[1862] = 16'h3333;
  dhr_lut[1863] = 16'h3333;
  dhr_lut[1864] = 16'h333A;
  dhr_lut[1865] = 16'h3338;
  dhr_lut[1866] = 16'h333E;
  dhr_lut[1867] = 16'h333B;
  dhr_lut[1868] = 16'h3332;
  dhr_lut[1869] = 16'h3331;
  dhr_lut[1870] = 16'h3334;
  dhr_lut[1871] = 16'h3330;
  dhr_lut[1872] = 16'hCCCF;
  dhr_lut[1873] = 16'hCCC9;
  dhr_lut[1874] = 16'hCCC6;
  dhr_lut[1875] = 16'hCCCD;
  dhr_lut[1876] = 16'hCCCC;
  dhr_lut[1877] = 16'hCCCC;
  dhr_lut[1878] = 16'hCCCC;
  dhr_lut[1879] = 16'hCCCC;
  dhr_lut[1880] = 16'hCC88;
  dhr_lut[1881] = 16'hCC88;
  dhr_lut[1882] = 16'hCCBB;
  dhr_lut[1883] = 16'hCCBB;
  dhr_lut[1884] = 16'hCC11;
  dhr_lut[1885] = 16'hCC11;
  dhr_lut[1886] = 16'hCC00;
  dhr_lut[1887] = 16'hCC00;
  dhr_lut[1888] = 16'h55FF;
  dhr_lut[1889] = 16'h55FF;
  dhr_lut[1890] = 16'h5566;
  dhr_lut[1891] = 16'h5566;
  dhr_lut[1892] = 16'h5553;
  dhr_lut[1893] = 16'h5555;
  dhr_lut[1894] = 16'h5555;
  dhr_lut[1895] = 16'h5555;
  dhr_lut[1896] = 16'h55AA;
  dhr_lut[1897] = 16'h55AA;
  dhr_lut[1898] = 16'h55EE;
  dhr_lut[1899] = 16'h55EE;
  dhr_lut[1900] = 16'h5444;
  dhr_lut[1901] = 16'h5444;
  dhr_lut[1902] = 16'h5444;
  dhr_lut[1903] = 16'h5444;
  dhr_lut[1904] = 16'h777F;
  dhr_lut[1905] = 16'h7779;
  dhr_lut[1906] = 16'h7776;
  dhr_lut[1907] = 16'h777D;
  dhr_lut[1908] = 16'h7773;
  dhr_lut[1909] = 16'h777C;
  dhr_lut[1910] = 16'h7777;
  dhr_lut[1911] = 16'h7777;
  dhr_lut[1912] = 16'h7777;
  dhr_lut[1913] = 16'h7777;
  dhr_lut[1914] = 16'h7777;
  dhr_lut[1915] = 16'h7777;
  dhr_lut[1916] = 16'h7000;
  dhr_lut[1917] = 16'h7000;
  dhr_lut[1918] = 16'h7000;
  dhr_lut[1919] = 16'h7000;
  dhr_lut[1920] = 16'hFFFF;
  dhr_lut[1921] = 16'hFFFF;
  dhr_lut[1922] = 16'hFFFF;
  dhr_lut[1923] = 16'hFFFF;
  dhr_lut[1924] = 16'hFFFF;
  dhr_lut[1925] = 16'hFFFF;
  dhr_lut[1926] = 16'hFFFF;
  dhr_lut[1927] = 16'hFFFF;
  dhr_lut[1928] = 16'hAAAA;
  dhr_lut[1929] = 16'hAAAA;
  dhr_lut[1930] = 16'hAAAE;
  dhr_lut[1931] = 16'hAAAB;
  dhr_lut[1932] = 16'hAAA2;
  dhr_lut[1933] = 16'hAAA1;
  dhr_lut[1934] = 16'hAAA4;
  dhr_lut[1935] = 16'hAAA0;
  dhr_lut[1936] = 16'h9999;
  dhr_lut[1937] = 16'h9999;
  dhr_lut[1938] = 16'h9999;
  dhr_lut[1939] = 16'h9999;
  dhr_lut[1940] = 16'h99CC;
  dhr_lut[1941] = 16'h99CC;
  dhr_lut[1942] = 16'h9977;
  dhr_lut[1943] = 16'h9977;
  dhr_lut[1944] = 16'h8888;
  dhr_lut[1945] = 16'h8888;
  dhr_lut[1946] = 16'h8888;
  dhr_lut[1947] = 16'h888B;
  dhr_lut[1948] = 16'h8811;
  dhr_lut[1949] = 16'h8811;
  dhr_lut[1950] = 16'h8800;
  dhr_lut[1951] = 16'h8800;
  dhr_lut[1952] = 16'h666F;
  dhr_lut[1953] = 16'h6666;
  dhr_lut[1954] = 16'h6666;
  dhr_lut[1955] = 16'h6666;
  dhr_lut[1956] = 16'h6666;
  dhr_lut[1957] = 16'h6666;
  dhr_lut[1958] = 16'h6666;
  dhr_lut[1959] = 16'h6666;
  dhr_lut[1960] = 16'hEEEE;
  dhr_lut[1961] = 16'hEEEE;
  dhr_lut[1962] = 16'hEEEE;
  dhr_lut[1963] = 16'hEEEE;
  dhr_lut[1964] = 16'hEEE2;
  dhr_lut[1965] = 16'hEEE1;
  dhr_lut[1966] = 16'hEEE4;
  dhr_lut[1967] = 16'hEEE0;
  dhr_lut[1968] = 16'hDDDF;
  dhr_lut[1969] = 16'hDDD9;
  dhr_lut[1970] = 16'hDDDD;
  dhr_lut[1971] = 16'hDDDD;
  dhr_lut[1972] = 16'hDDD3;
  dhr_lut[1973] = 16'hDDDC;
  dhr_lut[1974] = 16'hDD77;
  dhr_lut[1975] = 16'hDD77;
  dhr_lut[1976] = 16'hBBBB;
  dhr_lut[1977] = 16'hBBBB;
  dhr_lut[1978] = 16'hBBBB;
  dhr_lut[1979] = 16'hBBBB;
  dhr_lut[1980] = 16'hBBBB;
  dhr_lut[1981] = 16'hBBBB;
  dhr_lut[1982] = 16'hBB00;
  dhr_lut[1983] = 16'hBB00;
  dhr_lut[1984] = 16'h0FFF;
  dhr_lut[1985] = 16'h0FFF;
  dhr_lut[1986] = 16'h0FFF;
  dhr_lut[1987] = 16'h0FFF;
  dhr_lut[1988] = 16'h0333;
  dhr_lut[1989] = 16'h0333;
  dhr_lut[1990] = 16'h0333;
  dhr_lut[1991] = 16'h0333;
  dhr_lut[1992] = 16'h0AAA;
  dhr_lut[1993] = 16'h0AAA;
  dhr_lut[1994] = 16'h0AAE;
  dhr_lut[1995] = 16'h0AAB;
  dhr_lut[1996] = 16'h0222;
  dhr_lut[1997] = 16'h0222;
  dhr_lut[1998] = 16'h0224;
  dhr_lut[1999] = 16'h0220;
  dhr_lut[2000] = 16'h0999;
  dhr_lut[2001] = 16'h0999;
  dhr_lut[2002] = 16'h0999;
  dhr_lut[2003] = 16'h0999;
  dhr_lut[2004] = 16'h0CCC;
  dhr_lut[2005] = 16'h0CCC;
  dhr_lut[2006] = 16'h0CCC;
  dhr_lut[2007] = 16'h0CCC;
  dhr_lut[2008] = 16'h0888;
  dhr_lut[2009] = 16'h0888;
  dhr_lut[2010] = 16'h0888;
  dhr_lut[2011] = 16'h088B;
  dhr_lut[2012] = 16'h0111;
  dhr_lut[2013] = 16'h0111;
  dhr_lut[2014] = 16'h0111;
  dhr_lut[2015] = 16'h0110;
  dhr_lut[2016] = 16'h00FF;
  dhr_lut[2017] = 16'h00FF;
  dhr_lut[2018] = 16'h0066;
  dhr_lut[2019] = 16'h0066;
  dhr_lut[2020] = 16'h0033;
  dhr_lut[2021] = 16'h0033;
  dhr_lut[2022] = 16'h0055;
  dhr_lut[2023] = 16'h0055;
  dhr_lut[2024] = 16'h00AA;
  dhr_lut[2025] = 16'h00AA;
  dhr_lut[2026] = 16'h00EE;
  dhr_lut[2027] = 16'h00EE;
  dhr_lut[2028] = 16'h0022;
  dhr_lut[2029] = 16'h0022;
  dhr_lut[2030] = 16'h0044;
  dhr_lut[2031] = 16'h0044;
  dhr_lut[2032] = 16'h000F;
  dhr_lut[2033] = 16'h0009;
  dhr_lut[2034] = 16'h0006;
  dhr_lut[2035] = 16'h000D;
  dhr_lut[2036] = 16'h0003;
  dhr_lut[2037] = 16'h000C;
  dhr_lut[2038] = 16'h0005;
  dhr_lut[2039] = 16'h0007;
  dhr_lut[2040] = 16'h0000;
  dhr_lut[2041] = 16'h0000;
  dhr_lut[2042] = 16'h0000;
  dhr_lut[2043] = 16'h0000;
  dhr_lut[2044] = 16'h0000;
  dhr_lut[2045] = 16'h0000;
  dhr_lut[2046] = 16'h0000;
  dhr_lut[2047] = 16'h0000;
end
// [gamebub] end inlined dhr_lut.vh

// GSHGR 16-color palette (4 bits/channel), index 0 = white .. 15 = black
function automatic [11:0] dhr_pal(input [3:0] c);
    case (c)
        4'h0: dhr_pal = 12'hFFF; // white
        4'h1: dhr_pal = 12'hFF0; // yellow
        4'h2: dhr_pal = 12'hF60; // orange
        4'h3: dhr_pal = 12'hD03; // deep red
        4'h4: dhr_pal = 12'hF98; // pink
        4'h5: dhr_pal = 12'hD2D; // purple
        4'h6: dhr_pal = 12'h009; // dark blue
        4'h7: dhr_pal = 12'h6AF; // light blue
        4'h8: dhr_pal = 12'h1D0; // green
        4'h9: dhr_pal = 12'h072; // dark green
        4'hA: dhr_pal = 12'h850; // brown
        4'hB: dhr_pal = 12'h4F9; // aquamarine
        4'hC: dhr_pal = 12'hAAA; // light gray
        4'hD: dhr_pal = 12'h22F; // medium blue
        4'hE: dhr_pal = 12'h555; // dark gray
        4'hF: dhr_pal = 12'h000; // black
    endcase
endfunction

// Group latch phase: the reference preloads 3-phase_offset bits (DHR
// phase_offset=1 -> 2), making lookups land on stream index 4k+5 -- but our
// graphics_pixel is registered (one tick behind graphics_pix_shift[0]), so
// the matching H phase is one later, wrapping to H[1:0] == 0. Verified
// against the real Prince of Persia title screen (phase sweep: 1,2,3 all
// produce rotated hues; 0 matches orange dome / dark blue tapestry / red
// borders exactly).
localparam [1:0] DHR_PHASE = 2'b00;

reg [10:0] dhr_win;
reg [15:0] dhr_hold;
reg [1:0]  dhr_nib;
always @(posedge clk_vid) if (ce_pix) begin
    if (H < BLE || H >= BRE + 10'd8) begin
        dhr_win  <= 11'd0;
        dhr_nib  <= 2'd0;
    end else begin
        dhr_win <= {dhr_win[9:0], graphics_pixel};
        if (H[1:0] == DHR_PHASE && H >= BLE + 10'd5) begin
            dhr_hold <= dhr_lut[{dhr_win[9:0], graphics_pixel}];
            dhr_nib  <= 2'd0;
        end else
            dhr_nib  <= dhr_nib + 2'd1;
    end
end
wire [3:0]  dhr_color = (dhr_nib == 2'd0) ? dhr_hold[15:12] :
                        (dhr_nib == 2'd1) ? dhr_hold[11:8]  :
                        (dhr_nib == 2'd2) ? dhr_hold[7:4]   : dhr_hold[3:0];
wire [11:0] dhr_rgb   = dhr_pal(dhr_color);

// Graphics active window. Dhires: with the head-start (init emits bits 0/1
// at BLE-2/BLE-1, pre-shifted preload from bit 2), stream bit j displays at
// H = BLE-1+j -- window [BLE-1, BRE-2] = the full 560px. The color decode
// consumes the same corrected stream with its 6px LUT latency next to it.
// Other GFX modes trail by 5px (apple2_shift_reg).
wire [9:0] gfx_lb = dhires_mode ? (DHRG_MONO ? BLE-10'd1 : BLE + 10'd4) : (BLE + 10'd5);
wire [9:0] gfx_rb = dhires_mode ? (DHRG_MONO ? BRE-10'd2 : BRE + 10'd3) : (BRE + 10'd4);
// ---------------------------------------------------------------------------

// Apple II color generation logic
reg [7:0] apple2_r, apple2_g, apple2_b;
always @(*) begin
    if (hires_mode) begin
        // Start with black background
        apple2_r = 8'h00;
        apple2_g = 8'h00;
        apple2_b = 8'h00;

        // Use NTSC color artifacting for ALL hires modes (including DHIRES)
        // The dhires_mode monochrome rendering was breaking games like 8bit-Slicks
        // that run in standard HIRES but with EIGHTYCOL left set by menu software.
        // True DHIRES color (16-color) mode would need different handling.
        if (dhires_mode) begin
            if (DHRG_MONO) begin
                // Mono double-hi-res (NEWVIDEO[5] set, e.g. A2Desktop): render raw
                // 1bpp pixels from the registered graphics_pixel. That stream is
                // byte-exact but one pixel LATE, with a stale garbage bit landing in
                // the first displayed column (verified against GSSquared: our pixels
                // were ground truth >> 1). The display window below starts at BLE+1
                // to skip the garbage column and show the full 560 real pixels; the
                // whole image sits 1px right of nominal, which beats the comb tap
                // (its reload bypass skews mid-byte cadence) and the apple2_shift_reg
                // artifact window (6-deep fill transient mangled the cursor).
                // Programs that run hires+80col but with AN3=1 (e.g. 8bit-Slicks)
                // have dhires_mode=0 and keep artifacting.
                apple2_r = graphics_pixel ? 8'hff : 8'h00;
                apple2_g = graphics_pixel ? 8'hff : 8'h00;
                apple2_b = graphics_pixel ? 8'hff : 8'h00;
            end else begin
                // Color double-hi-res: AppleColor RGB 16-color decode (see the
                // dhr_lut pipeline above). 6px decode latency; the dhires-color
                // border window below is shifted to match.
                apple2_r = {dhr_rgb[11:8], dhr_rgb[11:8]};
                apple2_g = {dhr_rgb[7:4],  dhr_rgb[7:4]};
                apple2_b = {dhr_rgb[3:0],  dhr_rgb[3:0]};
            end
        end
        else if (consistent_tint) begin
            // Regular hires with consistent tint: display color using basis vectors
            // Add contributions from 4 adjacent pixels
            if (apple2_shift_reg[3]) begin
                apple2_r = apple2_r + basis_r[(color_phase + 1) & 2'b11];
                apple2_g = apple2_g + basis_g[(color_phase + 1) & 2'b11];
                apple2_b = apple2_b + basis_b[(color_phase + 1) & 2'b11];
            end
            if (apple2_shift_reg[4]) begin
                apple2_r = apple2_r + basis_r[(color_phase + 2) & 2'b11];
                apple2_g = apple2_g + basis_g[(color_phase + 2) & 2'b11];
                apple2_b = apple2_b + basis_b[(color_phase + 2) & 2'b11];
            end
            if (apple2_shift_reg[1]) begin
                apple2_r = apple2_r + basis_r[(color_phase + 3) & 2'b11];
                apple2_g = apple2_g + basis_g[(color_phase + 3) & 2'b11];
                apple2_b = apple2_b + basis_b[(color_phase + 3) & 2'b11];
            end
            if (apple2_shift_reg[2]) begin
                apple2_r = apple2_r + basis_r[color_phase];
                apple2_g = apple2_g + basis_g[color_phase];
                apple2_b = apple2_b + basis_b[color_phase];
            end
        end else begin
            // Tint is changing: display only black, gray, or white
            case (apple2_shift_reg[3:2])
                2'b11: begin apple2_r = 8'hFF; apple2_g = 8'hFF; apple2_b = 8'hFF; end // White
                2'b01, 2'b10: begin apple2_r = 8'h80; apple2_g = 8'h80; apple2_b = 8'h80; end // Gray
                default: begin apple2_r = 8'h00; apple2_g = 8'h00; apple2_b = 8'h00; end // Black
            endcase
        end
    end else begin
        // Not hi-res mode: use existing lores logic
        apple2_r = 8'h00;
        apple2_g = 8'h00;
        apple2_b = 8'h00;
    end
end

// Graphics RGB calculation - different for lores vs hires
wire [11:0] graphics_rgb = lores_mode ? palette_rgb_r[graphics_color] : 
                                       {apple2_r[7:4], apple2_g[7:4], apple2_b[7:4]};

// ce(ce_pix): gate the char-ROM read to the pixel-clock enable so it samples
// chrom_addr once per pipeline step, aligned with the ce_pix-gated text logic.
// With ce(1'b1) the ROM reads every clk_vid (2x ce_pix); on silicon the extra
// intermediate read latches a transitional address, so consecutive 80-col
// characters load the SAME glyph (aux char doubled, main dropped) -- garbled
// text on FPGA that the sim can't reproduce (SignalTap-confirmed 2026-07-06).
rom_chr charrom( // [gamebub] chr.mem, generated module
  .clock(clk_vid),
  .address(chrom_addr),
  .q(chrom_data_out),
  .ce(ce_pix)
);

wire [7:0] chrom_data_out;
// KEGS font data: 1 = foreground pixel, 0 = background pixel
// No inversion needed for KEGS-based chr.mem
wire [7:0] chrom_data_inv = chrom_data_out;
wire [11:0] chram_addr;
wire [11:0] chrom_addr;

// Text mode shift register for FPGA-compatible timing
// The character ROM has 1-cycle latency, so we need to pre-fetch and buffer
// Load the ROM data into a shift register, then shift out pixels
reg [6:0] text_shift_reg;

//
// 40 and 80 column video modes
//
//wire [2:0] chpos_y = V[2:0];
reg [5:0] chram_x;
// Anticipated column index for the dhires video address, 2 cycles ahead of chram_x
// (see aux_bank_early). chram_x increments at xpos==4 (a16==0), one cycle too late for
// the next column's aux-byte reload; chram_x_early increments at the aux_bank_early
// column boundary so the address (column + bank) is settled before each reload.
reg [5:0] chram_x_early;
//wire [12:0] chram_y = BASEADDR;


//  in EIGHTCOL mode we need each pixel, in 40 we pixel double
// Apple II character ROM: 7 pixels wide (bits 0-6), bit 7 unused for text
// In 80-column mode: xpos 0-6 maps directly to character bits 0-6
// In 40-column mode: xpos 0-13 maps to character bits 0-6 (pixel doubled)
// Text pixel output from shift register (FPGA-compatible with sync ROM)
wire textpixel = text_shift_reg[0];

    // Regular Hires - Apple II hi-res: 7 pixels per byte (bits 0-6), bit 7 is color/palette
    // Emit 7 pixel bits LSB-first and replicate the last pixel into the pad bit.
    // This prevents a black seam if an extra shift occurs before the next reload.
    function automatic bit [7:0] expandHires40([7:0] vd);
        reg [7:0] vs;
        vs = {vd[6], vd[6:0]};  // replicate last pixel instead of zero padding
        return vs;
    endfunction

    // Double Hires
    function automatic bit [6:0] expandHires80([7:0] vd);
        reg [6:0] vs;
        vs = vd[6:0];
        return vs;
    endfunction

    // Regular Text
    function automatic bit [6:0] expandText40([7:0] vd);
        reg [6:0] vs;
        vs = vd[6:0];
        return vs;
    endfunction

    // Regular Lores
    function automatic bit [6:0] expandLores40([7:0] vd, bit seg);
        reg [6:0] vs;
        case (seg)
            1'b0: vs = {
                vd[3],vd[2],vd[1],vd[0],
                vd[3],vd[2],vd[1]
            };
            1'b1: vs = {
                vd[7],vd[6],vd[5],vd[4],
                vd[7],vd[6],vd[5]
            };
        endcase
        return vs;
    endfunction


        // Double Lores
    function automatic bit [6:0] expandLores80([7:0] vd, bit seg);
        reg [6:0] vs;
        case (seg)
            1'b0: vs = {
                vd[3],vd[2],vd[1],vd[0],
                vd[3],vd[2],vd[1]
            };
            1'b1: vs = {
                vd[7],vd[6],vd[5],vd[4],
                vd[7],vd[6],vd[5]
            };
        endcase
        return vs;
    endfunction

    // Memory address generation, per Sather
    function automatic bit [15:0] lineaddr([9:0] y);
        reg [15:0] a;
        a[2:0] = 3'b0;
        a[6:3] = ({ 1'b1, y[6], 1'b1, 1'b1}) +
                 ({ y[7], 1'b1, y[7], 1'b1}) +
                 ({ 3'b000,           y[6]});
        a[9:7] = y[5:3];
        a[14:10] = (HIRES_MODE & GR) == 1'b0 ?
            {2'b00, 1'b0, PAGE2 &  ~STORE80, ~(PAGE2 &  ~STORE80)} :
            {PAGE2 &  ~STORE80, ~(PAGE2 &  ~STORE80), y[2:0]};
        a[15] = 1'b0;
        return a;
    endfunction

    localparam [2:0] TEXT40_LINE = 0;
    localparam [2:0] TEXT80_LINE = 1;
    localparam [2:0] LORES40_LINE = 4;
    localparam [2:0] LORES80_LINE = 5;
    localparam [2:0] HIRES40_LINE = 6;
    localparam [2:0] HIRES80_LINE = 7;


        // Line type detection for Apple II video modes
// AN3 controls whether EIGHTYCOL selects double-width modes:
// - AN3=1: Standard Apple II modes (40-column), EIGHTYCOL ignored for graphics
// - AN3=0: IIgs double modes (80-column) when EIGHTYCOL=1
// For text modes, EIGHTYCOL always controls 40/80 column selection
wire [2:0] line_type_w = (!GR & !EIGHTYCOL) ? TEXT40_LINE :
        (!GR & EIGHTYCOL) ? TEXT80_LINE :
        (GR & !HIRES_MODE & (AN3 | !EIGHTYCOL)) ? LORES40_LINE :  // Standard Apple II lores (AN3=1 OR EIGHTYCOL=0)
        (GR & !HIRES_MODE & !AN3 & EIGHTYCOL) ? LORES80_LINE :    // IIgs double lores (AN3=0 AND EIGHTYCOL=1)
        (GR & HIRES_MODE & (AN3 | !EIGHTYCOL)) ? HIRES40_LINE :   // Standard Apple II hires (AN3=1 OR EIGHTYCOL=0)
        (GR & HIRES_MODE & !AN3 & EIGHTYCOL) ? HIRES80_LINE :     // IIgs double hires (AN3=0 AND EIGHTYCOL=1)
        TEXT40_LINE;

// True when THIS line uses 80-column (1:1, no pixel-doubling) pixel timing:
// text80, lores80, and dhires. Standard hi-res/lores with EIGHTYCOL set but
// AN3=1 is a 40-column line and must NOT use the 80-column pixel cadence --
// the pixel pipeline keys off this, not the raw EIGHTYCOL bit, so that
// HIRES40+EIGHTYCOL=1 (e.g. the diagnostic keyboard test, 8bit-Slicks) keeps
// correct pixel doubling and hi-res color artifacting.
wire line_is_80 = (line_type_w == TEXT80_LINE) | (line_type_w == LORES80_LINE) |
                  (line_type_w == HIRES80_LINE);

//
// Apple II Graphics Mode Support - Pixel Buffer System
//

// Pixel buffer system (inspired by apple_video.sv but adapted for vgc.v memory timing)
reg [7:0] graphics_pix_shift;    // Shifts out one pixel per clock
reg [3:0] graphics_color;        // Current pixel color
reg graphics_pixel;              // Current pixel value
reg buffer_needs_reload;         // Flag to reload buffer when chram_x increments

// Color artifacting for hires mode (simplified version of apple2hack logic)

// Current mode detection using existing line_type_w
wire lores_mode = (line_type_w == LORES40_LINE) | (line_type_w == LORES80_LINE);
wire hires_mode = (line_type_w == HIRES40_LINE) | (line_type_w == HIRES80_LINE);
wire graphics_mode = lores_mode | hires_mode;

// Current graphics pixel output (combinational for immediate display, no pipeline delay)
// During buffer reload, output the first pixel of the new byte directly
// For lores mode, bit 0 of expanded data is the high nibble bit 0 (upper half) or low nibble bit 0 (lower half)
// For hires mode, bit 0 of video_data is first pixel (LSB-first)
// Note: expandLores40 returns {nibble[3],nibble[2],nibble[1],nibble[0],nibble[3],nibble[2],nibble[1]}
// so bit 0 is nibble[1], but we just need any valid pixel - use nibble bit directly

//
// Text Mode chars are 7 bits wide, not 8
//

// LDPS_N equivalent for memory loading control (inspired by Apple IIe timing)
// This signal controls when to load new character/graphics data
wire ldps_load;
//wire text80_mode = (!GR & EIGHTYCOL);
// ldps_load triggers buffer reload. For 40-col mode, we need 2+ cycles between
// chram_x increment and reload for memory latency:
// - xpos=10: ldps_load triggers buffer_needs_reload
// - xpos=11: chram_x increments (address changes, registered)
// - xpos=12: video_addr_ii updates (combinational from new chram_x)
// - xpos=13: video_data valid (after memory latency)
// - xpos=0 (next char): reload from valid video_data
// So ldps_load at xpos=10 gives us reload at xpos=11, which is still too early.
// We need reload to happen AFTER video_data is valid at xpos=13.
// Solution: change ldps_load to xpos=12 so reload happens at xpos=13 when data is ready.
assign ldps_load = (SHRG) ?
                   // SHRG mode timing
                   ((H >= (BL-4) && H < BL) || (H >= BL && ((EIGHTYCOL && (xpos == 3)) || (!EIGHTYCOL && (xpos == 12))))) :
                   // Apple II mode timing (line_is_80: text80/lores80/dhires use the
                   // 80-col cadence; HIRES40+EIGHTYCOL=1 stays on the 40-col cadence)
                   ((H >= (BLE-4) && H < BLE) || (H >= BLE && ((line_is_80 && (xpos == 3)) || (!line_is_80 && (xpos == 12)))));

reg [3:0] xpos;
reg [16:0] aux;
// Double-hi-res anticipated aux/main bank select for the video address. video_data
// has a 1-cycle BRAM latency and the per-byte reload reads it ~1 cycle after the
// aux[16] bank toggle (xpos==4), so the reload latches the stale aux byte into the
// main slot -> the byte (mouse cursor / first character) displays twice. aux_bank_early
// toggles 2 cycles sooner (xpos==2) and drives the dhires address only, so the main
// byte is addressed early enough to settle before its reload. aux[16] still drives the
// chram_x increment cadence unchanged.
reg aux_bank_early;
always @(posedge clk_vid) 
begin
   if (ce_pix)
   begin
	if ((SHRG && H<BL) || (!SHRG && H<BLE))
	begin
		// Early character loading during border period
		// Different timing for SHRG vs Apple II modes
		if (SHRG) begin
			// SHRG mode: start loading at H=28
			if (H == 26) begin
				if (EIGHTYCOL) begin
					chram_x <= 0;
					aux[16] <= 1'b1;
				end else begin
					chram_x <= 0;
					aux <= 0;
				end
			end else if (H == BL-4) begin
				buffer_needs_reload <= 1'b1;
			end else if (H == BL-2) begin
				buffer_needs_reload <= 1'b1;
			end
		end else begin
			// Apple II modes: start loading at H=68
			// Pre-fetch timing: chram_x=0 at H=68, reload at H=71, data ready at H=72
			if (H == BLE-4) begin
				if (line_is_80) begin
					chram_x <= 0;
					chram_x_early <= 0;
					aux[16] <= 1'b1;
					aux_bank_early <= 1'b1;
				end else begin
					chram_x <= 0;
					chram_x_early <= 0;
					aux <= 0;
					aux_bank_early <= 1'b0;
				end
			end else if (H == (BLE-1)) begin
				// Pre-load the shift register at H=71 so first pixel is ready at H=72
				// This is the ONLY place where we load during the init block
				if (hires_mode) begin
					// Double hi-res: pre-shifted by 2 -- bits 0 and 1 of the first
					// aux byte are emitted directly through graphics_pixel below
					// (the registered pixel path otherwise starts 2px late and the
					// first mid-line reload clips the byte to 5 of its 7 pixels:
					// the A2Desktop "doubled cursor" / broken left edge).
					graphics_pix_shift <= dhires_mode
						? {video_data[6], video_data[6], video_data[6], video_data[6:2]}
						: expandHires40(video_data);
					graphics_color <= {3'b0, video_data[7]};
				end else if (lores_mode) begin
					graphics_pix_shift <= {expandLores40(video_data, window_y_w[2]), 1'b0};
					graphics_color <= window_y_w[2] ? video_data[7:4] : video_data[3:0];
				end
			end
		end

		xpos<=0;
		// Only clear graphics shift register early in the line (before pre-load)
		if (H < 71) begin
			graphics_pix_shift <= 8'b0;
			graphics_color <= 4'b0;
		end
		apple2_shift_reg <= 6'b0;
		graphics_pixel <= 1'b0;
		pixel_counter <= 11'b0;
		// Double hi-res head start (after the unconditional clear above so it
		// wins): emit the first aux byte's bits 0/1 directly; the shift-register
		// path takes over at bit 2 via the pre-shifted preload. video_data holds
		// aux byte 0 from H=BLE-2 (address set at BLE-4, one BRAM cycle).
		if (dhires_mode && H == (BLE-2)) graphics_pixel <= video_data[0];
		if (dhires_mode && H == (BLE-1)) graphics_pixel <= video_data[1];
		text_shift_reg <= 7'b0;
	end
	else
	begin
		// Graphics pixel buffer system - coordinate with memory timing
		// Debug start and end of line to check horizontal alignment
`ifdef VGC_DEBUG
		if (((H >= 70 && H <= 90) || (H >= 620 && H <= 640)) && V == 100 && hires_mode)
			$display("HPIX: H=%d xpos=%d chram_x=%d reload=%b shift=%b pixel=%b video_data=%h",
			         H, xpos, chram_x, buffer_needs_reload, graphics_pix_shift, graphics_pix_shift[0], video_data);
`endif
		if (graphics_mode && GR) begin
			// Reload buffer when chram_x changes (new memory data available)
			// Only reload if chram_x is within valid range (0-39 for 40-col, 0-59 for 80-col)
			if (buffer_needs_reload) begin
				// Only load valid data if chram_x is within valid range (0-59 for 40-col, 0-79 for 80-col)
				if ((line_is_80 && chram_x < 60) || (!line_is_80 && chram_x < 40)) begin
					if (lores_mode) begin
						// Lores: expand nibbles based on line position
						graphics_pix_shift <= {expandLores40(video_data, window_y_w[2]), 1'b0};
						graphics_color <= window_y_w[2] ? video_data[7:4] : video_data[3:0];
`ifdef VGC_DEBUG
						if (H >= BL && H <= 100 && V == BT)
							$display("  LORES RELOAD: H=%d video_data=%h expanded=%b color=%h", H, video_data, {expandLores40(video_data, window_y_w[2]), 1'b0}, window_y_w[2] ? video_data[7:4] : video_data[3:0]);
`endif
					end else if (hires_mode) begin
						// Hires: expand pixel bits (0-6), store color bit (7) separately
						// Always store bit 7 for color phase - even in "DHIRES" mode since
						// games like 8bit-Slicks run with EIGHTYCOL set but still need color
						graphics_pix_shift <= expandHires40(video_data);
						graphics_color <= {3'b0, video_data[7]};  // Store color/palette bit
					end
				end
				// Always clear reload flag, even if we skipped loading due to out-of-bounds
				buffer_needs_reload <= 1'b0;
			end else begin
				// Shift pixels out: every clock in 80-col, every 2 clocks in 40-col (pixel doubling)
				// In 40-col mode: shift on odd xpos (1,3,5,7,9,11,13) so each pixel displays twice
                if (line_is_80 || xpos[0] == 1'b1) begin
                    // Shift with last-pixel fill to avoid introducing black seams
                    graphics_pix_shift <= {graphics_pix_shift[0], graphics_pix_shift[7:1]};
`ifdef VGC_DEBUG
                    if (H >= BL && H <= 100 && V == BT)
                        $display("  PIXEL SHIFT: H=%d xpos=%d shift_before=%b shift_after=%b pixel_out=%b", H, xpos, graphics_pix_shift, {graphics_pix_shift[0], graphics_pix_shift[7:1]}, graphics_pix_shift[0]);
`endif
                end else begin
					// Hold pixel for doubling in 40-column mode
`ifdef VGC_DEBUG
					if (H >= BL && H <= 100 && V == BT)
						$display("  PIXEL HOLD: H=%d xpos=%d shift=%b pixel_out=%b", H, xpos, graphics_pix_shift, graphics_pix_shift[0]);
`endif
				end
			end
			graphics_pixel <= graphics_pix_shift[0];
			
			// Update Apple II 6-pixel shift register for color artifacting
			apple2_shift_reg <= {graphics_pixel, apple2_shift_reg[5:1]};
			
			// Increment pixel counter for color phase (during active video)
			// Mode-dependent boundaries: SHRG uses full width, Apple II modes are centered
			if (SHRG) begin
				// SHRG mode: use full 640-pixel width (within 704 visible area)
				if (H >= BL && H < BR && V >= V_SCAN && V < BB)
					pixel_counter <= pixel_counter + 1'b1;
				else if (H < BL)
					pixel_counter <= 11'b0; // Reset at start of each line
			end else begin
				// Apple II modes: 192 lines starting at V=16 (scanline 0 to 191)
				if (H >= BLE && H < BRE && V >= V_SCAN && V < BBE)
					pixel_counter <= pixel_counter + 1'b1;
				else if (H < BLE)
					pixel_counter <= 11'b0; // Reset at start of each line
			end
		end

		xpos<=xpos+1'b1;

		// Text mode shift register management (FPGA-compatible sync ROM timing)
		// ROM has 1-cycle latency, so we pre-fetch and buffer in shift register
		if (!GR) begin
			if (EIGHTYCOL) begin
				// 80-column text mode: 7 pixels per character (xpos 0-6)
				// Timing: xpos=4: set address, xpos=5: video_data ready, xpos=6: ROM ready
				// At xpos=0: load shift register with pre-fetched ROM data
				if (xpos == 'd0) begin
					// Load shift register with ROM data (ready from pre-fetch)
					text_shift_reg <= chrom_data_inv[6:0];
					// Latch video_data for this character's ROM addressing
				end else begin
					// Shift out pixels LSB first (shift right, read bit 0)
					text_shift_reg <= {1'b0, text_shift_reg[6:1]};
				end
			end else begin
				// 40-column text mode: 14 pixels per character (xpos 0-13), pixel doubled
				// Each pixel displays twice (even xpos shows pixel, odd xpos shifts to next)
				if (xpos == 'd0) begin
					// Load shift register with ROM data
					text_shift_reg <= chrom_data_inv[6:0];
				end else if (xpos[0] == 1'b0 && xpos != 'd0) begin
					// Shift on EVEN xpos (2,4,6,8,10,12) for pixel doubling
					// This way: xpos 0-1 show bit0, xpos 2-3 show bit1, etc.
					text_shift_reg <= {1'b0, text_shift_reg[6:1]};
				end
				// Odd xpos (1,3,5,7,9,11,13): hold for pixel doubling
			end
		end

		if (line_is_80) begin
		  if (xpos=='d2) begin
		    // Anticipated bank toggle for the dhires video address (see aux_bank_early
		    // declaration): 2 cycles ahead of aux[16] so the next byte settles in time.
		    aux_bank_early <= ~aux_bank_early;
		    // Advance the anticipated column at the main->aux boundary (abe==0 about to
		    // flip to 1), 2 cycles before chram_x, so the next column's aux byte is
		    // addressed in time for its reload.
		    if (aux_bank_early == 1'b0)
		      chram_x_early <= chram_x_early + 1'b1;
		  end
		  if (xpos=='d4) begin
		    // Pre-fetch: advance memory 1 cycle earlier for sync ROM timing
		    // This gives memory 1 cycle to respond, then ROM 1 cycle
		    aux[16]<=~aux[16];                    // Toggle between main/aux every character
		    if (aux[16]==1'b0)                    // Only increment memory address every 2 characters
		      chram_x<=chram_x+1'b1;              // (each memory location holds 2 characters)
		  end
		  if (xpos=='d6) begin
			xpos<=0;
                  end
        end else if (xpos=='d11 && !line_is_80) begin
            // Pre-fetch for 40-column mode: increment address 2 cycles early
            // xpos=11: address changes, xpos=12: video_data ready, xpos=13: ROM ready
            // This gives memory + ROM time to respond before xpos=0
            chram_x<=chram_x+1'b1;
        end else if (xpos=='d13) begin
            // 40-column mode: wrap xpos at end of character (no chram_x inc here)
            xpos<=0;
        end

		// Clear shift registers at right border to prevent stray pixels
		// Text mode right border starts at H=632, Graphics at H=637
		if (!SHRG && !GR && H >= BRE) begin
			text_shift_reg <= 7'b0;
		end
		if (!SHRG && GR && H > (BRE+4)) begin
			graphics_pix_shift <= 8'b0;
			apple2_shift_reg <= 6'b0;
			graphics_pixel <= 1'b0;
			graphics_color <= 4'b0;  // Clear color to prevent stale palette lookups
		end

		// Use LDPS equivalent for buffer reload timing - but only trigger on edges
		if (ldps_load && !buffer_needs_reload) begin
			buffer_needs_reload <= 1'b1;
		end
	end
     end
//$display("xpos[2:0] %x xpos[3:1] %x xpos %x",xpos[2:0],xpos[3:1],xpos);
//$display("chram_x[6:1] %x chram_x %x chrom_data_out %x chrom_addr %x",chram_x[6:1],chram_x,chrom_data_out,chrom_addr);

// VBL starts at V=208 (scanline 192), per TN.IIGS.040




// Mode-dependent border generation (704-pixel visible area, H=0-703)
// Apple II TEXT modes: |Left Border(72px)|Active Display(560px)|Right Border(72px)| = 704 total
//   Text has minimal pipeline latency, uses original timing
// Apple II GFX modes:  |Left Border(77px)|Active Display(560px)|Right Border(67px)| = 704 total
//   Graphics has 5-pixel pipeline latency (apple2_shift_reg), shift border right
// SHRG modes:          |Left Border(32px)|Active Display(640px)|Right Border(32px)| = 704 total
// Border generation:
// Apple II TEXT: active display H=72-631 (560 pixels), V=16-207 (192 lines)
// Apple II GFX:  active display H=77-636 (560 pixels), V=16-207 (192 lines)
// SHRG modes:    active display H=32-671 (640 pixels), V=16-215 (200 lines)
if ((!SHRG && GR && ((H < gfx_lb || H > gfx_rb) || (V < V_SCAN || V >= BBE))) ||
    (!SHRG && !GR && ((H < BLE || H >= BRE) || (V < V_SCAN || V >= BBE))) ||
    (SHRG && ((H < (BL+1) || H >= BR || V < V_SCAN || V >= BB))))  // SHRG: 33px left border (mem latency), 639px active
begin
R <= {BORGB[11:8],BORGB[11:8]};
G <= {BORGB[7:4],BORGB[7:4]};
B <= {BORGB[3:0],BORGB[3:0]};
end
else
begin
    if (SHRG) begin
        // SHRG mode - use combinational first_pix to bypass pipeline latency
        // At H=33, video_data has first pixel byte (addr set H=31, mem latency)
        // In 320 mode, pixel 0 spans H=33-34. In 640 mode, pixel 0 is at H=33.
        // Also at H=34, shrg_r_pix has stale data (computed H=32 from wrong video_data)
        // So bypass H=33-34 for 320 mode, H=33 for 640 mode
        if (H == (BL+1) || (H == (BL+2) && !scb[7])) begin
            R <= {first_pix_r, first_pix_r};
            G <= {first_pix_g, first_pix_g};
            B <= {first_pix_b, first_pix_b};
        end else begin
            R <= {shrg_r_pix,shrg_r_pix};
            G <= {shrg_g_pix,shrg_g_pix};
            B <= {shrg_b_pix,shrg_b_pix};
        end
    end else if (GR) begin
        // Graphics mode (lores/hires)
        R <= {graphics_rgb[11:8],graphics_rgb[11:8]};
        G <= {graphics_rgb[7:4],graphics_rgb[7:4]};
        B <= {graphics_rgb[3:0],graphics_rgb[3:0]};
    end else begin
        // Text mode
        R <= textpixel ? {TRGB[11:8],TRGB[11:8]} : {BRGB[11:8],BRGB[11:8]};
        G <= textpixel ? {TRGB[7:4],TRGB[7:4]} : {BRGB[7:4],BRGB[7:4]};
        B <= textpixel ? {TRGB[3:0],TRGB[3:0]} : {BRGB[3:0],BRGB[3:0]};
    end
end
end


//assign a = chrom_data_out[chpos_x[2:0]];
// Window coordinates derived from H and V
// Apple II modes: Active display H=72-632 (560 pixels for 40 chars × 14 pixels)
// SHRG modes: Active display H=32-672 (640 pixels)
wire [9:0] window_y_w = (V >= V_SCAN) ? {2'b0, V[7:0]} : 10'b0;  // Apple II display starts at V=16 (scanline 0)

// Apple II coordinate mapping: Now properly centered, window_y_w is 0-191 (192 lines)
// No clamping needed since we're properly centered within the 200-line area
wire [7:0] apple_ii_y_clamped = window_y_w[7:0];

// GR signal calculation for mixed mode support  
// Mixed mode should switch to text at y=160 in Apple II coordinates (192-line system)
wire mixed_mode_active = (apple_ii_y_clamped >= 160) & MIXG;
wire GR = ~(TEXTG | mixed_mode_active);

// Apple II address generation using lineaddr() function with clamped coordinates
wire [15:0] lineaddr_result = lineaddr({2'b0, apple_ii_y_clamped});
wire [22:0] video_addr_ii_base = {7'b0, lineaddr_result} + {17'b0, (dhires_mode ? chram_x_early : chram_x)};

// 80-column modes (text80 and double hi-res) need aux memory bank switching
wire text80_mode = (!GR & EIGHTYCOL);
wire dhires_mode = (GR & HIRES_MODE & EIGHTYCOL & !AN3);  // Double Hi-Res mode
wire use_aux_bank = (text80_mode | dhires_mode) & (dhires_mode ? aux_bank_early : aux[16]);
// text80 floating-bus fetch: the real Mega II shows the pair's MAIN byte to
// the CPU ("col80 is a nop" for the FLOATBUS capture), but our schedule has
// the aux byte on video_data at the CPU sample tick (xpos 0 of the aux
// half). The text path consumes video_data ONLY at xpos 6 (char ROM lookup;
// the ROM registers it that tick and xpos 0 loads from chrom_data_out), so
// overriding the ADDRESS at xpos 6 is invisible to the display -- the main
// byte lands on video_data at xpos 0, right on the sample tick, and
// persists through xpos 4 (covering the 2px sample-phase shift the NTSC
// stretch introduces). aux[16] is already high at the preceding slot's
// xpos 6 and chram_x already points at the current pair. Text80 only:
// dhires consumes video_data continuously and must not be disturbed.
wire fb_main_slot = text80_mode & aux[16] & (xpos == 4'd6);
wire [22:0] video_addr_ii = fb_main_slot ? video_addr_ii_base :
                            use_aux_bank ? video_addr_ii_base + 23'h10000 :
                                           video_addr_ii_base;

// Character Y position within 8-pixel character cell (using clamped coordinates)
wire [2:0] chpos_y = apple_ii_y_clamped[2:0];

// Character ROM address calculation with proper attribute handling (a2fpga-style)
// The Apple II character set uses bits 6-7 for display attributes:
//   $00-$3F (bit 7=0, bit 6=0): Inverse characters
//   $40-$7F (bit 7=0, bit 6=1): Flash (primary) or MouseText (alternate charset)
//   $80-$FF (bit 7=1): Normal characters
// ROM address format (12 bits total):
//   bit 11: always 0
//   bit 10: normal char OR (flash char AND flash_state AND primary charset)
//   bit 9:  flash/mousetext bit AND (ALTCHARSET OR normal char)
//   bits 8:3: character code lower 6 bits (video_data[5:0])
//   bits 2:0: row within character (chpos_y)
wire chrom_bit10 = video_data[7] | (video_data[6] & flash_state & ~ALTCHARSET);
wire chrom_bit9 = video_data[6] & (ALTCHARSET | video_data[7]);
assign chrom_addr = {1'b0, chrom_bit10, chrom_bit9, video_data[5:0], chpos_y};

// Debug: trace MouseText character rendering
// Uncomment to see what's happening with specific characters
// `define DEBUG_MOUSETEXT 1
`ifdef DEBUG_MOUSETEXT
always @(posedge clk_vid) if (ce_pix) begin
    // Trace any MouseText character (0x40-0x5F range with ALTCHARSET)
    if (H >= BLE && H <= 200 && V >= 80 && V <= 88 && !GR && text80_mode &&
        ALTCHARSET && video_data >= 8'h40 && video_data < 8'h60 && xpos == 0) begin
        $display("MT: H=%d V=%d chpos_y=%d vdata=%h addr=%h data=%h bits=%b%b%b%b%b%b%b",
                 H, V, chpos_y, video_data, chrom_addr, chrom_data_out,
                 chrom_data_out[6], chrom_data_out[5], chrom_data_out[4],
                 chrom_data_out[3], chrom_data_out[2], chrom_data_out[1], chrom_data_out[0]);
    end
end
`endif

always @(posedge clk_vid) if (ce_pix)
begin
    
    // Debug disabled
    // if (H >= 72 && H <= 130 && V == 56 && !GR && text80_mode) begin
    //     $display("  80COL: H=%d V=%d video_data=%h aux=%b chram_x=%d xpos=%d addr=%h use_aux=%b",
    //              H, V, video_data, aux[16], chram_x, xpos, video_addr_ii, use_aux_bank);
    // end
//	$display("V %x oldV %x chram_y %x base_y %x offset %x video_addr %x video_data %x video_data %x %c %x \n",V[8:3],oldV,chram_y,base_y,offset,video_addr,video_data,video_data[6:0],video_data[6:0],chrom_data_out);
end



`ifdef VGC_DEBUG
/*
    reg [8:0] V_d;
    always @(posedge clk_vid) if(ce_pix) begin
        V_d <= V;
        if (V != V_d) begin
            $display("VGC_DEBUG @ %0t: V counter changed to %d", $time, V);
        end
    end
*/
`endif


// VBL Pulse Generation
// Generate a single-cycle pulse at the start of the vertical blanking interval
// to avoid IRQ storms.
wire v_blank = (V >= BBE); // V=208 is scanline 192 (V-16), where VBL begins per TN.IIGS.040
reg v_blank_d;
always @(posedge clk_vid) if(ce_pix) v_blank_d <= v_blank;
assign vbl_irq = v_blank & ~v_blank_d;

endmodule
