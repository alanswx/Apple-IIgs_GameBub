#!/usr/bin/env bash
#
# Build and run the whole-core Verilator testbench (sim/tb_gamebub.sv).
#
#   sim/run_tb.sh                           # boot ROM 3, 300 frames
#   sim/run_tb.sh +frames=60 +dump=10 +raw  # quick look, raw VGC frames too
#   sim/run_tb.sh +disk=scratch/roms/game.woz
#   TAC_PS=12000 TOH_PS=5000 SIM_OBJ=sim/obj_t12 sim/run_tb.sh   # SDRAM read timing
#
# ROMs and disk images stay out of git (scratch/ is ignored). Frames land in
# sim_out/ (or +out=<dir>) as PPM; scripts/ppm2png.py converts them. The build
# is cached in sim/obj_dir (or $SIM_OBJ, so two runs can coexist).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/opt/verilator-5.052/bin:$PATH"   # Verilator 5, as scripts/env.sh

files=(sim/xilinx_stubs.v rtl/iigs/65C816/P65C816_pkg.sv)
while IFS= read -r f; do files+=("$f"); done < <(find rtl -name '*.v' -o -name '*.sv' | grep -v P65C816_pkg | sort)
files+=(sim/tb_gamebub.sv)

obj=${SIM_OBJ:-sim/obj_dir}
verilator --binary --timing -j 0 -O3 --x-assign fast --x-initial fast \
	-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	-GTAC_PS="${TAC_PS:-9000}" -GTOH_PS="${TOH_PS:-7000}" \
	--top-module tb_gamebub --Mdir "$obj" -o Vtb_gamebub \
	"${files[@]}" > "$obj.build.log" 2>&1 || { tail -40 "$obj.build.log"; exit 1; }

out=sim_out
for a in "$@"; do [[ "$a" == +out=* ]] && out=${a#+out=}; done
mkdir -p "$out"
exec "$obj/Vtb_gamebub" "$@"
