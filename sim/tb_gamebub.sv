// ============================================================================
// tb_gamebub.sv: boot the whole Game Bub IIgs core in Verilator, with a model
// of the Game Bub MCU on the host interface. After MacLC_GameBub's testbench.
//
//   sim/run_tb.sh [plusargs]           (builds, then runs; see that script)
//
// What it models:
//   * the framework's HostV0 memory bus as framework/.../SpiReceiverFifo.scala
//     drives it, and the command handshake;
//   * the MCU's core-load sequence (docs.gamebub.net): FileWriteStart /
//     words / FileWriteEnd per file, SetupComplete, CoreRun;
//   * a W9825G6KH SDRAM at CAS latency 3 with burst-8 reads, clocked by the
//     core's own sdram_clock (clk_mem inverted), with adjustable read data
//     timing (parameters TAC_PS / TOH_PS, see the "SDRAM" section below);
//   * the framework's frame capture: pixels on video_dataEnable, rows on
//     video_hblank, frames on video_vblank -> <out>/frame_NNNN.ppm.
//
// Plusargs:
//   +rom3=<file>    ROM 3 image, 256 KiB (default scratch/roms/boot.rom)
//   +rom01=<file>   ROM 01 image, 128 KiB (optional; loaded when given)
//   +no_rom3        do not load ROM 3 (ROM 01 only)
//   +disk=<file>    disk 1 (WOZ)          +disk2=<file>  disk 2 (WOZ)
//   +gamedb=<file>  game database (tools/mkgamedb.py; file 4)
//   +speed=<n>      CPU speed setting 0..4, 15 = auto (the default)
//   +kbd_mode       start the pad in keyboard mode (default: auto)
//   +mouse=<hex>    d-pad pointer steps setting {fast, slow}, 0 = auto
//   +trace_mouse    print each pointer report the pad sends
//   +volume=<n>     Music Volume setting: DOC x(1 << n), 2..5 (default 4)
//   +disk_light=<n> Disk Light setting: 1 on (default), 0 off
//   +frames=<n>     stop after n frames (default 300)
//   +dump=<k>       write every k-th frame (default 25)
//   +raw            also dump the VGC's raw output (whole line, border included)
//   +out=<dir>      where frames go (default sim_out; created by run_tb.sh)
//   +paced          stream files at the real MCU's fixed SPI rate through a
//                   model of the framework's FIFOs (see "Paced host model")
//   +press=<f>:<b>  hold button b (a b x y l r up down left right start
//                   select) from frame f for 6 frames (+press=<f>:<b>:<n>
//                   for n frames); repeatable up to 8x as +press=...,
//                   +press2=..., ... +press8=...
//   +stop_after_load   end after the files are loaded
//   +io_stats       count reads of the input registers (keyboard, mouse,
//                   buttons, paddles) per 100 frames
// ============================================================================
`timescale 1ps/1ps
`default_nettype none

