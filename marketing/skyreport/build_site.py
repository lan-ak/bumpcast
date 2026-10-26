#!/usr/bin/env python3
"""Build the website with a page for every Sky Report route, ready for any static host.

Copies `site/` (home, support, privacy), then adds /routes/ and one page per route at
/routes/jfk-lax/, plus sitemap.xml and robots.txt. Each page answers "Will my flight be bumpy?"
for today and tomorrow, by departure time, with the grade only: when and how long the bumps
last stays in the app. Rebuild it hourly, after the worker's report.

    python3 marketing/skyreport/build_site.py --base-url https://bumpcast.app            # from Supabase
    python3 marketing/skyreport/build_site.py marketing/skyreport/fixtures/sample-report.json --allow-sample --allow-stale --base-url http://localhost:8000

Output: build/site/ (set with --out)
"""

import argparse
import json
import shutil
from datetime import UTC, date, datetime
from html import escape
from pathlib import Path

import report as rpt

OUT = rpt.ROOT / "build" / "site"
SITE = rpt.ROOT / "site"
FONT_FILES = ["FamiljenGrotesk-SemiBold.ttf", "FamiljenGrotesk-Bold.ttf", "AtkinsonHyperlegible-Regular.ttf",
              "AtkinsonHyperlegible-Bold.ttf", "IBMPlexMono-Medium.ttf"]
# Accuracy is only quoted once enough flyers have rated their flights to mean something.
MIN_ACCURACY_REPORTS = 50

CSS = """
@font-face { font-family: "Familjen"; src: url("/fonts/FamiljenGrotesk-SemiBold.ttf"); font-weight: 600; font-display: swap; }
@font-face { font-family: "Familjen"; src: url("/fonts/FamiljenGrotesk-Bold.ttf"); font-weight: 700; font-display: swap; }
@font-face { font-family: "Atkinson"; src: url("/fonts/AtkinsonHyperlegible-Regular.ttf"); font-weight: 400; font-display: swap; }
@font-face { font-family: "Atkinson"; src: url("/fonts/AtkinsonHyperlegible-Bold.ttf"); font-weight: 700; font-display: swap; }
@font-face { font-family: "Plex Mono"; src: url("/fonts/IBMPlexMono-Medium.ttf"); font-weight: 500; font-display: swap; }
:root {
  --ink: #15253A; --ink2: #45576C; --accent: #2A7385; --line: rgba(21, 37, 58, .12);
  --card: rgba(255, 255, 255, .72); --sky: linear-gradient(180deg, #CFE3F3 0%, #E6EFF6 45%, #F4F7FA 100%);
  --bg: #F4F7FA;
  --smooth: #3A9A8F; --light: #C99A2E; --moderate: #C9733A; --severe: #8E4A6B;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --ink: #E6EFF6; --ink2: #9FB0C4; --accent: #6FBCCC; --line: rgba(230, 239, 246, .14);
  --card: rgba(19, 32, 58, .72); --sky: linear-gradient(180deg, #1B2A45 0%, #121D31 50%, #0B1322 100%);
  --bg: #0B1322;
  --smooth: #5CC0B3; --light: #E0B54E; --moderate: #E38F55; --severe: #C57EA0;
} }
* { box-sizing: border-box; }
html { background: var(--bg); }
body { margin: 0; min-height: 100vh; background: var(--sky) no-repeat; color: var(--ink);
  font: 17px/1.55 "Atkinson", -apple-system, BlinkMacSystemFont, sans-serif; }
main { max-width: 720px; margin: 0 auto; padding: 40px 16px 72px; }
h1, h2, h3 { font-family: "Familjen", -apple-system, sans-serif; line-height: 1.15; }
h1 { font-size: clamp(1.9rem, 6vw, 2.6rem); margin: .25em 0 .35em; font-weight: 700; }
h2 { font-size: 1.3rem; margin: 2em 0 .6em; font-weight: 600; }
a { color: var(--accent); }
.eyebrow { font: 500 .78rem/1 "Plex Mono", ui-monospace, monospace; letter-spacing: .1em; text-transform: uppercase;
  color: var(--ink2); }
.eyebrow a { color: inherit; text-decoration: none; }
.lede { font-size: 1.15rem; }
.muted { color: var(--ink2); }
.small { font-size: .9rem; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 18px; padding: 6px 18px;
  backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); }
.day + .day { margin-top: 14px; }
.day h3 { font-size: 1.05rem; margin: 12px 0 4px; font-weight: 600; }
.row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 0;
  border-top: 1px solid var(--line); }
.row:first-of-type { border-top: 0; }
.when { min-width: 0; }
.when b { display: block; }
.when span { color: var(--ink2); font-size: .9rem; }
.grade { display: inline-flex; align-items: center; gap: 8px; font-weight: 700; white-space: nowrap; }
.dot { width: 12px; height: 12px; border-radius: 50%; background: var(--c); flex: none; }
.g-smooth, .g-mostly_smooth { --c: var(--smooth); }
.g-some_bumps { --c: var(--light); }
.g-bumpy { --c: var(--moderate); }
.g-rough { --c: var(--severe); }
.best { font: 500 .7rem/1 "Plex Mono", ui-monospace, monospace; letter-spacing: .08em; text-transform: uppercase;
  color: var(--accent); margin-left: 6px; }
.cta { margin: 28px 0; padding: 22px 20px; border-radius: 18px; background: var(--card); border: 1px solid var(--line); }
.cta h2 { margin: 0 0 .3em; }
.button { display: inline-block; margin-top: 10px; padding: 12px 20px; border-radius: 999px; background: var(--accent);
  color: #fff; font-weight: 700; text-decoration: none; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) .button { color: #0B1322; } }
.stale { display: none; padding: 12px 16px; border-radius: 12px; border: 1px solid var(--moderate); margin: 16px 0; }
.stale.on { display: block; }
.routes { list-style: none; padding: 0; margin: 0; }
.routes li { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 12px 0;
  border-top: 1px solid var(--line); }
.routes li:first-child { border-top: 0; }
.routes a { font-weight: 700; text-decoration: none; }
.routes .grade { font-weight: 400; font-size: .95rem; }
footer { margin-top: 48px; }
footer p { margin: .4em 0; }
"""

