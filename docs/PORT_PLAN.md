# Apple IIgs on Game Bub: port plan

Written 2026-10-11 from a research pass over the Game Bub docs, the IIgs
MiSTer core and the Mac LC Game Bub port. Nothing here has been built yet;
block-RAM figures for the IIgs are estimates from reading the RTL, not tool
reports. Treat every number marked "est." as something to confirm with the
first Vivado run.

## 1. Goal: a "consolized" IIgs

Not a general-purpose IIgs. Game Bub has 12 buttons and no keyboard, so the
GS/OS Finder is not useful. Instead:

* The user drops known **WOZ** images of IIgs games on the microSD card and
  picks one from the firmware's file browser. The game boots directly.
* Disks are **read-only on the card**. Writes go to the SDRAM copy and are
  discarded at exit (some games refuse a write-protected disk or want to save
  high scores).
* A **game database** (`games.tsv`, see section 6) identifies each disk and
  supplies per-game settings: ROM version, RAM size, CPU speed, input mode,
  button-to-key map.
* The gamepad acts as a **joystick or a mouse** depending on the game.
* Target: roughly the top 25 IIgs games (Zany Golf, Arkanoid, Shufflepuck
  Café, Lemmings, Crystal Quest, Dungeon Master, Battle Chess, Bubble Ghost,
  Out of This World, Rastan, Task Force, Xenocide, Sword of Sodan, The
  Immortal, Thexder, Marble Madness, ...). Skip games that need a hard disk
  or a lot of typing (Sierra adventures, Wolfenstein 3D GS).

## 2. Where things are

On `misterubuntu` (x86-64 Ubuntu 24.04, 16 cores, 62 GB):

