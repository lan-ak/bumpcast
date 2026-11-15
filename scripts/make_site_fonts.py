#!/usr/bin/env python3
"""Make the website's body font: Atkinson Hyperlegible with a plain (unslashed) zero.

Atkinson Hyperlegible only has a slashed zero, which makes number-heavy pages ("2,470 mi",
"2026", "120 of 35,528") read like code. This draws a plain zero from the font's own capital O,
narrowed to the zero's width with the side strokes kept at the O's weight, and saves the result as
"BumpCast Text" (a renamed copy, as the SIL Open Font License asks of modified fonts) in site/fonts/.
The app keeps the original font.

    python3 scripts/make_site_fonts.py
"""
import copy
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._g_l_y_f import GlyphCoordinates

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "ios" / "Shared" / "Fonts"
OUT = ROOT / "site" / "fonts"
FAMILY = "BumpCast Text"


def contours(glyph, glyf):
    coords, ends, _ = glyph.getCoordinates(glyf)
    out, start = [], 0
    for end in ends:
        out.append((start, end + 1))
        start = end + 1
    return coords, out


def plain_zero(font: TTFont) -> None:
    glyf = font["glyf"]
    o, zero = glyf["O"], glyf["zero"]
    coords, spans = contours(o, glyf)
    if len(spans) != 2:
        raise SystemExit("expected O to have two contours")
    boxes = []
    for a, b in spans:
        xs = [coords[i][0] for i in range(a, b)]
        boxes.append((min(xs), max(xs)))
    outer_i = 0 if boxes[0][1] - boxes[0][0] > boxes[1][1] - boxes[1][0] else 1
    (ox0, ox1), (ix0, ix1) = boxes[outer_i], boxes[1 - outer_i]
    stem_l, stem_r = ix0 - ox0, ox1 - ix1
    zx0, zx1 = zero.xMin, zero.xMax
    new_outer_w = zx1 - zx0
    sx_outer = new_outer_w / (ox1 - ox0)
    new_inner_w = new_outer_w - stem_l - stem_r
    sx_inner = new_inner_w / (ix1 - ix0)

    new_coords = list(coords)
    for idx, (a, b) in enumerate(spans):
        if idx == outer_i:
            x_from, sx, x_to = ox0, sx_outer, zx0
        else:
            x_from, sx, x_to = ix0, sx_inner, zx0 + stem_l
        for i in range(a, b):
            x, y = coords[i]
            new_coords[i] = (round(x_to + (x - x_from) * sx), y)
    # A copy of O (same contours and on/off-curve flags) with the moved points.
    z = copy.deepcopy(o)
    z.coordinates = GlyphCoordinates(new_coords)
    z.recalcBounds(glyf)
    glyf["zero"] = z
    # Keep the zero's own advance width and left side bearing.
    adv, _ = font["hmtx"]["zero"]
    font["hmtx"]["zero"] = (adv, z.xMin)


def rename(font: TTFont, style: str) -> None:
    name = font["name"]
    for rec in list(name.names):
        if rec.nameID in (1, 3, 4, 6, 16, 17):
            name.removeNames(nameID=rec.nameID)
    full = f"{FAMILY} {style}"
    for nid, value in ((1, FAMILY), (2, style), (3, f"{full}; site"), (4, full), (6, full.replace(" ", "")),
                       (16, FAMILY), (17, style)):
        name.setName(value, nid, 3, 1, 0x409)
        name.setName(value, nid, 1, 0, 0)


def main() -> None:
    for style in ("Regular", "Bold"):
        font = TTFont(SRC / f"AtkinsonHyperlegible-{style}.ttf")
        plain_zero(font)
        rename(font, style)
        out = OUT / f"BumpCastText-{style}.ttf"
        font.save(out)
        print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
