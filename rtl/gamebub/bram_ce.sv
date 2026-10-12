// ============================================================================
// bram_ce.sv: true dual-port block RAM with a clock enable per port.
//
// Stands in for upstream rtl/dpram_bram.vhd (Altera altsyncram, BIDIR_DUAL_PORT,
// unregistered outputs, NEW_DATA read-during-write), which the slow RAM uses.
// rtl/iigs/bram.sv has no clock enables; the slow RAM needs them: port A
// follows the CPU's slowram_ce and port B (video) reads only on ce_pix.
//
// Memories deeper than 32K words are built as explicit 32K-deep banks (one
// RAMB36 per data bit, 32K x 1) with a registered output select. Left to
// itself Vivado 2025.2 cascades RAMB36 pairs for the 128K slow RAM and then
// fails DRC REQP-1962 (cascade ADDR15 pins tied differently) at placement.
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
	output wire [width_a-1:0]   q_a,

	input  wire                 clock_b,
	input  wire                 enable_b,
	input  wire                 wren_b,
	input  wire [widthad_a-1:0] address_b,
	input  wire [width_a-1:0]   data_b,
	output wire [width_a-1:0]   q_b
);
	localparam integer BANK_AW = (widthad_a > 15) ? 15 : widthad_a;
	localparam integer SEL_W   = (widthad_a > 15) ? widthad_a - 15 : 1;
	localparam integer NBANKS  = 1 << (widthad_a - BANK_AW);

	wire [width_a-1:0] bq_a [0:NBANKS-1];
	wire [width_a-1:0] bq_b [0:NBANKS-1];
	reg  [SEL_W-1:0]   sel_a = '0, sel_b = '0;

	genvar g;
	generate
		for (g = 0; g < NBANKS; g = g + 1) begin : bank
			wire hit_a = (NBANKS == 1) || ((address_a >> BANK_AW) == g);
			wire hit_b = (NBANKS == 1) || ((address_b >> BANK_AW) == g);

			reg [width_a-1:0] mem [0:(2**BANK_AW)-1];
			reg [width_a-1:0] qa, qb;

			always @(posedge clock_a)
				if (enable_a) begin
					if (wren_a && hit_a) begin
						mem[address_a[BANK_AW-1:0]] <= data_a;
						qa <= data_a;
					end else
						qa <= mem[address_a[BANK_AW-1:0]];
				end

			always @(posedge clock_b)
				if (enable_b) begin
					if (wren_b && hit_b) begin
						mem[address_b[BANK_AW-1:0]] <= data_b;
						qb <= data_b;
					end else
						qb <= mem[address_b[BANK_AW-1:0]];
				end

			assign bq_a[g] = qa;
			assign bq_b[g] = qb;
		end
	endgenerate

	// The output select follows the address the data was read at, so q holds
	// its value while the port is disabled, as one RAM would.
	if (NBANKS > 1) begin : g_sel
		always @(posedge clock_a) if (enable_a) sel_a <= SEL_W'(address_a >> BANK_AW);
		always @(posedge clock_b) if (enable_b) sel_b <= SEL_W'(address_b >> BANK_AW);
	end
	assign q_a = bq_a[(NBANKS > 1) ? sel_a : 0];
	assign q_b = bq_b[(NBANKS > 1) ? sel_b : 0];
endmodule
