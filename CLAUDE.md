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
  Vivado 2023.2+; this box has 2026.1 in `~/vivado`. 2026.1's free tier
  needs a license file renewed yearly and limits the ILA).
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
