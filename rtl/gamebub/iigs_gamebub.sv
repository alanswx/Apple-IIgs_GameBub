// ============================================================================
// iigs_gamebub.sv: Apple IIgs for Game Bub, the framework-facing top.
//
// chisel/src/AppleIIgs.scala declares the framework interfaces; the framework
// binds them to this module (port names are generated from that bundle; the
// build prints the template if they ever change). This file only wires the
// platform layer around the machine:
//
//   gb_clocks      one MMCM: sys 14.32, vid 28.64, mem 114.6, SPI 171.9, LCD 28.64,
//                  IDELAY reference 206.25
//   gb_sdram_idelay  input delays on the SDRAM data pins
//   gb_host        HostV0 commands, settings, file window into SDRAM
//   gb_blockdev    the 3.5" drive's sectors, served from the WOZ in SDRAM
//   gb_pad_input   12 buttons -> PS/2 keyboard + mouse (-> ADB)
//   gb_video_out   VGC scanout -> 320x200 3/3/3 frame stream (dithered)
//   gb_debug_uart  status beacon on the PMOD header
//   iigs_core      the IIgs itself (from the MiSTer core)
//
// PMOD header (3.3 V):  pin 3 (pmod[2]) out  debug beacon, 115200 8N1
// ============================================================================
`default_nettype none

module iigs_gamebub (
	input  wire         clock,
	input  wire         reset,
	input  wire         clocks_clockIn50M,
	output logic        clocks_clockOutSystem,
	output logic        clocks_clockOutDisplay,
	output logic        clocks_clockOutSpi,
	output logic        clocks_locked,
	output logic [2:0]  video_data_r,
	output logic [2:0]  video_data_g,
	output logic [2:0]  video_data_b,
	output logic        video_dataEnable,
	output logic        video_vblank,
	output logic        video_hblank,
	output logic [15:0] audio_left,
	output logic [15:0] audio_right,
	input  wire         host_mem_enable,
	input  wire         host_mem_write,
	output logic        host_mem_done,
	input  wire  [31:0] host_mem_address,
	output logic [31:0] host_mem_dataRead,
	input  wire  [31:0] host_mem_dataWrite,
	input  wire         host_commandHost_request,
	output logic        host_commandHost_busy,
	output logic        host_commandHost_done,
	output logic        host_commandHost_error,
	output logic        host_commandCore_request,
	input  wire         host_commandCore_busy,
	input  wire         host_commandCore_done,
	input  wire         host_commandCore_error,
	input  wire         input_buttons_a,
	input  wire         input_buttons_b,
	input  wire         input_buttons_x,
	input  wire         input_buttons_y,
	input  wire         input_buttons_up,
	input  wire         input_buttons_down,
	input  wire         input_buttons_left,
	input  wire         input_buttons_right,
	input  wire         input_buttons_l,
	input  wire         input_buttons_r,
	input  wire         input_buttons_start,
	input  wire         input_buttons_select,
	output logic        sdram_clock,
	output logic        sdram_cke,
	output logic        sdram_cs,
	output logic        sdram_ras,
	output logic        sdram_cas,
	output logic        sdram_we,
	output logic [1:0]  sdram_dqm,
	output logic [1:0]  sdram_bank,
	output logic [12:0] sdram_address,
	input  wire  [15:0] sdram_dataIn,
	output logic [15:0] sdram_dataOut,
	output logic        sdram_dataDir,
	input  wire  [3:0]  pmod_in,
	output logic [3:0]  pmod_out,
	output logic [3:0]  pmod_dir
);

	localparam integer CLK_SYS_HZ = 14_322_917;   // 1031.25 MHz / 72

	// ---------------------------------------------------------------------
	// Clocks
	// ---------------------------------------------------------------------
	wire clk_sys, clk_vid, clk_mem, clk_ref, pll_locked;
	gb_clocks clocks (
		.clk_in_50mhz (clocks_clockIn50M),
		.clk_sys      (clk_sys),
		.clk_vid      (clk_vid),
		.clk_mem      (clk_mem),
		.clk_spi      (clocks_clockOutSpi),
		.clk_display  (clocks_clockOutDisplay),
		.clk_ref      (clk_ref),
		.locked       (pll_locked)
	);
	assign clocks_clockOutSystem = clk_sys;
	assign clocks_locked         = pll_locked;
	// `clock` is clk_sys handed back by the framework; logic here uses
	// clk_sys directly (same net) and the framework's synchronous `reset`.

	// ---------------------------------------------------------------------
	// Host protocol
	// ---------------------------------------------------------------------
	wire        core_reset, rom_select, act_reset, act_swap, mount_req, focus;
	wire  [2:0] host_speed;
	wire        ptr_default;
	wire  [4:0] file_present;
	wire [159:0] file_size_flat;
	wire [31:0] dbg_blockdev, dbg_host_state, dbg_woz_magic;
	wire        db_start, db_done, db_found;
	wire  [1:0] db_rom;
	wire  [7:0] db_speed, db_input, db_mouse, mouse_steps;
	wire  [2:0] doc_gain;
	wire        disk_light, controls_card;
	wire [3:0]  dbg_disk;             // iigs_core: {motor, busy, ready, mounted}
	wire [31:0] db_crc;
	wire [62:0] db_keymap;

	wire        host_sd_req, host_sd_we, host_sd_ack;
	wire [23:0] host_sd_addr;
	wire [15:0] host_sd_din;

	gb_host host (
		.clk            (clk_sys),
		.reset          (reset),
		.mem_enable     (host_mem_enable),
		.mem_write      (host_mem_write),
		.mem_address    (host_mem_address),
		.mem_dataWrite  (host_mem_dataWrite),
		.mem_dataRead   (host_mem_dataRead),
		.mem_done       (host_mem_done),
		.cmd_request    (host_commandHost_request),
		.cmd_busy       (host_commandHost_busy),
		.cmd_done       (host_commandHost_done),
		.cmd_error      (host_commandHost_error),
		.sd_req         (host_sd_req),
		.sd_we          (host_sd_we),
		.sd_addr        (host_sd_addr),
		.sd_din         (host_sd_din),
		.sd_ack         (host_sd_ack),
		.core_reset     (core_reset),
		.rom_select     (rom_select),
		.host_speed     (host_speed),
		.act_reset      (act_reset),
		.act_swap       (act_swap),
		.mount_req      (mount_req),
		.focus          (focus),
		.ptr_default    (ptr_default),
		.db_start       (db_start),
		.db_done        (db_done),
		.db_found       (db_found),
		.db_rom         (db_rom),
		.db_speed       (db_speed),
		.db_input       (db_input),
		.db_mouse       (db_mouse),
		.mouse_steps    (mouse_steps),
		.doc_gain       (doc_gain),
		.disk_light     (disk_light),
		.controls_card  (controls_card),
		.file_present   (file_present),
		.file_size_flat (file_size_flat),
		.dbg_blockdev   (dbg_blockdev),
		.dbg_state      (dbg_host_state),
		.dbg_woz_magic  (dbg_woz_magic)
	);
	// No core->host commands exist in framework v1.1.
	assign host_commandCore_request = 1'b0;

	// ---------------------------------------------------------------------
	// The disk in the 3.5" drive: disk 1, or disk 2 after "Swap disk"
	// (SDRAM word addresses of the images, gb_host.sv map / 2).
	// ---------------------------------------------------------------------
	localparam [23:0] DISK1_WORD = 24'h80_0000;   // byte 0x100_0000
	localparam [23:0] DISK2_WORD = 24'hA0_0000;   // byte 0x140_0000

	reg disk_sel = 1'b0;                          // 0 = disk 1, 1 = disk 2
	always @(posedge clk_sys)
		if (reset || core_reset)                 disk_sel <= 1'b0;
		else if (act_swap && file_present[1])    disk_sel <= ~disk_sel;

	wire [23:0] img_base  = disk_sel ? DISK2_WORD : DISK1_WORD;
	wire [31:0] img_bytes = disk_sel ? file_size_flat[63:32] :
	                        (file_present[0] ? file_size_flat[31:0] : 32'd0);

	// ---------------------------------------------------------------------
	// Block device
	// ---------------------------------------------------------------------
	wire [31:0] sd_lba;
	wire        sd_rd, sd_wr, sd_ack, sd_buff_wr, img_mounted, img_readonly;
	wire [8:0]  sd_buff_addr;
	wire [7:0]  sd_buff_dout, sd_buff_din;
	wire [63:0] img_size;

	wire        bd_sd_req, bd_sd_we, bd_sd_ack;
	wire [23:0] bd_sd_addr;
	wire [15:0] bd_sd_din, bd_sd_dout;
	wire [127:0] pm_line;

	gb_blockdev blockdev (
		.clk          (clk_sys),
		.reset        (reset),
		.img_base     (img_base),
		.img_bytes    (img_bytes),
		.mount_req    (mount_req || (act_swap && file_present[1])),
		.sd_lba       (sd_lba),
		.sd_rd        (sd_rd),
		.sd_wr        (sd_wr),
		.sd_ack       (sd_ack),
		.sd_buff_addr (sd_buff_addr),
		.sd_buff_dout (sd_buff_dout),
		.sd_buff_din  (sd_buff_din),
		.sd_buff_wr   (sd_buff_wr),
		.img_mounted  (img_mounted),
		.img_size     (img_size),
		.img_readonly (img_readonly),
		.mem_req      (bd_sd_req),
		.mem_we       (bd_sd_we),
		.mem_addr     (bd_sd_addr),
		.mem_din      (bd_sd_din),
		.mem_ack      (bd_sd_ack),
		.mem_dout     (bd_sd_dout),
		.mem_line     (pm_line),
		.dbg          (dbg_blockdev)
	);

	// ---------------------------------------------------------------------
	// Game database: the disk's per-game settings (tools/mkgamedb.py),
	// looked up after SetupComplete, before the IIgs is released.
	// ---------------------------------------------------------------------
	localparam [23:0] GAMEDB_WORD = 24'hC0_0000;  // byte 0x180_0000

	wire        db_sd_req, db_sd_ack;
	wire [23:0] db_sd_addr;
	gb_gamedb gamedb (
		.clk          (clk_sys),
		.reset        (reset),
		.start        (db_start),
		.disk_present (file_present[0]),
		.db_present   (file_present[4]),
		.disk_word    (DISK1_WORD),
		.db_word      (GAMEDB_WORD),
		.db_bytes     (file_size_flat[159:128]),
		.mem_req      (db_sd_req),
		.mem_addr     (db_sd_addr),
		.mem_ack      (db_sd_ack),
		.mem_line     (pm_line),
		.done         (db_done),
		.found        (db_found),
		.crc          (db_crc),
		.rom          (db_rom),
		.speed        (db_speed),
		.input_mode   (db_input),
		.mouse        (db_mouse),
		.keymap       (db_keymap)
	);

	// Host window (files) and the lookup (only ever one at a time: the
	// lookup starts after SetupComplete), then those and the block device,
	// share SDRAM ch2.
	wire        hd_req, hd_we, hd_ack;
	wire [23:0] hd_addr;
	wire [15:0] hd_din;
	gb_eth_arb hd_arb (
		.clk    ( clk_sys ),
		.reset  ( reset ),
		.a_req  ( host_sd_req ), .a_we ( host_sd_we ), .a_addr ( host_sd_addr ),
		.a_din  ( host_sd_din ), .a_ack ( host_sd_ack ), .a_dout ( ),
		.b_req  ( db_sd_req ),   .b_we ( 1'b0 ),       .b_addr ( db_sd_addr ),
		.b_din  ( 16'd0 ),       .b_ack ( db_sd_ack ), .b_dout ( ),
		.m_req  ( hd_req ),      .m_we ( hd_we ),      .m_addr ( hd_addr ),
		.m_din  ( hd_din ),      .m_ack ( hd_ack ),    .m_dout ( 16'd0 )
	);

	wire        pm_req, pm_we, pm_ack;
	wire [23:0] pm_addr;
	wire [15:0] pm_din, pm_dout;
	gb_eth_arb pm_arb (
		.clk    ( clk_sys ),
		.reset  ( reset ),
		.a_req  ( hd_req ),      .a_we ( hd_we ),      .a_addr ( hd_addr ),
		.a_din  ( hd_din ),      .a_ack ( hd_ack ),    .a_dout ( ),
		.b_req  ( bd_sd_req ),   .b_we ( bd_sd_we ),   .b_addr ( bd_sd_addr ),
		.b_din  ( bd_sd_din ),   .b_ack ( bd_sd_ack ), .b_dout ( bd_sd_dout ),
		.m_req  ( pm_req ),      .m_we ( pm_we ),      .m_addr ( pm_addr ),
		.m_din  ( pm_din ),      .m_ack ( pm_ack ),    .m_dout ( pm_dout )
	);

	// ---------------------------------------------------------------------
	// Input: Game Bub buttons in the Pocket cont1_key layout. Select
	// toggles mouse / keyboard mode (gb_pad_input); holding it opens the
	// on-screen keyboard (gb_osk). A..Start type the keys
	// the game database gives this disk, else the defaults below (keep them
	// in step with tools/mkgamedb.py DEFAULT_MAP). The d-pad also drives
	// the joystick, full deflection; L and R are Open Apple and Option,
	// which the IIgs reads as joystick buttons 0 and 1 too.
	// ---------------------------------------------------------------------
	wire [15:0] cont1_key = {
		input_buttons_start,   // 15
		input_buttons_select,  // 14
		4'd0,                  // 13:10
		input_buttons_r,       // 9  (R1)
		input_buttons_l,       // 8  (L1)
		input_buttons_y,       // 7
		input_buttons_x,       // 6
		input_buttons_b,       // 5
		input_buttons_a,       // 4
		input_buttons_right,   // 3
		input_buttons_left,    // 2
		input_buttons_down,    // 1
		input_buttons_up       // 0
	};
	// {start, r, l, y, x, b, a}, PS/2 set 2 scancodes (bit 8 = E0),
	// translated by rtl/iigs/adb.sv
	localparam [62:0] DEFAULT_KEYMAP = {
		9'h05A,   // Start: Return
		9'h11F,   // R: Left GUI -> Option (joystick button 1)
		9'h011,   // L: Left Alt -> Open Apple (joystick button 0)
		9'h035,   // Y: Y
		9'h076,   // X: Escape
		9'h029,   // B: Space
		9'h05A    // A: Return (mouse button in pointer mode)
	};
	wire [62:0] keymap = db_found ? db_keymap : DEFAULT_KEYMAP;

	// The on-screen keyboard (gb_osk) takes Select holds and, while open,
	// every button; the rest reaches the pad, and its keys join the pad's.
	wire [15:0] pad_keys;
	wire [10:0] pad_ps2_key, ps2_key;
	wire [24:0] ps2_mouse;
	wire        ptr_mode, osk_open;
	gb_pad_input #(
		.CLK_HZ (CLK_SYS_HZ)
	) pad (
		.clk         (clk_sys),
		// re-sampled each time the IIgs is released, so the "start in mouse
		// mode" setting written during setup takes effect
		.reset       (reset || core_reset),
		.cont1_key   (pad_keys),
		.map_a       (keymap[8:0]),
		.map_b       (keymap[17:9]),
		.map_x       (keymap[26:18]),
		.map_y       (keymap[35:27]),
		.map_l       (keymap[44:36]),
		.map_r       (keymap[53:45]),
		.map_start   (keymap[62:54]),
		.ps2_key     (pad_ps2_key),
		.ps2_mouse   (ps2_mouse),
		.ptr_default (ptr_default),
		.step_slow   (mouse_steps[3:0]),
		.step_fast   (mouse_steps[7:4]),
		.ptr_mode    (ptr_mode)
	);

	wire [7:0] joy_x = pad_keys[2] ? 8'h81 : pad_keys[3] ? 8'h7F : 8'h00;
	wire [7:0] joy_y = pad_keys[0] ? 8'h81 : pad_keys[1] ? 8'h7F : 8'h00;

	// ---------------------------------------------------------------------
	// The IIgs
	// ---------------------------------------------------------------------
	wire [7:0]  vid_r, vid_g, vid_b;
	wire        vid_hblank, vid_vblank;
	wire        sdram_dq_oe;
	wire [15:0] sdram_dq_in;
	wire        idelay_ready;

	// SDRAM read data: a fixed input delay centres the capture window
	// (gb_sdram_idelay.sv, rtl/gamebub/iigs.xdc).
	gb_sdram_idelay #(.TAPS(9)) sdram_idelay (
		.clk_ref    (clk_ref),
		.ref_locked (pll_locked),
		.pin_in     (sdram_dataIn),
		.data_out   (sdram_dq_in),
		.ready      (idelay_ready)
	);
	wire [23:0] dbg_addr;
	wire        dbg_core_reset;

	iigs_core core (
		.clk_sys             (clk_sys),
		.clk_vid             (clk_vid),
		.clk_mem             (clk_mem),
		.pll_locked          (pll_locked),
		.host_reset          (core_reset || reset),
		.warm_reset          (act_reset),
		.rom_select          (rom_select),
		.host_speed          (host_speed),
		.ps2_key             (ps2_key),
		.ps2_mouse           (ps2_mouse),
		.doc_gain            (doc_gain),
		.joystick_0          (32'd0),
		.joystick_l_analog_0 ({joy_y, joy_x}),
		.sd_lba              (sd_lba),
		.sd_rd               (sd_rd),
		.sd_wr               (sd_wr),
		.sd_ack              (sd_ack),
		.sd_buff_addr        (sd_buff_addr),
		.sd_buff_dout        (sd_buff_dout),
		.sd_buff_din         (sd_buff_din),
		.sd_buff_wr          (sd_buff_wr),
		.img_mounted         (img_mounted),
		.img_size            (img_size),
		.img_readonly        (img_readonly),
		.pm_req              (pm_req),
		.pm_we               (pm_we),
		.pm_addr             (pm_addr),
		.pm_din              (pm_din),
		.pm_ack              (pm_ack),
		.pm_dout             (pm_dout),
		.pm_line             (pm_line),
		.vid_r               (vid_r),
		.vid_g               (vid_g),
		.vid_b               (vid_b),
		.vid_hblank          (vid_hblank),
		.vid_vblank          (vid_vblank),
		.audio_l             (audio_left),
		.audio_r             (audio_right),
		.sdram_clk           (sdram_clock),
		.sdram_dq_out        (sdram_dataOut),
		.sdram_dq_in         (sdram_dq_in),
		.sdram_dq_oe         (sdram_dq_oe),
		.sdram_a             (sdram_address),
		.sdram_dqm           (sdram_dqm),
		.sdram_ba            (sdram_bank),
		.sdram_cs_n          (sdram_cs),
		.sdram_we_n          (sdram_we),
		.sdram_ras_n         (sdram_ras),
		.sdram_cas_n         (sdram_cas),
		.dbg_addr            (dbg_addr),
		.dbg_reset           (dbg_core_reset),
		.dbg_disk            (dbg_disk)
	);
	assign sdram_cke     = 1'b1;
	assign sdram_dataDir = sdram_dq_oe;

	// ---------------------------------------------------------------------
	// Video
	// ---------------------------------------------------------------------
	// The on-screen keyboard and the status icons (drive light, input
	// mode) are drawn on the VGC picture before it is scaled down.
	wire [7:0] ok_r, ok_g, ok_b;
	wire       ok_hblank, ok_vblank;
	gb_osk #(.CLK_HZ(CLK_SYS_HZ)) osk (
		.clk         (clk_sys),
		.reset       (reset || core_reset),
		.keys_in     (cont1_key),
		.keys_out    (pad_keys),
		.open        (osk_open),
		.ps2_in      (pad_ps2_key),
		.ps2_out     (ps2_key),
		.lights_en   (disk_light),
		.card_at_start (controls_card),
		.keymap      (keymap),
		.disk_active (dbg_disk[3]),      // drive motor on
		.ptr_mode    (ptr_mode),
		.in_r        (vid_r),
		.in_g        (vid_g),
		.in_b        (vid_b),
		.in_hblank   (vid_hblank),
		.in_vblank   (vid_vblank),
		.out_r       (ok_r),
		.out_g       (ok_g),
		.out_b       (ok_b),
		.out_hblank  (ok_hblank),
		.out_vblank  (ok_vblank)
	);

	gb_video_out video (
		.clk        (clk_sys),
		.reset      (reset || core_reset),
		.in_r       (ok_r),
		.in_g       (ok_g),
		.in_b       (ok_b),
		.in_hblank  (ok_hblank),
		.in_vblank  (ok_vblank),
		.out_r      (video_data_r),
		.out_g      (video_data_g),
		.out_b      (video_data_b),
		.out_de     (video_dataEnable),
		.out_hblank (video_hblank),
		.out_vblank (video_vblank)
	);

	// ---------------------------------------------------------------------
	// Debug beacon (PMOD pin 3). Words, in order:
	//   0  gb_host state: "GS" | engine state, file_present[4:0], rom, run, setup
	//   1  first word of disk 1 ("WOZ2" = 325A4F57)
	//   2  disk 1 size (bytes)
	//   3  the disk's WOZ CRC32, the game database key (add unknown disks)
	//   4  block device {writes, reads}
	//   5  {disk_sel, rom_select, host_speed, focus, core_reset, CPU reset, CPU address}
	//   6  {frames[15:0], 9'd0, game found, lookup done, IDELAYCTRL ready,
	//       disk {motor, busy, ready, mounted}}
	//   7  "IIGS"
	// ---------------------------------------------------------------------
	reg [15:0] frames = 16'd0;
	reg        vbl_d  = 1'b0;
	always @(posedge clk_sys) begin
		vbl_d <= video_vblank;
		if (video_vblank && !vbl_d) frames <= frames + 16'd1;
	end
	wire dbg_txd;
	gb_debug_uart #(.CLK_HZ(CLK_SYS_HZ), .NWORDS(8)) beacon (
		.clk   (clk_sys),
		.reset (reset),
		.words ({
			32'h49494753,
			{frames, 9'd0, db_found, db_done, idelay_ready, dbg_disk},
			{disk_sel, rom_select, host_speed, focus, core_reset, dbg_core_reset, dbg_addr},
			dbg_blockdev,
			db_crc,
			file_size_flat[31:0],
			dbg_woz_magic,
			dbg_host_state
		}),
		.txd   (dbg_txd)
	);

	assign pmod_out = {1'b0, dbg_txd, 2'b00};
	assign pmod_dir = 4'b0100;

endmodule

`default_nettype wire
