"""Render the "Calm line" app icon (DESIGN_SPEC.md §8) to PNG, default and dark.

Usage: uvx --with pillow python ios/scripts/render_icon.py
Placeholder until the Icon Composer .icon file exists.
"""
from pathlib import Path
from PIL import Image, ImageDraw

S = 4  # supersample
N = 1024
OUT = Path(__file__).parent.parent / "BumpCast/Assets.xcassets/AppIcon.appiconset"

THEMES = {
    "default": dict(sky=("F6D9C4", "DFE6EF"), water=("A9C6E2", "7FA6CC"), sun=("FFF3E8", 0.95), line="1F5F6E"),
    "dark": dict(sky=("1B2A45", "2C4262"), water=("13203A", "0B1322"), sun=("F2D8B8", 0.85), line="8FD7E0"),
}

def rgb(h): return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
def lerp(a, b, t): return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

def cubic(p0, p1, p2, p3, steps=120):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        x = (1-t)**3*p0[0] + 3*(1-t)**2*t*p1[0] + 3*(1-t)*t**2*p2[0] + t**3*p3[0]
        y = (1-t)**3*p0[1] + 3*(1-t)**2*t*p1[1] + 3*(1-t)*t**2*p2[1] + t**3*p3[1]
        pts.append((x, y))
    return pts

def render(theme):
    c = THEMES[theme]
    W = N * S
    horizon = 604 * S
    img = Image.new("RGB", (W, W))
    d = ImageDraw.Draw(img)
    sky0, sky1 = rgb(c["sky"][0]), rgb(c["sky"][1])
    for y in range(horizon):
        d.line([(0, y), (W, y)], fill=lerp(sky0, sky1, y / horizon))
    # Sun behind the water: draw full circle, then water covers the lower half.
    sun = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sun)
    cx, cy, r = 655 * S, 604 * S, 154 * S
    sd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=rgb(c["sun"][0]) + (round(255 * c["sun"][1]),))
    img.paste(sun, (0, 0), sun)
    w0, w1 = rgb(c["water"][0]), rgb(c["water"][1])
    for y in range(horizon, W):
        d.line([(0, y), (W, y)], fill=lerp(w0, w1, (y - horizon) / (W - horizon)))
    line = rgb(c["line"])
    # Reflections, 70% opacity, round caps.
    refl = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    rd = ImageDraw.Draw(refl)
    for x0, x1, y in [(573, 737, 686), (614, 696, 737)]:
        rd.line([(x0 * S, y * S), (x1 * S, y * S)], fill=rgb(c["sun"][0]) + (178,), width=15 * S)
        for x in (x0, x1):
            rd.ellipse([(x - 7.5) * S, (y - 7.5) * S, (x + 7.5) * S, (y + 7.5) * S], fill=rgb(c["sun"][0]) + (178,))
    img.paste(refl, (0, 0), refl)
    # Line: M133 604 C215 604 246 502 317 502 S420 604 502 604 L1085 604
    pts = cubic((133, 604), (215, 604), (246, 502), (317, 502))
    pts += cubic((317, 502), (388, 502), (420, 604), (502, 604))[1:]  # S reflects the previous control point
    pts += [(1085, 604)]
    pts = [(x * S, y * S) for x, y in pts]
    # Stamp a round brush densely along the path: round caps and joins, no seams.
    radius = 51 * S / 2
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        steps = max(1, int(((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5 / 2))
        for i in range(steps + 1):
            x, y = x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps
            d.ellipse([x - radius, y - radius, x + radius, y + radius], fill=line)
    return img.resize((N, N), Image.LANCZOS)

for theme in THEMES:
    render(theme).save(OUT / f"AppIcon-{theme}.png")
print("rendered", [p.name for p in OUT.glob("*.png")])
