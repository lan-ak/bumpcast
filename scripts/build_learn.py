#!/usr/bin/env python3
"""Build the website's Learn section from the app's Learn library.

The explainers are written once, in ios/BumpCast/Views/LearnView.swift. This script reads them
from there, adds the web-only parts (URL slug, search title, one-line summary, question headings),
and writes into site/:

- learn/index.html and learn/<slug>.html: the Learn hub and one page per explainer, with search
  metadata (title, description, canonical, Open Graph) and JSON-LD (Article, FAQPage, BreadcrumbList).
- learn/*.html.md: a clean Markdown copy of each page for AI agents (the llmstxt.org convention).
- llms-full.txt: llms.txt followed by every explainer in full.
- sitemap.xml: every page on the site.

It also rewrites the "## Learn" section of llms.txt and the Learn section of the home page
(between the learn:start and learn:end comments). Everything in site/learn/ is generated.

    python3 scripts/build_learn.py           # write the files
    python3 scripts/build_learn.py --check   # exit 1 if anything is stale (publish_site.sh runs this)

A new explainer in the app needs an entry in WEB below; the script stops until it has one.
"""
from __future__ import annotations

import argparse
import datetime
import html
import json
import math
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT = ROOT / "ios/BumpCast/Views/LearnView.swift"
SITE = ROOT / "site"
LEARN = SITE / "learn"

SITE_URL = "https://bumpcast.app"
APP_ID = "6824269447"
APP_URL = f"https://apps.apple.com/app/id{APP_ID}"
ICON_URL = f"{SITE_URL}/icon.png"
PUBLISHED = "2026-11-06"
UPDATED = "2026-11-06"  # Bump when the explainers' words change.

GROUPS = {"causes": "Why it gets bumpy", "basics": "Good to know"}


@dataclass(frozen=True)
class Web:
    """The web-only parts of an explainer. The questions head the app's three sections
    ("What's happening", "What the crew is doing", "What you'll feel"), in that order."""
    slug: str
    title: str
    summary: str
    questions: tuple[str, str, str]


WEB = {
    "clear-air": Web(
        "clear-air-turbulence",
        "Clear-Air Turbulence: What It Is and How It Feels",
        "Clear-air turbulence is bumpy air at cruising height, often in clear skies, where the fast jet stream flows next to slower air. It's usually light chop.",
        ("What causes clear-air turbulence?",
         "What do pilots do about clear-air turbulence?",
         "What does clear-air turbulence feel like?")),
    "mountain-wave": Web(
        "mountain-wave-turbulence",
        "Mountain Wave Turbulence: Why It's Bumpy Over Mountains",
        "Mountain waves form when strong wind blows across mountains and makes waves in the air, like water over rocks in a stream. They can reach cruising height.",
        ("What causes mountain wave turbulence?",
         "How do pilots handle mountain waves?",
         "What do mountain waves feel like?")),
    "clouds": Web(
        "turbulence-near-clouds",
        "Turbulence Around Clouds and Storms: What to Expect",
        "Warm air rising inside and around big clouds stirs the air nearby. Bumps in puffy clouds are usually brief, and pilots fly around storms, often by many miles.",
        ("Why is it bumpy around clouds?",
         "How do pilots avoid storms?",
         "What does turbulence near clouds feel like?")),
    "low-level": Web(
        "turbulence-on-takeoff-and-landing",
        "Why Takeoff and Landing Can Be Bumpy",
        "Close to the ground, wind flows over buildings, hills and warm land, so the lowest few thousand feet are often a bit bumpy. It usually lasts only a few minutes.",
        ("Why is it bumpy after takeoff and before landing?",
         "What do pilots do near the ground?",
         "What do bumps near the ground feel like?")),
    "gusty-airport": Web(
        "gusty-takeoffs-and-landings",
        "Gusty Takeoffs and Landings on Windy Days",
        "On a windy day, the wind near the ground speeds up and slows down over buildings and land. You feel it for a few minutes as you climb out and on the way down.",
        ("Why are takeoffs and landings bumpy on windy days?",
         "What do pilots do in gusty wind?",
         "What does a gusty takeoff or landing feel like?")),
    "built": Web(
        "planes-are-built-for-turbulence",
        "Is Turbulence Dangerous? Planes Are Built for It",
        "Airliners are designed and tested to handle forces well beyond anything turbulence produces in normal flight. Turbulence is a comfort issue, not a structural one.",
        ("Are planes built to handle turbulence?",
         "What do pilots do when it gets bumpy?",
         "Why do the drops feel so big?")),
    "seatbelt": Web(
        "why-the-seatbelt-matters",
        "Why Your Seatbelt Matters in Turbulence",
        "Almost all turbulence injuries happen to people who aren't buckled in. Keep your seatbelt loosely fastened whenever you're seated, even with the sign off.",
        ("Who gets hurt in turbulence?",
         "Why do flight attendants sit down?",
         "What does turbulence feel like with your belt on?")),
    "levels": Web(
        "turbulence-levels",
        "Light, Moderate and Strong Turbulence: What Each Feels Like",
        "Light chop is small rhythmic bumps, moderate is noticeable jolts, and strong is hard jolts that push you against your belt. Most flights see light chop at most.",
        ("What are the levels of turbulence?",
         "How do pilots handle moderate and strong turbulence?",
         "What does each level feel like?")),
    "forecast": Web(
        "how-bumpcast-forecasts-turbulence",
        "How BumpCast Forecasts Turbulence for Your Flight",
        "BumpCast gives an advance turbulence forecast up to two days before your flight, then confirms it about 18 hours before departure and updates it every hour until you fly.",
        ("How does BumpCast forecast turbulence?",
         "Does the crew have its own forecast?",
         "How exact is the forecast?")),
}


