// ============================================================================
// bram_ce.sv: true dual-port block RAM with a clock enable per port.
//
// Stands in for upstream rtl/dpram_bram.vhd (Altera altsyncram, BIDIR_DUAL_PORT,
// unregistered outputs, NEW_DATA read-during-write), which the slow RAM uses.
// rtl/iigs/bram.sv has no clock enables; the slow RAM needs them: port A
// follows the CPU's slowram_ce and port B (video) reads only on ce_pix.
// ============================================================================
module bram_ce #(
	parameter width_a   = 8,
	parameter widthad_a = 10
) (
	input  wire                 clock_a,
	input  wire                 enable_a,
	input  wire                 wren_a,
	input  wire [widthad_a-1:0] address_a,
	input  wire [width_a-1:0]   data_a,
	output reg  [width_a-1:0]   q_a,

	input  wire                 clock_b,
	input  wire                 enable_b,
	input  wire                 wren_b,
	input  wire [widthad_a-1:0] address_b,
	input  wire [width_a-1:0]   data_b,
	output reg  [width_a-1:0]   q_b
);
	reg [width_a-1:0] mem [0:(2**widthad_a)-1];

	always @(posedge clock_a)
		if (enable_a) begin
			if (wren_a) begin
				mem[address_a] <= data_a;
				q_a <= data_a;
			end else
				q_a <= mem[address_a];
		end

	always @(posedge clock_b)
		if (enable_b) begin
			if (wren_b) begin
				mem[address_b] <= data_b;
				q_b <= data_b;
			end else
				q_b <= mem[address_b];
		end
endmodule
