#!/usr/bin/env python3
"""Import Marty_MiSTer's on-screen keyboard into rtl/osk/, as an Apple IIgs
keyboard.

    python3 scripts/import_osk.py [--src ../Marty_MiSTer]

From Marty_MiSTer rtl/osk/ (Jamie Blanks, 2026; used in this GPL-3.0 core with
the author's permission, given to the Game Bub port's author on 2026-10-12):

  * osd_keyboard.sv is copied with exact-text patches (never hand-edit the
    result): the Altera-backed cache_ram/cache_ram_dp ROMs become the generated
    osk_font_rom/osk_layout_rom, the glyph index grows to 7 bits, and Option
    becomes a sticky modifier like Shift, Control and Alt (Open Apple).
  * osk_font.hex's 64 glyphs (4 x 12 pixels) are kept, and the glyphs the IIgs
    keyboard and the status strip need are added from 64 up (FONT_EXTRA).
  * The layout is redrawn here (LAYOUT) after the Apple Desktop Bus keyboard
    (A9M0330) the IIgs shipped with: no function keys, Open Apple and Option,
    the L-shaped Return, arrows in a row (left right down up), the Apple
    keypad (clear = / *), and the Reset key on the strip above.

Writes rtl/osk/osd_keyboard.sv and rtl/osk/osk_rom.sv, and records the
upstream commit in scripts/import_osk.txt.
"""
import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class PatchError(Exception):
    pass


def replace_once(text, old, new, what):
    count = text.count(old)
    if count != 1:
        raise PatchError(f"{what}: expected exactly 1 match, found {count}")
    return text.replace(old, new)


# ---------------------------------------------------------------------------
# osd_keyboard.sv patches
# ---------------------------------------------------------------------------
def patch_osd_keyboard(text):
    # ROMs: generated modules with the data inlined (no init files in rtl/).
    text = replace_once(text,
        "cache_ram_dp #(.ADDR_WIDTH(9), .DATA_WIDTH(20), .MEM_INIT_FILE(LAYOUT_INIT), .SIM_INIT_FILE(LAYOUT_SIM)) layout\n"
        "(\n"
        "\t.clk_i(clk),\n"
        "\t.addr_a_i(lay_a), .wren_a_i(1'b0), .wdata_a_i(20'd0), .q_a_o(lay_qa),\n"
        "\t.addr_b_i(lay_b), .wren_b_i(1'b0), .wdata_b_i(20'd0), .q_b_o(lay_qb)\n"
        ");\n",
        "// [gamebub] generated ROM (scripts/import_osk.py), same timing\n"
        "osk_layout_rom layout\n"
        "(\n"
        "\t.clk(clk),\n"
        "\t.addr_a(lay_a), .q_a(lay_qa),\n"
        "\t.addr_b(lay_b), .q_b(lay_qb)\n"
        ");\n",
        "layout ROM")
    text = replace_once(text,
        "reg   [5:0] glyph1;\n", "reg   [6:0] glyph1;   // [gamebub] 7-bit glyph index\n",
        "glyph width")
    text = replace_once(text,
        "cache_ram #(.ADDR_WIDTH(10), .DATA_WIDTH(4), .MEM_INIT_FILE(FONT_INIT), .SIM_INIT_FILE(FONT_SIM)) font\n"
        "(\n"
        "\t.clk_i(clk), .addr_i({glyph1, kline1}), .wren_i(1'b0), .wdata_i(4'd0), .q_o(font_q)\n"
        ");\n",
        "// [gamebub] generated ROM (scripts/import_osk.py), 128 glyphs\n"
        "osk_font_rom font\n"
        "(\n"
        "\t.clk(clk), .addr({glyph1, kline1}), .q(font_q)\n"
        ");\n",
        "font ROM")
    text = replace_once(text,
        "\t\tglyph1 <= lay_qa[14:9];\n", "\t\tglyph1 <= lay_qa[15:9];\n", "glyph field")

    # Option (PS/2 left GUI, 0x11F -> ADB Option) sticky like the others.
    text = replace_once(text,
        "localparam [8:0] C_LSHIFT = 9'h012, C_RSHIFT = 9'h059, C_CTRL = 9'h014, C_ALT = 9'h011;\n",
        "localparam [8:0] C_LSHIFT = 9'h012, C_RSHIFT = 9'h059, C_CTRL = 9'h014, C_ALT = 9'h011;\n"
        "localparam [8:0] C_OPT = 9'h11F;   // [gamebub] Option, sticky too\n",
        "C_OPT")
    text = replace_once(text,
        "reg        sh_on, sh_right, ct_on, al_on;\n",
        "reg        sh_on, sh_right, ct_on, al_on, op_on;\n", "op_on")
    text = replace_once(text,
        "wire       cur_mod   = cur_shift || (cur_code == C_CTRL) || (cur_code == C_ALT);\n",
        "wire       cur_mod   = cur_shift || (cur_code == C_CTRL) || (cur_code == C_ALT) || (cur_code == C_OPT);\n",
        "cur_mod")
    text = replace_once(text,
        "\t\tsh_on <= 0; sh_right <= 0; ct_on <= 0; al_on <= 0; ev_req <= 0; ev_press <= 0; ev_code <= 0;\n",
        "\t\tsh_on <= 0; sh_right <= 0; ct_on <= 0; al_on <= 0; op_on <= 0; ev_req <= 0; ev_press <= 0; ev_code <= 0;\n",
        "op_on reset")
    text = replace_once(text,
        "\t\t\tif (sh_on | ct_on | al_on) st <= S_MODS;\n",
        "\t\t\tif (sh_on | ct_on | al_on | op_on) st <= S_MODS;\n", "op_on release")
    text = replace_once(text,
        "\t\t\t\telse if (cur_code == C_CTRL) begin ev_press <= ~ct_on; ev_code <= C_CTRL; ct_on <= ~ct_on; end\n",
        "\t\t\t\telse if (cur_code == C_CTRL) begin ev_press <= ~ct_on; ev_code <= C_CTRL; ct_on <= ~ct_on; end\n"
        "\t\t\t\telse if (cur_code == C_OPT)  begin ev_press <= ~op_on; ev_code <= C_OPT;  op_on <= ~op_on; end\n",
        "op_on toggle")
    text = replace_once(text,
        "\t\telse if (al_on) begin al_on <= 0; ev_req <= 1; ev_code <= C_ALT;  st <= S_SEND; end\n",
        "\t\telse if (al_on) begin al_on <= 0; ev_req <= 1; ev_code <= C_ALT;  st <= S_SEND; end\n"
        "\t\telse if (op_on) begin op_on <= 0; ev_req <= 1; ev_code <= C_OPT;  st <= S_SEND; end\n",
        "op_on auto-release")
    text = replace_once(text,
        "(ct_on && code1 == C_CTRL) || (al_on && code1 == C_ALT);\n",
        "(ct_on && code1 == C_CTRL) || (al_on && code1 == C_ALT) || (op_on && code1 == C_OPT);\n",
        "op_on highlight")
    return "// Imported by scripts/import_osk.py from Marty_MiSTer rtl/osk (see that script) - do not edit.\n" + text