@dataclass
class Explainer:
    id: str
    group: str
    title: str
    subtitle: str
    diagram: str
    happening: str
    crew: str
    feel: str
    good_to_know: str
    related_ids: list[str] = field(default_factory=list)

    @property
    def web(self) -> Web:
        return WEB[self.id]

    @property
    def file(self) -> str:
        return f"{self.web.slug}.html"

    @property
    def url(self) -> str:
        return f"{SITE_URL}/learn/{self.file}"

    def sections(self) -> list[tuple[str, str, str]]:
        """(anchor, question, answer) for the app's three sections."""
        q = self.web.questions
        return [("happening", q[0], self.happening), ("crew", q[1], self.crew), ("feel", q[2], self.feel)]


# ---------- Reading the app's explainers

FIELD = re.compile(r'(\w+):\s*("(?:[^"\\]|\\.)*"|\.\w+|\[[^\]]*\]|true|false)')
REQUIRED = {"id", "title", "subtitle", "diagram", "happening", "crew", "feel", "goodToKnow"}
KNOWN = REQUIRED | {"relatedIDs", "offersLightChopFeel"}


def swift_string(literal: str) -> str:
    body = literal[1:-1]
    if "\\(" in body:
        sys.exit(f"build_learn: string interpolation isn't supported: {literal}")
    return re.sub(r'\\(["\\nt])', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)


def read_explainers() -> list[Explainer]:
    src = SWIFT.read_text()
    explainers = []
    for group in GROUPS:
        m = re.search(rf"static let {group}: \[Explainer\] = \[(.*?)\n    \]", src, re.S)
        if not m:
            sys.exit(f"build_learn: couldn't find Explainer.{group} in {SWIFT.relative_to(ROOT)}")
        body = "\n".join(line for line in m.group(1).splitlines() if not line.strip().startswith("//"))
        for chunk in re.split(r"\bExplainer\(", body)[1:]:
            fields = dict(FIELD.findall(chunk))
            if missing := REQUIRED - fields.keys():
                sys.exit(f"build_learn: an explainer is missing {sorted(missing)}")
            if unknown := fields.keys() - KNOWN:
                sys.exit(f"build_learn: unknown explainer fields {sorted(unknown)}; teach build_learn.py about them")
            related = re.findall(r'"([^"]*)"', fields.get("relatedIDs", "[]"))
            explainers.append(Explainer(
                id=swift_string(fields["id"]), group=group,
                title=swift_string(fields["title"]), subtitle=swift_string(fields["subtitle"]),
                diagram=fields["diagram"].lstrip("."),
                happening=swift_string(fields["happening"]), crew=swift_string(fields["crew"]),
                feel=swift_string(fields["feel"]), good_to_know=swift_string(fields["goodToKnow"]),
                related_ids=related))
    ids = [e.id for e in explainers]
    if missing := [i for i in ids if i not in WEB]:
        sys.exit(f"build_learn: add a WEB entry (slug, title, summary, questions) for {missing}")
    if stale := sorted(WEB.keys() - set(ids)):
        sys.exit(f"build_learn: WEB has entries for explainers the app no longer has: {stale}")
    for e in explainers:
        if bad := [r for r in e.related_ids if r not in ids]:
            sys.exit(f"build_learn: {e.id} is related to unknown explainers {bad}")
    return explainers


