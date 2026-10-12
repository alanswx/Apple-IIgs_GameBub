// ============================================================================
// gb_clocks.sv: every clock the core uses, from one MMCM.
//
//   50 MHz x 20.625 = 1031.25 MHz VCO (Artix-7 -1 range: 600..1200 MHz)
//     /72   14.323 MHz  clk_sys      CLK_14M: the machine and the framework
//                                    (MiSTer: 14.318; 0.03% fast)
//     /36   28.646 MHz  clk_vid      CLK_28M / VGC pixel pipeline (ce_pix /2)
//     /9   114.58  MHz  clk_mem      sdram_burst (MiSTer: 114.545)
//     /6   171.88  MHz  clk_spi      framework MCU SPI sampler (>= 160 MHz)
//     /36   28.646 MHz  clk_display  LCD dot clock (must stay below ~29.7 MHz,
//                                    see chisel/src/AppleIIgs.scala)
//
// All outputs come from one MMCM through BUFGs, so clk_vid and clk_mem are
// exact multiples of clk_sys with aligned rising edges, as on MiSTer, and
// Vivado times the paths between them (no CDC). The frequencies are mirrored
// in chisel/src/AppleIIgs.scala; keep them in sync.
// ============================================================================
`default_nettype none

module gb_clocks (
	input  wire clk_in_50mhz,
	output wire clk_sys,
	output wire clk_vid,
	output wire clk_mem,
	output wire clk_spi,
	output wire clk_display,
	output wire locked
);

	wire clk_fb;
	wire clk_sys_u, clk_vid_u, clk_mem_u, clk_spi_u;
	// Vivado names the MMCM output clock after this net, and the framework's
	// common.xdc declares a clock called "clk_dpi" physically exclusive with
	// its HDMI clock (both feed one BUFGMUX). Any other name leaves the two
	// timed against each other (MacLC_GameBub, FRAMEWORK_ISSUES #4).
	wire clk_dpi;

	MMCME2_BASE #(
		.BANDWIDTH          ("OPTIMIZED"),
		.CLKIN1_PERIOD      (20.000),
		.CLKFBOUT_MULT_F    (20.625),
		.DIVCLK_DIVIDE      (1),
		.CLKOUT0_DIVIDE_F   (72.000),
		.CLKOUT1_DIVIDE     (36),
		.CLKOUT2_DIVIDE     (9),
		.CLKOUT3_DIVIDE     (6),
		.CLKOUT4_DIVIDE     (36),
		.CLKOUT0_PHASE      (0.0),
		.CLKOUT1_PHASE      (0.0),
		.CLKOUT2_PHASE      (0.0),
		.CLKOUT3_PHASE      (0.0),
		.CLKOUT4_PHASE      (0.0),
		.CLKOUT0_DUTY_CYCLE (0.5),
		.CLKOUT1_DUTY_CYCLE (0.5),
		.CLKOUT2_DUTY_CYCLE (0.5),
		.CLKOUT3_DUTY_CYCLE (0.5),
		.CLKOUT4_DUTY_CYCLE (0.5),
		.STARTUP_WAIT       ("FALSE")
	) mmcm (
		.CLKIN1   (clk_in_50mhz),
		.CLKFBIN  (clk_fb),
		.CLKFBOUT (clk_fb),
		.CLKFBOUTB(),
		.CLKOUT0  (clk_sys_u),
		.CLKOUT0B (),
		.CLKOUT1  (clk_vid_u),
		.CLKOUT1B (),
		.CLKOUT2  (clk_mem_u),
		.CLKOUT2B (),
		.CLKOUT3  (clk_spi_u),
		.CLKOUT3B (),
		.CLKOUT4  (clk_dpi),
		.CLKOUT5  (),
		.CLKOUT6  (),
		.LOCKED   (locked),
		.PWRDWN   (1'b0),
		.RST      (1'b0)
	);

	BUFG bufg_sys     (.I(clk_sys_u), .O(clk_sys));
	BUFG bufg_vid     (.I(clk_vid_u), .O(clk_vid));
	BUFG bufg_mem     (.I(clk_mem_u), .O(clk_mem));
	BUFG bufg_spi     (.I(clk_spi_u), .O(clk_spi));
	BUFG bufg_display (.I(clk_dpi),   .O(clk_display));

endmodule

`default_nettype wire