# ---------------------------------------------------------------------------
# Font: Marty's 64 glyphs + ours
# ---------------------------------------------------------------------------
# Marty glyph indexes: 0 space, 1-26 A-Z, 27-36 0-9, 37 ` 38 - 39 = 40 [
# 41 ] 42 \ 43 ; 44 ' 45 , 46 . 47 / 48 left 49 up 50 down 51 right,
# 52-54 floppy icon (55-60 CD and hard disk icons: unused here).
CHARS = {' ': 0, '`': 37, '-': 38, '=': 39, '[': 40, ']': 41, '\\': 42, ';': 43,
         "'": 44, ',': 45, '.': 46, '/': 47, '<': 48, '^': 49, 'v': 50, '>': 51}
CHARS.update({chr(ord('A') + i): 1 + i for i in range(26)})
CHARS.update({chr(ord('0') + i): 27 + i for i in range(10)})

# New glyphs, 4 pixels wide (column 0 left blank as a gap) x 12 lines; a
# glyph wider than one cell is listed as consecutive cells.
FONT_EXTRA = {
    '*': ["....", "....", "....", ".#.#", "..#.", ".###", "..#.", ".#.#"],
    '+': ["....", "....", "....", "....", "..#.", ".###", "..#.", "...."],
    '@': ["....", "....", "....", "...#", "..##", ".###", "..##", "...#"],   # Reset (the triangle)
    ':': ["....", "....", "....", "..#.", "....", "....", "..#.", "...."],
    # Open Apple outline, 2 cells
    'APPLE': [".....#..", "....#...", "..##.##.", ".#.....#", ".#....#.",
              ".#....#.", ".#.....#", "..##.##.", "........"],
    # status strip: mouse (pointer mode) and keyboard (keyboard mode), 3 cells
    'MOUSE': ["............", "......#.....", ".....#......", "...######...",
              "..#......#..", "..########..", "..#......#..", "..#......#..",
              "..#......#..", "...######...", "............"],
    'KEYS':  ["............", "............", ".##########.", ".#........#.",
              ".#.#.#.#.##.", ".#........#.", ".#.#.#.#.##.", ".#........#.",
              ".#..####..#.", ".##########.", "............"],
}