# ---------- Diagrams: the app's ExplainerDiagram Canvas, drawn as SVG

PLANE = ("M21.6 12c0 .75-.85 1.15-1.9 1.15H15.9L10.6 20.6H8.7l3-7.45H6.9l-2 2.75H3.4L4.5 12 3.4 8.1h1.5l2 2.75h4.8"
         "l-3-7.45h1.9l5.3 7.45h3.8c1.05 0 1.9.4 1.9 1.15z")


def diagram(kind: str, w: float, h: float, plane: float, steps: int = 40) -> str:
    """The app draws each wave as 40 straight steps; the larger web diagram uses more, for smooth curves."""
    def wave(y: float, amplitude: float, waves: float) -> str:
        points = []
        for i in range(steps + 1):
            x = w * i / steps
            points.append(f"{x:.1f} {y + math.sin(i / steps * math.pi * 2 * waves) * amplitude:.1f}")
        return "M" + "L".join(points)

    def line(d: str, opacity: float = 1) -> str:
        o = "" if opacity == 1 else f' stroke-opacity="{opacity:g}"'
        return f'<path class="ln" d="{d}"{o}/>'

    def ground(x: float, y: float, rw: float, rh: float, opacity: float) -> str:
        return f'<rect class="gr" x="{x:.1f}" y="{y:.1f}" width="{rw:.1f}" height="{rh:.1f}" fill-opacity="{opacity:g}"/>'

    parts: list[str] = []
    if kind == "jetStream":
        for i, y in enumerate((0.3, 0.5, 0.7)):
            parts.append(line(wave(h * y, h * 0.04 * (i + 1), 2 + i), round(0.35 + 0.2 * i, 2)))
    elif kind == "mountain":
        ridge = [(0, h), (w * 0.3, h * 0.55), (w * 0.45, h * 0.75), (w * 0.6, h * 0.5), (w, h)]
        pts = " ".join(f"{x:.1f},{y:.1f}" for x, y in ridge)
        parts.append(f'<polygon class="gr" points="{pts}" fill-opacity="0.3"/>')
        parts.append(line(wave(h * 0.3, h * 0.08, 2)))
    elif kind == "clouds":
        for x, y, r in ((0.3, 0.55, 0.22), (0.5, 0.45, 0.28), (0.7, 0.55, 0.2)):
            parts.append(f'<circle class="gr" cx="{w * x:.1f}" cy="{h * y:.1f}" r="{h * r:.1f}" fill-opacity="0.25"/>')
        parts.append(line(wave(h * 0.25, h * 0.05, 3)))
    elif kind == "lowLevel":
        parts.append(ground(0, h * 0.85, w, h * 0.15, 0.3))
        parts.append(line(wave(h * 0.6, h * 0.05, 4)))
    elif kind == "gusty":
        parts.append(ground(0, h * 0.85, w, h * 0.15, 0.3))
        parts.append(ground(w * 0.72, h * 0.7, w * 0.08, h * 0.15, 0.25))
        for i, y in enumerate((0.62, 0.74)):
            parts.append(line(wave(h * y, h * 0.03, 1.5 + i * 0.5), 0.5 + 0.25 * i))
    elif kind == "calm":
        parts.append(line(f"M0 {h * 0.55:.1f}H{w:g}"))
    else:
        sys.exit(f"build_learn: no SVG for diagram .{kind}")
    s = plane / 24
    parts.append(f'<path class="pl" transform="translate({w * 0.5 - plane / 2:.1f} {h * 0.4 - plane / 2:.1f}) scale({s:.3f})" d="{PLANE}"/>')
    return (f'<svg class="dg" viewBox="0 0 {w:g} {h:g}" width="{w:g}" height="{h:g}" aria-hidden="true" focusable="false">'
            + "".join(parts) + "</svg>")


