# Apple IIgs for Game Bub

A port of the [Apple IIgs MiSTer core](https://github.com/alanswx/Apple-IIgs_MiSTer)
to the [Game Bub](https://gamebub.net/) handheld, using the Game Bub Core
Framework (v1.1-beta, in `framework/` as a git submodule and never edited
here). It is aimed at playing 3.5" IIgs games from WOZ images with the
gamepad.

**Status: early alpha, runs on hardware.** On a Game Bub rev 4 it boots
ROM 01 or ROM 3, loads 3.5" WOZ games and plays them with sound. A game
list sets the ROM, CPU speed, input mode and button keys per game, and
an on-screen IIgs keyboard covers the keys the buttons don't. See
[docs/PORT_PLAN.md](docs/PORT_PLAN.md) for the design and progress notes.

## Try it

You need:
* a **Game Bub rev 4** with firmware **v1.1-beta2 or later** (older firmware
  does not list cores on the SD card);
* a **FAT32 microSD card**;
* an **Apple IIgs ROM**: ROM 01 (128 KiB) and/or ROM 3 (256 KiB), the same
  files as MiSTer's `boot1.rom` and `boot.rom`. They are Apple's
  copyrighted code and are not included;
* games as **3.5" WOZ images** (`.woz`, up to 4 MiB).

1. Download the newest `AppleIIgs_GameBub_*.zip` from
   [Releases](https://github.com/alanswx/Apple-IIgs_GameBub/releases) and
   unzip it at the root of the card. It creates `/cores/alanswx.AppleIIgs/`.
2. Copy your ROMs into that folder as `rom01.rom` (ROM 01) and/or
   `rom3.rom` (ROM 3). One is enough; ROM 01 runs more games.
3. Put WOZ files anywhere on the card, for example `roms/AppleIIgs/`. The
   file browser shows at most 100 entries per folder, so split big
   collections into subfolders (`A-C/`, `D-G/`, ...).
4. Start "Apple IIgs" from the Game Bub menu and pick a disk.

## Controls

Select switches between two modes (a quick tap). The game list picks the
mode a game starts in; unknown disks start in mouse mode.

| Button | Mouse mode | Keyboard mode |
|---|---|---|
| D-pad | move the pointer (hold to speed up) | arrow keys |
| A | mouse button | Return |
| B | Space | Space |
| X | Escape | Escape |
| Y | Y | Y |
| L / R | Open Apple / Option (joystick buttons 0 / 1) | same |
| Start | Return | Return |
| Select | tap: switch mode; hold: on-screen keyboard | same |

Games in the list replace these with their own keys, for example Arkanoid's
Start is Escape (pause). A **controls card** shows the current game's
buttons for 10 seconds when it starts; any button closes it.

**On-screen keyboard**: hold Select for half a second to open or close it
(Start also closes it). The d-pad moves, A types the key, B is Delete, X is
Space and Y is Return; a tap of Select moves the keyboard between the top
and bottom of the screen. Control, Open Apple, Option and Shift stay down
until the next key, so Control + Open Apple + Reset restarts the IIgs. The
HELP key shows the controls card again.

**Status icons** (top left): a green floppy while the disk drive runs, and
an orange mouse or red keyboard for 2 seconds after the mode changes.

## Settings

| Setting | What it does |
|---|---|
| Swap Disk | Switch to the second disk (see [Limits](#limits)) |
| Reset | Warm reset of the IIgs |
| ROM (on restart) | Auto (game list, else ROM 01), ROM 3 or ROM 01 |
| CPU Speed | Auto (game list) or 2.8 to 14.3 MHz. The CPU drops to 2.8 MHz while the drive runs, as a real ZipGS does, so this does not speed up loading |
| Start In | Auto (game list), mouse mode or keyboard mode |
| D-pad Mouse Speed | Auto (game list), accelerating, or steady slow / medium / fast |
| Music Volume | Ensoniq DOC volume: original (x4) up to x32 |
| Status Icons | On or off |
| Controls Card at Start | On or off |

"Auto" settings take the game list's value for the disk you picked and fall
back to the default for disks it doesn't know.

## Game list

`gamedb/games.tsv` lists 356 disks with per-game ROM, CPU speed,
starting mode, d-pad mouse speed and button keys, keyed by the CRC32 in each
WOZ header. `tools/mkgamedb.py` turns it into `gamedb.bin`, which ships in
the release zip, so adding a game needs no FPGA rebuild:

```bash
python3 tools/mkgamedb.py --crc "My Game.woz"   # print the disk's key
python3 tools/mkgamedb.py -o build/gamedb.bin   # rebuild; copy to the card
```

The button maps for 128 games come from their manuals (marked `[manual]`)
or from the Control field on
[What is the Apple IIgs?](https://whatisthe2gs.apple2.org.za/) (`[site]`).
Most have not been played on the Game Bub yet; corrections are welcome.

## Limits

* **3.5" disks only.** 5.25" WOZ images are not supported yet (the 5.25"
  controller is left out to save block RAM).
* **No disk changes from the card while a game runs.** The firmware copies
  every file into SDRAM when the core starts and has no way to load another
  one later. The core can preload a second disk named like the first with a
  `.d2` extension (`Game - Disk 1.d2` next to `Game - Disk 1.woz`) and
  switch to it with Swap Disk, but multi-disk games are otherwise limited
  until the firmware can load files on demand.
* **Disks are read-only.** Writes go to the copy in SDRAM and are lost when
  the core exits; games that need to save to their disk can't keep it.
* No keyboard or mouse: the buttons and the on-screen keyboard stand in for
  them.

## Building

```bash
git submodule update --init
source scripts/env.sh                       # Verilator 5.052, Vivado
scripts/lint.sh                             # Verilator lint
sim/run_tb.sh +disk=scratch/roms/game.woz +frames=600 +dump=50   # simulate
./mill root.buildCore --target gamebub_rev4 # bitstream (Vivado 2023.2+)
scripts/package.sh                          # -> releases/AppleIIgs_GameBub_<date>.zip
```

The simulation needs a ROM in `scratch/roms/boot.rom` (ROM 3; `+rom01=` for
ROM 01). [CLAUDE.md](CLAUDE.md) lists the testbench options and project
rules.

## Layout

| Path | What |
|---|---|
| `framework/` | Game Bub framework (submodule, pinned) |
| `chisel/` | Declares the framework interfaces the core uses |
| `rtl/gamebub/` | Game Bub platform layer: host protocol, disk access from SDRAM, video, input, game list lookup, controls card, clocks, constraints |
| `rtl/iigs/` | The IIgs, **imported** from the MiSTer core by `scripts/import_iigs.py`; never edit by hand |
| `rtl/osk/` | On-screen keyboard from [Marty_MiSTer](https://github.com/MiSTer-devel/Marty_MiSTer), **imported** by `scripts/import_osk.py` with the IIgs layout |
| `metadata/` | `core.json`, `files.json`, `settings.json` for the SD card |
| `gamedb/`, `tools/` | The game list and its builder |
| `sim/` | Verilator testbench (`tb_gamebub.sv`) with an MCU and SDRAM model |
| `scripts/` | Imports, lint, packaging, `env.sh` |

## Credits and license

**GPL-3.0** (see [LICENSE](LICENSE)). The IIgs RTL comes from the
[Apple IIgs MiSTer core](https://github.com/alanswx/Apple-IIgs_MiSTer)
(GPL-3.0). Much of the Game Bub platform layer comes from
[MacLC_GameBub](https://github.com/danifunker/MacLC_GameBub) (GPL-3.0). The
on-screen keyboard is Jamie Blanks's, from Marty_MiSTer, used here with the
author's permission. The Game Bub framework is used unmodified under
CERN-OHL-W-2.0 (see `framework/LICENSE`).

Apple's ROMs and the games are not covered by this license and are not
included.
