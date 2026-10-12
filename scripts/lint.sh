#!/usr/bin/env bash
#
# Verilator lint of the whole core, no Vivado needed.
#
#   scripts/lint.sh            # errors + warnings in rtl/gamebub/
#   scripts/lint.sh --all      # every warning, including imported MiSTer RTL
#
# Xilinx primitives come from sim/xilinx_stubs.v. Until rtl/gamebub has a top
# level, every module nothing instantiates is linted as its own top.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/opt/verilator-5.052/bin:$PATH"  # Verilator 5, as scripts/env.sh

# The CPU package must come before its users.
files=(sim/xilinx_stubs.v rtl/iigs/65C816/P65C816_pkg.sv)
while IFS= read -r f; do files+=("$f"); done < <(find rtl -name '*.v' -o -name '*.sv' | grep -v P65C816_pkg | sort)

# The imported MiSTer RTL is lint-noisy by design (Quartus-era idioms); keep
# the categories that matter for the platform layer.
waivers=(-Wno-WIDTH -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME
         -Wno-CASEINCOMPLETE -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN
         -Wno-BLKSEQ -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-GENUNNAMED -Wno-VARHIDDEN
         -Wno-IMPORTSTAR -Wno-LATCH -Wno-COMBDLY -Wno-CASEOVERLAP -Wno-ASCRANGE
         -Wno-PROCASSINIT -Wno-MULTITOP -Wno-CASEX -Wno-INITIALDLY)

log=$(mktemp)
set +e
verilator --lint-only --timing --timescale 1ns/1ps -Wall -Wno-fatal "${waivers[@]}" \
	"${files[@]}" >"$log" 2>&1
status=$?
set -e

if [[ "${1:-}" == "--all" ]]; then
	cat "$log"
else
	grep -E '^%Error' "$log" || true
	grep -E '^%Warning' "$log" | grep -E 'rtl/gamebub/' || true
fi
errors=$(grep -c '^%Error' "$log" || true)
echo "lint: ${errors} error(s) (verilator exit ${status})"
rm -f "$log"
[[ "$errors" == "0" ]]