# ---------- HTML

def text(s: str) -> str:
    return html.escape(s, quote=False)


def attr(s: str) -> str:
    return html.escape(s, quote=True).replace("&#x27;", "'")


def json_ld(data: dict) -> str:
    raw = json.dumps(data, ensure_ascii=False, indent=1).replace("</", "<\\/")
    return f'<script type="application/ld+json">\n{raw}\n</script>'


def long_date(iso: str) -> str:
    d = datetime.date.fromisoformat(iso)
    return f"{d:%B} {d.day}, {d.year}"


def page_title(title: str) -> str:
    full = f"{title} · BumpCast"
    return full if len(full) <= 65 else title


ORG = {"@type": "Organization", "@id": f"{SITE_URL}/#org", "name": "Akinyemi & Co Ltd", "url": f"{SITE_URL}/",
       "logo": ICON_URL, "email": "support@akinyemi.ca"}
WEBSITE = {"@type": "WebSite", "@id": f"{SITE_URL}/#website", "name": "BumpCast", "url": f"{SITE_URL}/",
           "inLanguage": "en", "publisher": {"@id": ORG["@id"]}}
APP = {"@type": "MobileApplication", "@id": f"{SITE_URL}/#app", "name": "BumpCast", "operatingSystem": "iOS",
       "applicationCategory": "TravelApplication", "url": f"{SITE_URL}/", "installUrl": APP_URL,
       "publisher": {"@id": ORG["@id"]}}


def head(*, title: str, description: str, url: str, og_type: str, og_title: str, markdown: str, data: dict) -> str:
    article_times = (f'\n<meta property="article:published_time" content="{PUBLISHED}">'
                     f'\n<meta property="article:modified_time" content="{UPDATED}">') if og_type == "article" else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{text(title)}</title>
<meta name="description" content="{attr(description)}">
<link rel="canonical" href="{url}">
<meta name="robots" content="index, follow, max-snippet:-1, max-image-preview:large">
<meta name="apple-itunes-app" content="app-id={APP_ID}">
<meta property="og:type" content="{og_type}">
<meta property="og:site_name" content="BumpCast">
<meta property="og:title" content="{attr(og_title)}">
<meta property="og:description" content="{attr(description)}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{ICON_URL}">
<meta name="twitter:card" content="summary">{article_times}
<link rel="alternate" type="text/markdown" href="{markdown}" title="Markdown">
<link rel="icon" href="../favicon.png" type="image/png">
<link rel="apple-touch-icon" href="../apple-touch-icon.png">
<link rel="stylesheet" href="../style.css">
<script src="../sky.js"></script>
{json_ld(data)}
</head>
<body>
<header class="nav"><div class="nav-inner">
  <a class="brand" href="../"><img src="../icon.png" alt="" width="30" height="30">BumpCast</a>
  <nav aria-label="Site"><a href="./"{' aria-current="page"' if og_type == "website" else ""}>Learn</a><a class="hide-sm" href="../support.html">Support</a><a class="hide-sm" href="../privacy.html">Privacy</a><a class="pill" href="{APP_URL}">Get the app</a></nav>
</div></header>
"""


FOOT = f"""<footer>
  <nav aria-label="Footer"><a href="../">Home</a><a href="./">Learn</a><a href="../support.html">Support</a><a href="../privacy.html">Privacy Policy</a><a href="../email.html">Email access</a><a href="../terms.html">Terms of Use</a></nav>
  <p>© 2026 Akinyemi &amp; Co Ltd · <a href="mailto:support@akinyemi.ca">support@akinyemi.ca</a></p>
</footer>
</body>
</html>
"""

CTA = f"""<aside class="app-cta" aria-labelledby="cta-h">
  <div>
    <p class="eyebrow">BumpCast for iPhone</p>
    <h2 id="cta-h">Know when the bumps will come.</h2>
    <p class="muted">Live flight status and a calm turbulence forecast for your exact route: when the bumps will come, how strong they'll be, and when they'll end. Covers the continental United States and southern Canada.</p>
  </div>
  <div class="actions"><a class="button" href="{APP_URL}">Download on the App Store</a><span class="muted small">Free · No ads · No account</span></div>
