# Apple IIgs for Game Bub

A port of the Apple IIgs MiSTer core (`../Apple-IIgs_MiSTer`) to the Game Bub
handheld, aimed at playing a curated set of read-only WOZ games with the
gamepad. Read `docs/PORT_PLAN.md` first: it holds the design, the hardware
and framework constraints, the block-RAM budget, the reuse list and the phases.

## Environment (misterubuntu)

* `source scripts/env.sh` puts Verilator 5.052 (`~/opt/verilator-5.052`) and,
  once installed, Vivado on the PATH. The system Verilator in `/usr/local/bin`
  is 4.204; don't use it.
* `./mill root.compile` compiles the framework and our Chisel wrapper.
  `./mill root.buildCore --target gamebub_rev4` builds the bitstream (needs
  Vivado 2023.2+; this box has 2025.2 ML Standard, Artix-7 only, in
  `~/vivado`, i.e. `~/vivado/2025.2/Vivado`).
* `scripts/lint.sh` lints the whole core with Verilator (no Vivado).
* `sim/run_tb.sh` builds and runs the whole-core testbench
  (`sim/tb_gamebub.sv`: MCU host model, SDRAM model with real read timing,
  frame capture). ROMs and disks go in the ignored `scratch/` folder
  (default ROM: `scratch/roms/boot.rom`); e.g. `sim/run_tb.sh
  +disk=scratch/roms/game.woz +frames=600 +dump=50 +raw`. About 3 s of wall
  time per IIgs frame. `scripts/ppm2png.py sim_out/*.ppm` converts frames.
  `python3 scripts/import_iigs.py` re-imports `rtl/iigs/` from upstream.
* Per-game settings live in `gamedb/games.tsv`; `tools/mkgamedb.py` builds
  `build/gamedb.bin` (`--crc disk.woz` prints a disk's key; the testbench
  takes `+gamedb=build/gamedb.bin`). `scripts/package.sh` zips the SD-card
  folder (metadata, bitstream, gamedb.bin) into `releases/`.
* Chisel elaboration alone (prints the `iigs_gamebub` port template, no
  Vivado): `./mill -i --no-build-lock root.runMain platform.handheld.HandheldTop
  AppleIIgs 4 --target-dir=<dir>`.
* References next to this repo: `../MacLC_GameBub` (the port we copy from),
  `../core-example` (official template), `../gamebub` (firmware and built-in
  cores).

## Rules

* **Never modify `framework/`.** The Game Bub docs forbid it; request missing
  features upstream instead.
* Imported upstream RTL is copied by a script with exact-text patches and is
  never hand-edited. Record the upstream commit it came from.
* No `` `include `` or `` `define `` reliance in `rtl/` (the build passes
  none); `.v` files are renamed `.sv`; only RTL and `.xdc` files under `rtl/`.
* Never commit ROMs, WOZ or other disk images (see `.gitignore`).
* License: GPL-3.0 (upstream IIgs core and MacLC_GameBub are GPL-3).
