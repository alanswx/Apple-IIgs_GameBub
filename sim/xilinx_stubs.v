// ============================================================================
// Minimal behavioural stand-ins for the Xilinx primitives the core uses, so
// that lint and simulation can run without Vivado. Never part of the FPGA build
// (sim/ is outside rtl/, which is all the framework build picks up).
// The MMCM model needs --timing; it produces the clocks of gb_clocks.sv with
// aligned rising edges: clk_sys 14.32, clk_vid 28.65, clk_mem 114.6 MHz
// (periods rounded to 8 ps steps so the ratios stay exactly 1:2:8).
// ============================================================================
`timescale 1ps/1ps

module MMCME2_BASE #(
	parameter BANDWIDTH = "OPTIMIZED",
	parameter real CLKIN1_PERIOD = 20.0,
	parameter real CLKFBOUT_MULT_F = 20.625,
	parameter integer DIVCLK_DIVIDE = 1,
	parameter real CLKOUT0_DIVIDE_F = 72.0,
	parameter integer CLKOUT1_DIVIDE = 36,
	parameter integer CLKOUT2_DIVIDE = 9,
	parameter integer CLKOUT3_DIVIDE = 6,
	parameter integer CLKOUT4_DIVIDE = 36,
	parameter integer CLKOUT5_DIVIDE = 5,
	parameter integer CLKOUT6_DIVIDE = 1,
	parameter real CLKOUT0_PHASE = 0.0, parameter real CLKOUT1_PHASE = 0.0,
	parameter real CLKOUT2_PHASE = 0.0, parameter real CLKOUT3_PHASE = 0.0,
	parameter real CLKOUT4_PHASE = 0.0, parameter real CLKFBOUT_PHASE = 0.0,
	parameter real CLKOUT0_DUTY_CYCLE = 0.5, parameter real CLKOUT1_DUTY_CYCLE = 0.5,
	parameter real CLKOUT2_DUTY_CYCLE = 0.5, parameter real CLKOUT3_DUTY_CYCLE = 0.5,
	parameter real CLKOUT4_DUTY_CYCLE = 0.5,
	parameter STARTUP_WAIT = "FALSE"
)(
	input  CLKIN1, CLKFBIN, PWRDWN, RST,
	output CLKFBOUT, CLKFBOUTB,
	output reg CLKOUT0 = 0, output CLKOUT0B,
	output reg CLKOUT1 = 0, output CLKOUT1B,
	output reg CLKOUT2 = 0, output CLKOUT2B,
	output CLKOUT3, CLKOUT3B,
	output CLKOUT4, CLKOUT5, CLKOUT6,
	output reg LOCKED = 0
);
	assign CLKFBOUT = 1'b0; assign CLKFBOUTB = 1'b1;
	assign CLKOUT0B = ~CLKOUT0; assign CLKOUT1B = ~CLKOUT1;
	assign CLKOUT2B = ~CLKOUT2;
	// SPI and LCD clocks only feed the framework, which is not simulated.
	assign CLKOUT3 = 1'b0; assign CLKOUT3B = 1'b1;
	// The IDELAYCTRL reference clock only matters in hardware.
	assign CLKOUT4 = 1'b0; assign CLKOUT5 = 1'b0; assign CLKOUT6 = 1'b0;
	initial begin
		#100000 LOCKED = 1;
	end
	// 69.824 / 34.912 / 8.728 ns: true 69.817 / 34.908 / 8.727 ns, kept 1:2:8
	always #34912 CLKOUT0 = ~CLKOUT0;
	always #17456 CLKOUT1 = ~CLKOUT1;
	always #4364  CLKOUT2 = ~CLKOUT2;
endmodule

module BUFG (input I, output O);
	assign O = I;
endmodule

module ODDR #(
	parameter DDR_CLK_EDGE = "SAME_EDGE",
	parameter INIT = 1'b0,
	parameter SRTYPE = "SYNC"
)(
	input C, CE, D1, D2, R, S,
	output Q
);
	// Clock-forwarding use only (D1/D2 constant): Q = C or ~C.
	assign Q = C ? D1 : D2;
endmodule

// SDRAM read delays (gb_sdram_idelay.sv): no delay in simulation; the
// testbench's SDRAM model sets the read data timing directly.
module IDELAYCTRL (input REFCLK, input RST, output RDY);
	assign RDY = !RST;
endmodule

module IDELAYE2 #(
	parameter CINVCTRL_SEL = "FALSE",
	parameter DELAY_SRC = "IDATAIN",
	parameter HIGH_PERFORMANCE_MODE = "TRUE",
	parameter IDELAY_TYPE = "FIXED",
	parameter integer IDELAY_VALUE = 0,
	parameter PIPE_SEL = "FALSE",
	parameter real REFCLK_FREQUENCY = 200.0,
	parameter SIGNAL_PATTERN = "DATA"
)(
	input C, CE, CINVCTRL, DATAIN, IDATAIN, INC, LD, LDPIPEEN, REGRST,
	input [4:0] CNTVALUEIN,
	output [4:0] CNTVALUEOUT,
	output DATAOUT
);
	assign DATAOUT = IDATAIN;
	assign CNTVALUEOUT = IDELAY_VALUE;
endmodule