</aside>
"""


def crumbs(*items: tuple[str, str | None]) -> str:
    lis = "".join(f'<li><a href="{href}">{text(name)}</a></li>' if href else f'<li aria-current="page">{text(name)}</li>'
                  for name, href in items)
    return f'<nav class="crumbs" aria-label="Breadcrumb"><ol>{lis}</ol></nav>'


def breadcrumb_ld(*items: tuple[str, str | None]) -> dict:
    return {"@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": i, "name": name, **({"item": url} if url else {})}
        for i, (name, url) in enumerate(items, 1)]}


def article_html(e: Explainer, by_id: dict[str, Explainer]) -> str:
    w = e.web
    data = {"@context": "https://schema.org", "@graph": [
        {"@type": "Article", "@id": f"{e.url}#article", "headline": e.title, "alternativeHeadline": e.subtitle,
         "description": w.summary, "url": e.url, "mainEntityOfPage": e.url, "inLanguage": "en",
         "articleSection": GROUPS[e.group], "datePublished": PUBLISHED, "dateModified": UPDATED, "image": ICON_URL,
         "author": {"@id": ORG["@id"]}, "publisher": {"@id": ORG["@id"]},
         "isPartOf": {"@id": f"{SITE_URL}/learn/#collection"}, "mentions": {"@id": APP["@id"]}},
        {"@type": "FAQPage", "@id": f"{e.url}#faq", "url": e.url, "mainEntity": [
            {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}}
            for _, q, a in e.sections()]},
        breadcrumb_ld(("Home", f"{SITE_URL}/"), ("Learn", f"{SITE_URL}/learn/"), (e.title, None)),
        ORG, APP]}
    sections = "\n".join(
        f'  <section aria-labelledby="{anchor}"><h2 id="{anchor}">{text(q)}</h2><p>{text(a)}</p></section>'
        for anchor, q, a in e.sections())
    if e.related_ids:
        more_title, more = "More turbulence types", [by_id[r] for r in e.related_ids]
    else:
        more_title, more = "More to know", [o for o in by_id.values() if o.group == e.group and o.id != e.id]
    chips = "".join(f'<li><a href="{o.file}" title="{attr(o.subtitle)}">{text(o.title)}</a></li>' for o in more)
    return (head(title=page_title(w.title), description=w.summary, url=e.url, og_type="article", og_title=e.title,
                 markdown=f"{e.file}.md", data=data)
            + f"""
<main class="learn read">
{crumbs(("Home", "../"), ("Learn", "./"), (e.title, None))}
<article class="explainer">
  <header>
    <p class="eyebrow">{text(GROUPS[e.group])}</p>
    <h1>{text(e.title)}</h1>
    <p class="lede">{text(w.summary)}</p>
  </header>
  <figure class="diagram">{diagram(e.diagram, 360, 140, 16, steps=120)}</figure>
{sections}
  <aside class="good" aria-labelledby="good-h"><h2 id="good-h">Good to know</h2><p>{text(e.good_to_know)}</p></aside>
  <p class="updated muted small">Updated <time datetime="{UPDATED}">{long_date(UPDATED)}</time> · From the Learn library in the BumpCast app · <a href="{e.file}.md">Markdown</a></p>
  <section class="more" aria-labelledby="more-h"><h2 id="more-h">{more_title}</h2><ul class="chips">{chips}</ul></section>
</article>
{CTA}</main>

