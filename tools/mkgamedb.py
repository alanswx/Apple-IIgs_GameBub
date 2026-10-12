#!/usr/bin/env python3
"""Build gamedb.bin (the core's per-game settings) from gamedb/games.tsv.

    python3 tools/mkgamedb.py [games.tsv] [-o build/gamedb.bin]
    python3 tools/mkgamedb.py --crc disk.woz ...   # print the lookup key

Copy gamedb.bin into the core's folder on the SD card next to rom3.rom
(files.json file 4). Adding a game needs no Vivado run.

LOOKUP KEY: the CRC32 in bytes 8..11 of every WOZ1/WOZ2 file (the CRC of the
rest of the file). rtl/gamebub/gb_gamedb.sv reads it from the loaded disk.

FORMAT (all little-endian, 16-byte lines so the core reads each with one
SDRAM burst):
  line 0      "GSDB", u8 version (1), u8 0, u16 record count, 8 bytes 0
  line 1..n   u32 crc32
              u8  rom    0 auto, 1 ROM 3, 2 ROM 01
              u8  speed  0..4 (2.8, 3.6, 4.8, 7.2, 14.3 MHz), 0xFF no preference
              u8  input  0 keyboard mode, 1 mouse mode, 0xFF no preference
              u8  mouse  pointer speed in mouse units per d-pad report (100 Hz):
                         [3:0] for the first 0.4 s a direction is held,
                         [7:4] after; 0 = the core's default (1, then 6)
              u64 button map: 9-bit PS/2 set 2 scancodes (bit 8 = E0
                  prefix, 0 = button does nothing), A [8:0], B [17:9],
                  X [26:18], Y [35:27], L [44:36], R [53:45], Start [62:54],
                  bit 63 set
"""
import argparse
import struct
import sys
import zlib
from pathlib import Path

VERSION = 1
MAX_BYTES = 0x10000            # files.json max_size for gamedb.bin

# PS/2 set 2 scancodes the IIgs ADB translation (rtl/iigs/adb.sv) knows.
KEYS = {
    'none': 0x000,
    'return': 0x05A, 'enter': 0x05A, 'space': 0x029, 'esc': 0x076,
    'tab': 0x00D, 'delete': 0x066, 'backspace': 0x066,
    'up': 0x175, 'down': 0x172, 'left': 0x16B, 'right': 0x174,
    'oa': 0x011, 'cmd': 0x011, 'command': 0x011,      # Open Apple
    'option': 0x11F, 'ca': 0x11F,                     # Option / Closed Apple
    'ctrl': 0x014, 'shift': 0x012, 'capslock': 0x058,
    ',': 0x041, '.': 0x049, '/': 0x04A, ';': 0x04C, "'": 0x052,
    '[': 0x054, ']': 0x05B, '-': 0x04E, '=': 0x055, '\\': 0x05D, '`': 0x00E,
    'f1': 0x005, 'f2': 0x006, 'f3': 0x004, 'f4': 0x00C, 'f5': 0x003,
    'f6': 0x00B, 'f7': 0x083, 'f8': 0x00A, 'f9': 0x001, 'f10': 0x009,
}
KEYS.update(zip('abcdefghijklmnopqrstuvwxyz',
                [0x01C, 0x032, 0x021, 0x023, 0x024, 0x02B, 0x034, 0x033, 0x043,
                 0x03B, 0x042, 0x04B, 0x03A, 0x031, 0x044, 0x04D, 0x015, 0x02D,
                 0x01B, 0x02C, 0x03C, 0x02A, 0x01D, 0x022, 0x035, 0x01A]))
KEYS.update(zip('0123456789',
                [0x045, 0x016, 0x01E, 0x026, 0x025, 0x02E, 0x036, 0x03D, 0x03E, 0x046]))

BUTTONS = ['a', 'b', 'x', 'y', 'l', 'r', 'start']
# Must match the defaults in rtl/gamebub/iigs_gamebub.sv (used for unknown disks).
DEFAULT_MAP = {'a': 'return', 'b': 'space', 'x': 'esc', 'y': 'y',
               'l': 'oa', 'r': 'option', 'start': 'return'}

