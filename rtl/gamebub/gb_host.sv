// ============================================================================
// gb_host.sv: the Game Bub host protocol (HostV0) for the Apple IIgs.
// Derived from MacLC_GameBub rtl/gamebub/gb_host.sv (GPL-3.0-or-later).
//
// Owns everything the MCU talks to:
//   * the command channel (GetStatus, SetupComplete, CoreRun/Halt,
//     NotifyFocus, FileWrite/ReadStart/End) and its parameter/result
//     registers at 0xF000_0000;
//   * the settings registers written from settings.json (0x0000_0xxx);
//   * a write window onto the SDRAM through which the MCU loads every file
//     from files.json. Every file is read-only, so nothing is read back.
//
// HOST MEMORY MAP (byte addresses, 32-bit accesses)
//   0x0000_0100..0x0000_02FF  settings (see SETTINGS below)
//   0x0000_0800..0x0000_08FF  read-only status/debug words
//   0x1000_0000 + n           SDRAM byte n (32 MiB). files.json addresses:
//       0x10F8_0000  ROM 01     128 KiB  (iigs.sv rom_select=1 map)
//       0x10FC_0000  ROM 3      256 KiB  (iigs.sv rom_select=0 map)
//       0x1100_0000  disk 1     <= 4 MiB (WOZ)
//       0x1140_0000  disk 2     <= 4 MiB (WOZ, optional)
//       0x1180_0000  game db    <= 64 KiB
//     (0x1000_0000..0x107F_FFFF is the IIgs's 8 MB of fast RAM.)
//   0xF000_0000..0xF000_001C  host->core command opcode/params/results
//
// FILE BYTE ORDER. The MCU packs four file bytes into each 32-bit word
// least significant byte first (firmware: core/mod.rs streams the raw file
// through the same SPI word path write_u32() feeds with to_le_bytes()). The
// IIgs memory path stores byte n in SDRAM word n/2, even bytes in [7:0]
// (Apple-IIgs.sv: wrl = ~addr[0]), so host word {b3,b2,b1,b0} at byte n is
// written as {b1,b0} to word n/2 and {b3,b2} to word n/2+1, unchanged.
//
// The MCU streams at a fixed pace and the framework drops what the core does
// not take in time, so SDRAM writes are POSTED into a queue (MacLC's lesson)
// and commands wait until it has drained.
// ============================================================================
`default_nettype none

module gb_host (
	input  wire        clk,
	input  wire        reset,

	// ---- framework host memory interface (HostV0.mem) ----
	input  wire        mem_enable,
	input  wire        mem_write,
	input  wire [31:0] mem_address,
	input  wire [31:0] mem_dataWrite,
	output reg  [31:0] mem_dataRead,
	output reg         mem_done,

	// ---- framework host->core command channel ----
	input  wire        cmd_request,
	output wire        cmd_busy,
	output wire        cmd_done,
	output wire        cmd_error,

	// ---- SDRAM client (gb_eth_arb protocol; 16-bit word address) ----
	output reg         sd_req,
	output wire        sd_we,
	output reg  [23:0] sd_addr,
	output reg  [15:0] sd_din,
	input  wire        sd_ack,

	// ---- machine control ----
	output wire        core_reset,       // hold the IIgs in reset
	output wire        rom_select,       // 0 = ROM 3, 1 = ROM 01
	output wire  [2:0] host_speed,       // iigs.sv host_speed
	output reg         act_reset,        // pulse: warm reset (settings action)
	output reg         act_swap,         // pulse: swap disk 1 <-> disk 2
	output reg         mount_req,        // pulse: present the disk image
	output reg         focus,

	// ---- settings for the input layer ----
	output wire        ptr_default,      // start in pointer (mouse) mode

	// ---- game database (gb_gamedb) ----
	output reg         db_start,         // pulse: look the disk up (SetupComplete)
	input  wire        db_done,
	input  wire        db_found,
	input  wire  [1:0] db_rom,           // 0 auto, 1 ROM 3, 2 ROM 01
	input  wire  [7:0] db_speed,         // 0..4, 0xFF no preference
	input  wire  [7:0] db_input,         // 0 keyboard, 1 mouse, 0xFF no preference
	input  wire  [7:0] db_mouse,         // pointer steps {fast, slow}, 0 no preference
	output wire  [7:0] mouse_steps,      // pointer steps {fast, slow}, 0 = default
	output wire  [2:0] doc_gain,         // music volume: DOC x(1 << doc_gain)
	output wire        disk_light,       // draw the drive light (gb_disk_light)

	// ---- file table ----
	output reg   [4:0] file_present,
	output wire [159:0] file_size_flat,  // {size[4], ..., size[0]}

	// ---- debug ----
	input  wire [31:0] dbg_blockdev,
	output wire [31:0] dbg_state,
	output wire [31:0] dbg_woz_magic
);

	// ---------------------------------------------------------------------
	// File IDs (files.json)
	// ---------------------------------------------------------------------
	localparam [2:0] FILE_DISK1  = 3'd0;
	localparam [2:0] FILE_DISK2  = 3'd1;
	localparam [2:0] FILE_ROM3   = 3'd2;
	localparam [2:0] FILE_ROM01  = 3'd3;
	localparam [2:0] FILE_GAMEDB = 3'd4;
	localparam integer NFILES = 5;

	localparam [31:0] DISK1_HOST_ADDR = 32'h1100_0000;

	// ---------------------------------------------------------------------
	// HostV0 command opcodes and status codes
	// ---------------------------------------------------------------------
	localparam [15:0] CMD_GET_STATUS     = 16'h0000;
	localparam [15:0] CMD_CORE_RUN       = 16'h0100;
	localparam [15:0] CMD_CORE_HALT      = 16'h0101;
	localparam [15:0] CMD_SETUP_COMPLETE = 16'h0102;
	localparam [15:0] CMD_NOTIFY_FOCUS   = 16'h0200;
	localparam [15:0] CMD_FILE_WR_START  = 16'h0300;
	localparam [15:0] CMD_FILE_WR_END    = 16'h0301;
	localparam [15:0] CMD_FILE_RD_START  = 16'h0302;
	localparam [15:0] CMD_FILE_RD_END    = 16'h0303;

	localparam [31:0] STATUS_SETUP     = 32'd2;
	localparam [31:0] STATUS_CORE_HALT = 32'd3;
	localparam [31:0] STATUS_CORE_RUN  = 32'd4;

	// ---------------------------------------------------------------------
	// SETTINGS (settings.json writes these)
	// ---------------------------------------------------------------------
	localparam [11:0] SET_ACT_RESET   = 12'h100;  // action: warm reset
	localparam [11:0] SET_ACT_SWAP    = 12'h104;  // action: swap disk 1 / disk 2
	localparam [11:0] SET_ROM         = 12'h200;  // 0 = auto, 1 = ROM 3, 2 = ROM 01
	localparam [11:0] SET_SPEED       = 12'h204;  // host_speed 0..4, 0xF = auto
	localparam [11:0] SET_PTR_DEFAULT = 12'h208;  // 0 keyboard, 1 mouse, 2 = auto
	localparam [11:0] SET_MOUSE       = 12'h20C;  // pointer steps {fast, slow}, 0 = auto
	localparam [11:0] SET_VOLUME      = 12'h210;  // DOC gain shift 2..5 (2 = upstream)
	localparam [11:0] SET_DISK_LIGHT  = 12'h214;  // 1 = show the drive light

	reg  [31:0] set_rom         = 32'd0;
	reg  [31:0] set_speed       = 32'hF;
	reg  [31:0] set_ptr_default = 32'd2;
	reg  [31:0] set_mouse       = 32'd0;
	reg  [31:0] set_volume      = 32'd4;
	reg  [31:0] set_disk_light  = 32'd1;

	// "Auto" settings take the game database's choice for this disk
	// (gb_gamedb), else: ROM 01 if the card has it (the ROM most games
	// were written for; none of the WOZ collection's IIgs titles needs
	// ROM 3), else ROM 3; normal speed; mouse mode.
	wire db_rom3  = db_found && db_rom == 2'd1 && file_present[FILE_ROM3];
	wire db_rom01 = db_found && db_rom == 2'd2 && file_present[FILE_ROM01];
	assign rom_select  = (set_rom[1:0] == 2'd2) ||
	                     (set_rom[1:0] == 2'd0 && !db_rom3 && file_present[FILE_ROM01]);
	// (The accelerator already runs at native speed while a drive motor is
	// on -- iigs.sv fast_thresh -- so a faster CPU cannot speed disk reads.)
	assign host_speed  = (set_speed[3:0] == 4'hF) ?
	                         ((db_found && db_speed <= 8'd4) ? db_speed[2:0] : 3'd0) :
	                     (set_speed[2:0] > 3'd4) ? 3'd4 : set_speed[2:0];
	assign ptr_default = (set_ptr_default[1:0] == 2'd2) ?
	                         ((db_found && db_input <= 8'd1) ? db_input[0] : 1'b1) :
	                     set_ptr_default[0];
	assign disk_light  = set_disk_light[0];
	assign doc_gain    = (set_volume[2:0] < 3'd2) ? 3'd2 : (set_volume[2:0] > 3'd5) ? 3'd5 : set_volume[2:0];
	assign mouse_steps = (set_mouse[7:0] == 8'd0) ? (db_found ? db_mouse : 8'd0) : set_mouse[7:0];

	// ---------------------------------------------------------------------
	// Core state
	// ---------------------------------------------------------------------
	reg         setup_done = 1'b0;   // SetupComplete received
	reg         run        = 1'b0;   // CoreRun (vs CoreHalt)
	reg  [31:0] file_size [0:NFILES-1];
	reg  [31:0] woz_magic  = 32'd0;  // first word of disk 1 ("WOZ2" = 0x325A4F57)

	wire        rom_loaded = file_present[FILE_ROM3] || file_present[FILE_ROM01];

	assign file_size_flat = {file_size[4], file_size[3], file_size[2], file_size[1], file_size[0]};
	assign core_reset     = !(run && rom_loaded && db_done);

	// ---------------------------------------------------------------------
	// Command channel
	// ---------------------------------------------------------------------
	reg  [31:0] cmd_reg [0:7];       // 0xF000_0000.. opcode/params, then results
	localparam [1:0] CS_IDLE = 2'd0, CS_DONE = 2'd2, CS_ERROR = 2'd3;
	reg  [1:0]  cmd_state = CS_IDLE;
	assign cmd_busy  = 1'b0;
	assign cmd_done  = (cmd_state == CS_DONE);
	assign cmd_error = (cmd_state == CS_ERROR);

	wire [15:0] opcode    = cmd_reg[0][15:0];
	wire [2:0]  arg_id    = cmd_reg[1][2:0];
	wire        arg_id_ok = (cmd_reg[1] < NFILES);

	reg         run_d = 1'b0;

	// ---------------------------------------------------------------------
	// Host memory transactions
	// ---------------------------------------------------------------------
	wire        is_sdram = (mem_address[31:28] == 4'h1);
	wire        is_cmd   = (mem_address[31:12] == 20'hF0000) && (mem_address[11:5] == 7'd0);
	wire        is_local = (mem_address[31:12] == 20'h00000);
	wire [11:0] loc      = mem_address[11:0];

	reg         ms_done = 1'b0;      // answer the current transaction next cycle

	// Write queue: {32-bit word address, data}, block RAM, registered read.
	localparam integer WQ_AW = 9;    // 512 words
	reg  [54:0]     wq_mem [0:(1 << WQ_AW) - 1];
	reg  [54:0]     wq_head;
	reg  [WQ_AW:0]  wq_wp = '0, wq_rp = '0;
	wire            wq_empty = (wq_wp == wq_rp);
	wire            wq_full  = (wq_wp[WQ_AW] != wq_rp[WQ_AW]) &&
	                           (wq_wp[WQ_AW-1:0] == wq_rp[WQ_AW-1:0]);
	wire            wq_push  = !ms_done && mem_enable && !mem_done && is_sdram
	                           && mem_write && !wq_full && !reset;
	always @(posedge clk) begin
		if (wq_push) wq_mem[wq_wp[WQ_AW-1:0]] <= {mem_address[24:2], mem_dataWrite};
		wq_head <= wq_mem[wq_rp[WQ_AW-1:0]];
	end

	// SDRAM engine: one 32-bit word = two 16-bit writes, low half first.
	localparam [2:0] E_IDLE = 3'd0, E_LOAD = 3'd1, E_LO = 3'd2, E_LO_DROP = 3'd3,
	                 E_HI = 3'd4, E_HI_DROP = 3'd5;
	reg  [2:0]  e = E_IDLE;
	reg  [22:0] e_addr;
	reg  [15:0] e_hi;
	wire        wq_drained = wq_empty && (e == E_IDLE);
	assign sd_we = 1'b1;

	function [31:0] local_read(input [11:0] a);
		case (a)
			SET_ROM:          local_read = set_rom;
			SET_SPEED:        local_read = set_speed;
			SET_PTR_DEFAULT:  local_read = set_ptr_default;
			SET_MOUSE:        local_read = set_mouse;
			SET_VOLUME:       local_read = set_volume;
			SET_DISK_LIGHT:   local_read = set_disk_light;
			12'h800:          local_read = 32'h49494753;   // "IIGS"
			12'h804:          local_read = dbg_state;
			12'h808:          local_read = woz_magic;
			12'h810:          local_read = file_size[0];
			12'h814:          local_read = file_size[1];
			12'h818:          local_read = file_size[2];
			12'h81C:          local_read = file_size[3];
			12'h820:          local_read = file_size[4];
			12'h824:          local_read = dbg_blockdev;
			12'h828:          local_read = {29'd0, db_found, db_done, setup_done};
			default:          local_read = 32'd0;
		endcase
	endfunction

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			mem_done     <= 1'b0;
			mem_dataRead <= 32'd0;
			ms_done      <= 1'b0;
			wq_wp        <= '0;
			wq_rp        <= '0;
			e            <= E_IDLE;
			sd_req       <= 1'b0;
			cmd_state    <= CS_IDLE;
			setup_done   <= 1'b0;
			run          <= 1'b0;
			run_d        <= 1'b0;
			mount_req    <= 1'b0;
			db_start     <= 1'b0;
			act_reset    <= 1'b0;
			act_swap     <= 1'b0;
			focus        <= 1'b0;
			file_present <= '0;
			woz_magic    <= 32'd0;
			for (i = 0; i < NFILES; i = i + 1) file_size[i] <= 32'd0;
			for (i = 0; i < 8; i = i + 1)      cmd_reg[i]   <= 32'd0;
		end else begin
			mem_done  <= 1'b0;
			mount_req <= 1'b0;
			db_start  <= 1'b0;
			act_reset <= 1'b0;
			act_swap  <= 1'b0;

			// ---- host memory transactions ----
			// !mem_done: the framework's SPI receiver keeps `enable` high for
			// the cycle in which it sees `done` (it pops the request on that
			// edge), so that cycle still shows the FINISHED transaction.
			if (ms_done) begin
				mem_done <= 1'b1;
				ms_done  <= 1'b0;
			end else if (mem_enable && !mem_done) begin
				if (is_sdram) begin
					if (mem_write) begin
						// Posted: wq_push stores it this cycle. With wq full the
						// request just waits here; the framework FIFO holds the rest.
						if (!wq_full) begin
							wq_wp   <= wq_wp + 1'd1;
							ms_done <= 1'b1;
							if (mem_address == DISK1_HOST_ADDR) woz_magic <= mem_dataWrite;
						end
					end else begin
						mem_dataRead <= 32'd0;   // no read-back: every file is read-only
						ms_done      <= 1'b1;
					end
				end else begin
					if (mem_write) begin
						if (is_cmd)
							cmd_reg[mem_address[4:2]] <= mem_dataWrite;
						else if (is_local) case (loc)
							// Actions count only while the IIgs runs: settings are
							// also replayed during setup.
							SET_ACT_RESET:   if (mem_dataWrite != 0 && !core_reset) act_reset <= 1'b1;
							SET_ACT_SWAP:    if (mem_dataWrite != 0 && !core_reset) act_swap  <= 1'b1;
							SET_ROM:         set_rom         <= mem_dataWrite;
							SET_SPEED:       set_speed       <= mem_dataWrite;
							SET_PTR_DEFAULT: set_ptr_default <= mem_dataWrite;
							SET_MOUSE:       set_mouse       <= mem_dataWrite;
							SET_VOLUME:      set_volume      <= mem_dataWrite;
							SET_DISK_LIGHT:  set_disk_light  <= mem_dataWrite;
							default: ;
						endcase
					end else begin
						mem_dataRead <= is_cmd   ? cmd_reg[mem_address[4:2]] :
						                is_local ? local_read(loc) : 32'd0;
					end
					ms_done <= 1'b1;
				end
			end

			// ---- SDRAM engine: drain wq ----
			case (e)
			E_IDLE: if (!wq_empty) e <= E_LOAD;   // wq_head is read from wq_rp this cycle
			E_LOAD: begin
				e_addr  <= wq_head[54:32];
				e_hi    <= wq_head[31:16];
				sd_addr <= {wq_head[54:32], 1'b0};
				sd_din  <= wq_head[15:0];
				sd_req  <= 1'b1;
				e       <= E_LO;
			end
			E_LO: if (sd_ack) begin
				sd_req <= 1'b0;
				e      <= E_LO_DROP;
			end
			// The arbiter releases on the edge where the ack falls and passes
			// a new request straight through.
			E_LO_DROP: if (!sd_ack) begin
				sd_addr <= {e_addr, 1'b1};
				sd_din  <= e_hi;
				sd_req  <= 1'b1;
				e       <= E_HI;
			end
			E_HI: if (sd_ack) begin
				sd_req <= 1'b0;
				e      <= E_HI_DROP;
			end
			E_HI_DROP: if (!sd_ack) begin
				wq_rp <= wq_rp + 1'd1;
				e     <= E_IDLE;
			end
			default: e <= E_IDLE;
			endcase

			// ---- command channel ----
			if (cmd_request) begin
				// Not before the posted writes are in SDRAM (FileWriteEnd must
				// mean the file is there).
				if (cmd_state == CS_IDLE && wq_drained) begin
					cmd_state  <= CS_DONE;
					cmd_reg[0] <= 32'd0;
					case (opcode)
					// The firmware waits for "halted" after SetupComplete: not
					// before the game database lookup has finished.
					CMD_GET_STATUS:
						cmd_reg[0] <= (!setup_done || !db_done) ? STATUS_SETUP :
						              run         ? STATUS_CORE_RUN : STATUS_CORE_HALT;
					CMD_SETUP_COMPLETE: begin
						setup_done <= 1'b1;
						db_start   <= 1'b1;
					end
					CMD_CORE_RUN:
						run <= 1'b1;
					CMD_CORE_HALT:
						run <= 1'b0;
					CMD_NOTIFY_FOCUS:
						focus <= cmd_reg[1][0];
					CMD_FILE_WR_START:
						if (!arg_id_ok) cmd_state <= CS_ERROR;
					CMD_FILE_WR_END:
						if (!arg_id_ok) cmd_state <= CS_ERROR;
						else begin
							file_present[arg_id] <= 1'b1;
							file_size[arg_id]    <= cmd_reg[2];
						end
					CMD_FILE_RD_START:
						if (!arg_id_ok) cmd_state <= CS_ERROR;
						else cmd_reg[0] <= file_size[arg_id];
					CMD_FILE_RD_END:
						if (!arg_id_ok) cmd_state <= CS_ERROR;
					default:
						cmd_state <= CS_ERROR;
					endcase
				end
			end else begin
				cmd_state <= CS_IDLE;
			end

			// Present the disk every time the IIgs is released: a halt and
			// re-run reboots it, and a mount is how the machine learns about
			// media (MiSTer's img_mounted semantics).
			run_d <= !core_reset;
			if (!core_reset && !run_d) mount_req <= 1'b1;
		end
	end

	assign dbg_state = {
		16'h4753,                   // "GS" marker
		5'd0,
		e,                          // [10:8] SDRAM engine state
		file_present,               // [7:3]
		rom_loaded,                 // [2]
		run,                        // [1]
		setup_done                  // [0]
	};
	assign dbg_woz_magic = woz_magic;

endmodule

`default_nettype wire
