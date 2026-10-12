// Uncomment to enable detailed PRTC protocol tracing
// `define DEBUG_PRTC

module prtc(
  input CLK_14M,
  input cen,
  input reset,
  input addr,
  input [32:0] timestamp,
  input [7:0] din,
  output reg [7:0] dout,
  output reg onesecond_irq,
  output reg qtrsecond_irq,
  input rw,
  input strobe, // must be high for one clock enable(cen) only!

  // NVRAM backup port (MiSTer SD save/load).
  // bk_wr strobes land while the SD block streams in; folded into the same
  // always block as the protocol writes (single writer, FPGA-safe).
  input  [7:0] bk_addr,
  input        bk_wr,
  input  [7:0] bk_data,
  output [7:0] bk_q
);

reg old_strobe;
reg [7:0] pram [255:0];
reg [31:0] clock_data;
reg [7:0] c033, c034;

// Debug: transaction counter for tracing
`ifdef DEBUG_PRTC
reg [15:0] prtc_txn_count = 0;
`endif

initial begin
  // Initialize PRAM from hex file - MAME ROM3 nvram/apple2gs/rtc values
  // Bytes 0x00-0x59: ROM defaults, 0x5A-0xFB: 0xFF, 0xFC-0xFF: checksum
  // USERSLTST ($E8) = 0x00 (Scan mode: boot from slot 7 down)
  // Checksum 0xAE1F, Complement 0x04B5 (verified: 0xAE1F XOR 0xAAAA = 0x04B5)
  // [gamebub] rtl/roms/pram_init.hex, inlined by scripts/import_iigs.py
  pram[0] = 8'h00;
  pram[1] = 8'h00;
  pram[2] = 8'h00;
  pram[3] = 8'h01;
  pram[4] = 8'h00;
  pram[5] = 8'h00;
  pram[6] = 8'h0D;
  pram[7] = 8'h06;
  pram[8] = 8'h02;
  pram[9] = 8'h01;
  pram[10] = 8'h01;
  pram[11] = 8'h00;
  pram[12] = 8'h01;
  pram[13] = 8'h00;
  pram[14] = 8'h00;
  pram[15] = 8'h00;
  pram[16] = 8'h00;
  pram[17] = 8'h00;
  pram[18] = 8'h07;
  pram[19] = 8'h06;
  pram[20] = 8'h02;
  pram[21] = 8'h01;
  pram[22] = 8'h01;
  pram[23] = 8'h00;
  pram[24] = 8'h00;
  pram[25] = 8'h00;
  pram[26] = 8'h0F;
  pram[27] = 8'h06;
  pram[28] = 8'h06;
  pram[29] = 8'h00;
  pram[30] = 8'h05;
  pram[31] = 8'h06;
  pram[32] = 8'h01;
  pram[33] = 8'h00;
  pram[34] = 8'h00;
  pram[35] = 8'h00;
  pram[36] = 8'h00;
  pram[37] = 8'h00;
  pram[38] = 8'h00;
  pram[39] = 8'h01;
  pram[40] = 8'h00;
  pram[41] = 8'h00;
  pram[42] = 8'h00;
  pram[43] = 8'h00;
  pram[44] = 8'h05;
  pram[45] = 8'h02;
  pram[46] = 8'h02;
  pram[47] = 8'h00;
  pram[48] = 8'h00;
  pram[49] = 8'h00;
  pram[50] = 8'h2D;
  pram[51] = 8'h2D;
  pram[52] = 8'h00;
  pram[53] = 8'h00;
  pram[54] = 8'h00;
  pram[55] = 8'h00;
  pram[56] = 8'h00;
  pram[57] = 8'h00;
  pram[58] = 8'h02;
  pram[59] = 8'h02;
  pram[60] = 8'h02;
  pram[61] = 8'h06;
  pram[62] = 8'h08;
  pram[63] = 8'h00;
  pram[64] = 8'h01;
  pram[65] = 8'h02;
  pram[66] = 8'h03;
  pram[67] = 8'h04;
  pram[68] = 8'h05;
  pram[69] = 8'h06;
  pram[70] = 8'h07;
  pram[71] = 8'h0A;
  pram[72] = 8'h00;
  pram[73] = 8'h01;
  pram[74] = 8'h02;
  pram[75] = 8'h03;
  pram[76] = 8'h04;
  pram[77] = 8'h05;
  pram[78] = 8'h06;
  pram[79] = 8'h07;
  pram[80] = 8'h08;
  pram[81] = 8'h09;
  pram[82] = 8'h0A;
  pram[83] = 8'h0B;
  pram[84] = 8'h0C;
  pram[85] = 8'h0D;
  pram[86] = 8'h0E;
  pram[87] = 8'h0F;
  pram[88] = 8'h00;
  pram[89] = 8'h00;
  pram[90] = 8'hFF;
  pram[91] = 8'hFF;
  pram[92] = 8'hFF;
  pram[93] = 8'hFF;
  pram[94] = 8'hFF;
  pram[95] = 8'hFF;
  pram[96] = 8'hFF;
  pram[97] = 8'hFF;
  pram[98] = 8'hFF;
  pram[99] = 8'hFF;
  pram[100] = 8'hFF;
  pram[101] = 8'hFF;
  pram[102] = 8'hFF;
  pram[103] = 8'hFF;
  pram[104] = 8'hFF;
  pram[105] = 8'hFF;
  pram[106] = 8'hFF;
  pram[107] = 8'hFF;
  pram[108] = 8'hFF;
  pram[109] = 8'hFF;
  pram[110] = 8'hFF;
  pram[111] = 8'hFF;
  pram[112] = 8'hFF;
  pram[113] = 8'hFF;
  pram[114] = 8'hFF;
  pram[115] = 8'hFF;
  pram[116] = 8'hFF;
  pram[117] = 8'hFF;
  pram[118] = 8'hFF;
  pram[119] = 8'hFF;
  pram[120] = 8'hFF;
  pram[121] = 8'hFF;
  pram[122] = 8'hFF;
  pram[123] = 8'hFF;
  pram[124] = 8'hFF;
  pram[125] = 8'hFF;
  pram[126] = 8'hFF;
  pram[127] = 8'hFF;
  pram[128] = 8'hFF;
  pram[129] = 8'hFF;
  pram[130] = 8'hFF;
  pram[131] = 8'hFF;
  pram[132] = 8'hFF;
  pram[133] = 8'hFF;
  pram[134] = 8'hFF;
  pram[135] = 8'hFF;
  pram[136] = 8'hFF;
  pram[137] = 8'hFF;
  pram[138] = 8'hFF;
  pram[139] = 8'hFF;
  pram[140] = 8'hFF;
  pram[141] = 8'hFF;
  pram[142] = 8'hFF;
  pram[143] = 8'hFF;
  pram[144] = 8'hFF;
  pram[145] = 8'hFF;
  pram[146] = 8'hFF;
  pram[147] = 8'hFF;
  pram[148] = 8'hFF;
  pram[149] = 8'hFF;
  pram[150] = 8'hFF;
  pram[151] = 8'hFF;
  pram[152] = 8'hFF;
  pram[153] = 8'hFF;
  pram[154] = 8'hFF;
  pram[155] = 8'hFF;
  pram[156] = 8'hFF;
  pram[157] = 8'hFF;
  pram[158] = 8'hFF;
  pram[159] = 8'hFF;
  pram[160] = 8'hFF;
  pram[161] = 8'hFF;
  pram[162] = 8'hFF;
  pram[163] = 8'hFF;
  pram[164] = 8'hFF;
  pram[165] = 8'hFF;
  pram[166] = 8'hFF;
  pram[167] = 8'hFF;
  pram[168] = 8'hFF;
  pram[169] = 8'hFF;
  pram[170] = 8'hFF;
  pram[171] = 8'hFF;
  pram[172] = 8'hFF;
  pram[173] = 8'hFF;
  pram[174] = 8'hFF;
  pram[175] = 8'hFF;
  pram[176] = 8'hFF;
  pram[177] = 8'hFF;
  pram[178] = 8'hFF;
  pram[179] = 8'hFF;
  pram[180] = 8'hFF;
  pram[181] = 8'hFF;
  pram[182] = 8'hFF;
  pram[183] = 8'hFF;
  pram[184] = 8'hFF;
  pram[185] = 8'hFF;
  pram[186] = 8'hFF;
  pram[187] = 8'hFF;
  pram[188] = 8'hFF;
  pram[189] = 8'hFF;
  pram[190] = 8'hFF;
  pram[191] = 8'hFF;
  pram[192] = 8'hFF;
  pram[193] = 8'hFF;
  pram[194] = 8'hFF;
  pram[195] = 8'hFF;
  pram[196] = 8'hFF;
  pram[197] = 8'hFF;
  pram[198] = 8'hFF;
  pram[199] = 8'hFF;
  pram[200] = 8'hFF;
  pram[201] = 8'hFF;
  pram[202] = 8'hFF;
  pram[203] = 8'hFF;
  pram[204] = 8'hFF;
  pram[205] = 8'hFF;
  pram[206] = 8'hFF;
  pram[207] = 8'hFF;
  pram[208] = 8'hFF;
  pram[209] = 8'hFF;
  pram[210] = 8'hFF;
  pram[211] = 8'hFF;
  pram[212] = 8'hFF;
  pram[213] = 8'hFF;
  pram[214] = 8'hFF;
  pram[215] = 8'hFF;
  pram[216] = 8'hFF;
  pram[217] = 8'hFF;
  pram[218] = 8'hFF;
  pram[219] = 8'hFF;
  pram[220] = 8'hFF;
  pram[221] = 8'hFF;
  pram[222] = 8'hFF;
  pram[223] = 8'hFF;
  pram[224] = 8'hFF;
  pram[225] = 8'hFF;
  pram[226] = 8'hFF;
  pram[227] = 8'hFF;
  pram[228] = 8'hFF;
  pram[229] = 8'hFF;
  pram[230] = 8'hFF;
  pram[231] = 8'hFF;
  pram[232] = 8'h00;
  pram[233] = 8'hFF;
  pram[234] = 8'hFF;
  pram[235] = 8'hFF;
  pram[236] = 8'hFF;
  pram[237] = 8'hFF;
  pram[238] = 8'hFF;
  pram[239] = 8'hFF;
  pram[240] = 8'hFF;
  pram[241] = 8'hFF;
  pram[242] = 8'hFF;
  pram[243] = 8'hFF;
  pram[244] = 8'hFF;
  pram[245] = 8'hFF;
  pram[246] = 8'hFF;
  pram[247] = 8'hFF;
  pram[248] = 8'hFF;
  pram[249] = 8'hFF;
  pram[250] = 8'hFF;
  pram[251] = 8'hFF;
  pram[252] = 8'h1F;
  pram[253] = 8'hAE;
  pram[254] = 8'hB5;
  pram[255] = 8'h04;

