// ============================================================================
// iigs_stubs.sv: empty stand-ins for cards rtl/iigs/iigs.sv always instantiates
// but the Game Bub port leaves out (docs/PORT_PLAN.md, section 4).
//
//   hdd        slot-7 ProDOS hard disk. With no card, slot 7 reads $00, so the
//              ROM's slot scan finds no signature there and moves on.
//   twgs_card  TransWarp GS, absent (iigs.sv's twgs_present = 0). sel is 0,
//              as twgs_card drives it with enable = 0; iigs.sv reads the
//              speed/config outputs only when twgs_present is 1, and the NVRAM
//              and gfx/snd outputs only feed MiSTer's OSD and SD backup.
// ============================================================================
module hdd (
	input  wire        CLK_14M,
	input  wire        phi0,
	input  wire        IO_SELECT,
	input  wire        DEVICE_SELECT,
	input  wire        RESET,
	input  wire [15:0] A,
	input  wire        RD,
	input  wire [7:0]  D_IN,
	output wire [7:0]  D_OUT,
	output wire        DMA,
	output wire [15:0] DMA_ADDR,
	output wire        DMA_WE,
	output wire [15:0] sector,
	output wire [1:0]  sd_rd,
	output wire [1:0]  sd_wr,
	input  wire [1:0]  img_mounted,
	input  wire        img_readonly,
	input  wire [63:0] img_size,
	input  wire [8:0]  hps_ram_addr,
	input  wire [7:0]  ram_di,
	output wire [7:0]  ram_do,
	input  wire        ram_we,
	input  wire [1:0]  sd_ack
);
	assign D_OUT    = 8'h00;
	assign DMA      = 1'b0;
	assign DMA_ADDR = 16'h0000;
	assign DMA_WE   = 1'b0;
	assign sector   = 16'h0000;
	assign sd_rd    = 2'b00;
	assign sd_wr    = 2'b00;
	assign ram_do   = 8'h00;
endmodule

module twgs_card (
	input  wire        clk,
	input  wire        reset,
	input  wire        enable,
	input  wire [7:0]  bank,
	input  wire [15:0] addr,
	input  wire        we,
	input  wire        phi2,
	input  wire        vda,
	input  wire        vpa,
	input  wire [7:0]  wr_data,
	input  wire        cyareg7,
	input  wire [2:0]  turbo_code,
	input  wire        host_irq_en,
	input  wire        host_gfx_en,
	input  wire        host_snd_en,
	output wire        gfx_en,
	output wire        snd_en,
	input  wire        boot_armed,
	input  wire        nmi_armed,
	output wire        sel,
	output wire [7:0]  dout,
	output wire        accel_en,
	output wire [2:0]  speed_code,
	output wire [2:0]  cfg_speed_code,
	output wire        cache_enable,
	output wire        irq_logic_en,
	input  wire [4:0]  bk_addr,
	input  wire        bk_wr,
	input  wire [7:0]  bk_data,
	output wire [7:0]  bk_q
);
	assign gfx_en         = 1'b0;
	assign snd_en         = 1'b0;
	assign sel            = 1'b0;
	assign dout           = 8'h00;
	assign accel_en       = 1'b0;
	assign speed_code     = 3'd0;
	assign cfg_speed_code = 3'd0;
	assign cache_enable   = 1'b0;
	assign irq_logic_en   = 1'b0;
	assign bk_q           = 8'hFF;
endmodule
