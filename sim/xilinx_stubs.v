// ============================================================================
// Minimal behavioural stand-ins for the Xilinx primitives the core uses, so
// that lint and simulation can run without Vivado. Never part of the FPGA build
// (sim/ is outside rtl/, which is all the framework build picks up).
// ============================================================================
`timescale 1ps/1ps

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