`ifdef DEBUG_PRTC
  // Debug: verify PRAM initialization
  $display("PRTC INIT: pram[00]=%02x pram[03]=%02x pram[06]=%02x pram[07]=%02x",
           pram[8'h00], pram[8'h03], pram[8'h06], pram[8'h07]);
  $display("PRTC INIT: pram[F0]=%02x pram[F7]=%02x pram[FC]=%02x pram[FF]=%02x",
           pram[8'hF0], pram[8'hF7], pram[8'hFC], pram[8'hFF]);
`endif

`ifdef DEBUG_VERBOSE
  // Seed to deterministic values; CTL starts at 0x00 to match early read
  c033 = 8'h06;   // DATA
  c034 = 8'h00;   // CTL initial read returns 0x00
`else
  c033 = 8'h00;
  c034 = 8'h00;
`endif
end

// calculate checksum, not tested!!
// it will start when checksum_state = 1;

parameter
  IDLE = 3'd0,
  WAIT = 3'd1,
  PRAM = 3'd2,
  CLOCK = 3'd3,
  INTERNAL = 3'd4;



reg [24:0] clock_counter;
reg [24:0] clock_counter2;



reg [2:0] state;
reg [1:0] checksum_state;
reg [1:0] checksum_writes;
reg [31:0] checksum;
reg [7:0] counter;
reg [7:0] clk_reg1;

// Flag to indicate a read result is pending (needs one cycle to propagate to c033)
reg read_pending = 1'b0;
reg [7:0] read_result = 8'h00;

// Combinational signals to detect read-in-progress and provide immediate data
wire pram_read_now = strobe && cen && (addr == 1'b1) && ~rw && din[7] && (state == PRAM) && din[6];
wire clock_read_now = strobe && cen && (addr == 1'b1) && ~rw && din[7] && (state == CLOCK) && din[6];
wire [7:0] pram_read_data = pram[clk_reg1];
assign bk_q = pram[bk_addr];
wire [7:0] clock_read_data = clock_data[clk_reg1[1:0]*8+:8];

// Combinational output for dout - must be available immediately, not registered
always @(*) begin
  if (addr == 1'b0 && rw) begin
    // Reading C033 (CLOCKDATA)
    if (pram_read_now)
      dout = pram_read_data;
    else if (clock_read_now)
      dout = clock_read_data;
    else if (read_pending)
      dout = read_result;
    else
      dout = c033;
  end else if (addr == 1'b1 && rw) begin
    // Reading C034 (CLOCKCTL)
    dout = c034;
  end else begin
    dout = 8'h00;
  end
end

// State name decoder for debug
`ifdef DEBUG_PRTC
function [7*8:1] state_name;
  input [2:0] st;
  begin
    case (st)
      3'd0: state_name = "IDLE   ";
      3'd1: state_name = "WAIT   ";
      3'd2: state_name = "PRAM   ";
      3'd3: state_name = "CLOCK  ";
      3'd4: state_name = "INTERNAL";
      default: state_name = "UNKNOWN";
    endcase
  end
