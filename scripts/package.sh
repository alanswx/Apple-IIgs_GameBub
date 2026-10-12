#!/usr/bin/env bash
#
# Zip the core for the SD card, after `./mill root.buildCore --target
# gamebub_rev4`:
#
#   scripts/package.sh          # -> releases/AppleIIgs_GameBub_<yyyymmdd>.zip
#
# Unzipped at the card's root it creates /cores/alanswx.AppleIIgs/ with the
# metadata, the bitstream, gamedb.bin (built from gamedb/games.tsv) and the
# license. The ROMs (rom3.rom, rom01.rom) are Apple's and never go in it.
set -euo pipefail
cd "$(dirname "$0")/.."

id=$(python3 -c 'import json; print(json.load(open("metadata/core.json"))["metadata"]["id"])')
bit=build/AppleIIgs-gamebub_rev4/AppleIIgs-gamebub_rev4.bit
[[ -f $bit ]] || { echo "no $bit: build the core first" >&2; exit 1; }

python3 tools/mkgamedb.py -o build/gamedb.bin

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
dir=$stage/cores/$id
mkdir -p "$dir"
cp metadata/core.json metadata/files.json metadata/settings.json "$bit" build/gamedb.bin "$dir/"
cp LICENSE "$dir/LICENSE.txt"

mkdir -p releases
zip_path=$PWD/releases/AppleIIgs_GameBub_$(date +%Y%m%d).zip
rm -f "$zip_path"
(cd "$stage" && zip -qr "$zip_path" cores)
unzip -l "$zip_path"
