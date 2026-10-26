#!/usr/bin/env python3
"""Render the daily Sky Report cards for TikTok, Reels and Shorts (1080 x 1920).

From the latest report it picks tomorrow (Eastern time) and makes:
  01-cover.png     "Tomorrow's sky" and the date
  02-smooth.png    the smoothest routes
  03-bumps.png     routes with bumps, and the smoothest time to leave on each
  04-app.png       the app: your flight, minute by minute
  sky-report.mp4   the cards as a slideshow (add a sound in the app when posting)
  caption.txt      a caption with hashtags

Grades only, never when or how long: that's what the app sells. Calm wording, no red.
Content stays out of the bottom and right edges, where TikTok and Reels draw their buttons.

    python3 marketing/skyreport/render_cards.py                       # from Supabase
    python3 marketing/skyreport/render_cards.py marketing/skyreport/fixtures/sample-report.json --allow-sample --allow-stale

Output: build/cards/YYYY-MM-DD/ (set with --out). Needs Chrome or Chromium (CHROME=path to
override) and ffmpeg for the video.
"""

import argparse
import glob
import os
import shutil
import subprocess
import tempfile
from datetime import UTC, date, datetime
from html import escape
from pathlib import Path

import report as rpt

W, H = 1080, 1920
SECONDS_PER_CARD = 3.5
FADE = 0.4
ROWS = 6
CHROMES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    *sorted(glob.glob("/opt/pw-browsers/chromium-*/chrome-linux*/chrome"), reverse=True),
]

STYLE = f"""
@font-face {{ font-family: "Familjen"; src: url("{(rpt.FONTS / 'FamiljenGrotesk-Bold.ttf').as_uri()}"); font-weight: 700; }}
@font-face {{ font-family: "Familjen"; src: url("{(rpt.FONTS / 'FamiljenGrotesk-SemiBold.ttf').as_uri()}"); font-weight: 600; }}
@font-face {{ font-family: "Atkinson"; src: url("{(rpt.FONTS / 'AtkinsonHyperlegible-Regular.ttf').as_uri()}"); font-weight: 400; }}
@font-face {{ font-family: "Atkinson"; src: url("{(rpt.FONTS / 'AtkinsonHyperlegible-Bold.ttf').as_uri()}"); font-weight: 700; }}
@font-face {{ font-family: "Plex Mono"; src: url("{(rpt.FONTS / 'IBMPlexMono-Medium.ttf').as_uri()}"); font-weight: 500; }}
* {{ box-sizing: border-box; margin: 0; }}
html, body {{ width: {W}px; height: {H}px; overflow: hidden; }}
body {{ background: linear-gradient(180deg, #1B2A45 0%, #121D31 55%, #0B1322 100%); color: #F2F6FA;
  font-family: "Atkinson", sans-serif; }}
.safe {{ position: absolute; top: 150px; left: 84px; right: 150px; bottom: 430px; display: flex; flex-direction: column; }}
.eyebrow {{ font: 500 30px/1 "Plex Mono", monospace; letter-spacing: .12em; text-transform: uppercase; color: #9FB0C4; }}
h1 {{ font: 700 104px/1.02 "Familjen", sans-serif; margin-top: 34px; letter-spacing: -.01em; }}
h1 em {{ font-style: normal; color: #6FBCCC; }}
h2 {{ font: 700 76px/1.05 "Familjen", sans-serif; margin-top: 28px; }}
.sub {{ font-size: 40px; line-height: 1.35; color: #C9D6E3; margin-top: 30px; }}
.rows {{ margin-top: 44px; }}
.row {{ display: flex; justify-content: space-between; align-items: center; padding: 24px 0;
  border-top: 2px solid rgba(230, 239, 246, .12); gap: 24px; }}
.row:first-child {{ border-top: 0; }}
.route {{ font: 700 52px/1 "Familjen", sans-serif; }}
.city {{ font-size: 30px; color: #9FB0C4; margin-top: 10px; }}
.right {{ text-align: right; }}
.grade {{ display: inline-flex; align-items: center; gap: 14px; font: 700 34px/1 "Atkinson", sans-serif; white-space: nowrap; }}
.dot {{ width: 22px; height: 22px; border-radius: 50%; background: var(--c); }}
.note {{ font: 500 24px/1 "Plex Mono", monospace; letter-spacing: .06em; text-transform: uppercase; color: #6FBCCC; margin-top: 12px; }}
.foot {{ margin-top: auto; font-size: 30px; color: #9FB0C4; line-height: 1.4; }}
.brand {{ font: 700 44px/1 "Familjen", sans-serif; color: #F2F6FA; }}
.big {{ font-size: 46px; line-height: 1.4; color: #C9D6E3; margin-top: 36px; }}
.pill {{ display: inline-block; margin-top: 52px; padding: 26px 44px; border-radius: 999px; background: #6FBCCC;
  color: #0B1322; font: 700 40px/1 "Atkinson", sans-serif; }}
"""