endfunction
`endif

reg [31:0] timestamp_prev;
reg clock_initialized;

always @(posedge CLK_14M) begin

  if (reset) begin
    // Initialize all registers on reset
    clock_data <= 32'd0;
    clock_initialized <= 1'b0;
    c033 <= 8'd0;
    c034 <= 8'd0;
    state <= IDLE;
    checksum_state <= 2'd0;
    checksum_writes <= 2'd0;
    checksum <= 32'd0;
    counter <= 8'd0;
    clk_reg1 <= 8'd0;
    clock_counter <= 25'd0;
    clock_counter2 <= 25'd0;
    timestamp_prev <= 32'd0;
    onesecond_irq <= 1'b0;
    qtrsecond_irq <= 1'b0;
    //dout <= 8'd0;
  end
  else begin

    onesecond_irq <= 1'b0;
    qtrsecond_irq <= 1'b0;

    // Initialize clock from timestamp once after reset
    // Use clock_initialized flag instead of checking clock_data==0
    if (!clock_initialized) begin
      clock_data <= timestamp[31:0] + 2082844800; // difference between unix epoch and mac epoch
      timestamp_prev <= timestamp[31:0];
      clock_initialized <= 1'b1;
    end
    // Update clock if timestamp changes (e.g., user sets time)
    else if (timestamp_prev != timestamp[31:0]) begin
      clock_data <= timestamp[31:0] + 2082844800;
      timestamp_prev <= timestamp[31:0];
    end


// Use real hardware timing for both FPGA and simulation
// Modern computers are fast enough to handle this
clock_counter<=clock_counter+1'd1;
clock_counter2<=clock_counter2+1'd1;
if (clock_counter=='d14318181)
begin
	clock_counter<=0;
	onesecond_irq<=1;
	clock_data<=clock_data+1;
	// Note: One-second IRQ fires - omitting log to reduce noise
end
if (clock_counter2=='d3818186)
begin
	clock_counter2<=0;
	qtrsecond_irq<=1;
	// Note: Quarter-second IRQ fires - omitting log to reduce noise
end


  case (checksum_state)
    2'd1: begin
      checksum_state <= 2'd2;
      checksum <= 32'd0;
      counter <= 8'd250;
      checksum_writes <= 2'd0;
    end
    2'd2: begin
      checksum <= {16'd0, checksum[31:16]} + {16'd0, checksum[14:0], 1'b0} + {16'd0, pram[counter+1], pram[counter]};
      if (counter == 8'd0) begin
        checksum <= { checksum[15:0] ^ 16'haaaa, checksum[15:0] };
        checksum_state <= 2'd3;
      end
      else begin
        counter <= counter - 8'd1;
      end
    end
    2'd3: begin
      pram[8'd252 + {6'd0, checksum_writes}] <= checksum[({3'd0, checksum_writes}*8)-1+:8];
      checksum_writes <= checksum_writes + 2'd1;
      if (checksum_writes == 2'd3) checksum_state <= 2'd0;
    end
    default: ;
  endcase


  // c033 (DATA) - dout is now combinationally driven, only handle state updates here
  // Note: read_pending is cleared ONLY when CPU actually reads C033 (strobe && cen)
  if (addr == 1'b0) begin
    if (rw) begin
      // When reading C033, check for pending read result
`ifdef DEBUG_PRTC
      if (strobe && cen)
        $display("PRTC [%0d] C033 READ: state=%s read_pending=%d pram_read_now=%d clock_read_now=%d | read_result=%02x c033=%02x -> dout=%02x",
                 prtc_txn_count, state_name(state), read_pending, pram_read_now, clock_read_now, read_result, c033, dout);
