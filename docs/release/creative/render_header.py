#!/usr/bin/env python3
"""Universal App Store creative (product page header + search results), 5244 x 2950, 16:9.

Night sky, eyebrow + headline + subhead on the left, three phones on the right.
Key content stays inside the central 21:9 band (y 352..2598) so crops don't clip it.
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).parent  # expects cap/ (raw captures from docs/release/screenshot-captures) and fonts/ (ios/Shared/Fonts)
CAP = HERE / "cap"
FONTS = HERE / "fonts"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "header.png"

W, H = 5244, 2950
TOP, BOTTOM = (0x1B, 0x2A, 0x45), (0x0B, 0x13, 0x22)
ACCENT = (0x6F, 0xBC, 0xCC)
DAWN = (0xF6, 0xD9, 0xC4)
WHITE = (255, 255, 255)
MUTED = (0xB9, 0xC6, 0xD6)


def font(name, size):
    return ImageFont.truetype(str(FONTS / name), size)


def sky():
    col = Image.new("RGB", (1, H))
    for y in range(H):
        t = y / (H - 1)
        col.putpixel((0, y), tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)))
    img = col.resize((W, H))
    # Soft glows: accent behind the phones, a faint dawn warmth low on the right.
    glow = Image.new("RGB", (W // 8, H // 8), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse((2700 // 8, 300 // 8, 5000 // 8, 2700 // 8), fill=(0x2A, 0x73, 0x85))
    g.ellipse((3700 // 8, 2100 // 8, 5600 // 8, 3600 // 8), fill=(0x8A, 0x5A, 0x48))
    glow = glow.filter(ImageFilter.GaussianBlur(52)).resize((W, H), Image.BICUBIC)
    glow = glow.point(lambda v: int(v * 0.55))
    return ImageChops.add(img, glow)


def phone(screen_path, height):
    shot = Image.open(screen_path).convert("RGB")
    sw = round(height * shot.width / shot.height)
    shot = shot.resize((sw, height), Image.LANCZOS)
    bezel = round(height * 0.018)
    radius = round(sw * 0.17)
    fw, fh = sw + bezel * 2, height + bezel * 2
    frame = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle((0, 0, fw - 1, fh - 1), radius + bezel, fill=(0x0E, 0x11, 0x16, 255))
    d.rounded_rectangle((2, 2, fw - 3, fh - 3), radius + bezel - 2, outline=(0x4A, 0x55, 0x66, 255), width=4)
    mask = Image.new("L", (sw, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, height - 1), radius, fill=255)
    frame.paste(shot, (bezel, bezel), mask)
    return frame


def place(canvas, ph, cx, cy):
    """Paste a phone centred at (cx, cy) with a soft drop shadow."""
    x, y = cx - ph.width // 2, cy - ph.height // 2
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    alpha = ph.split()[3].point(lambda v: int(v * 0.55))
    shadow.paste((0, 0, 0, 255), (x + 30, y + 60), alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(70))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(ph, (x, y))


def main():
    canvas = sky().convert("RGBA")

    # Phones: two behind, forecast in front. Centre band y 352..2598.
    back_h, front_h = 1640, 1980
    cy = 1475
    place(canvas, phone(CAP / "03-lockscreen.png", back_h), 3180, cy + 60)
    place(canvas, phone(CAP / "09-search.png", back_h), 4560, cy + 60)
    place(canvas, phone(CAP / "01-forecast.png", front_h), 3870, cy)

    d = ImageDraw.Draw(canvas)
    left = 420
    eyebrow = font("IBMPlexMono-Medium.ttf", 92)
    head = font("FamiljenGrotesk-Bold.ttf", 268)
    sub = font("AtkinsonHyperlegible-Regular.ttf", 112)

    y = 820
    x = left
    for ch in "FOR NERVOUS FLYERS":  # ~0.2em tracking, like the screenshot eyebrows
        d.text((x, y), ch, font=eyebrow, fill=ACCENT)
        x += d.textlength(ch, font=eyebrow) + 20
    y += 210
    lines = [[("Know every ", WHITE), ("bump", ACCENT)], [("before you board.", WHITE)]]
    for line in lines:
        x = left
        for text, colour in line:
            d.text((x, y), text, font=head, fill=colour)
            x += d.textlength(text, font=head)
        y += 300
    y += 70
    for s in ["Turbulence forecasts and live flight status,", "minute by minute, in plain words."]:
        d.text((left, y), s, font=sub, fill=MUTED)
        y += 150

    canvas.convert("RGB").save(OUT, "PNG", optimize=True)
    print(OUT, canvas.size)


if __name__ == "__main__":
    main()