def page(body: str) -> str:
    return f'<!doctype html><html><head><meta charset="utf-8"><style>{STYLE}</style></head><body><div class="safe">{body}</div></body></html>'


def grade_html(grade: str) -> str:
    return f'<span class="grade" style="--c:{rpt.GRADE_COLORS[grade][1]}"><span class="dot"></span>{escape(rpt.GRADE_TITLES[grade])}</span>'


def row(s: dict, note: str = "") -> str:
    r = s["route"]
    note_html = f'<div class="note">{escape(note)}</div>' if note else ""
    return (f'<div class="row"><div><div class="route">{escape(rpt.route_title(r))}</div>'
            f'<div class="city">{escape(rpt.city_title(r))}</div></div>'
            f'<div class="right">{grade_html(s["grade"])}{note_html}</div></div>')


def pick(report: dict, on: date) -> tuple[list[dict], list[dict], int]:
    summaries = [s for r in report["routes"] if (s := rpt.summary(r, on))]
    calm = [s for s in summaries if s["grade"] in ("smooth", "mostly_smooth")]
    calm.sort(key=lambda s: (-s["min_score"], rpt.route_title(s["route"])))
    bumps = [s for s in summaries if s["grade"] not in ("smooth", "mostly_smooth")]
    bumps.sort(key=lambda s: (-rpt.GRADES.index(s["grade"]), s["min_score"], rpt.route_title(s["route"])))
    return calm[:ROWS], bumps[:ROWS], len(summaries)


def cards(report: dict, on: date) -> list[tuple[str, str]]:
    calm, bumps, count = pick(report, on)
    out = [("01-cover", page(f"""
<p class="eyebrow">BumpCast Sky Report</p>
<h1>Tomorrow's<br><em>sky</em></h1>
<p class="sub">{escape(rpt.day_title(on))}</p>
<p class="big">How {count} popular routes look for morning, afternoon and evening flights.</p>
<p class="foot">Early outlook. Forecasts are guidance, not guarantees.</p>"""))]
    if calm:
        out.append(("02-smooth", page(f"""
<p class="eyebrow">{escape(rpt.short_day(on))}</p>
<h2>Smoothest routes</h2>
<div class="rows">{''.join(row(s) for s in calm)}</div>
<p class="foot">Grade for the roughest departure of the day.</p>""")))
    if bumps:
        rows = "".join(row(s, f"Smoothest: {s['best']['slot']}" if s["varies"] else "") for s in bumps)
        out.append(("03-bumps", page(f"""
<p class="eyebrow">{escape(rpt.short_day(on))}</p>
<h2>Where to expect bumps</h2>
<div class="rows">{rows}</div>
<p class="foot">Bumps are uncomfortable, not dangerous. Keep your seatbelt on while seated.</p>""")))
    out.append(("04-app", page("""
<p class="eyebrow">Flying soon?</p>
<h1>Your flight,<br><em>minute by minute</em></h1>
<p class="big">Add your flight number. See when the bumps will come, how strong they'll be, and when they'll end.</p>
<span class="pill">BumpCast on the App Store</span>
<p class="foot"><span class="brand">BumpCast</span><br>US and southern Canada flights. Your first forecasts are free.</p>""")))
    return out