ROMS = {'-': 0, 'auto': 0, 'rom3': 1, '3': 1, 'rom01': 2, '01': 2, '1': 2}
SPEEDS = {'-': 0xFF, '2.8': 0, '3.6': 1, '4.8': 2, '7.2': 3, '14.3': 4,
          '0': 0, '1': 1, '2': 2, '3': 3, '4': 4}
INPUTS = {'-': 0xFF, 'keyboard': 0, 'kbd': 0, 'mouse': 1}


def woz_crc(path):
    data = Path(path).read_bytes()
    if data[:4] not in (b'WOZ1', b'WOZ2'):
        raise ValueError(f'{path}: not a WOZ file')
    crc = struct.unpack_from('<I', data, 8)[0]
    actual = zlib.crc32(data[12:])
    if crc != actual:
        print(f'warning: {path}: header CRC {crc:08x}, file CRC {actual:08x}',
              file=sys.stderr)
    return crc


def parse_map(text, where):
    m = dict(DEFAULT_MAP)
    if text not in ('', '-'):
        for item in text.split(';'):
            btn, _, key = item.partition('=')
            btn, key = btn.strip().lower(), key.strip().lower()
            if btn not in BUTTONS:
                raise ValueError(f'{where}: unknown button {btn!r}')
            if key not in KEYS:
                raise ValueError(f'{where}: unknown key {key!r}')
            m[btn] = key
    word = 0
    for i, btn in enumerate(BUTTONS):
        word |= KEYS[m[btn]] << (9 * i)
    return word | (1 << 63)


def parse_mouse(text, where):
    """'-' default, 'N' steady N, 'S-F' S for 0.4 s then F (1..15)."""
    t = text.strip() or '-'
    if t == '-':
        return 0
    try:
        slow, _, fast = t.partition('-')
        slow, fast = int(slow), int(fast or slow)
    except ValueError:
        raise ValueError(f'{where}: bad mouse {text!r} (-, N or S-F)')
    if not (1 <= slow <= 15 and 1 <= fast <= 15):
        raise ValueError(f'{where}: mouse steps must be 1..15: {text!r}')
    return fast << 4 | slow


def lookup(table, value, what, where):
    v = value.strip().lower() or '-'
    if v not in table:
        raise ValueError(f'{where}: bad {what} {value!r} ({", ".join(table)})')
    return table[v]


def read_tsv(path):
    rows = []
    header = None
    for n, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        cols = line.split('\t')
        if header is None:
            header = [c.strip().lower() for c in cols]
            for need in ('crc32', 'title', 'rom', 'speed', 'input', 'buttons'):
                if need not in header:
                    raise ValueError(f'{path}: header lacks {need!r}')
            continue
        cols += [''] * (len(header) - len(cols))
        rows.append((f'{path}:{n}', dict(zip(header, cols))))
    return rows


def build(rows):
    seen = {}
    recs = []
    for where, r in rows:
        crc = int(r['crc32'], 16)
        if crc in seen:
            raise ValueError(f'{where}: CRC {crc:08x} repeats {seen[crc]}')
        seen[crc] = where
        recs.append(struct.pack('<IBBBBQ', crc,
                                lookup(ROMS, r['rom'], 'rom', where),
                                lookup(SPEEDS, r['speed'], 'speed', where),
                                lookup(INPUTS, r['input'], 'input', where),
                                parse_mouse(r.get('mouse', '-'), where),
                                parse_map(r['buttons'], where)))
    out = b'GSDB' + struct.pack('<BBH', VERSION, 0, len(recs)) + bytes(8) + b''.join(recs)
    if len(out) > MAX_BYTES:
        raise ValueError(f'gamedb.bin would be {len(out)} bytes (max {MAX_BYTES})')
    return out


def main():
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('tsv', nargs='?', default=root / 'gamedb' / 'games.tsv')
    ap.add_argument('-o', '--out', default=root / 'build' / 'gamedb.bin')
    ap.add_argument('--crc', nargs='+', metavar='WOZ', help='print WOZ lookup keys and exit')
    a = ap.parse_args()
    if a.crc:
        for f in a.crc:
            print(f'{woz_crc(f):08x}\t{Path(f).name}')
        return
    data = build(read_tsv(a.tsv))
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    print(f'{out}: {(len(data) - 16) // 16} games, {len(data)} bytes')


if __name__ == '__main__':
    try:
        main()
    except ValueError as e:
        sys.exit(f'error: {e}')