# Relabels dates as Today / Tomorrow in the viewer's own day, and flags a page that's gone stale
# (the host kept serving it after the hourly rebuild stopped).
SCRIPT = """
(function () {
  var page = document.documentElement;
  var generated = new Date(page.dataset.generated);
  if (Date.now() - generated.getTime() > 6 * 3600 * 1000) {
    var s = document.querySelector(".stale"); if (s) s.classList.add("on");
  }
  var fmt = function (d) { return d.toLocaleDateString("en-CA"); };
  var today = new Date(), tomorrow = new Date(Date.now() + 86400000);
  document.querySelectorAll("[data-date]").forEach(function (el) {
    var label = el.dataset.date === fmt(today) ? "Today" : el.dataset.date === fmt(tomorrow) ? "Tomorrow" : null;
    if (label) el.textContent = label + ", " + el.textContent.split(", ").slice(1).join(", ");
  });
})();
"""


def head(title: str, description: str, canonical: str, generated: str, extra: str = "") -> str:
    return f"""<!doctype html>
<html lang="en" data-generated="{escape(generated)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)}</title>
<meta name="description" content="{escape(description)}">
<link rel="canonical" href="{escape(canonical)}">
<meta name="apple-itunes-app" content="app-id={rpt.APP_ID}">
<meta property="og:title" content="{escape(title)}">
<meta property="og:description" content="{escape(description)}">
<meta property="og:url" content="{escape(canonical)}">
<meta property="og:type" content="website">
<meta name="theme-color" content="#1B2A45" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#CFE3F3" media="(prefers-color-scheme: light)">
<link rel="stylesheet" href="/sky.css">
{extra}</head>
"""


def footer(updated: str) -> str:
    return f"""<footer class="small muted">
<p>Updated {escape(updated)}. Rebuilt every hour.</p>
<p>Forecasts are guidance, not guarantees. Always follow crew instructions and keep your seatbelt fastened while seated.</p>
<p><a href="/">BumpCast</a> · <a href="/routes/">All routes</a> · <a href="/support.html">Support</a> · <a href="/privacy.html">Privacy</a></p>
</footer>
<script>{SCRIPT}</script>
"""


def grade_html(grade: str, title: str | None = None) -> str:
    return f'<span class="grade g-{escape(grade)}"><span class="dot"></span>{escape(title or rpt.GRADE_TITLES[grade])}</span>'


def updated_text(report: dict) -> str:
    at = rpt.parse_time(report["generated_at"]).astimezone(rpt.ZoneInfo("America/New_York"))
    return f"{rpt.short_day(at.date())} at {rpt.clock(at)} ET"


def day_sentence(route: dict, on: date, first: bool) -> str | None:
    s = rpt.summary(route, on)
    if s is None:
        return None
    subject = rpt.city_title(route, "to") if first else "it"
    text = f"{rpt.day_title(on)}: {subject} {rpt.GRADE_PHRASES[s['grade']]}"
    if s["varies"]:
        text += f" at worst, and the {s['best']['slot']} departure looks smoothest"
    return text + "."


def answer(route: dict) -> str:
    sentences = []
    for d in route["days"]:
        if s := day_sentence(route, date.fromisoformat(d["date"]), not sentences):
            sentences.append(s)
    return " ".join(sentences) or "Forecasts for this route are being updated."