def caption(report: dict, on: date) -> str:
    calm, bumps, _ = pick(report, on)
    lines = [f"Tomorrow's sky, {rpt.day_title(on)} ✈️"]
    if calm:
        lines.append("Smoothest: " + ", ".join(rpt.route_title(s["route"], "→") for s in calm[:3]))
    if bumps:
        lines.append("Some bumps: " + ", ".join(rpt.route_title(s["route"], "→") for s in bumps[:3]))
    lines += [
        "Your exact flight, minute by minute: BumpCast on the App Store.",
        "Early outlook. Forecasts are guidance, not guarantees.",
        "",
        "#turbulence #nervousflyer #fearofflying #flightanxiety #travel #thanksgivingtravel #avgeek",
    ]
    return "\n".join(lines) + "\n"


def chrome() -> str:
    for path in [os.environ.get("CHROME"), *CHROMES, shutil.which("chromium"), shutil.which("google-chrome")]:
        if path and Path(path).exists():
            return path
    raise SystemExit("No Chrome or Chromium found: set CHROME to its path")


def screenshot(html: str, path: Path, browser: str) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(html)
    try:
        subprocess.run([
            browser, "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
            "--force-device-scale-factor=1", "--allow-file-access-from-files", "--no-first-run",
            f"--window-size={W},{H}", "--virtual-time-budget=5000", f"--screenshot={path}", Path(f.name).as_uri(),
        ], check=True, capture_output=True, timeout=60)
    finally:
        os.unlink(f.name)


def video(images: list[Path], path: Path) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        print("ffmpeg not found: skipping the video")
        return
    inputs = []
    for image in images:
        inputs += ["-loop", "1", "-t", str(SECONDS_PER_CARD), "-i", str(image)]
    chain, last = [], "[0:v]"
    for i in range(1, len(images)):
        offset = i * (SECONDS_PER_CARD - FADE)
        chain.append(f"{last}[{i}:v]xfade=transition=fade:duration={FADE}:offset={offset:.2f}[v{i}]")
        last = f"[v{i}]"
    filters = ";".join(chain) + (";" if chain else "") + f"{last}format=yuv420p,fps=30[out]"
    subprocess.run([ffmpeg, "-y", "-loglevel", "error", *inputs, "-filter_complex", filters, "-map", "[out]",
                    "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-movflags", "+faststart", str(path)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", nargs="?", help="Report JSON (default: the latest in Supabase)")
    parser.add_argument("--out", type=Path, help="Output folder (default: build/cards/<date>)")
    parser.add_argument("--date", help="Day to show, YYYY-MM-DD (default: tomorrow, Eastern time)")
    parser.add_argument("--no-video", action="store_true")
    parser.add_argument("--allow-sample", action="store_true", help="Render from the sample report (previews only)")
    parser.add_argument("--allow-stale", action="store_true", help="Render from a report older than 3 hours")
    args = parser.parse_args()
    report = rpt.load(args.report)
    now = datetime.now(UTC)
    rpt.check_fresh(report, now, args.allow_stale, args.allow_sample)
    on = date.fromisoformat(args.date) if args.date else rpt.tomorrow(rpt.parse_time(report["generated_at"]))
    out = args.out or rpt.ROOT / "build" / "cards" / on.isoformat()
    out.mkdir(parents=True, exist_ok=True)
    browser = chrome()
    images = []
    for name, html in cards(report, on):
        path = out / f"{name}.png"
        screenshot(html, path, browser)
        images.append(path)
        print(path)
    (out / "caption.txt").write_text(caption(report, on))
    if not args.no_video:
        video(images, out / "sky-report.mp4")
        print(out / "sky-report.mp4")


if __name__ == "__main__":
    main()