`endif
      // Clear read_pending on actual read transaction (strobe && cen)
      if (read_pending && strobe && cen) begin
`ifdef DEBUG_PRTC
        $display("PRTC [%0d] C033 READ clears read_pending, updating c033 <- %02x", prtc_txn_count, read_result);
`endif
        c033 <= read_result;      // Also update c033 for consistency
        read_pending <= 1'b0;     // Clear ONLY after CPU reads it
      end
    end else begin
`ifdef DEBUG_PRTC
      if (strobe && cen)
        $display("PRTC [%0d] C033 WRITE: %02x (was %02x) state=%s", prtc_txn_count, din, c033, state_name(state));
`endif
      c033 <= din;
    end
  end

  // c034 - dout is now combinationally driven, only handle state updates here
  if (addr == 1'b1) begin
    if (rw) begin
`ifdef DEBUG_PRTC
      if (strobe && cen)
        $display("PRTC [%0d] C034 READ: %02x state=%s", prtc_txn_count, c034, state_name(state));
`endif
    end else begin
`ifdef DEBUG_PRTC
      if (strobe && cen)
        $display("PRTC [%0d] C034 WRITE: %02x (bit7=%d bit6=%d) state=%s c033=%02x",
                 prtc_txn_count, din, din[7], din[6], state_name(state), c033);