""" + FOOT)


HUB_TITLE = "Turbulence, explained."
HUB_SEO_TITLE = "Turbulence Explained: Why Flights Get Bumpy"
HUB_SUMMARY = ("Why flights get bumpy, what the crew is doing, and what you'll feel. Short, factual explainers from "
               "the BumpCast app: clear-air turbulence, mountain waves, clouds, windy takeoffs and landings, and why "
               "planes are built for it.")
HUB_DESCRIPTION = ("Why flights get bumpy: clear-air turbulence, mountain waves, clouds, windy takeoffs and landings, "
                   "and why planes are built for it. Calm explainers from BumpCast.")


def hub_html(explainers: list[Explainer]) -> str:
    url = f"{SITE_URL}/learn/"
    data = {"@context": "https://schema.org", "@graph": [
        {"@type": "CollectionPage", "@id": f"{url}#collection", "name": HUB_SEO_TITLE, "description": HUB_DESCRIPTION,
         "url": url, "inLanguage": "en", "dateModified": UPDATED, "isPartOf": {"@id": WEBSITE["@id"]},
         "publisher": {"@id": ORG["@id"]}, "mainEntity": {"@id": f"{url}#list"}},
        {"@type": "ItemList", "@id": f"{url}#list", "numberOfItems": len(explainers), "itemListElement": [
            {"@type": "ListItem", "position": i, "url": e.url, "name": e.title, "description": e.web.summary}
            for i, e in enumerate(explainers, 1)]},
        breadcrumb_ld(("Home", f"{SITE_URL}/"), ("Learn", None)),
        WEBSITE, ORG]}
    groups = []
    for group, label in GROUPS.items():
        cards = "\n".join(
            f'    <li><a class="card" href="{e.file}">{diagram(e.diagram, 56, 40, 14)}'
            f'<span><b>{text(e.title)}</b><span>{text(e.subtitle)}</span></span></a></li>'
            for e in explainers if e.group == group)
        groups.append(f"""<section class="learn-group" aria-labelledby="{group}-h">
  <h2 class="eyebrow" id="{group}-h">{text(label)}</h2>
  <ul class="cards">
{cards}
  </ul>
</section>""")
    return (head(title=page_title(HUB_SEO_TITLE), description=HUB_DESCRIPTION, url=url, og_type="website",
                 og_title=HUB_SEO_TITLE, markdown="index.html.md", data=data)
            + f"""
<main class="learn">
{crumbs(("Home", "../"), ("Learn", None))}
<header class="learn-head">
  <p class="eyebrow">Learn</p>
  <h1>{text(HUB_TITLE)}</h1>
  <p class="lede">{text(HUB_SUMMARY)}</p>
</header>
{chr(10).join(groups)}
{CTA}</main>

""" + FOOT)


HOME_START = "<!-- learn:start (generated by scripts/build_learn.py) -->"
HOME_END = "<!-- learn:end -->"


def home_section(explainers: list[Explainer]) -> str:
    cols = []
    for group, label in GROUPS.items():
        links = "".join(f'<li><a href="learn/{e.file}">{text(e.title)}</a> <span class="muted">{text(e.subtitle)}</span></li>'
                        for e in explainers if e.group == group)
        cols.append(f'<div><h3>{text(label)}</h3><ul class="links">{links}</ul></div>')
    return f"""{HOME_START}
<section class="split" id="learn" aria-labelledby="learn-h">
  <div>
    <p class="eyebrow">Learn</p>
    <h2 id="learn-h">{text(HUB_TITLE)}</h2>
    <p class="muted">The app's short, factual explainers, open to everyone: why flights get bumpy, what the crew is doing, and what you'll feel.</p>
    <p><a href="learn/">Read all the explainers</a></p>
  </div>
  <div class="plan-list">
    {(chr(10) + '    ').join(cols)}
  </div>