def day_block(route: dict, d: dict) -> str:
    on = date.fromisoformat(d["date"])
    tz = route["origin"]["tz"]
    best = rpt.smoothest(d["departures"])
    varies = len({x["grade"] for x in rpt.ready(d["departures"])}) > 1
    rows = []
    for dep in d["departures"]:
        at = rpt.local(dep["departure_at"], tz)
        when = f"<b>{rpt.SLOT_TITLES.get(dep['slot'], dep['slot'].title())}</b><span>Leaving {rpt.clock(at)} local</span>"
        if dep["status"] == "ready":
            tag = '<span class="best">Smoothest</span>' if varies and dep is best else ""
            grade = grade_html(dep["grade"], dep["grade_title"]) + tag
            note = f'<span class="small muted">{escape(dep["confidence_title"])}</span>'
        else:
            grade, note = '<span class="muted">Not available</span>', ""
        rows.append(f'<div class="row"><div class="when">{when}{note and "<br>" + note}</div><div>{grade}</div></div>')
    return f"""<div class="day"><h3 data-date="{on.isoformat()}">{escape(rpt.day_title(on))}</h3>
{''.join(rows)}</div>"""


def faq(route: dict) -> str:
    o, d = route["origin"], route["destination"]
    items = [
        (f"Will my flight from {o['city']} to {d['city']} be bumpy?", answer(route)),
        (
            f"What's the smoothest time to fly {o['iata']} to {d['iata']}?",
            " ".join(
                f"{rpt.day_title(date.fromisoformat(x['date']))}: the {b['slot']} departure ({b['grade_title'].lower()})."
                for x in route["days"]
                if (b := rpt.smoothest(x["departures"]))
            ) or "Forecasts for this route are being updated.",
        ),
        (
            "Is turbulence dangerous?",
            "Airliners are built to handle far more turbulence than they meet in normal flying. Most turbulence "
            "injuries happen to people who aren't wearing a seatbelt, so keep it fastened while seated.",
        ),
    ]
    data = {
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "mainEntity": [
            {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in items
        ],
    }
    return f'<script type="application/ld+json">{json.dumps(data)}</script>\n'


def accuracy_html(stats: dict | None) -> str:
    if not stats or (stats.get("reports") or 0) < MIN_ACCURACY_REPORTS:
        return ""
    share = round(100 * stats["within_one"] / stats["reports"])
    return (
        f"<h2>How accurate is it?</h2><p>After landing, BumpCast asks how bumpy the flight really felt. "
        f"Of {stats['reports']:,} flights rated so far, {share}% felt the way the forecast said, or within one level.</p>"
    )


def route_page(route: dict, report: dict, others: list[dict], stats: dict | None, base: str) -> str:
    o, d = route["origin"], route["destination"]
    canonical = f"{base}/routes/{route['slug']}/"
    title = f"{o['iata']} to {d['iata']} turbulence forecast: {o['city']} to {d['city']} | BumpCast"
    description = (
        f"Will {o['city']} to {d['city']} be bumpy? Today's and tomorrow's turbulence forecast for "
        f"{o['iata']} → {d['iata']}, by departure time. Updated every hour."
    )
    duration = route.get("duration_min")
    flight_time = f" About {duration // 60} h {duration % 60:02d} min in the air." if duration else ""
    reverse = next((r for r in others if r["origin"]["iata"] == d["iata"] and r["destination"]["iata"] == o["iata"]), None)
    nearby = [r for r in others if r is not reverse and r["origin"]["iata"] == o["iata"]][:6]
    links = []
    if reverse:
        links.append(f'<li><a href="/routes/{reverse["slug"]}/">{escape(rpt.route_title(reverse))}</a>'
                     f'<span class="muted small">The way back</span></li>')
    links += [f'<li><a href="/routes/{r["slug"]}/">{escape(rpt.route_title(r))}</a>'
              f'<span class="muted small">{escape(rpt.city_title(r))}</span></li>' for r in nearby]
    more = f'<h2>More routes</h2><ul class="routes">{"".join(links)}</ul>' if links else ""
    return f"""{head(title, description, canonical, report["generated_at"], faq(route))}<body>
<main>
<p class="eyebrow"><a href="/routes/">BumpCast Sky Report</a></p>
<h1>Will {escape(o['city'])} to {escape(d['city'])} be bumpy?</h1>
<p class="lede">{escape(answer(route))}</p>
<p class="muted small">{escape(o['iata'])} {escape(o['name'])} → {escape(d['iata'])} {escape(d['name'])}.{flight_time}</p>
<div class="stale">This page hasn't been updated for a few hours. Check your flight in the app for the latest forecast.</div>
<div class="card">{''.join(day_block(route, x) for x in route["days"])}</div>
<p class="small muted">Grades for typical departures on this route. An early outlook comes 48 hours before departure; a confirmed forecast takes over on the day you fly.</p>
<div class="cta">
<h2>Your flight, minute by minute</h2>
<p>Add your flight number and BumpCast shows when the bumps will come, how strong they'll be and when they'll end, with an update if the weather changes before you board. Your first forecasts are free.</p>
<a class="button" href="{rpt.APP_STORE_URL}">Get BumpCast on the App Store</a>
</div>
{accuracy_html(stats)}
<h2>Why flights get bumpy</h2>
<p>Turbulence is weather. Fast winds high up (the jet stream), air flowing over mountains, and rising air near clouds all make the ride uneven. Like other weather, it can be forecast, and it changes during the day, which is why one departure can be smoother than another.</p>
{more}
{footer(updated_text(report))}</main>
</body>
</html>
"""


def index_page(report: dict, base: str) -> str:
    routes = sorted(report["routes"], key=lambda r: (r["origin"]["city"], r["destination"]["city"]))
    days = sorted({x["date"] for r in routes for x in r["days"]})
    last = date.fromisoformat(days[-1]) if days else None
    items = []
    for r in routes:
        s = rpt.summary(r, last) if last else None
        grade = grade_html(s["grade"]) if s else '<span class="muted">Updating</span>'
        items.append(f'<li><span><a href="/routes/{r["slug"]}/">{escape(rpt.route_title(r))}</a><br>'
                     f'<span class="small muted">{escape(rpt.city_title(r))}</span></span>{grade}</li>')
    title = "Turbulence forecasts for popular routes, today and tomorrow | BumpCast"
    description = "Will your flight be bumpy? Turbulence forecasts for popular US and Canadian routes, by departure time. Updated every hour."
    when = f'<span data-date="{last.isoformat()}">{escape(rpt.day_title(last))}</span>' if last else ""
    return f"""{head(title, description, f"{base}/routes/", report["generated_at"])}<body>
<main>
<p class="eyebrow"><a href="/">BumpCast</a></p>
<h1>The Sky Report</h1>
<p class="lede">Turbulence forecasts for {len(routes)} popular routes in the US and Canada, for morning, afternoon and evening departures. Pick a route to see today and tomorrow.</p>
<div class="stale">This page hasn't been updated for a few hours. Check your flight in the app for the latest forecast.</div>
<h2>{when}</h2>
<p class="small muted">The roughest departure of the day on each route.</p>
<div class="card"><ul class="routes">{''.join(items)}</ul></div>
<div class="cta">
<h2>Flying on another route?</h2>
<p>BumpCast forecasts any flight within the continental US and southern Canada. Add your flight number to see when the bumps will come.</p>
<a class="button" href="{rpt.APP_STORE_URL}">Get BumpCast on the App Store</a>
</div>
{footer(updated_text(report))}</main>
</body>
</html>
"""


def paths(report: dict) -> list[str]:
    return ["/", "/routes/", *(f"/routes/{r['slug']}/" for r in report["routes"])]


def sitemap(report: dict, base: str) -> str:
    lastmod = rpt.parse_time(report["generated_at"]).strftime("%Y-%m-%dT%H:%M:%SZ")
    urls = "".join(f"<url><loc>{escape(base + p)}</loc><lastmod>{lastmod}</lastmod></url>" for p in paths(report))
    return f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urls}</urlset>\n'