module tb_gamebub #(
	parameter integer TAC_PS = 9000,     // see "SDRAM" below; run_tb.sh TAC_PS=...
	parameter integer TOH_PS = 7000
);

	// -------------------------------------------------------------------
	// DUT
	// -------------------------------------------------------------------
	reg  clk50 = 1'b0;
	always #10000 clk50 = ~clk50;

	wire clk_sys, locked;
	reg  fw_reset = 1'b1;           // framework reset (pll_reset_generator)

	reg         h_en = 1'b0, h_wr = 1'b0;
	reg  [31:0] h_addr = 32'd0, h_wdata = 32'd0;
	wire [31:0] h_rdata;
	wire        h_done;
	reg         c_req = 1'b0;
	wire        c_busy, c_done, c_error;

	wire [2:0]  v_r, v_g, v_b;
	wire        v_de, v_vblank, v_hblank;
	wire [15:0] a_left, a_right;

	wire        sd_clk, sd_cke, sd_cs, sd_ras, sd_cas, sd_we, sd_dir;
	wire [1:0]  sd_dqm, sd_ba;
	wire [12:0] sd_a;
	wire [15:0] sd_dout;
	reg  [15:0] sd_din = 16'd0;

	wire [3:0]  pmod_out, pmod_dir;

	// buttons: {start, select, r, l, y, x, b, a, right, left, down, up}
	reg  [11:0] btn = 12'd0;

	iigs_gamebub dut (
		.clock                    (clk_sys),
		.reset                    (fw_reset),
		.clocks_clockIn50M        (clk50),
		.clocks_clockOutSystem    (clk_sys),
		.clocks_clockOutDisplay   (),
		.clocks_clockOutSpi       (),
		.clocks_locked            (locked),
		.video_data_r             (v_r),
		.video_data_g             (v_g),
		.video_data_b             (v_b),
		.video_dataEnable         (v_de),
		.video_vblank             (v_vblank),
		.video_hblank             (v_hblank),
		.audio_left               (a_left),
		.audio_right              (a_right),
		.host_mem_enable          (h_en),
		.host_mem_write           (h_wr),
		.host_mem_done            (h_done),
		.host_mem_address         (h_addr),
		.host_mem_dataRead        (h_rdata),
		.host_mem_dataWrite       (h_wdata),
		.host_commandHost_request (c_req),
		.host_commandHost_busy    (c_busy),
		.host_commandHost_done    (c_done),
		.host_commandHost_error   (c_error),
		.host_commandCore_request (),
		.host_commandCore_busy    (1'b0),
		.host_commandCore_done    (1'b0),
		.host_commandCore_error   (1'b0),
		.input_buttons_up         (btn[0]),
		.input_buttons_down       (btn[1]),
		.input_buttons_left       (btn[2]),
		.input_buttons_right      (btn[3]),
		.input_buttons_a          (btn[4]),
		.input_buttons_b          (btn[5]),
		.input_buttons_x          (btn[6]),
		.input_buttons_y          (btn[7]),
		.input_buttons_l          (btn[8]),
		.input_buttons_r          (btn[9]),
		.input_buttons_select     (btn[10]),
		.input_buttons_start      (btn[11]),
		.sdram_clock              (sd_clk),
		.sdram_cke                (sd_cke),
		.sdram_cs                 (sd_cs),
		.sdram_ras                (sd_ras),
		.sdram_cas                (sd_cas),
		.sdram_we                 (sd_we),
		.sdram_dqm                (sd_dqm),
		.sdram_bank               (sd_ba),
		.sdram_address            (sd_a),
		.sdram_dataIn             (sd_din),
		.sdram_dataOut            (sd_dout),
		.sdram_dataDir            (sd_dir),
		.pmod_in                  (4'b0000),
		.pmod_out                 (pmod_out),
		.pmod_dir                 (pmod_dir)
	);

	// Framework reset: held until the core's MMCM locks, released in clk_sys.
	reg [3:0] lock_cnt = 4'd0;
	always @(posedge clk_sys) begin
		if (!locked) lock_cnt <= 4'd0;
		else if (lock_cnt != 4'hF) lock_cnt <= lock_cnt + 4'd1;
		fw_reset <= (lock_cnt != 4'hF);
	end

	// -------------------------------------------------------------------
	// SDRAM: W9825G6KH, 4 banks x 8192 rows x 512 columns x 16 bits,
	// CAS latency 3, burst length from LOAD MODE (8 for reads, single writes).
	// The array is indexed by sdram_burst's word address {bank, row, col}
	// (= addr[24:1]), so it can be peeked directly.
	//
	// The chip clocks on sdram_clock's rising edge, which is clk_mem's falling
	// edge here (the stubs have no I/O delay). A READ at chip edge k drives
	// beat i from tAC after edge k+CL-1+i until tOH after the next edge;
	// in between the bus reads 16'hBAD0. TAC_PS / TOH_PS are those times
	// as the FPGA's dq_in register sees them, so they include the round trip
	// a real board adds: the forwarded clock's ODDR + OBUF (~3.7 ns, from the
	// routed design), traces, IBUF. Defaults: ~4 ns + W9825G6KH-6 tAC 5 /
	// tOH 3 ns. sdram_burst captures beat i 1.5 clk_mem periods (13.1 ns)
	// after the edge that launched it (STATE_LDAT0 = CONT + CL + 2), so it
	// needs TAC_PS < ~13 ns and TOH_PS > ~4.4 ns; with no I/O delay (TAC 2 ns)
	// every read returns the next word.
	// -------------------------------------------------------------------
	reg [15:0] sdram [0:(1<<24)-1];
	reg [12:0] open_row [0:3];
	reg [3:0]  burst_len = 4'd1;
	wire [3:0] sd_cmd = {sd_cs, sd_ras, sd_cas, sd_we};

	reg        rp_v [0:1];               // CL-1 = 2 chip clocks to the bus
	reg [23:0] rp_a [0:1];
	reg [23:0] rb_addr;                  // burst in progress
	reg [3:0]  rb_left = 4'd0;
	integer    sdram_writes = 0, sdram_reads = 0, sdram_cmd_errors = 0;
	initial for (int k = 0; k < 2; k++) rp_v[k] = 1'b0;

	// sdram_burst samples the pins only on clk_mem's rising edge, half a
	// period after each chip edge, so at every chip edge the model works out
	// what the pins show at that next sample instant from the recent beats
	// (launch time + value) and holds it until the next chip edge. No delayed
	// assignments: Verilator 5.052 treats a delay longer than the gap between
	// updates as inertial and drops beats.
	localparam longint HALF_PS = 4364;           // clk_mem / 2 (sim/xilinx_stubs.v)
	longint    bt [0:3];                         // launch times, newest first
	reg [15:0] bv [0:3];
	integer    nbeats = 0;
	initial for (int k = 0; k < 4; k++) bt[k] = -64'd1_000_000;

	always @(posedge sd_clk) begin : sdram_model
		reg        v;
		reg [23:0] a;
		if (rp_v[0]) begin
			for (int k = 3; k > 0; k--) begin bt[k] = bt[k-1]; bv[k] = bv[k-1]; end
			bt[0] = $time; bv[0] = sdram[rp_a[0]];
		end
		begin : pins_at_next_sample
			longint t;
			reg [15:0] d;
			reg        found;
			t = $time + HALF_PS;
			found = 1'b0;
			d = 16'hBAD0;
			// newest beat whose data has arrived and is not yet displaced
			for (int k = 0; k < 4; k++)
				if (!found && bt[k] + TAC_PS <= t) begin
					found = 1'b1;
					if (k == 0 || bt[k-1] + TOH_PS > t) d = bv[k];
				end
			if (found) sd_din <= d;
		end
		rp_v[0] <= rp_v[1]; rp_a[0] <= rp_a[1];
		// a burst in progress feeds the pipeline's tail
		v = 1'b0;
		if (rb_left != 4'd0) begin
			v = 1'b1; a = rb_addr;
			rb_addr <= {rb_addr[23:3], rb_addr[2:0] + 3'd1};   // burst wraps in 8
			rb_left <= rb_left - 4'd1;
		end
		case (sd_cmd)
			4'b0000: burst_len <= (sd_a[2:0] == 3'd3) ? 4'd8 : 4'd1;               // LOAD MODE
			4'b0011: open_row[sd_ba] <= sd_a;                                       // ACTIVE
			4'b0101: begin                                                          // READ
				v = 1'b1;
				a = {sd_ba, open_row[sd_ba], sd_a[8:0]};
				rb_addr <= {sd_ba, open_row[sd_ba], sd_a[8:3], sd_a[2:0] + 3'd1};
				rb_left <= burst_len - 4'd1;
				sdram_reads = sdram_reads + 1;
				if (sd_a[12:11] != 2'b00) begin
					sdram_cmd_errors = sdram_cmd_errors + 1;
					if (sdram_cmd_errors < 5) $display("TB ERROR: SDRAM READ with DQM=%b @%0t", sd_a[12:11], $time);
				end
			end
			4'b0100: begin                                                          // WRITE
				if (!sd_dqm[1]) sdram[{sd_ba, open_row[sd_ba], sd_a[8:0]}][15:8] <= sd_dout[15:8];
				if (!sd_dqm[0]) sdram[{sd_ba, open_row[sd_ba], sd_a[8:0]}][7:0]  <= sd_dout[7:0];
				if (!sd_dir) $display("TB ERROR: SDRAM WRITE with data bus not driven @%0t", $time);
				if (rb_left != 4'd0) $display("TB ERROR: SDRAM WRITE during a read burst @%0t", $time);
				sdram_writes = sdram_writes + 1;
			end
			default: ;
		endcase
		rp_v[1] <= v; rp_a[1] <= a;
	end

	// Read-back check: every ch3 (native CPU) word read and ch2 (block
	// device) line read must return what the array holds.
	integer rd_checks = 0, rd_bad = 0;
	reg     ack3_d = 1'b0, ack2_d = 1'b0;
	always @(posedge dut.core.clk_mem) begin
		ack3_d <= dut.core.sdram.ack3;
		ack2_d <= dut.core.sdram.ack2;
		if (dut.core.sdram.ack3 != ack3_d) begin
			rd_checks = rd_checks + 1;
			if (dut.core.sdram.word3 !== sdram[dut.core.sdram.addr3]) begin
				rd_bad = rd_bad + 1;
				if (rd_bad <= 10)
					$display("TB ERROR: ch3 read %06h got %04h, SDRAM holds %04h @%0t",
					         dut.core.sdram.addr3, dut.core.sdram.word3, sdram[dut.core.sdram.addr3], $time);
			end
		end
		if (dut.core.sdram.ack2 != ack2_d && !(dut.core.sdram.wrl2 || dut.core.sdram.wrh2)) begin : ch2_line
			reg [23:0] base;
			base = {dut.core.sdram.addr2[24:4], 3'b000};
			rd_checks = rd_checks + 1;
			for (int k = 0; k < 8; k++)
				if (dut.core.sdram.line2[k*16 +: 16] !== sdram[base + k]) begin
					rd_bad = rd_bad + 1;
					if (rd_bad <= 10)
						$display("TB ERROR: ch2 line %06h word %0d got %04h, SDRAM holds %04h @%0t",
						         base, k, dut.core.sdram.line2[k*16 +: 16], sdram[base + k], $time);
				end
		end
	end

	// Native read latency: clk_mem cycles from a ch3 request to its data. At
	// native speed the CPU latches it 3 clk_sys (24 clk_mem) after the
	// request whatever happens, so anything near 24 is a wrong byte the
	// data check above cannot see.
	integer nat_lat = 0, nat_lat_max = 0, nat_late = 0;
	reg     req3_d = 1'b0, nat_wait = 1'b0;
	reg [4:0] nat_st0;
	reg [1:0] nat_sv0;
	reg       nat_act0;
	reg [4:0] nat_since0;
	always @(posedge dut.core.clk_mem) begin
		req3_d <= dut.core.sdram.req3;
		if (dut.core.sdram.req3 != req3_d) begin
			nat_wait <= 1'b1; nat_lat <= 1;
			nat_st0 <= dut.core.sdram.state; nat_sv0 <= dut.core.sdram.serving;
			nat_act0 <= dut.core.sdram.active; nat_since0 <= dut.core.since_phi2;
		end
		else if (nat_wait) begin
			nat_lat <= nat_lat + 1;
			if (dut.core.sdram.ack3 == dut.core.sdram.req3) begin
				nat_wait <= 1'b0;
				if (nat_lat > nat_lat_max) nat_lat_max <= nat_lat;
				if (nat_lat > 22) begin
					nat_late <= nat_late + 1;
					if (nat_late < 12) $display("TB ERROR: native read took %0d clk_mem cycles (at request: state %0d serving %0d active %0d since_phi2 %0d) @%0t",
					                            nat_lat, nat_st0, nat_sv0, nat_act0, nat_since0, $time);
				end
			end
		end
	end

	// What the CPU really sees at native speed: on the half cycle before each
	// phi2 latch, the byte iigs_core presents for this cycle's ch3 read
	// (nat_data) must be the one in memory. Catches late reads directly.
	integer cpu_reads = 0, cpu_bad = 0;
	reg     nat_req_n = 1'b0, nat_pend = 1'b0;
	always @(negedge clk_sys) begin
		if (dut.core.nat_req != nat_req_n) begin
			nat_req_n <= dut.core.nat_req;
			nat_pend  <= 1'b1;
		end else if (dut.core.phi2 && nat_pend) begin : cpu_latch
			reg [15:0] wd;
			nat_pend <= 1'b0;
			wd = sdram[dut.core.nat_addr];
			cpu_reads = cpu_reads + 1;
			if (dut.core.nat_data !== (dut.core.nat_bsel ? wd[15:8] : wd[7:0])) begin
				cpu_bad = cpu_bad + 1;
				if (cpu_bad <= 10)
					$display("TB ERROR: CPU latched %02h from %06h.%0d, memory holds %04h @%0t",
					         dut.core.nat_data, dut.core.nat_addr, dut.core.nat_bsel, wd, $time);
			end
		end
	end

	// Block device check: every byte gb_blockdev hands the floppy controller
	// must be the disk image's byte at lba * 512 + offset (the disk is the
	// last file loaded, so filebuf still holds it). +trace_bd lists sectors.
	integer bd_bytes = 0, bd_bad = 0, bd_writes = 0;
	bit     bd_check = 1'b0;
	reg     bd_rd_d = 1'b0, bd_wr_d = 1'b0;
	always @(posedge clk_sys) begin
		bd_rd_d <= dut.sd_rd;
		bd_wr_d <= dut.sd_wr;
		if (dut.sd_rd && !bd_rd_d && $test$plusargs("trace_bd"))
			$display("TB BD: read lba %0d frame %0d", dut.sd_lba, frame);
		if (dut.sd_wr && !bd_wr_d) begin
			bd_writes = bd_writes + 1;
			$display("TB BD: WRITE lba %0d frame %0d", dut.sd_lba, frame);
		end
		if (bd_check && !dut.disk_sel && dut.sd_ack && dut.sd_buff_wr) begin
			bd_bytes = bd_bytes + 1;
			if (dut.sd_buff_dout !== filebuf[dut.sd_lba * 512 + dut.sd_buff_addr]) begin
				bd_bad = bd_bad + 1;
				if (bd_bad <= 10)
					$display("TB ERROR: blockdev lba %0d byte %0d = %02h, image has %02h @%0t", dut.sd_lba,
					         dut.sd_buff_addr, dut.sd_buff_dout, filebuf[dut.sd_lba * 512 + dut.sd_buff_addr], $time);
			end
		end
	end

	reg eject_d = 1'b0;
	always @(posedge clk_sys) begin
		eject_d <= dut.core.drive35_eject_req;
		if (dut.core.drive35_eject_req && !eject_d)
			$display("TB: 3.5\" EJECT requested at frame %0d, cpu=%06h", frame, dut.dbg_addr);
	end

	// -------------------------------------------------------------------
	// Host (MCU) model
	// -------------------------------------------------------------------
	reg  [7:0]  filebuf [0:(1<<23)-1];
	integer     xfers = 0;

	// One HostV0 memory transaction, shaped like SpiReceiverFifo: enable is
	// held, the first cycle is never a completion, and the transaction ends
	// on the edge that samples done high. The testbench drives and samples
	// the host signals on clk_sys's FALLING edge: Verilator 5.052 committed
	// back-to-back non-blocking writes from a task out of order, and blocking
	// writes on the rising edge raced the core's clocked logic.
	task automatic mem_xfer(input bit wr, input [31:0] a, input [31:0] d, output [31:0] q);
		@(negedge clk_sys);
		h_en = 1'b1; h_wr = wr; h_addr = a; h_wdata = d;
		forever begin
			@(negedge clk_sys);
			if (h_done) break;
		end
		q    = h_rdata;
		h_en = 1'b0;
		if ($test$plusargs("trace_host")) begin $display("TB HOST: %s %08h -> %08h @%0t", wr ? "wr" : "rd", a, wr ? d : q, $time); $fflush; end
		xfers = xfers + 1;
	endtask

	task automatic mem_write(input [31:0] a, input [31:0] d);
		reg [31:0] dummy;
		mem_xfer(1'b1, a, d, dummy);
	endtask

	task automatic mem_read(input [31:0] a, output [31:0] q);
		mem_xfer(1'b0, a, 32'd0, q);
	endtask

	task automatic host_cmd(input [15:0] op, input [31:0] p1, input [31:0] p2,
	                        input [31:0] p3, output [31:0] r0);
		mem_write(32'hF000_0000, {16'd0, op});
		mem_write(32'hF000_0004, p1);
		mem_write(32'hF000_0008, p2);
		mem_write(32'hF000_000C, p3);
		c_req = 1'b1;
		forever begin
			@(negedge clk_sys);
			if (c_done || c_error) break;
		end
		if (c_error) $display("TB: command %04h returned ERROR", op);
		mem_read(32'hF000_0000, r0);
		c_req = 1'b0;
		forever begin
			@(negedge clk_sys);
			if (!c_done && !c_error) break;
		end
	endtask

	// -------------------------------------------------------------------
	// Paced host model (+paced). The real MCU streams file data over quad
	// SPI at 10 MHz, one 32-bit word every 800 ns whether or not the core
	// keeps up, in 16 KiB transactions, through the framework's
	// SpiReceiverFifo: a 512-entry request FIFO; once it is full the rest of
	// that SPI transaction is dropped. (MacLC_GameBub's model, writes only.)
	// -------------------------------------------------------------------
	localparam longint SPI_WORD_PS  = 800_000;
	localparam longint SPI_START_PS = 1_600_000;
	localparam longint CDC_PS       = 125_000;
	localparam integer FIFO_DEPTH   = 512;
	localparam integer CHUNK_BYTES  = 16384;
	typedef struct { bit start; bit [31:0] data; longint t; } spi_req_t;
	spi_req_t   req_q[$];
	bit         paced = 1'b0, sys_active = 1'b0;
	longint     chunk_gap_ps = 10_000_000;
	integer     sys_xfers = 0, sys_cycles = 0, sys_max = 0, sys_min = 1 << 30;

	initial begin : sys_side
		reg [31:0] a;
		integer    n;
		forever begin
			@(negedge clk_sys);
			if (req_q.size() != 0 && req_q[0].t <= $time) begin
				sys_active = 1'b1;
				if (req_q[0].start) begin
					a = req_q[0].data;
					void'(req_q.pop_front());
				end else begin
					h_en = 1'b1; h_wr = 1'b1; h_addr = a; h_wdata = req_q[0].data;
					n = 0;
					forever begin
						@(negedge clk_sys);
						n = n + 1;
						if (h_done) break;
					end
					h_en = 1'b0;
					void'(req_q.pop_front());
					a = a + 32'd4;
					sys_xfers  = sys_xfers + 1;
					sys_cycles = sys_cycles + n;
					if (n > sys_max) sys_max = n;
					if (n < sys_min) sys_min = n;
				end
			end else begin
				sys_active = 1'b0;
			end
		end
	end

	function automatic [31:0] file_word(input integer n);
		file_word = {filebuf[n+3], filebuf[n+2], filebuf[n+1], filebuf[n]};   // LSB first
	endfunction

	task automatic spi_push(input bit start, input [31:0] data, inout bit ovf);
		spi_req_t e;
		if (ovf) return;
		if (req_q.size() >= FIFO_DEPTH) begin
			ovf = 1'b1;
		end else begin
			e.start = start; e.data = data; e.t = $time + CDC_PS;
			req_q.push_back(e);
		end
	endtask

	task automatic wait_host_idle();
		do @(negedge clk_sys); while (req_q.size() != 0 || sys_active);
	endtask

	task automatic spi_write_file(input [31:0] addr, input integer len, output integer dropped);
		integer off, n;
		bit ovf;
		dropped = 0;
		for (off = 0; off < len; off = off + CHUNK_BYTES) begin
			ovf = 1'b0;
			#(SPI_START_PS);
			spi_push(1'b1, addr + off, ovf);
			for (n = off; n < off + CHUNK_BYTES && n < len; n = n + 4) begin
				#(SPI_WORD_PS);
				spi_push(1'b0, file_word(n), ovf);
				if (ovf) dropped = dropped + 1;
			end
			#(chunk_gap_ps);
		end
	endtask

	// What the core stored: byte n of the file at SDRAM word (base + n) / 2,
	// even bytes in [7:0] (gb_host.sv FILE BYTE ORDER).
	function automatic integer sdram_mismatches(input [31:0] addr, input integer len);
		integer n, bad;
		reg [23:0] wa;
		bad = 0;
		for (n = 0; n < len; n = n + 2) begin
			wa = (addr - 32'h1000_0000 + n) >> 1;
			if (sdram[wa] != {filebuf[n+1], filebuf[n]}) bad = bad + 1;
		end
		sdram_mismatches = bad;
	endfunction

	task automatic load_file(input [15:0] id, input string path, input [31:0] addr, output integer len);
		integer fd, n;
		reg [31:0] r;
		fd = $fopen(path, "rb");
		if (fd == 0) begin
			$display("TB: cannot open %s", path);
			$finish;
		end
		len = $fread(filebuf, fd, 0, 1 << 23);
		$fclose(fd);
		for (n = len; n < len + 4; n = n + 1) filebuf[n] = 8'h00;   // last partial word
		$display("TB: file %0d: %0d bytes -> host 0x%08h (%s)", id, len, addr, path);
		host_cmd(16'h0300, {16'd0, id}, 32'd0, 32'd0, r);
		if (paced) begin : paced_load
			integer dropped, x0, c0;
			x0 = sys_xfers; c0 = sys_cycles; sys_max = 0; sys_min = 1 << 30;
			spi_write_file(addr, len, dropped);
			wait_host_idle();
			host_cmd(16'h0301, {16'd0, id}, len, 32'd0, r);
			$display("TB PACED: file %0d: %0d words, %0d dropped by FIFO overflow; core took %0d..%0d cycles/word (avg %0.1f; 11.5 = 800 ns)",
			         id, (len + 3) / 4, dropped, sys_min, sys_max,
			         real'(sys_cycles - c0) / real'(sys_xfers - x0 > 0 ? sys_xfers - x0 : 1));
		end else begin
			for (n = 0; n < len; n = n + 4) mem_write(addr + n, file_word(n));
			host_cmd(16'h0301, {16'd0, id}, len, 32'd0, r);
		end
		$display("TB: file %0d: %0d of %0d SDRAM words wrong", id, sdram_mismatches(addr, len), len / 2);
	endtask

	// -------------------------------------------------------------------
	// Frame capture (what the framework stores): 320 x 200
	// -------------------------------------------------------------------
	localparam integer FW = 320, FH = 200;
	reg  [8:0]  fb [0:FW*FH-1];
	integer     fx = 0, fy = 0, frame = 0, max_frames = 300, dump_every = 25;
	integer     line_pixels_bad = 0, frame_rows_bad = 0;
	string      out_dir = "sim_out";
	reg         vbl_d = 1'b1, hbl_d = 1'b0;

	task automatic dump_frame(input integer n);
		integer fd, i;
		string name;
		reg [8:0] p;
		name = $sformatf("%s/frame_%04d.ppm", out_dir, n);
		fd = $fopen(name, "wb");
		$fwrite(fd, "P6\n%0d %0d\n255\n", FW, FH);
		for (i = 0; i < FW*FH; i = i + 1) begin
			p = fb[i];
			$fwrite(fd, "%c%c%c", {p[8:6], p[8:6], p[8:7]}, {p[5:3], p[5:3], p[5:4]}, {p[2:0], p[2:0], p[2:1]});
		end
		$fclose(fd);
	endtask

	always @(posedge clk_sys) begin
		vbl_d <= v_vblank;
		hbl_d <= v_hblank;
		if (v_vblank) begin
			fx <= 0; fy <= 0;
		end else if (v_hblank && !hbl_d) begin
			if (fx != FW) begin
				line_pixels_bad <= line_pixels_bad + 1;
				if (line_pixels_bad < 5)
					$display("TB WARNING: frame %0d row %0d had %0d pixels", frame, fy, fx);
			end
			fx <= 0; fy <= fy + 1;
		end else if (v_de) begin
			if (fx < FW && fy < FH) fb[fy*FW + fx] <= {v_r, v_g, v_b};
			fx <= fx + 1;
		end
		if (v_vblank && !vbl_d) begin
			frame <= frame + 1;
			if (fy != FH && frame > 0) begin
				frame_rows_bad <= frame_rows_bad + 1;
				if (frame_rows_bad < 5) $display("TB WARNING: frame %0d had %0d rows", frame, fy);
			end
			if (frame % 10 == 0) begin
				$display("TB: frame %0d host=%08h cpu=%06h cpu_reset=%0d disk=%04b bd=%08h (%0d bytes checked, %0d bad) native max %0d late %0d cpu %0d/%0d bad sdram rd=%0d wr=%0d checks=%0d bad=%0d audio=%0d",
				         frame, dut.dbg_host_state, dut.dbg_addr, dut.dbg_core_reset, dut.dbg_disk,
				         dut.dbg_blockdev, bd_bytes, bd_bad, nat_lat_max, nat_late, cpu_bad, cpu_reads, sdram_reads, sdram_writes, rd_checks, rd_bad, audio_peak);
				audio_peak = 0;
				$fflush;
			end
			if (dump_every > 0 && frame > 0 && frame % dump_every == 0) begin
				dump_frame(frame);
				if (raw_dump) raw_save = 1'b1;
			end
			if (frame >= max_frames) begin
				dump_frame(frame);
				$display("TB: done after %0d frames (%0d SDRAM reads checked, %0d wrong)", frame, rd_checks, rd_bad);
				$finish;
			end
		end
	end

	// Audio peak since the last report
	integer audio_peak = 0;
	always @(posedge clk_sys) begin : audio_mon
		integer l, r;
		l = $signed(a_left);  if (l < 0) l = -l;
		r = $signed(a_right); if (r < 0) r = -r;
		if (l > audio_peak) audio_peak = l;
		if (r > audio_peak) audio_peak = r;
	end

	// -------------------------------------------------------------------
	// +raw: the VGC's own output, one pixel per clk_sys, every line between
	// hblanks and every line between vblanks, to place CROP_X/CROP_Y.
	// -------------------------------------------------------------------
	localparam integer RW = 1024, RH = 320;
	reg  [23:0] rawfb [0:RW*RH-1];
	bit         raw_dump = 1'b0, raw_save = 1'b0;
	integer     rx = 0, ry = 0, raw_w = 0, raw_h = 0;
	reg         rhb_d = 1'b0, rvb_d = 1'b0;
	always @(posedge clk_sys) if (raw_dump) begin
		rhb_d <= dut.vid_hblank;
		rvb_d <= dut.vid_vblank;
		if (!dut.vid_hblank && !dut.vid_vblank) begin
			if (rx < RW && ry < RH) rawfb[ry*RW + rx] <= {dut.vid_r, dut.vid_g, dut.vid_b};
			rx <= rx + 1;
		end
		if (dut.vid_hblank && !rhb_d) begin
			if (!dut.vid_vblank) begin
				raw_w <= rx;
				ry <= ry + 1;
			end
			rx <= 0;
		end
		if (dut.vid_vblank && !rvb_d) begin
			raw_h <= ry;
			if (raw_save) begin : save
				integer fd, i, j;
				fd = $fopen($sformatf("%s/raw_%04d.ppm", out_dir, frame), "wb");
				$fwrite(fd, "P6\n%0d %0d\n255\n", raw_w, ry);
				for (j = 0; j < ry; j = j + 1)
					for (i = 0; i < raw_w; i = i + 1)
						$fwrite(fd, "%c%c%c", rawfb[j*RW+i][23:16], rawfb[j*RW+i][15:8], rawfb[j*RW+i][7:0]);
				$fclose(fd);
				$display("TB RAW: frame %0d visible area %0d x %0d", frame, raw_w, ry);
				raw_save = 1'b0;
			end
			ry <= 0;
		end
	end

	// -------------------------------------------------------------------
	// Input register reads (+io_stats): which of keyboard, mouse,
	// buttons and paddles the running program polls, per 100 frames.
	integer io_rd [0:255];
	integer io_frame = -1;
	initial for (int i = 0; i < 256; i++) io_rd[i] = 0;
	always @(posedge clk_sys) if ($test$plusargs("io_stats")) begin
		if (dut.core.iigs.phi2 && dut.core.iigs.IO && !dut.core.iigs.we)
			io_rd[dut.core.iigs.addr_bef[7:0]] <= io_rd[dut.core.iigs.addr_bef[7:0]] + 1;
		if (frame % 100 == 0 && frame != io_frame) begin
			io_frame <= frame;
			$display("TB IO: frame %0d kbd C000=%0d C010=%0d C025=%0d | mouse C024=%0d C027=%0d C044=%0d C045=%0d | btn C061=%0d C062=%0d C063=%0d | paddle C064=%0d C065=%0d C070=%0d | vbl C019=%0d C02E=%0d",
			         frame, io_rd[8'h00], io_rd[8'h10], io_rd[8'h25], io_rd[8'h24], io_rd[8'h27], io_rd[8'h44], io_rd[8'h45],
			         io_rd[8'h61], io_rd[8'h62], io_rd[8'h63], io_rd[8'h64], io_rd[8'h65], io_rd[8'h70], io_rd[8'h19], io_rd[8'h2E]);
			for (int i = 0; i < 256; i++) io_rd[i] <= 0;
		end
	end

	// +trace_mouse: the pad's pointer reports (gb_pad_input -> adb.sv)
	reg mouse_tog = 1'b0;
	always @(posedge clk_sys) begin
		mouse_tog <= dut.ps2_mouse[24];
		if ($test$plusargs("trace_mouse") && dut.ps2_mouse[24] != mouse_tog)
			$display("TB MOUSE: frame %0d dx=%0d dy=%0d btn=%0d", frame,
			         $signed({dut.ps2_mouse[4], dut.ps2_mouse[15:8]}),
			         $signed({dut.ps2_mouse[5], dut.ps2_mouse[23:16]}), dut.ps2_mouse[0]);
	end

	// Button presses (+press=<frame>:<button>)
	// -------------------------------------------------------------------
	function automatic integer btn_index(input string s);
		case (s)
			"up": return 0;  "down": return 1;  "left": return 2; "right": return 3;
			"a": return 4;   "b": return 5;     "x": return 6;    "y": return 7;
			"l": return 8;   "r": return 9;     "select": return 10; "start": return 11;
			default: return -1;
		endcase
	endfunction

	integer press_frame [0:7];
	integer press_btn   [0:7];
	integer press_len   [0:7];
	integer npress = 0;
	initial begin : parse_presses
		string s, b, key;
		integer f, i, k;
		for (k = 0; k < 8; k = k + 1) begin
			key = (k == 0) ? "press=%s" : $sformatf("press%0d=%%s", k + 1);
			if ($value$plusargs(key, s)) begin
				f = 0;
				for (i = 0; i < s.len() && s[i] != ":"; i = i + 1) f = f * 10 + (s[i] - "0");
				b = s.substr(i + 1, s.len() - 1);
				press_len[npress] = 6;
				for (i = 0; i < b.len() && b[i] != ":"; i = i + 1) ;
				if (i < b.len()) begin
					press_len[npress] = b.substr(i + 1, b.len() - 1).atoi();
					b = b.substr(0, i - 1);
				end
				press_frame[npress] = f;
				press_btn[npress]   = btn_index(b);
				if (press_btn[npress] < 0) $display("TB: unknown button '%s'", b);
				else $display("TB: will press %s at frame %0d for %0d frames", b, f, press_len[npress]);
				npress = npress + 1;
			end
		end
	end
	always @(posedge clk_sys) begin : buttons
		integer k;
		reg [11:0] want;
		want = 12'd0;
		for (k = 0; k < npress; k = k + 1)
			if (press_btn[k] >= 0 && frame >= press_frame[k] && frame < press_frame[k] + press_len[k])
				want[press_btn[k]] = 1'b1;
		btn <= want;
	end

	// +heartbeat: simulated time every ms, flushed (a stalled run shows where)
	initial if ($test$plusargs("heartbeat")) forever begin
		#(64'd1_000_000_000);
		$display("TB: t=%0d ms frame=%0d xfers=%0d sdram rd=%0d wr=%0d", $time / 64'd1_000_000_000, frame, xfers, sdram_reads, sdram_writes);
		$fflush;
	end

	// -------------------------------------------------------------------
	// The MCU's core-load sequence
	// -------------------------------------------------------------------
	string rom3_path, rom01_path, disk_path, disk2_path, gamedb_path;
	integer len, speed, polls;
	longint t_setup;
	reg [31:0] r;
	initial begin
		if (!$value$plusargs("rom3=%s", rom3_path)) rom3_path = "scratch/roms/boot.rom";
		if ($test$plusargs("no_rom3")) rom3_path = "";
		if (!$value$plusargs("rom01=%s", rom01_path)) rom01_path = "";
		if (!$value$plusargs("disk=%s", disk_path)) disk_path = "";
		if (!$value$plusargs("disk2=%s", disk2_path)) disk2_path = "";
		if (!$value$plusargs("gamedb=%s", gamedb_path)) gamedb_path = "";
		if (!$value$plusargs("frames=%d", max_frames)) max_frames = 300;
		if (!$value$plusargs("dump=%d", dump_every)) dump_every = 25;
		if (!$value$plusargs("out=%s", out_dir)) out_dir = "sim_out";
		if ($test$plusargs("paced")) paced = 1'b1;
		if ($test$plusargs("raw")) raw_dump = 1'b1;

		wait (!fw_reset);
		repeat (10) @(posedge clk_sys);
		host_cmd(16'h0000, 0, 0, 0, r);
		$display("TB: GetStatus = %0d (expect 2 = setup)", r);
		mem_read(32'h0000_0800, r);
		$display("TB: magic = %08h (expect 49494753)", r);

		// Settings, written during setup like the MCU does (settings.json)
		if ($value$plusargs("speed=%d", speed)) mem_write(32'h0000_0204, speed);
		if ($test$plusargs("kbd_mode"))         mem_write(32'h0000_0208, 32'd0);
		if ($value$plusargs("mouse=%h", speed)) mem_write(32'h0000_020C, speed);
		if ($value$plusargs("volume=%d", speed)) mem_write(32'h0000_0210, speed);
		if ($value$plusargs("disk_light=%d", speed)) mem_write(32'h0000_0214, speed);

		if (rom3_path != "")  load_file(2, rom3_path,  32'h10FC_0000, len);
		if (rom01_path != "") load_file(3, rom01_path, 32'h10F8_0000, len);
		// (before the disks: the block-device check compares against the
		// last file loaded, which stays in filebuf)
		if (gamedb_path != "") load_file(4, gamedb_path, 32'h1180_0000, len);
		if (disk_path != "")  load_file(0, disk_path,  32'h1100_0000, len);
		if (disk2_path != "") load_file(1, disk2_path, 32'h1140_0000, len);
		bd_check = (disk_path != "" && disk2_path == "");
		if ($test$plusargs("stop_after_load")) begin
			$display("TB: +stop_after_load, done");
			$finish;
		end

		t_setup = $time;
		host_cmd(16'h0102, 0, 0, 0, r);           // SetupComplete
		// The firmware polls until the core reports halted (100 ms limit):
		// the game database lookup runs in between.
		polls = 0;
		do begin
			host_cmd(16'h0000, 0, 0, 0, r);
			polls++;
		end while (r == 2 && polls < 10000);
		$display("TB: GetStatus = %0d (expect 3 = halted) after %0d polls, %0d us after SetupComplete (firmware limit 100000)",
		         r, polls, ($time - t_setup) / 1_000_000);
		if (r != 3) $display("TB ERROR: core never reported halted");
		$display("TB: gamedb found=%0d crc=%08h rom=%0d speed=%0d input=%0d mouse=%02h keymap=%016h -> rom_select=%0d host_speed=%0d ptr_default=%0d mouse_steps=%02h",
		         dut.db_found, dut.db_crc, dut.db_rom, dut.db_speed, dut.db_input, dut.db_mouse, dut.db_keymap,
		         dut.rom_select, dut.host_speed, dut.ptr_default, dut.mouse_steps);
		host_cmd(16'h0200, 1, 0, 0, r);           // NotifyFocus(1)
		host_cmd(16'h0100, 0, 0, 0, r);           // CoreRun
		host_cmd(16'h0000, 0, 0, 0, r);
		$display("TB: GetStatus = %0d (expect 4 = running) host=%08h", r, dut.dbg_host_state);
	end

	// -------------------------------------------------------------------
	// PMOD debug beacon receiver (pin 3, 115200 8N1): prints each line.
	// -------------------------------------------------------------------
	localparam longint BAUD_PS = 1_000_000_000_000 / 115_200;
	string beacon_line = "";
	initial if ($test$plusargs("beacon")) begin : beacon_rx
		reg [7:0] ch;
		integer b;
		forever begin
			@(negedge pmod_out[2]);
			#(BAUD_PS + BAUD_PS / 2);
			for (b = 0; b < 8; b = b + 1) begin
				ch[b] = pmod_out[2];
				#(BAUD_PS);
			end
			if (ch == 8'h0A) begin
				$display("TB BEACON: %s", beacon_line);
				beacon_line = "";
			end else if (ch != 8'h0D) begin
				beacon_line = {beacon_line, string'(ch)};
			end
		end
	end

endmodule

`default_nettype wire