| Path | What |
|---|---|
| `~/mister/iigs/Apple-IIgs_GameBub` | this repo |
| `~/mister/iigs/Apple-IIgs_GameBub/framework` | submodule, github.com/gamebub/framework (v1.1-beta, `db9d3b0`, same commit MacLC pins) |
| `~/mister/iigs/Apple-IIgs_MiSTer` | upstream IIgs core, branch `scc-printer-port` (github.com/alanswx/Apple-IIgs_MiSTer) |
| `~/mister/iigs/MacLC_GameBub` | reference port (github.com/danifunker/MacLC_GameBub), GPL-3.0-or-later |
| `~/mister/iigs/core-example` | official template (github.com/gamebub/core-example) |
| `~/mister/iigs/gamebub` | main Game Bub repo (firmware + built-in GB/GBA cores), reference only |
| `~/opt/verilator-5.052` | Verilator 5 (the system `/usr/local/bin/verilator` is 4.204; don't use it) |

Docs: <https://docs.gamebub.net/developing-cores/overview/> and the
`reference-interfaces`, `reference-metadata`, `core-structure`, `packaging`
pages next to it. Read MacLC's `docs/PORT_PLAN.md`, `docs/FRAMEWORK_ISSUES.md`
and `docs/BUILDING.md` before starting; most of their lessons apply here.

## 3. Game Bub hardware and framework constraints

* FPGA **XC7A100T** (`xc7a100tcsg324-1`): ~63k LUT6, 135 BRAM36, 240 DSP.
* **SDRAM**: W9825G6KH, 32 MiB, 16-bit. Docs say 64 MiB across 2 chips, but
  MacLC found the second chip unwired in v1.1 (their issue #7). Plan on 32.
* **SRAM**: 512 KiB async, 16-bit, 10 ns. Free for us to use.
* **Clock**: one 50 MHz oscillator; the core owns an MMCM and must supply
  `clocks.system`, `clocks.display` (net named `clk_dpi`, ≤ ~29.7 MHz because
  of a framework back-porch bug, MacLC issue #3) and an SPI clock ≥ 160 MHz.
  The whole framework, including host register access, runs on our system
  clock.
* **Video**: the core streams pixels through `VideoV0` (width, height,
  per-channel depth, frame period). The framework **double-buffers the whole
  frame in BRAM** (2 × W × H × bpp) and integer-scales it, centred, to the
  720×480 panel / 720×480p HDMI.
* **Audio**: `AudioV0`, signed 16-bit L/R levels, framework samples at 48 kHz.
* **Input**: 12 buttons via `InputV0`. No USB host, keyboard, mouse or touch.
* **Files**: up to 8 entries in `files.json`. The MCU copies each whole file
  into core memory at start (FileWriteStart / data / FileWriteEnd) and copies
  non-read-only files back at exit. **No on-demand sector reads.** The MCU
  streams at a fixed rate and the framework silently drops words the core
  can't accept in time: copy MacLC's posted-write queue in `gb_host.sv`.
  `max_transfer_speed` must be ≥ 5000.
* A `dependent_on_0` file takes File 0's path with its own extension, e.g.
  File 0 `/games/Zany Golf.woz` → `/games/Zany Golf.d2`. Use this for second
  disks (to verify: that a missing optional dependent file is skipped cleanly).
* **The framework must not be modified** (docs, overview page). Missing
  features are requested upstream.
* Build: `./mill root.buildCore --target gamebub_rev4` (Chisel elaboration,
  then Vivado via edalize). Every `.v/.sv/.vhdl/.xdc` under `rtl/` is
  collected. No include paths or macros are passed, so inline `` `include ``
  and `` `define ``; rename `.v` to `.sv`; keep non-RTL files out of `rtl/`.
* Firmware ≥ 1.1-beta2 runs SD-card cores from `/cores/<id>/` with
  `core.json`, `files.json`, `settings.json` and the `.bit`.

## 4. The IIgs MiSTer core, as it relates to this port

* Portable RTL is all under `rtl/`: `iigs.sv` (top), `mmu.sv`, `65C816/`,
  `vgc.v` + `video_timing.v`, `sound.v` (+ `soundglu.v`, `es5503.v`,
  `syncram.v`), `adb.v`, `prtc.v`, `iwm_woz.v` (+ `iwm_flux.v`,
  `flux_drive.v`, `smartport_dev.v`), `woz_floppy_controller.sv`, `hdd.v`,
  `clock_divider.v`, `paddle_timer.v`, `zipgs_regs.sv`, `twgs_*`, SCC/UART.
* MiSTer-only: `Apple-IIgs.sv` (`emu`, hps_io, OSD, ROM download, PRAM on SD
  slot 4) and `sys/`. **Exception:** `rtl/sound.v` uses `sys/iir_filter.v`.
* Clocks: 14.318 MHz `clk_sys` (CPU with `phi2` enable), 28.636 MHz
  `clk_vid`, 114.545 MHz SDRAM. CPU speed steps 2.86–14.32 MHz via
  `clock_divider.v`.
* Memory: 8 MB fast RAM (`RAMSIZE=128` banks) in SDRAM; ROM3 (256 KB) at
  SDRAM FC0000, ROM01 (128 KB) at F80000; slow RAM E0/E1 (128 KB) in
  dual-port BRAM because video reads it. `sdram_burst.sv` (4 channels,
  CL3 @ 114.5 MHz, MT48LC16M16A2 geometry = same as Game Bub's chip) +
  `sdram_cache.sv` for accelerated speeds.
* Video: 912×262 total, 640×200 active (SHR; 320 mode pixel-doubled; Apple II
  modes 560×192 centred), 744×240 with border, 14.318 MHz pixel rate,
  12-bit SHR palette → 8:8:8 out.
* Audio: ES5503 + GLU, 16-bit signed stereo.
* Floppy: `woz_floppy_controller.sv` parses WOZ1/WOZ2 only and copies whole
  tracks into BRAM via hps_io `sd_*` 512-byte blocks.
* Input: ADB from MiSTer `ps2_key[10:0]` / `ps2_mouse[24:0]`; paddles from
  analog joystick; RTC from `TIMESTAMP`.
* Altera IP to replace: `rtl/pll.v` → MMCM; `rtl/dpram_bram.vhd`
  (altsyncram, the only VHDL) → `rtl/bram.sv` (behavioural; check Vivado
  infers it); `altddio_out` in `sdram_burst.sv` → `ODDR`.

### Block RAM estimate (from RTL, est.)

| Memory | Size | Plan |
|---|---|---|
| Slow RAM E0/E1 | 1 Mbit | keep (or SRAM if short) |
| 3.5" track buffers (2 sides) | 1 Mbit | **remove**: read track bits from the WOZ in SDRAM |
| ES5503 sound RAM | 512 Kbit | keep, or SRAM |
| TWGS cache + ROM | 768 Kbit | **drop** TWGS |
| 5.25" track buffer | 256 Kbit | drop (5.25" later, if ever) |
| 65C816 microcode | ~106 Kbit | keep |
| char ROM, DHR LUT, ADB ROMs, misc | ~150 Kbit | keep |

Unchanged core ≈ 122 BRAM36 (est.). After the plan above ≈ 45–55.

Video budget: 640×200 at 9 bpp (3:3:3), double-buffered = 128K × 9 × 2 ≈ 64
BRAM36 (9-bit width packs well; 12 bpp packs badly, ~96). MacLC's
framework-plus-core overhead suggests ~20 for the framework. Total ≈ 130 of
135: tight. If short, move sound RAM and/or slow RAM to the SRAM (10 ns SRAM
has many slots per 70 ns 14 MHz tick).

## 5. Known problem: 640×200 on a 720×480 panel

The framework scales uniformly by an integer, so 640×200 shows as a squashed
strip at 1×. Declaring 640×400 doubles the framebuffer (~128 BRAM36): no fit.
Since we may not modify the framework, options are:

1. Ask upstream for per-axis integer scale (x1, y2) or a "line-double"
   flag on `VideoV0`. Best answer; file it with a clear BRAM rationale.
2. Ship v0 with the squashed 1× image until (1) lands.
3. Investigate whether the framework's buffer can be fed 640×200 while
   something else doubles lines (it can't from the core side as far as we
   know; confirm by reading `HandheldTop` scan-out in the framework).

Drop the border (send only the 640×200 active area). Use MacLC's
`gb_video_out.sv` 4×4 Bayer dither to 3:3:3.

**Chosen (phase 2): 320×200.** Super Hi-Res 320 mode, which nearly every
IIgs game uses, reaches the VGC output as pixel pairs, so `gb_video_out`
averages each pair and declares a 320×200 `VideoV0`. The framework scales it
×2 to 640×400 on the panel, at the right aspect ratio, and its
double-buffered store is 2 × 64000 × 9 bits (~32 BRAM36) instead of ~64.
640 mode and 80-column text blend pixel pairs: acceptable for games. A
640×200 build stays possible (`HALVE=0` and the Scala `videoWidth`), and
the upstream request in (1) is still worth filing for it.

## 6. Game database (`games.tsv`)

* One row per known WOZ image. Columns (draft):
  `md5  woz_crc32  size  title  disk  of  rom  ram_kb  speed  input
  mouse_speed  buttons  notes`
  e.g. `buttons` = `A=mouse;B=key:space;Start=key:return;Select=key:esc;L=swap`.
* **Lookup key: the WOZ header CRC32** (bytes 8–11 of every WOZ1/WOZ2 file,
  CRC32 of the rest of the file; Applesauce always fills it in). The core reads
  it from SDRAM after load: no hashing in hardware. md5 stays in the TSV for
  humans and to catch collisions.
* `tools/` script turns `games.tsv` into a small fixed-format `gamedb.bin`,
  loaded as a fixed-name file from the core directory (`filename` in
  `files.json`), so adding games needs no Vivado rebuild.
* Unknown disk: defaults (ROM3, 1 MB, normal speed, mouse mode) and its CRC
  shown on the PMOD debug beacon so it can be added.
* Seed the list from the 4am / Applesauce IIgs WOZ collections on archive.org;
  fill md5/crc/size automatically, ROM/input/buttons by hand while testing.
* Extra keys a game needs but has no button for go in `settings.json` actions
  (max 16 settings): "Press Y / N / 1 / 2 / Esc", "Swap disk", "Reset".

Draft `files.json`: 0 = game disk 1 (`user_selected`, `read_only`, `.woz`),
1 = disk 2 (`dependent_on_0`, ext `d2`, optional, read-only), 2 = ROM3 (fixed
filename), 3 = ROM01 (fixed filename, optional), 4 = `gamedb.bin` (fixed).

## 7. Clocks (proposed)

One MMCM: 50 MHz × 20.625 = 1031.25 MHz VCO.

| Out | Divide | Freq | Use |
|---|---|---|---|
| sys | 72 | 14.323 MHz | `clk_sys` / framework system clock (0.03% fast) |
| vid | 36 | 28.646 MHz | `clk_vid`; also usable as `clk_dpi` (≤ 29.7) |
| mem | 18 or 9 | 57.29 / 114.58 MHz | SDRAM (start at 57 MHz CL2; easier timing) |
| spi | 6 | 171.9 MHz | framework SPI receiver (≥ 160) |

At 14.3 MHz system clock the MCU's one-word-per-800 ns stream is ~11 clocks
per word: fine with MacLC's posted-write queue (2 clocks/word).

## 8. What to reuse from MacLC_GameBub (GPL-3.0-or-later)

* `rtl/gamebub/gb_host.sv`: HostV0 command FSM, settings registers, SDRAM
  file window with posted-write queue and read-ahead, byte-order detection
  (replace the Mac `0x35` ROM check with a IIgs/WOZ signature: `"WOZ"` at
  offset 0 of File 0 is an easy one).
* `gb_blockdev.sv` (hps_io `sd_*` look-alike over SDRAM): useful if we keep
  the existing floppy controller's block interface at first, before switching
  it to direct SDRAM track reads.
* `gb_clocks.sv`, `gb_video_out.sv`, `gb_pad_input.v` (buttons →
  `ps2_key`/`ps2_mouse`), `gb_eth_arb.sv` (2-client arbiter),
  `gb_vram_sram.sv` (SRAM controller pattern), `gb_debug_uart.sv` (PMOD
  beacon).
* `scripts/import_maclc.py` pattern: copy upstream RTL with exact-text
  patches, never hand-edit imported files, record the upstream commit.
* `sim/tb_gamebub.sv` (MCU protocol model with paced streaming, SDRAM/SRAM
  models), `sim/xilinx_stubs.v`, `scripts/lint.sh`, `scripts/debug/*.tcl`.
* `chisel/src/MacLC.scala` as the `bindExtModule` template (also see
  `core-example/chisel/src/DemoCore.scala`).

The IIgs repo also has its own Verilator harness (`vsim/`) that boots games;
useful for checking the stripped-down core before the Game Bub testbench.

## 9. Phases

1. **Import**: `scripts/import_iigs.py` copies the needed RTL from
   `../Apple-IIgs_MiSTer` into `rtl/iigs/` with patches (Altera IP, includes,
   `$readmemh` inlining, `.v`→`.sv`, `sys/iir_filter.v`). Lint with Verilator 5.
2. **Strip**: new `rtl/gamebub/iigs_core.sv` replacing `Apple-IIgs.sv`: no
   hps_io/OSD, no HDD, no TWGS, no PRAM file, no 5.25". Chisel wrapper `chisel/src/AppleIIgs.scala`, metadata.
3. **Simulate**: boot a WOZ game in a MacLC-style whole-core testbench
   (frames to PNG). First milestone: ROM3 boot screen, then Zany Golf title.
4. **Floppy from SDRAM**: rework the WOZ controller to fetch track bits from
   the in-SDRAM image (small prefetch FIFO), RAM-only writes.
5. **Game db + input**: `games.tsv` → `gamedb.bin`, per-game button map,
   mouse/joystick modes, settings actions.
6. **Vivado**: first build, utilization, timing; adjust BRAM/SRAM split.
7. **Hardware**: SD card layout, PMOD beacon, SDRAM phase tuning.
8. **Upstream**: file the video line-doubling request (section 5).

### Phase 1–2 status (2026-10-11)

Done: import (`scripts/import_iigs.py`, upstream `bf80e6d`), the Game Bub
top (`rtl/gamebub/iigs_gamebub.sv`, `iigs_core.sv`, `gb_*`), Chisel wrapper,
metadata. Verilator lint clean; Chisel elaboration's port template matches.
Decisions that differ from the sections above:

* **SDRAM at 114.58 MHz, CL3, as upstream**, not 57 MHz: the native CPU read
  path (ch3) is timed for it. Upstream has no SDRAM timing constraints;
  `rtl/gamebub/iigs.xdc` is a first pass, and the read-capture window
  (sampled two clk_mem edges after the chip edge) is the main hardware risk.
* **ch2 gained single-word reads** (import patch). It carries the host file
  window (writes) and `gb_blockdev` (the WOZ controller's sectors, from the
  image in SDRAM). The CPU channels are unchanged.
* **No byte-order detection**: the firmware sends file bytes least
  significant first (`write_u32` uses `to_le_bytes`, files go through the
  same SPI word path), which is the IIgs SDRAM layout; MacLC's ROM fixup is
  not needed.
* **SCC kept** (the ROM probes it); HDD and TWGS are stubs; 5.25" drive not
  instantiated. **RAMSIZE is an elaboration parameter** of `iigs.sv`, so it
  cannot come from the game db: fixed at upstream's 8 MB.
* **Disk 2** (`.d2`) is swapped into the single 3.5" drive by the "Swap Disk"
  action (eject + insert).
* Video crop (`CROP_X`/`CROP_Y` in `gb_video_out.sv`) is a guess until the
  phase 3 simulation shows the active area.

### First Vivado build and simulation (2026-10-12)

Vivado 2025.2 builds a bitstream that meets every timing constraint
(34% LUTs, 124 of 135 block RAMs: phase 4's track-buffer removal is needed
for headroom). The whole-core testbench (`sim/run_tb.sh`, below) boots
ROM 3 to its "Apple IIgs / ROM Version 3" screen with every SDRAM read
checked against the model. What it took:

* **Import patches**: `es5503` declares `ca` as a wire but assigns it in an
  always block (Vivado rejects it); `sdram_burst` enables the data bus from
  the start of a write round (one register drives 16 tristates, so it cannot
  sit in the I/O blocks and missed the chip's write setup by 0.3 ns).
* **`bram_ce` builds memories deeper than 32K as explicit 32K banks**:
  Vivado cascaded RAMB36 pairs for the 128K slow RAM and failed DRC
  REQP-1962 at placement.
* **SDRAM read capture**: the simulation proved `sdram_burst` samples a beat
  1.5 clk_mem periods after the chip edge that launched it (with no I/O
  delay in the model, every read returned the next word). On this board
  Vivado then showed setup +1.9 / hold -0.7 ns; `gb_sdram_idelay` puts a
  fixed IDELAYE2 (9 taps, reference 206.25 MHz from the MMCM) on each DQ
  pin, giving +0.29 / +0.16 ns. `iigs.xdc` documents the constraints. The
  margin is real but small: if hardware shows read errors, retune `TAPS`
  (about 76 ps each) first.
* **Video window**: `vgc.sv` draws Super Hi-Res at H 44..683 and lines
  19..218 of the 744 x 240 picture, so `CROP_X = 44`, `CROP_Y = 19`
  (checked on GS/OS's Super Hi-Res "Welcome to the IIgs" box).
* **Floppy speed and the native CPU deadline.** Booting Arkanoid's WOZ, the
  first block device (one SDRAM word per round trip, ~10 ms per track
  load) let the ROM step ahead of the loads, and the boot ran off the disk
  and was ejected; upstream's simulator, built from the same commit, reached
  the GS/OS loader. ch2 reads are now burst-8 lines into their own register
  (import patch), and `gb_blockdev` fetches a line ahead while sending
  bytes (~75 us a sector). But a 19-cycle ch2 burst can make the CPU's
  native ch3 read miss its fixed deadline (data within ~23 clk_mem of the
  request; upstream's worst case is 21), which no data check sees: the
  testbench now measures ch3 latency and compares the byte the CPU latches
  at each phi2 with memory. `iigs_core` only starts a ch2 read 2 clk_sys
  after phi2 at native speed (the gap between two CPU reads), so the worst
  case is 22 and 8.7 M CPU reads during track loading were all correct.
  With that the Arkanoid WOZ reaches the GS/OS loader in step with upstream
  (frame 600-700). Sector loads match the image byte for byte. A 2000-frame
  run reaches Arkanoid's Taito "Fun Time Arcade" intro at frame 2000, the
  same picture upstream's simulator shows there, with 62.5 M SDRAM reads,
  62 M CPU reads and 4.2 MB of sector data all correct.

## 10. Open questions

* ~~Does a missing optional `dependent_on_0` file get skipped cleanly?~~
  Yes: firmware `core/mod.rs` skips an optional file it cannot open.
* Exact framework BRAM overhead (overlay, line buffers) on rev 4.
* Which games need ROM01 vs ROM3, and how much RAM each needs.
* Mouse feel on a d-pad for Arkanoid: may need a per-game "horizontal only,
  fast" mode.
* No RTC from the host: use a build-time timestamp as MacLC does.