def robots(base: str) -> str:
    return f"User-agent: *\nAllow: /\nSitemap: {base}/sitemap.xml\n"


def build(report: dict, out: Path, base: str, stats: dict | None = None) -> list[str]:
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(SITE, out)
    (out / "fonts").mkdir()
    for name in FONT_FILES:
        shutil.copy(rpt.FONTS / name, out / "fonts" / name)
    (out / "sky.css").write_text(CSS.lstrip())
    (out / "routes").mkdir()
    (out / "routes" / "index.html").write_text(index_page(report, base))
    for route in report["routes"]:
        others = [r for r in report["routes"] if r is not route]
        path = out / "routes" / route["slug"]
        path.mkdir()
        (path / "index.html").write_text(route_page(route, report, others, stats, base))
    (out / "sitemap.xml").write_text(sitemap(report, base))
    (out / "robots.txt").write_text(robots(base))
    return paths(report)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", nargs="?", help="Report JSON (default: the latest in Supabase)")
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--base-url", required=True, help="The site's public origin, for canonical links")
    parser.add_argument("--allow-sample", action="store_true", help="Build from the sample report (previews only)")
    parser.add_argument("--allow-stale", action="store_true", help="Build from a report older than 3 hours")
    args = parser.parse_args()
    report = rpt.load(args.report)
    rpt.check_fresh(report, datetime.now(UTC), args.allow_stale, args.allow_sample)
    pages = build(report, args.out, args.base_url.rstrip("/"), rpt.accuracy(args.report))
    print(f"{args.out}: {len(pages)} pages")


if __name__ == "__main__":
    main()