`endif
      c034 <= {1'b0, din[6:0]};
    end
  end

`ifdef DEBUG_PRTC
  if (strobe && cen)
    prtc_txn_count <= prtc_txn_count + 1;
`endif

  // old_strobe <= strobe;
  if (strobe && cen) begin

    // write c034 (CTL)
    if (addr == 1'b1 && ~rw) begin

      if (din[7]) begin // start transaction (bit 7 = 1)
`ifdef DEBUG_PRTC
        $display("PRTC [%0d] === EXECUTE: C034 write with bit7=1, c033=%02x, din=%02x (bit6=%d==%s) state=%s ===",
                 prtc_txn_count, c033, din, din[6], din[6] ? "READ" : "WRITE", state_name(state));
`endif
        // FIX: Execute single-step operations immediately in the same cycle.
        // The original code used state transitions (IDLE->PRAM->IDLE) with
        // non-blocking assignments, which meant the target state logic wouldn't
        // execute until another strobe came (which the ROM never sends).
        // Now we execute the operation directly when the command is received.

        case (state)

          IDLE: begin
            // Command byte decoding (based on KEGS/Clemens implementation):
            // - bits 6:4 = operation type (op)
            // - bits 3:2 = register index (for clock) or address (for BRAM)
            // - bit 7 = read flag (z: 1=read, 0=write)
            //
            // op=0 (000): Clock/time registers
            // op=2 (010): BRAM 0x10-0x13
            // op=3 (011): Internal regs (bit3=0) or Extended BRAM (bit3=1)
            // op=4,5,6,7 (1xx): BRAM 0x00-0x0F
`ifdef DEBUG_PRTC
            $display("PRTC [%0d] IDLE: cmd byte c033=%02x (%08b) op[6:4]=%d",
                     prtc_txn_count, c033, c033, (c033>>4)&7);
`endif
            casez (c033)
              8'b?000????: begin // op=0: clock register
                // Two-phase protocol: save register index, transition to CLOCK state
                // The actual read/write happens in CLOCK state based on din[6]
                clk_reg1[1:0] <= c033[3:2]; // clock register index (0-3)
`ifdef DEBUG_PRTC
                $display("PRTC [%0d]   -> CLOCK cmd: reg=%d (seconds byte %0d), next C034 will %s",
                         prtc_txn_count, c033[3:2], c033[3:2], din[6] ? "READ" : "be ignored (need 2nd C034)");