def build_font(marty):
    font = list(marty) + [0] * (2048 - len(marty))
    glyph_of = dict(CHARS)
    nxt = 64
    for name, art in FONT_EXTRA.items():
        cells = len(art[0]) // 4
        first = nxt
        for c in range(cells):
            for line, row in enumerate(art):
                bits = row[c * 4:c * 4 + 4]
                font[nxt * 16 + line] = int(bits.replace('#', '1').replace('.', '0'), 2)
            nxt += 1
        glyph_of[name] = first
    return font, glyph_of


# ---------------------------------------------------------------------------
# Layout: 6 rows x 78 cells of 4 px; a key is (label, PS/2 set 2 code, cells)
# ---------------------------------------------------------------------------
KEYPAD_X = 61          # main block cells 0..59, a gap, keypad 61..76, 77 empty
LAYOUT = [
    # row 0: the strip above the keys holds Reset (F11 = the IIgs Reset key;
    # with sticky Control / Open Apple: Ctrl-Reset, Ctrl-OA-Reset)
    ([(None, 0, 18), ('@ RESET', 0x078, 8)], [(None, 0, 8), ('HELP', 0x1FF, 8)]),
    ([('ESC', 0x076, 4)] + [(d, c, 4) for d, c in zip('1234567890', [0x016, 0x01E, 0x026, 0x025, 0x02E, 0x036, 0x03D, 0x03E, 0x046, 0x045])]
     + [('-', 0x04E, 4), ('=', 0x055, 4), ('DELETE', 0x066, 8)],
     [('CLR', 0x077, 4), ('=', 0x00F, 4), ('/', 0x14A, 4), ('*', 0x07C, 4)]),
    ([('TAB', 0x00D, 6)] + [(k, c, 4) for k, c in zip('QWERTYUIOP', [0x015, 0x01D, 0x024, 0x02D, 0x02C, 0x035, 0x03C, 0x043, 0x044, 0x04D])]
     + [('[', 0x054, 4), (']', 0x05B, 4), ('', 0x05A, 6)],
     [('7', 0x06C, 4), ('8', 0x075, 4), ('9', 0x07D, 4), ('+', 0x079, 4)]),
    ([('CTRL', 0x014, 7)] + [(k, c, 4) for k, c in zip('ASDFGHJKL', [0x01C, 0x01B, 0x023, 0x02B, 0x034, 0x033, 0x03B, 0x042, 0x04B])]
     + [(';', 0x04C, 4), ("'", 0x052, 4), ('RETURN', 0x05A, 9)],
     [('4', 0x06B, 4), ('5', 0x073, 4), ('6', 0x074, 4), ('-', 0x07B, 4)]),
    ([('SHIFT', 0x012, 9)] + [(k, c, 4) for k, c in zip('ZXCVBNM', [0x01A, 0x022, 0x021, 0x02A, 0x032, 0x031, 0x03A])]
     + [(',', 0x041, 4), ('.', 0x049, 4), ('/', 0x04A, 4), ('SHIFT', 0x059, 11)],
     [('1', 0x069, 4), ('2', 0x072, 4), ('3', 0x07A, 4), ('', 0x15A, 4)]),
    ([('CAPS', 0x058, 5), ('OPT', 0x11F, 5), ('{APPLE}', 0x011, 6), ('`', 0x00E, 4),
      ('', 0x029, 20), ('\\', 0x05D, 4), ('<', 0x16B, 4), ('>', 0x174, 4), ('v', 0x172, 4), ('^', 0x175, 4)],
     [('0', 0x070, 8), ('.', 0x071, 4), ('ENT', 0x15A, 4)]),
]
# Status strip (row 6, top-left corner, each lit by one light): code 1 floppy
# (disk activity), 2 mouse (pointer mode), 3 keyboard (keyboard mode).
STRIP = [(52, 1), (53, 1), (54, 1), (None, 0),
         (('MOUSE', 0), 2), (('MOUSE', 1), 2), (('MOUSE', 2), 2), (None, 0),
         (('KEYS', 0), 3), (('KEYS', 1), 3), (('KEYS', 2), 3)]


def label_glyphs(label, glyph_of):
    out, i = [], 0
    while i < len(label):
        if label[i] == '{':
            j = label.index('}', i)
            name = label[i + 1:j]
            out += [glyph_of[name], glyph_of[name] + 1]
            i = j + 1
        else:
            if label[i] not in glyph_of:
                raise PatchError(f"no glyph for {label[i]!r}")
            out.append(glyph_of[label[i]])
            i += 1
    return out