</section>
{HOME_END}"""


# ---------- Markdown, llms.txt, llms-full.txt

def md_link(e: Explainer) -> str:
    return f"[{e.title}]({e.url}.md)"


def article_md(e: Explainer, by_id: dict[str, Explainer], level: int = 1) -> str:
    h = "#" * level
    out = [f"{h} {e.title}", "", f"> {e.subtitle}.", "", e.web.summary, ""]
    for _, q, a in e.sections():
        out += [f"{h}# {q}", "", a, ""]
    out += [f"{h}# Good to know", "", e.good_to_know, ""]
    if e.related_ids:
        out += [f"{h}# More turbulence types", ""] + [f"- {md_link(by_id[r])}: {by_id[r].subtitle}" for r in e.related_ids] + [""]
    out += [f"Source: {e.url} (updated {UPDATED}). From the Learn library in BumpCast, the flight tracker with "
            f"turbulence forecasts for nervous flyers: {APP_URL}", ""]
    return "\n".join(out)


def hub_md(explainers: list[Explainer]) -> str:
    out = [f"# {HUB_SEO_TITLE}", "", f"> {HUB_SUMMARY}", ""]
    for group, label in GROUPS.items():
        out += [f"## {label}", ""]
        out += [f"- {md_link(e)}: {e.web.summary}" for e in explainers if e.group == group]
        out.append("")
    out += [f"Source: {SITE_URL}/learn/ (updated {UPDATED}). Every explainer in one file: {SITE_URL}/llms-full.txt", ""]
    return "\n".join(out)


def llms_learn_section(explainers: list[Explainer]) -> str:
    out = ["## Learn: turbulence explained", "",
           f"The app's Learn library, published at {SITE_URL}/learn/. Short, factual explainers: why flights get bumpy, "
           "what the crew is doing, and what you'll feel. Each link is the Markdown copy of the page (drop the .md for "
           f"the web page). All of them in full: {SITE_URL}/llms-full.txt", ""]
    for group, label in GROUPS.items():
        out += [f"### {label}", ""]
        out += [f"- {md_link(e)}: {e.web.summary}" for e in explainers if e.group == group]
        out.append("")
    return "\n".join(out)


def with_learn_section(llms: str, section: str) -> str:
    m = re.search(r"^## Learn\b.*?(?=^## )", llms, re.S | re.M)
    if m:
        return llms[:m.start()] + section + "\n" + llms[m.end():]
    m = re.search(r"^## Pages\b", llms, re.M)
    if not m:
        sys.exit("build_learn: llms.txt has no '## Pages' section to put Learn before")
    return llms[:m.start()] + section + "\n" + llms[m.start():]


def llms_full(llms: str, explainers: list[Explainer], by_id: dict[str, Explainer]) -> str:
    out = [llms.rstrip(), "", "---", "", "# Learn library: every explainer in full", ""]
    for group, label in GROUPS.items():
        out += [f"## {label}", ""]
        out += [article_md(e, by_id, level=3) for e in explainers if e.group == group]
    return "\n".join(out).rstrip() + "\n"


# ---------- Sitemap

def sitemap(explainers: list[Explainer]) -> str:
    pages = sorted(p.name for p in SITE.glob("*.html") if p.name not in {"404.html", "index.html"})
    urls = [(f"{SITE_URL}/", None), (f"{SITE_URL}/learn/", UPDATED)]
    urls += [(e.url, UPDATED) for e in explainers]
    urls += [(f"{SITE_URL}/{p}", None) for p in pages]
    rows = "".join(f"  <url><loc>{u}</loc>{f'<lastmod>{d}</lastmod>' if d else ''}</url>\n" for u, d in urls)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + rows + "</urlset>\n")


# ---------- Main

def build() -> dict[Path, str]:
    explainers = read_explainers()
    by_id = {e.id: e for e in explainers}
    out: dict[Path, str] = {LEARN / "index.html": hub_html(explainers), LEARN / "index.html.md": hub_md(explainers)}
    for e in explainers:
        out[LEARN / e.file] = article_html(e, by_id)
        out[LEARN / f"{e.file}.md"] = article_md(e, by_id)

    llms = with_learn_section((SITE / "llms.txt").read_text(), llms_learn_section(explainers))
    out[SITE / "llms.txt"] = llms
    out[SITE / "llms-full.txt"] = llms_full(llms, explainers, by_id)
    out[SITE / "sitemap.xml"] = sitemap(explainers)

    home = (SITE / "index.html").read_text()
    start, end = home.find(HOME_START), home.find(HOME_END)
    if start < 0 or end < 0:
        sys.exit(f"build_learn: site/index.html needs the {HOME_START!r} and {HOME_END!r} markers")
    out[SITE / "index.html"] = home[:start] + home_section(explainers) + home[end + len(HOME_END):]
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="exit 1 if any generated file is out of date")
    args = parser.parse_args()

    out = build()
    stale = [p for p, content in out.items() if not p.exists() or p.read_text() != content]
    extra = sorted(p for p in LEARN.glob("*") if p not in out) if LEARN.exists() else []
    rel = lambda p: str(p.relative_to(ROOT))  # noqa: E731

    if args.check:
        if stale or extra:
            for p in stale:
                print(f"out of date: {rel(p)}")
            for p in extra:
                print(f"not generated: {rel(p)}")
            sys.exit("Run python3 scripts/build_learn.py and commit the result.")
        print(f"Learn pages are up to date ({len(out)} files).")
        return

    LEARN.mkdir(exist_ok=True)
    for p in stale:
        p.write_text(out[p])
        print(f"wrote {rel(p)}")
    for p in extra:
        p.unlink()
        print(f"removed {rel(p)}")
    if not stale and not extra:
        print("Nothing to change.")


if __name__ == "__main__":
    main()