`endif
                state <= CLOCK;
              end
              8'b?010????: begin // op=2: BRAM 0x10-0x13
                // Two-phase: save address, transition to PRAM state
                clk_reg1 <= {6'b000100, c033[3:2]}; // address 0x10-0x13
`ifdef DEBUG_PRTC
                $display("PRTC [%0d]   -> PRAM 0x10-0x13 cmd: addr=$%02x, next C034 will %s",
                         prtc_txn_count, {6'b000100, c033[3:2]}, din[6] ? "READ" : "be ignored");
`endif
                state <= PRAM;
              end
              8'b?0110???: begin // op=3, bit3=0: internal registers
`ifdef DEBUG_PRTC
                $display("PRTC [%0d]   -> INTERNAL cmd: c033=%02x (test/write-protect)", prtc_txn_count, c033);
`endif
                // Internal registers are mostly no-ops (test reg, write protect)
                state <= INTERNAL;
              end
              8'b?0111???: begin // op=3, bit3=1: BRAM extended (first byte)
`ifdef DEBUG_PRTC
                $display("PRTC [%0d]   -> EXTENDED PRAM (phase 1): high_addr[7:5]=%d, waiting for phase 2",
                         prtc_txn_count, c033[2:0]);
`endif
                // Three-phase: save high address bits, wait for second byte
                clk_reg1[7:5] <= c033[2:0];
                state <= WAIT;
              end
              8'b?1??????: begin // op=4,5,6,7: BRAM 0x00-0x0F
                // Two-phase: save address, transition to PRAM state
                clk_reg1 <= {4'b0, c033[5:2]}; // address 0x00-0x0F
`ifdef DEBUG_PRTC
                $display("PRTC [%0d]   -> PRAM 0x00-0x0F cmd: addr=$%02x, next C034 will %s",
                         prtc_txn_count, {4'b0, c033[5:2]}, din[6] ? "READ" : "be ignored");
`endif
                state <= PRAM;
              end
              default: ;
            endcase
          end

          WAIT: begin // BRAM extended address - second byte received
            // Three-phase protocol:
            // Phase 1: First cmd byte -> WAIT state, save high addr bits
            // Phase 2: Second cmd byte -> PRAM state, save low addr bits (DON'T execute yet)
            // Phase 3: Final C034 write with bit6=read flag -> PRAM state executes read/write
            //
            // Save the full address and transition to PRAM state for final execution
            clk_reg1 <= {clk_reg1[7:5], c033[6:2]}; // full 8-bit address
`ifdef DEBUG_PRTC
            $display("PRTC [%0d] WAIT (phase 2): low_addr from c033=%02x -> full_addr=$%02x, next C034 will execute",
                     prtc_txn_count, c033, {clk_reg1[7:5], c033[6:2]});
`endif
            state <= PRAM;
          end

          // PRAM state: execute the extended BRAM read/write
          // din[6] (c034 bit 6): 1=read, 0=write
          PRAM: begin
            state <= IDLE;
            if (din[6]) begin // read (c034 bit 6 = 1)
              // Set read_result and flag so CPU can read immediately
              read_result <= pram[clk_reg1];
              read_pending <= 1'b1;
`ifdef DEBUG_PRTC
              $display("PRTC [%0d] PRAM EXECUTE READ: addr=$%02x -> data=$%02x (setting read_pending=1)",
                       prtc_txn_count, clk_reg1, pram[clk_reg1]);
`endif
            end else begin
`ifdef DEBUG_PRTC
              $display("PRTC [%0d] PRAM EXECUTE WRITE: addr=$%02x <- data=$%02x (was $%02x)",
                       prtc_txn_count, clk_reg1, c033, pram[clk_reg1]);
`endif
              pram[clk_reg1] <= c033;
            end
          end

          CLOCK: begin
            // Execute clock read/write based on din[6] (c034 bit 6)
            state <= IDLE;
            if (din[6]) begin // read (c034 bit 6 = 1)
              // Set read_result and flag so CPU can read immediately
              read_result <= clock_data[clk_reg1[1:0]*8+:8];
              read_pending <= 1'b1;
`ifdef DEBUG_PRTC
              $display("PRTC [%0d] CLOCK EXECUTE READ: reg=%d -> data=$%02x (setting read_pending=1)",
                       prtc_txn_count, clk_reg1[1:0], clock_data[clk_reg1[1:0]*8+:8]);
`endif
            end else begin // write (c034 bit 6 = 0)
`ifdef DEBUG_PRTC
              $display("PRTC [%0d] CLOCK EXECUTE WRITE: reg=%d <- data=$%02x",
                       prtc_txn_count, clk_reg1[1:0], c033);
`endif
              clock_data[clk_reg1[1:0]*8+:8] <= c033;
            end
          end

          INTERNAL: begin
`ifdef DEBUG_PRTC
            $display("PRTC [%0d] INTERNAL: no-op, returning to IDLE", prtc_txn_count);
`endif
            state <= IDLE;
            // Internal registers are no-ops
          end

          default: ;
        endcase

      end else begin
`ifdef DEBUG_PRTC
        $display("PRTC [%0d] C034 write with bit7=0 (no execute), just updating border/ctrl bits", prtc_txn_count);
`endif
      end

    end

  end

  end // else !reset

  // NVRAM backup load (SD -> pram). Last assignment in the block so it wins
  // over a same-cycle protocol/checksum write (loads happen at mount/OSD time
  // while the machine is idle, so collisions are theoretical anyway).
  if (bk_wr) pram[bk_addr] <= bk_data;

end

endmodule