def build_layout(glyph_of):
    lay = [0] * 512

    def place(row, x, keys):
        for label, code, width in keys:
            if label is not None:
                g = label_glyphs(label, glyph_of)
                if len(g) > width:
                    raise PatchError(f"label {label!r} wider than its key")
                start = (width - len(g)) // 2
                for c in range(width):
                    gi = g[c - start] if 0 <= c - start < len(g) else 0
                    lay[row * 80 + x + c] = (gi << 9) | code
            x += width
        return x

    for row, (main, pad) in enumerate(LAYOUT):
        end = place(row, 0, main)
        if row > 0 and end != 60:
            raise PatchError(f"row {row}: main block is {end} cells, not 60")
        if pad and place(row, KEYPAD_X, pad) != KEYPAD_X + 16 and row > 0:
            raise PatchError(f"row {row}: keypad is not 16 cells")
    for cell, (g, code) in enumerate(STRIP):
        if g is not None:
            gi = g if isinstance(g, int) else glyph_of[g[0]] + g[1]
            lay[6 * 80 + cell] = (gi << 9) | code
    return lay


# ---------------------------------------------------------------------------
# The controls card (rtl/gamebub/gb_help_card.sv): 26 x 12 characters.
# Rows 2..8 col 8.. show the name of the key each button types; row 1 is the
# d-pad line in mouse mode, row 11 its keyboard-mode text.
# ---------------------------------------------------------------------------
HELP_W = 26
HELP_ROWS = [
    "        CONTROLS",
    " D-PAD  MOUSE + JOYSTICK",
    " A",
    " B",
    " X",
    " Y",
    " L",
    " R",
    " START",
    " SELECT MOUSE / KEYS",
    " HOLD SELECT: KEYBOARD",
    " D-PAD  ARROWS+JOYSTICK",
]
CLICK_CODE = 0x1FE        # pseudo code: "the mouse button"
KEY_NAMES = {
    0x000: '-', CLICK_CODE: 'CLICK', 0x1FF: 'HELP',
    0x05A: 'RETURN', 0x029: 'SPACE', 0x076: 'ESC', 0x00D: 'TAB', 0x066: 'DELETE',
    0x175: '^ UP', 0x172: 'v DOWN', 0x16B: '< LEFT', 0x174: '> RIGHT',
    0x011: '{APPLE}', 0x11F: 'OPTION', 0x014: 'CTRL', 0x012: 'SHIFT', 0x059: 'SHIFT',
    0x058: 'CAPS', 0x078: '@ RESET', 0x077: 'CLEAR', 0x15A: 'ENTER',
    0x00F: 'KP =', 0x14A: 'KP /', 0x07C: 'KP *', 0x079: 'KP +', 0x07B: 'KP -', 0x071: 'KP .',
}
for k, c in zip('ABCDEFGHIJKLMNOPQRSTUVWXYZ', [0x01C, 0x032, 0x021, 0x023, 0x024, 0x02B, 0x034, 0x033,
        0x043, 0x03B, 0x042, 0x04B, 0x03A, 0x031, 0x044, 0x04D, 0x015, 0x02D, 0x01B, 0x02C, 0x03C,
        0x02A, 0x01D, 0x022, 0x035, 0x01A]):
    KEY_NAMES[c] = k
for k, c in zip('0123456789', [0x045, 0x016, 0x01E, 0x026, 0x025, 0x02E, 0x036, 0x03D, 0x03E, 0x046]):
    KEY_NAMES[c] = k
for k, c in zip('0123456789', [0x070, 0x069, 0x072, 0x07A, 0x06B, 0x073, 0x074, 0x06C, 0x075, 0x07D]):
    KEY_NAMES[c] = 'KP ' + k
for k, c in [(',', 0x041), ('.', 0x049), ('/', 0x04A), (';', 0x04C), ("'", 0x052), ('[', 0x054),
             (']', 0x05B), ('-', 0x04E), ('=', 0x055), ('\\', 0x05D), ('`', 0x00E)]:
    KEY_NAMES[c] = k


