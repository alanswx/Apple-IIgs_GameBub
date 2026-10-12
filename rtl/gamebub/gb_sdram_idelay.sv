// ============================================================================
// gb_sdram_idelay.sv: a fixed input delay on each SDRAM data pin.
//
// sdram_burst captures a read beat 1.5 clk_mem periods after the chip edge
// that launched it (rtl/gamebub/iigs.xdc). On this board that left the setup
// side 1.9 ns of slack and the hold side -0.7 ns: the next beat could reach
// the capture register before the edge that takes the current one. An
// IDELAYE2 in each pin's input path moves the data later so the window is
// centred; Vivado times the path with IDELAY_VALUE, so TAPS is set from the
// routed design's setup and hold slack (about 76 ps per tap here).
//
// The IDELAYE2s sit directly on the framework's IBUF outputs (sdram_dataIn),
// and the controller's dq_in register stays in the I/O block after them.
// ============================================================================
`default_nettype none

module gb_sdram_idelay #(
	parameter integer TAPS = 16,             // 0..31
	parameter real    REF_MHZ = 206.25       // IDELAYCTRL reference (190..210)
)(
	input  wire        clk_ref,
	input  wire        ref_locked,           // the reference clock's MMCM lock
	input  wire [15:0] pin_in,               // framework sdram_dataIn
	output wire [15:0] data_out,             // to sdram_burst's dq_in
	output wire        ready                 // IDELAYCTRL calibrated
);

	// IDELAYCTRL needs its reset held for > 52 ns once the reference runs.
	reg [3:0] rst_cnt = 4'd0;
	always @(posedge clk_ref or negedge ref_locked)
		if (!ref_locked)            rst_cnt <= 4'd0;
		else if (rst_cnt != 4'hF)   rst_cnt <= rst_cnt + 4'd1;
	wire ctrl_rst = (rst_cnt != 4'hF);

	(* IODELAY_GROUP = "gb_sdram" *)
	IDELAYCTRL ctrl (
		.REFCLK (clk_ref),
		.RST    (ctrl_rst),
		.RDY    (ready)
	);

	genvar i;
	generate
		for (i = 0; i < 16; i = i + 1) begin : dq
			(* IODELAY_GROUP = "gb_sdram" *)
			IDELAYE2 #(
				.CINVCTRL_SEL          ("FALSE"),
				.DELAY_SRC             ("IDATAIN"),
				.HIGH_PERFORMANCE_MODE ("TRUE"),
				.IDELAY_TYPE           ("FIXED"),
				.IDELAY_VALUE          (TAPS),
				.PIPE_SEL              ("FALSE"),
				.REFCLK_FREQUENCY      (REF_MHZ),
				.SIGNAL_PATTERN        ("DATA")
			) dly (
				.C           (1'b0),
				.CE          (1'b0),
				.CINVCTRL    (1'b0),
				.CNTVALUEIN  (5'd0),
				.CNTVALUEOUT (),
				.DATAIN      (1'b0),
				.DATAOUT     (data_out[i]),
				.IDATAIN     (pin_in[i]),
				.INC         (1'b0),
				.LD          (1'b0),
				.LDPIPEEN    (1'b0),
				.REGRST      (1'b0)
			);
		end
	endgenerate

endmodule

`default_nettype wire
