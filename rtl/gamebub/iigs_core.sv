// ============================================================================
// iigs_core.sv: the Apple IIgs machine for Game Bub, in place of MiSTer's
// Apple-IIgs.sv (the `emu` top level).
//
// Kept from Apple-IIgs.sv (bf80e6d), as close to verbatim as the platform
// allows, because the CPU memory path is cycle-sensitive and hardware-proven:
//   * the iigs instance and its reset/cold-reset rules;
//   * the CPU <-> SDRAM path: ch0 posted writes, ch3 native reads, ch1
//     burst + sdram_cache when accelerated, the switch guard and mem_stall;
//   * the 3.5" WOZ drive (woz_floppy_controller) and its mount sequencing.
// Left out: hps_io/OSD, the status-mirror write-back, HDD, PRAM backup, the
// TWGS card (rtl/gamebub/iigs_stubs.sv), the 5.25" drive and the serial port
// routing (the SCC stays in, unconnected).
//
// SDRAM ch2 was MiSTer's HPS ROM upload. Here it is the platform port
// (pm_*, gb_eth_arb protocol): gb_host's file window and gb_blockdev's disk
// sectors, both through the single-word ch2 the import adds reads to.
//
// SDRAM MAP (byte addresses, see gb_host.sv): fast RAM 0..7F_FFFF,
// ROM 01 F8_0000, ROM 3 FC_0000, disk images from 100_0000 up.
// ============================================================================
`default_nettype none

module iigs_core (
	input  wire        clk_sys,          // 14.32 MHz (CLK_14M)
	input  wire        clk_vid,          // 28.64 MHz (CLK_28M, clk_vid)
	input  wire        clk_mem,          // 114.6 MHz (SDRAM)
	input  wire        pll_locked,

	// ---- control (gb_host) ----
	input  wire        host_reset,       // 1 = held in (cold) reset: no ROM yet / halted
	input  wire        warm_reset,       // pulse: warm reset (Ctrl-Reset)
	input  wire        rom_select,       // 0 = ROM 3, 1 = ROM 01
	input  wire [2:0]  host_speed,       // 0 = 2.8 MHz .. 4 = 14.3 MHz

	// ---- input ----
	input  wire [10:0] ps2_key,
	input  wire [24:0] ps2_mouse,
	input  wire [31:0] joystick_0,       // [4] button 0, [5] button 1
	input  wire [15:0] joystick_l_analog_0, // [7:0] X, [15:8] Y, signed

	// ---- 3.5" drive block device (gb_blockdev) ----
	output wire [31:0] sd_lba,
	output wire        sd_rd,
	output wire        sd_wr,
	input  wire        sd_ack,
	input  wire [8:0]  sd_buff_addr,
	input  wire [7:0]  sd_buff_dout,
	output wire [7:0]  sd_buff_din,
	input  wire        sd_buff_wr,
	input  wire        img_mounted,
	input  wire [63:0] img_size,
	input  wire        img_readonly,

	// ---- platform SDRAM port (gb_eth_arb protocol, 16-bit word address) ----
	input  wire        pm_req,
	input  wire        pm_we,
	input  wire [23:0] pm_addr,
	input  wire [15:0] pm_din,
	output reg         pm_ack,
	output reg  [15:0] pm_dout,

	// ---- video (clk_vid domain, one pixel per ce_pix) ----
	output wire [7:0]  vid_r,
	output wire [7:0]  vid_g,
	output wire [7:0]  vid_b,
	output wire        vid_hblank,
	output wire        vid_vblank,

	// ---- audio (signed) ----
	output wire [15:0] audio_l,
	output wire [15:0] audio_r,

	// ---- SDRAM pins ----
	output wire        sdram_clk,
	output wire [15:0] sdram_dq_out,
	input  wire [15:0] sdram_dq_in,
	output wire        sdram_dq_oe,
	output wire [12:0] sdram_a,
	output wire [1:0]  sdram_dqm,
	output wire [1:0]  sdram_ba,
	output wire        sdram_cs_n,
	output wire        sdram_we_n,
	output wire        sdram_ras_n,
	output wire        sdram_cas_n,

	// ---- debug ----
	output wire [23:0] dbg_addr,
	output wire        dbg_reset,
	output wire [3:0]  dbg_disk
);

	// ---------------------------------------------------------------------
	// Resets (Apple-IIgs.sv): cold = power-on, host hold or ROM switch;
	// warm = Ctrl-Reset (settings action or Ctrl+F11 from the ADB).
	// ---------------------------------------------------------------------
	wire keyboard_reset, keyboard_cold_reset;

	reg  [7:0] warm_cnt = 8'd0;          // stretch the one-clock action pulse
	always @(posedge clk_sys)
		if (warm_reset)            warm_cnt <= 8'hFF;
		else if (warm_cnt != 8'd0) warm_cnt <= warm_cnt - 8'd1;

	reg rom_select_prev = 1'b0;
	always @(posedge clk_sys) rom_select_prev <= rom_select;
	wire rom_switch_reset = (rom_select != rom_select_prev);

	wire warm_reset_trigger = (warm_cnt != 8'd0) | keyboard_reset;
	wire cold_reset_trigger = keyboard_cold_reset | rom_switch_reset | host_reset;
	wire reset      = ~pll_locked | warm_reset_trigger | cold_reset_trigger;
	wire cold_reset = ~pll_locked | cold_reset_trigger;

	// ZipGS registers visible (OSD "Accelerator > Card: ZipGS"); the delays
	// keep their power-on defaults (enabled; CPS follow off).
	wire accel_capable = 1'b1;
	wire zip_regs_en   = 1'b1;
	wire twgs_present  = 1'b0;

	reg ce_pix = 1'b0;
	always @(posedge clk_vid) ce_pix <= ~ce_pix;

	// ---------------------------------------------------------------------
	// The machine
	// ---------------------------------------------------------------------
	wire        phi2, phi0, clk_7M;
	wire        drive35_eject_req;
	wire        mem_stall;
	wire        accel_active;
	wire        cache_disable;
	wire [23:0] addr_bus;
	wire [1:0]  rom_bankaddr;
	wire [7:0]  iigs_dout;
	wire        we;
	wire        fastram_ce;
	wire        rom_ce;
	wire [7:0]  sdram_dout;

	wire [7:0]  WOZ_TRACK3;
	wire [15:0] WOZ_TRACK3_BIT_ADDR;
	wire        WOZ_TRACK3_STABLE_SIDE;
	wire [7:0]  WOZ_TRACK3_BIT_DATA;
	wire [31:0] WOZ_TRACK3_BIT_COUNT;
	wire        WOZ_TRACK3_LOAD_COMPLETE;
	wire        WOZ_TRACK3_IS_FLUX;
	wire [31:0] WOZ_TRACK3_FLUX_SIZE;
	wire [31:0] WOZ_TRACK3_FLUX_TOTAL_TICKS;
	wire        WOZ_TRACK3_WP;
	wire        WOZ_TRACK3_READY;
	wire        WOZ_TRACK3_DATA_VALID;
	wire [7:0]  WOZ_TRACK3_BIT_DATA_IN;
	wire        WOZ_TRACK3_BIT_WE;
	wire [15:0] WOZ_TRACK3_BIT_WR_ADDR;
	wire        floppy_motor_on, floppy35_motor_on;
	wire [3:0]  DISK_READY;

	/* verilator lint_off PINMISSING */
	iigs iigs (
		.reset(reset),
		.cold_reset(cold_reset),
		.CLK_28M(clk_vid),
		.CLK_14M(clk_sys),
		.clk_vid(clk_vid),
		.ce_pix(ce_pix),
		.phi2(phi2),
		.phi0(phi0),
		.clk_7M(clk_7M),
		.timestamp(33'd0),
		.floppy_wp(1'b1),
		.R(vid_r),
		.G(vid_g),
		.B(vid_b),
		.HBlank(vid_hblank),
		.VBlank(vid_vblank),
		.HS(),
		.VS(),
		.AUDIO_L(audio_l),
		.AUDIO_R(audio_r),
		// no hard disk (hdd stub)
		.HDD_SECTOR(),
		.HDD_READ(),
		.HDD_WRITE(),
		.HDD_MOUNTED(2'b00),
		.img_readonly(1'b0),
		.img_size(64'd0),
		.HDD_RAM_ADDR(9'd0),
		.HDD_RAM_DI(8'd0),
		.HDD_RAM_DO(),
		.HDD_RAM_WE(1'b0),
		.HDD_ACK(2'b00),
		// 3.5" drive 1
		.WOZ_TRACK3(WOZ_TRACK3),
		.WOZ_TRACK3_BIT_ADDR(WOZ_TRACK3_BIT_ADDR),
		.WOZ_TRACK3_STABLE_SIDE(WOZ_TRACK3_STABLE_SIDE),
		.WOZ_TRACK3_BIT_DATA(WOZ_TRACK3_BIT_DATA),
		.WOZ_TRACK3_BIT_COUNT(WOZ_TRACK3_BIT_COUNT),
		.WOZ_TRACK3_LOAD_COMPLETE(WOZ_TRACK3_LOAD_COMPLETE),
		.WOZ_TRACK3_IS_FLUX(WOZ_TRACK3_IS_FLUX),
		.WOZ_TRACK3_FLUX_SIZE(WOZ_TRACK3_FLUX_SIZE),
		.WOZ_TRACK3_FLUX_TOTAL_TICKS(WOZ_TRACK3_FLUX_TOTAL_TICKS),
		.WOZ_TRACK3_WP(WOZ_TRACK3_WP),
		.WOZ_TRACK3_READY(WOZ_TRACK3_READY),
		.WOZ_TRACK3_DATA_VALID(WOZ_TRACK3_DATA_VALID),
		.WOZ_TRACK3_BIT_DATA_IN(WOZ_TRACK3_BIT_DATA_IN),
		.WOZ_TRACK3_BIT_WE(WOZ_TRACK3_BIT_WE),
		.WOZ_TRACK3_BIT_WR_ADDR(WOZ_TRACK3_BIT_WR_ADDR),
		// no 5.25" drive
		.WOZ_TRACK1(),
		.WOZ_TRACK1_QTRACK(),
		.WOZ_TRACK1_DATA_VALID(1'b0),
		.WOZ_TRACK1_BIT_ADDR(),
		.WOZ_TRACK1_BIT_DATA(8'd0),
		.WOZ_TRACK1_BIT_COUNT(32'd0),
		.WOZ_TRACK1_LOAD_COMPLETE(1'b0),
		.WOZ_TRACK1_IS_FLUX(1'b0),
		.WOZ_525_BIT_TIMING(8'd0),
		.WOZ_TRACK1_FLUX_SIZE(32'd0),
		.WOZ_TRACK1_FLUX_TOTAL_TICKS(32'd0),
		.WOZ_TRACK1_WP(1'b1),
		.WOZ_TRACK1_BIT_DATA_IN(),
		.WOZ_TRACK1_BIT_WE(),
		.WOZ_TRACK1_BIT_WR_ADDR(),
		.DISK_READY(DISK_READY),
		.floppy_motor_on(floppy_motor_on),
		.floppy35_motor_on(floppy35_motor_on),
		.drive35_eject_req(drive35_eject_req),
		.top_addr(addr_bus),
		.rom_bankaddr(rom_bankaddr),
		.top_din(sdram_dout),
		.top_dout(iigs_dout),
		.we(we),
		.fastram_ce(fastram_ce),
		.rom_ce(rom_ce),
		.rom_select(rom_select),
		.ps2_key(ps2_key),
		.ps2_mouse(ps2_mouse),
		.selftest_override(1'b0),
		.host_speed(host_speed),
		.accel_capable(accel_capable),
		.accel_active(accel_active),
		.zip_regs_en(zip_regs_en),
		.twgs_present(twgs_present),
		.osd_spkr_delay(1'b1),
		.osd_pdl_delay(1'b1),
		.osd_ctr_delay(1'b1),
		.osd_cps_follow(1'b0),
		.accel_cfg_speed(),
		.accel_spkr_delay(),
		.accel_pdl_delay(),
		.accel_ctr_delay(),
		.accel_cps_follow(),
		.osd_irq_delay(1'b1),
		.accel_irq_delay(),
		.osd_twgs_gfx(1'b1),
		.osd_twgs_snd(1'b1),
		.accel_twgs_gfx(),
		.accel_twgs_snd(),
		.nv_addr(9'd0),
		.nv_wr(1'b0),
		.nv_din(8'd0),
		.nv_dout(),
		.mem_stall(mem_stall),
		.dbg_hdd_dma(),
		.FLOPPY_WP(1'b1),
		.joystick_0(joystick_0),
		.joystick_1(32'd0),
		.joystick_l_analog_0(joystick_l_analog_0),
		.joystick_l_analog_1(16'd0),
		.paddle_0(8'd0),
		.paddle_1(8'd0),
		.paddle_2(8'd0),
		.paddle_3(8'd0),
		.UART_TXD(),
		.UART_RXD(1'b1),
		.UART_RTS(),
		.UART_CTS(1'b0),
		.serial_port_printer(1'b0),
		.serial_loopback(1'b0),
		.keyboard_reset(keyboard_reset),
		.keyboard_cold_reset(keyboard_cold_reset),
		.capslock(),
		.cache_disable(cache_disable)
	);
	/* verilator lint_on PINMISSING */

	// =====================================================================
	// CPU <-> SDRAM (Apple-IIgs.sv, verbatim apart from the comments; see
	// there for the hardware history behind each rule)
	// =====================================================================

	// CPU byte address into the 16MB SDRAM map (fast RAM low, ROM at top)
	wire [23:0] cpu_sdram_addr =
	                    (rom_ce & ~we & ~rom_select)  ? {6'b111111, rom_bankaddr, addr_bus[15:0]} :
	                    (rom_ce & ~we &  rom_select)  ? {7'b1111100, rom_bankaddr[0], addr_bus[15:0]} :
	                    {1'b0, addr_bus[22:0]};

	// ch0: the closing cycle's write, committed at the phi2 edge
	reg         wr_req = 0;
	wire        wr_ack;
	reg  [24:1] wr_addr;
	reg         wr_wrl, wr_wrh;
	reg  [15:0] wr_din;

	// Speed-selected CPU read path: ch3 single-word reads at native speed,
	// ch1 burst + line cache + stall-on-miss when accelerated.
	reg         accel_r = 0;

	wire        rd_req;
	wire        rd_ack;
	wire [24:1] rd_addr;
	wire [127:0] rd_line;
	wire        cache_rd;
	wire [24:1] cache_addr  = {1'b0, cpu_sdram_addr[23:1]};
	wire [15:0] cache_data;
	wire        cache_hit_now;
	wire [15:0] cache_data_now;
	wire        cache_ready, cache_stall;

	reg         wr_ack_s1, wr_ack_s2;
	wire        wr_pending = (wr_req != wr_ack_s2);
	reg         snoop_stb;

	reg         nat_req = 0;
	wire        nat_ack;
	reg  [24:1] nat_addr;
	reg         nat_bsel;
	wire [15:0] nat_dout;
	reg  [7:0]  nat_data;

	reg  [1:0]  accel_switch_guard = 0;
	wire        use_cache_path = accel_r | (accel_switch_guard != 2'd0);

	assign mem_stall = use_cache_path & ( (~we & (fastram_ce | rom_ce) & ~cache_hit_now)
	                                    | ( we & fastram_ce & wr_pending) );

	assign sdram_dout = use_cache_path ? (cpu_sdram_addr[0] ? cache_data_now[15:8] : cache_data_now[7:0])
	                                   : nat_data;

	reg phi2_d;
	assign cache_rd = phi2_d & ~we & (fastram_ce | rom_ce) & use_cache_path;

	always @(posedge clk_sys) begin
		phi2_d <= phi2;
		if (phi2) begin
			accel_r <= accel_active;
			if (accel_r != accel_active)          accel_switch_guard <= 2'd2;
			else if (accel_switch_guard != 2'd0)  accel_switch_guard <= accel_switch_guard - 2'd1;
		end
		wr_ack_s1 <= wr_ack;
		wr_ack_s2 <= wr_ack_s1;

		if (phi2_d & ~we & (fastram_ce | rom_ce) & ~accel_r) begin
			nat_addr <= {1'b0, cpu_sdram_addr[23:1]};
			nat_bsel <= cpu_sdram_addr[0];
			nat_req  <= ~nat_req;
		end
		nat_data <= nat_bsel ? nat_dout[15:8] : nat_dout[7:0];

		if (phi2 & we & fastram_ce & ~(accel_r & wr_pending)) begin
			wr_addr <= {2'b00, addr_bus[22:1]};
			wr_din  <= {iigs_dout, iigs_dout};
			wr_wrl  <= ~addr_bus[0];
			wr_wrh  <=  addr_bus[0];
			wr_req  <= ~wr_req;
		end

		snoop_stb <= phi2 & we & fastram_ce & ~(accel_r & wr_pending);
	end

	// ---------------------------------------------------------------------
	// ch2: the platform port. Level request in, toggle request out; ch2
	// writes both bytes, a request with pm_we = 0 is a single-word read.
	// clk_mem is 8 x clk_sys from the same MMCM, so ack2/dout2 are sampled
	// directly, as Apple-IIgs.sv does with up_ack.
	// ---------------------------------------------------------------------
	reg         up_req = 0;
	wire        up_ack;
	reg  [24:1] up_addr;
	reg         up_wr;
	reg  [15:0] up_din;
	wire [15:0] up_dout;
	reg         up_busy = 1'b0;

	always @(posedge clk_sys) begin
		if (~pll_locked) begin
			up_busy <= 1'b0;
			pm_ack  <= 1'b0;
		end else if (up_busy) begin
			if (up_req == up_ack) begin
				up_busy <= 1'b0;
				pm_ack  <= 1'b1;
				pm_dout <= up_dout;
			end
		end else if (pm_ack) begin
			if (!pm_req) pm_ack <= 1'b0;
		end else if (pm_req) begin
			up_addr <= pm_addr;
			up_wr   <= pm_we;
			up_din  <= pm_din;
			up_req  <= ~up_req;
			up_busy <= 1'b1;
		end
	end

	wire sdram_dqml, sdram_dqmh;
	assign sdram_dqm = {sdram_dqmh, sdram_dqml};

	sdram_burst sdram
	(
		.SDRAM_DQ_OUT(sdram_dq_out), .SDRAM_DQ_IN(sdram_dq_in), .SDRAM_DQ_OE(sdram_dq_oe),
		.SDRAM_A(sdram_a), .SDRAM_DQML(sdram_dqml), .SDRAM_DQMH(sdram_dqmh),
		.SDRAM_BA(sdram_ba), .SDRAM_nCS(sdram_cs_n), .SDRAM_nWE(sdram_we_n),
		.SDRAM_nRAS(sdram_ras_n), .SDRAM_nCAS(sdram_cas_n), .SDRAM_CLK(sdram_clk), .SDRAM_CKE(),
		.init(~pll_locked), .clk(clk_mem),
		.addr0(wr_addr), .wrl0(wr_wrl), .wrh0(wr_wrh), .din0(wr_din), .dout0(), .req0(wr_req), .ack0(wr_ack),
		.addr1(rd_addr), .wrl1(1'b0), .wrh1(1'b0), .din1(16'd0), .dout1(rd_line), .req1(rd_req), .ack1(rd_ack),
		.addr2(up_addr), .wrl2(up_wr), .wrh2(up_wr), .din2(up_din), .dout2(up_dout), .req2(up_req), .ack2(up_ack),
		.addr3(nat_addr), .dout3(nat_dout), .req3(nat_req), .ack3(nat_ack)
	);

	sdram_cache #(.LINES(8), .LINE_WORDS(8), .ADDR_W(24)) icache
	(
		.clk(clk_sys), .reset(reset), .cache_off(cache_disable),
		.cpu_addr(cache_addr), .cpu_rd(cache_rd), .cpu_data(cache_data),
		.cpu_ready(cache_ready), .cpu_stall(cache_stall),
		.hit_now(cache_hit_now), .cpu_data_now(cache_data_now),
		.wr_addr(wr_addr), .wr_data(wr_din), .wr_be({wr_wrh, wr_wrl}), .wr_stb(snoop_stb),
		.mem_addr(rd_addr), .mem_req(rd_req), .mem_ack(rd_ack), .mem_line(rd_line)
	);

	// =====================================================================
	// 3.5" drive 1 (Apple-IIgs.sv woz_ctrl)
	// =====================================================================
	wire        woz_ctrl_ready;
	wire        woz_ctrl_disk_mounted;
	wire        woz_ctrl_busy;
	wire [31:0] woz_ctrl_bit_count;
	wire [7:0]  woz_ctrl_bit_data;
	wire        woz_ctrl_track_load_complete;
	wire [31:0] woz_ctrl_flux_total_ticks;

	// An image arriving while one is mounted is an eject + insert: unmount
	// for a cycle, then mount again. A software eject unmounts.
	reg         img_mounted_d = 1'b0;
	reg         woz_ctrl_mount = 1'b0;
	reg         woz_ctrl_remount_pending = 1'b0;
	reg         woz3_stable_side_reg;

	always @(posedge clk_sys) begin
		img_mounted_d <= img_mounted;
		if (drive35_eject_req) begin
			woz_ctrl_mount <= 1'b0;
			woz_ctrl_remount_pending <= 1'b0;
		end else if (~img_mounted_d & img_mounted) begin
			if (woz_ctrl_mount) begin
				woz_ctrl_mount <= 1'b0;
				woz_ctrl_remount_pending <= (img_size != 0);
			end else begin
				woz_ctrl_mount <= (img_size != 0);
			end
		end else if (woz_ctrl_remount_pending) begin
			woz_ctrl_mount <= 1'b1;
			woz_ctrl_remount_pending <= 1'b0;
		end
		woz3_stable_side_reg <= WOZ_TRACK3_STABLE_SIDE;
	end

	assign WOZ_TRACK3_BIT_DATA         = woz_ctrl_bit_data;
	assign WOZ_TRACK3_BIT_COUNT        = woz_ctrl_bit_count;
	assign WOZ_TRACK3_LOAD_COMPLETE    = woz_ctrl_track_load_complete;
	assign WOZ_TRACK3_FLUX_TOTAL_TICKS = woz_ctrl_flux_total_ticks;
	assign WOZ_TRACK3_READY            = woz_ctrl_ready;

	assign DISK_READY = {1'b0, woz_ctrl_disk_mounted, 1'b0, 1'b0};

	woz_floppy_controller #(
		.IS_35_INCH(1)
	) woz_ctrl (
		.clk(clk_sys),
		.reset(reset),
		.sd_lba(sd_lba),
		.sd_rd(sd_rd),
		.sd_wr(sd_wr),
		.sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr),
		.img_mounted(woz_ctrl_mount),
		.img_readonly(img_readonly),
		.img_size(img_size),
		.track_id(WOZ_TRACK3),
		.ready(woz_ctrl_ready),
		.disk_mounted(woz_ctrl_disk_mounted),
		.busy(woz_ctrl_busy),
		.active(floppy35_motor_on),
		.bit_count(woz_ctrl_bit_count),
		.bit_addr(WOZ_TRACK3_BIT_ADDR),
		.stable_side(woz3_stable_side_reg),
		.bit_data(woz_ctrl_bit_data),
		.bit_data_in(WOZ_TRACK3_BIT_DATA_IN),
		.bit_we(WOZ_TRACK3_BIT_WE),
		.bit_wr_addr(WOZ_TRACK3_BIT_WR_ADDR),
		.track_load_complete(woz_ctrl_track_load_complete),
		.is_flux_track(WOZ_TRACK3_IS_FLUX),
		.flux_data_size(WOZ_TRACK3_FLUX_SIZE),
		.flux_total_ticks(woz_ctrl_flux_total_ticks),
		.track_data_valid(WOZ_TRACK3_DATA_VALID),
		.disk_type_mismatch(),
		.disk_write_protected(WOZ_TRACK3_WP),
		.optimal_bit_timing(),
		.dbg_load_sum(),
		.dbg_load_bytes(),
		.dbg_load_blocks()
	);

	assign dbg_addr  = addr_bus;
	assign dbg_reset = reset;
	assign dbg_disk  = {floppy35_motor_on, woz_ctrl_busy, woz_ctrl_ready, woz_ctrl_disk_mounted};

endmodule

`default_nettype wire