def help_sv(glyph_of):
    out = ["// The controls card's fixed text: row, column -> glyph\n",
           "module osk_help_template (\n\tinput  wire [3:0] row,\n\tinput  wire [4:0] col,\n",
           "\toutput reg  [6:0] glyph\n);\nalways @(*) begin\n\tglyph = 7'd0;\n\tcase ({row, col})\n"]
    for r, text in enumerate(HELP_ROWS):
        g = label_glyphs(text, glyph_of)
        if len(g) > HELP_W:
            raise PatchError(f"help row {r} too wide")
        for c, gi in enumerate(g):
            if gi:
                out.append(f"\t9'd{r * 32 + c}: glyph = 7'd{gi};\n")
    out += ["\tdefault: glyph = 7'd0;\n\tendcase\nend\nendmodule\n\n",
            "// A key's name (8 characters) for the controls card; code 0x1FE = CLICK\n",
            "module osk_key_name (\n\tinput  wire [8:0] code,\n\tinput  wire [2:0] pos,\n",
            "\toutput wire [6:0] glyph\n);\nreg [55:0] name;\nalways @(*) begin\n\tcase (code)\n"]
    for code, text in sorted(KEY_NAMES.items()):
        g = label_glyphs(text, glyph_of)
        if len(g) > 8:
            raise PatchError(f"key name {text!r} too long")
        g += [0] * (8 - len(g))
        packed = 0
        for i, gi in enumerate(g):
            packed |= gi << (7 * i)
        out.append(f"\t9'h{code:03X}: name = 56'h{packed:014X};   // {text}\n")
    unk = label_glyphs('?', glyph_of) if '?' in glyph_of else [0]
    out += ["\tdefault:  name = 56'h0;\n\tendcase\nend\nassign glyph = name[pos * 7 +: 7];\nendmodule\n\n"]
    return "".join(out)


def rom_sv(font, lay, commit):
    out = [f"// Generated by scripts/import_osk.py (Marty_MiSTer {commit[:12]} rtl/osk + the IIgs\n",
           "// layout and glyphs in that script) - do not edit.\n",
           "`default_nettype none\n\n",
           "// {glyph[6:0] at [15:9], PS/2 set 2 code [8:0]}, address row * 80 + cell\n",
           "module osk_layout_rom (\n\tinput  wire        clk,\n",
           "\tinput  wire [8:0]  addr_a,\n\toutput reg  [19:0] q_a,\n",
           "\tinput  wire [8:0]  addr_b,\n\toutput reg  [19:0] q_b\n);\n",
           "reg [19:0] d [0:511];\ninitial begin\n"]
    out += [f"\td[{i}] = 20'h{v:05X};\n" for i, v in enumerate(lay) if v]
    out += ["end\nalways @(posedge clk) begin\n\tq_a <= d[addr_a];\n\tq_b <= d[addr_b];\nend\nendmodule\n\n",
            "// {glyph[6:0], line[3:0]} -> 4 pixels, [3] leftmost\n",
            "module osk_font_rom (\n\tinput  wire        clk,\n\tinput  wire [10:0] addr,\n",
            "\toutput reg  [3:0]  q\n);\nreg [3:0] d [0:2047];\ninitial begin\n",
            "\tfor (int i = 0; i < 2048; i++) d[i] = 4'h0;\n"]
    out += [f"\td[{i}] = 4'h{v:X};\n" for i, v in enumerate(font) if v]
    out += ["end\nalways @(posedge clk) q <= d[addr];\nendmodule\n\n`default_nettype wire\n"]
    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--src", type=Path, default=ROOT.parent / "Marty_MiSTer")
    a = ap.parse_args()
    osk = a.src / "rtl" / "osk"
    if not (osk / "osd_keyboard.sv").is_file():
        sys.exit(f"Marty_MiSTer rtl/osk not found under {a.src}")
    try:
        commit = subprocess.check_output(["git", "-C", str(a.src), "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        commit = "unknown"
    try:
        sv = patch_osd_keyboard((osk / "osd_keyboard.sv").read_text())
        marty_font = [int(t, 16) for t in (osk / "osk_font.hex").read_text().split()]
        font, glyph_of = build_font(marty_font)
        lay = build_layout(glyph_of)
    except PatchError as e:
        sys.exit(f"Import failed: {e}")
    dst = ROOT / "rtl" / "osk"
    dst.mkdir(exist_ok=True)
    (dst / "osd_keyboard.sv").write_text(sv)
    rom = rom_sv(font, lay, commit)
    rom = rom.replace("`default_nettype wire\n", help_sv(glyph_of) + "`default_nettype wire\n")
    (dst / "osk_rom.sv").write_text(rom)
    (ROOT / "scripts" / "import_osk.txt").write_text(
        f"Marty_MiSTer commit {commit}\nrtl/osk/osd_keyboard.sv, osk_font.hex\n"
        "Used with the author's (Jamie Blanks) permission in this GPL-3.0 core.\n")
    print(f"Imported the on-screen keyboard from {commit[:12]} into {dst}")


if __name__ == "__main__":
    main()
