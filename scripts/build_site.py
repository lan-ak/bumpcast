#!/usr/bin/env python3
"""Build the website's generated pages: Learn (the app's explainers) and Routes (turbulence by route).

Learn: the explainers are written once, in ios/BumpCast/Views/LearnView.swift. This script reads
them from there and adds the web-only parts: WEB (URL slug, search title, summary, question
headings) and MORE ("In more detail" questions, each citing SOURCES).

Routes: scripts/data/routes.json, a year of pilot reports along popular routes and gusts at their
airports, made by scripts/route_data.py (which needs the network; this script doesn't).

It writes into site/:

- learn/ and routes/: a hub and one page per explainer or route, with search metadata (title,
  description, canonical, Open Graph) and JSON-LD (Article, FAQPage, BreadcrumbList, and Dataset
  on route pages), plus a clean Markdown copy of each page (<page>.html.md, the llmstxt.org
  convention). Everything in these two folders is generated.
- llms-full.txt: llms.txt followed by every explainer and route in full.
- sitemap.xml: every page on the site.

It also rewrites the "## Learn" and "## Routes" sections of llms.txt and the generated block of the
home page (between the learn:start and learn:end comments).

    python3 scripts/build_site.py           # write the files
    python3 scripts/build_site.py --check   # exit 1 if anything is stale (publish_site.sh runs this)

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
ROUTES = SITE / "routes"
ROUTE_DATA = ROOT / "scripts/data/routes.json"

SITE_URL = "https://bumpcast.app"
APP_ID = "6824269447"
APP_URL = f"https://apps.apple.com/app/id{APP_ID}"
ICON_URL = f"{SITE_URL}/icon.png"
PUBLISHED = "2026-11-06"
UPDATED = "2026-11-07"  # Bump when the explainers' words (or MORE) change.

# App Store campaign links, so App Store Connect (Analytics, Acquisition, Campaigns) counts
# downloads by page. Fill in the provider token from App Store Connect; until then the buttons
# link to the plain listing. APP_STORE_PPID (optional) sends visitors to a custom product page.
APP_STORE_PT = ""
APP_STORE_PPID = ""


def app_link(campaign: str) -> str:
    """The App Store link for a page's buttons: campaign `campaign` (40 characters at most)."""
    if not APP_STORE_PT:
        return APP_URL
    query = f"pt={APP_STORE_PT}&ct={campaign[:40]}&mt=8" + (f"&ppid={APP_STORE_PPID}" if APP_STORE_PPID else "")
    return f"https://apps.apple.com/app/apple-store/id{APP_ID}?{query}"


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


@dataclass(frozen=True)
class Source:
    title: str
    publisher: str
    url: str


# Every fact in MORE comes from one of these, checked word for word against the source on
# 2026-11-07. Keep the answers to what the source says; numbers the sources don't state
# (2.5 x 1.5 = 3.75 g, 56 ft/s in mph) are shown as arithmetic.
SOURCES = {
    "awh": Source("Aviation Weather Handbook (FAA-H-8083-28B), 2026", "Federal Aviation Administration",
                  "https://www.faa.gov/sites/faa.gov/files/FAA-H-8083-28B.pdf"),
    "aim-7-1": Source("Aeronautical Information Manual, chapter 7, section 1: Meteorology", "Federal Aviation Administration",
                      "https://www.faa.gov/air_traffic/publications/atpubs/aim_html/chap7_section_1.html"),
    "aim-7-6": Source("Aeronautical Information Manual, 7-6-7: Mountain Flying", "Federal Aviation Administration",
                      "https://www.faa.gov/air_traffic/publications/atpubs/aim_html/chap7_section_6.html"),
    "afh-9": Source("Airplane Flying Handbook (FAA-H-8083-3C), chapter 9: Approaches and Landings",
                    "Federal Aviation Administration",
                    "https://www.faa.gov/sites/faa.gov/files/regulations_policies/handbooks_manuals/aviation/airplane_handbook/10_afh_ch9.pdf"),
    "cfr-25-303": Source("14 CFR 25.303: Factor of safety", "Electronic Code of Federal Regulations",
                         "https://www.ecfr.gov/current/title-14/section-25.303"),
    "cfr-25-305": Source("14 CFR 25.305: Strength and deformation", "Electronic Code of Federal Regulations",
                         "https://www.ecfr.gov/current/title-14/section-25.305"),
    "cfr-25-337": Source("14 CFR 25.337: Limit maneuvering load factors", "Electronic Code of Federal Regulations",
                         "https://www.ecfr.gov/current/title-14/section-25.337"),
    "cfr-25-341": Source("14 CFR 25.341: Gust and turbulence loads", "Electronic Code of Federal Regulations",
                         "https://www.ecfr.gov/current/title-14/section-25.341"),
    "cfr-121-317": Source("14 CFR 121.317: Passenger information requirements and seat belt requirements",
                          "Electronic Code of Federal Regulations",
                          "https://www.ecfr.gov/current/title-14/chapter-I/subchapter-G/part-121/subpart-K/section-121.317"),
    "faa-turbulence": Source("Turbulence: Staying Safe", "Federal Aviation Administration",
                             "https://www.faa.gov/travelers/fly_safe/turbulence"),
    "ntsb-ss2101": Source("Preventing Turbulence-Related Injuries in Air Carrier Operations (NTSB/SS-21/01), 2021",
                          "National Transportation Safety Board",
                          "https://www.ntsb.gov/safety/safety-studies/Documents/SS2101.pdf"),
    "bumpcast-routes": Source("Turbulence by route: a year of pilot reports and airport weather", "BumpCast",
                              f"{SITE_URL}/routes/"),
}


@dataclass(frozen=True)
class Detail:
    question: str
    answer: str
    sources: tuple[str, ...]


# "In more detail": web-only questions under the app's explainer, each with its sources.
MORE = {
    "clear-air": (
        Detail("How fast and how high is the jet stream?",
               "Jet streams are narrow bands of strong wind from about 20,000 to 45,000 feet, the heights where airliners cruise. They blow from west to east and can top 275 miles per hour. The speed itself isn't what makes bumps: it's the sharp change in wind speed at the jet's edges, where the air rolls over in waves.",
               ("awh",)),
        Detail("When is clear-air turbulence most common?",
               "In winter. Jet streams follow the boundary between warm and cold air, which is sharpest in winter, so that's when they're strongest. Over the US, clear-air turbulence is found most often on the north side of the jet stream, near the top of the lower atmosphere (the tropopause).",
               ("awh",)),
        Detail("How big is a patch of clear-air turbulence?",
               "Patches near the jet stream are typically 100 to 300 miles long, 50 to 100 miles wide and about 5,000 feet deep, and they can last from half an hour to a day. That's why a climb or descent of a few thousand feet often finds smoother air, and why reports from planes ahead help so much.",
               ("awh",)),
    ),
    "mountain-wave": (
        Detail("How much wind does it take to make mountain waves?",
               "Not much. Wind of 15 knots or more blowing across a range at an angle of at least 30 degrees can set them off, and the waves can roll on for many miles downwind. Satellite pictures of the Rockies have shown them stretching 700 miles.",
               ("aim-7-6",)),
        Detail("How high do mountain waves reach?",
               "Some waves travel upward and can be felt far above the peaks, at times above 60,000 feet. Where they break, the bumps are usually between about 20,000 and 39,000 feet, which is where jets cruise as they cross the range.",
               ("awh",)),
        Detail("Can you see mountain waves?",
               "Sometimes. Smooth, lens-shaped clouds (lenticular clouds) over and downwind of mountains show the waves are there. Smooth edges go with little or no turbulence; lumpy, rolling ones with more. In dry air the waves can be there with no clouds at all. The strongest mountain winds usually come from late autumn to early spring.",
               ("awh",)),
    ),
    "clouds": (
        Detail("How far do pilots stay from thunderstorms?",
               "The FAA tells pilots to stay at least 20 miles from any thunderstorm that's severe or shows up strongly on radar. The rising and sinking air reaches well beyond the cloud: severe turbulence can be found up to 20 miles from a severe storm, and about 10 miles from weaker ones. That margin is why your route might bend around a line of storms.",
               ("aim-7-1",)),
        Detail("Why is it smooth above the clouds?",
               "Puffy, cauliflower-shaped cumulus clouds mark rising air, and their tops show roughly where it stops rising. So it's often bumpy beneath and in them, and generally smooth above. They grow on sunny afternoons over land, which is one reason a summer afternoon climb or descent can feel bumpier than the cruise.",
               ("awh",)),
    ),
    "low-level": (
        Detail("What makes the air bumpy near the ground?",
               "Two things, mostly. Wind tumbling over trees, buildings and hills breaks into eddies; the stronger the wind and the rougher the ground, the bumpier it gets. And on sunny days, ground that heats unevenly (fields, rock, pavement, water) sends up bubbles of warm air.",
               ("awh",)),
        Detail("When is it bumpiest on the way up or down?",
               "Rising warm air is strongest on warm summer afternoons with light wind, so in summer the climb and descent are often calmer in the morning. On windy days, at any time of year, the wind stirs up the lowest few thousand feet instead.",
               ("awh",)),
        Detail("Does the size of the plane matter?",
               "Yes. The FAA notes that the effect of turbulence depends on the size of the aircraft, and the US turbulence forecast is made separately for light, medium and heavy aircraft.",
               ("awh",)),
    ),
    "gusty-airport": (
        Detail("How are gusts reported at airports?",
               "In an airport's weather report (a METAR), a G after the wind speed gives the gusts: 22015G25KT means wind from 220 degrees at 15 knots, gusting to 25 knots. BumpCast calls an end of your flight gusty when the airport's forecast has gusts of 25 knots or more.",
               ("aim-7-1",)),
        Detail("Why do pilots fly a little faster in gusty wind?",
               "Extra speed gives extra control when the wind keeps changing. A common technique taught to pilots is to add half the gust factor to the normal approach speed: with gusts 15 knots above the steady wind, about 7 knots more. Airline crews follow their aircraft maker's and airline's own procedures, which also add a little speed in gusty air.",
               ("afh-9",)),
    ),
    "built": (
        Detail("How strong are airliners built to be?",
               "US rules for airliners (14 CFR Part 25) set the loads a plane must carry. It must handle at least 2.5 g, two and a half times its weight pressing on the wings, without lasting damage. Then a safety factor of 1.5 goes on top: the structure must hold 1.5 times those loads without breaking. That's 2.5 × 1.5, or 3.75 g.",
               ("cfr-25-337", "cfr-25-303", "cfr-25-305")),
        Detail("Are planes designed for gusts and turbulence too?",
               "Yes. The same rules require designers to work out the loads from sudden up, down and sideways gusts, and from continuous turbulence, and to build for them. At sea level the design gust is a sudden 56 feet per second (about 38 mph) of moving air.",
               ("cfr-25-341",)),
    ),
    "seatbelt": (
        Detail("How often are people hurt by turbulence?",
               "Serious injuries are rare. The FAA's count of serious turbulence injuries on US airline flights from 2009 through 2024 lists 40 passengers and 166 crew members: about 2 or 3 passengers a year.",
               ("faa-turbulence",)),
        Detail("Why are flight attendants hurt more often than passengers?",
               "They're the ones up and moving when it gets bumpy. The NTSB found that from 2009 to 2018, flight attendants were 79% of the people seriously injured in turbulence on US airlines. About half of those accidents happened during descent or approach, and 60% below 20,000 feet.",
               ("ntsb-ss2101",)),
        Detail("Does the seatbelt really make a difference?",
               "Yes. Of the 123 passengers and flight attendants seriously injured in those accidents, only one passenger was recorded as wearing a seatbelt at the time. The NTSB found that being seated with your belt fastened is the most effective way to avoid a turbulence injury. On US flights, passengers must keep it fastened while the seatbelt sign is on.",
               ("ntsb-ss2101", "cfr-121-317")),
    ),
    "levels": (
        Detail("How does the FAA describe each level?",
               "By what happens in the cabin. Light: you may feel a slight strain against your seatbelt, loose things may shift a little, and food service and walking carry on. Moderate: a definite strain against the belt, loose things are dislodged, and food service and walking are difficult. Severe: you're forced hard against the belt, loose things are tossed about, and walking is impossible.",
               ("aim-7-1",)),
        Detail("What's the difference between light chop and light turbulence?",
               "Pilots report two kinds of light bumps. Light chop is slight, quick, rhythmic bumpiness without noticeable changes in height or attitude: the gentle rocking most people notice at cruise. Light turbulence is slight, uneven changes in height or attitude.",
               ("aim-7-1",)),
        Detail("How do forecasters measure turbulence?",
               "With eddy dissipation rate (EDR), the international standard for automated turbulence reports. It measures the air itself, not how one plane responds, so it works for any aircraft. BumpCast's levels are set on the EDR scale.",
               ("awh",)),
    ),
    "forecast": (
        Detail("Where does BumpCast's forecast come from?",
               "From about 18 hours before departure, the US National Weather Service's Graphical Turbulence Guidance (GTG): an automated forecast, made every hour, out to 18 hours ahead and from 1,000 to 45,000 feet. Before that, the advance forecast is BumpCast's own, from the winds in two global weather models (NOAA's GFS and ECMWF's), and on its own it never calls anything stronger than light that far out.",
               ("awh",)),
        Detail("What can't a turbulence forecast see?",
               "Mostly the bumps in and around thunderstorms. The national forecast covers clear-air and mountain-wave turbulence but doesn't specifically predict turbulence from storms or small local terrain. So BumpCast also raises your forecast wherever an official turbulence warning (a SIGMET) or a recent pilot report covers your route, and pilots steer around storms on the day.",
               ("awh",)),
    ),
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
    more: list[Detail] = field(default_factory=list)  # MORE, plus any from the route data

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

    def sources(self) -> list[str]:
        """The keys of every source cited in "In more detail", in order of first use."""
        keys: list[str] = []
        for d in self.more:
            keys += [k for k in d.sources if k not in keys]
        return keys


# ---------- Reading the app's explainers

FIELD = re.compile(r'(\w+):\s*("(?:[^"\\]|\\.)*"|\.\w+|\[[^\]]*\]|true|false)')
REQUIRED = {"id", "title", "subtitle", "diagram", "happening", "crew", "feel", "goodToKnow"}
KNOWN = REQUIRED | {"relatedIDs", "offersLightChopFeel"}


def fail(message: str) -> None:
    sys.exit(f"build_site: {message}")


def swift_string(literal: str) -> str:
    body = literal[1:-1]
    if "\\(" in body:
        fail(f"string interpolation isn't supported: {literal}")
    return re.sub(r'\\(["\\nt])', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)


def read_explainers() -> list[Explainer]:
    src = SWIFT.read_text()
    explainers = []
    for group in GROUPS:
        m = re.search(rf"static let {group}: \[Explainer\] = \[(.*?)\n    \]", src, re.S)
        if not m:
            fail(f"couldn't find Explainer.{group} in {SWIFT.relative_to(ROOT)}")
        body = "\n".join(line for line in m.group(1).splitlines() if not line.strip().startswith("//"))
        for chunk in re.split(r"\bExplainer\(", body)[1:]:
            fields = dict(FIELD.findall(chunk))
            if missing := REQUIRED - fields.keys():
                fail(f"an explainer is missing {sorted(missing)}")
            if unknown := fields.keys() - KNOWN:
                fail(f"unknown explainer fields {sorted(unknown)}; teach build_site.py about them")
            related = re.findall(r'"([^"]*)"', fields.get("relatedIDs", "[]"))
            eid = swift_string(fields["id"])
            explainers.append(Explainer(
                id=eid, group=group,
                title=swift_string(fields["title"]), subtitle=swift_string(fields["subtitle"]),
                diagram=fields["diagram"].lstrip("."),
                happening=swift_string(fields["happening"]), crew=swift_string(fields["crew"]),
                feel=swift_string(fields["feel"]), good_to_know=swift_string(fields["goodToKnow"]),
                related_ids=related, more=list(MORE.get(eid, ()))))
    ids = [e.id for e in explainers]
    if missing := [i for i in ids if i not in WEB]:
        fail(f"add a WEB entry (slug, title, summary, questions) for {missing}")
    if stale := sorted((WEB.keys() | MORE.keys()) - set(ids)):
        fail(f"WEB or MORE has entries for explainers the app no longer has: {stale}")
    for e in explainers:
        if bad := [r for r in e.related_ids if r not in ids]:
            fail(f"{e.id} is related to unknown explainers {bad}")
        for d in e.more:
            if bad := [s for s in d.sources if s not in SOURCES]:
                fail(f"{e.id}: unknown sources {bad}")
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
        fail(f"no SVG for diagram .{kind}")
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


def join(items: list[str]) -> str:
    items = list(items)
    if len(items) <= 1:
        return "".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]


ORG = {"@type": "Organization", "@id": f"{SITE_URL}/#org", "name": "Akinyemi & Co Ltd", "url": f"{SITE_URL}/",
       "logo": ICON_URL, "email": "support@akinyemi.ca"}
WEBSITE = {"@type": "WebSite", "@id": f"{SITE_URL}/#website", "name": "BumpCast", "url": f"{SITE_URL}/",
           "inLanguage": "en", "publisher": {"@id": ORG["@id"]}}
APP = {"@type": "MobileApplication", "@id": f"{SITE_URL}/#app", "name": "BumpCast", "operatingSystem": "iOS",
       "applicationCategory": "TravelApplication", "url": f"{SITE_URL}/", "installUrl": APP_URL,
       "publisher": {"@id": ORG["@id"]}}


def head(*, title: str, description: str, url: str, og_type: str, og_title: str, markdown: str, data: dict,
         section: str, hub: bool, campaign: str, app_argument: str | None = None,
         published: str | None = None, modified: str | None = None, scripts: tuple[str, ...] = ()) -> str:
    """The page up to the top bar, for pages in site/learn/ or site/routes/ (`section`). The
    section's own link stays in the top bar on phones; the other one moves to the footer."""
    times = "".join(f'\n<meta property="article:{k}_time" content="{v}">'
                     for k, v in (("published", published), ("modified", modified)) if v)
    banner = f"app-id={APP_ID}" + (f", app-argument={app_argument}" if app_argument else "")
    extra = "".join(f'\n<script src="../{s}" defer></script>' for s in scripts)

    def nav_link(name: str, href: str, own: str) -> str:
        current = ' aria-current="page"' if section == own and hub else ""
        cls = "" if section == own else ' class="hide-sm"'
        return f'<a{cls} href="{href}"{current}>{name}</a>'

    learn = nav_link("Learn", "./" if section == "learn" else "../learn/", "learn")
    routes = nav_link("Routes", "./" if section == "routes" else "../routes/", "routes")
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{text(title)}</title>
<meta name="description" content="{attr(description)}">
<link rel="canonical" href="{url}">
<meta name="robots" content="index, follow, max-snippet:-1, max-image-preview:large">
<meta name="apple-itunes-app" content="{attr(banner)}">
<meta property="og:type" content="{og_type}">
<meta property="og:site_name" content="BumpCast">
<meta property="og:title" content="{attr(og_title)}">
<meta property="og:description" content="{attr(description)}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{ICON_URL}">
<meta name="twitter:card" content="summary">{times}
<link rel="alternate" type="text/markdown" href="{markdown}" title="Markdown">
<link rel="icon" href="../favicon.png" type="image/png">
<link rel="apple-touch-icon" href="../apple-touch-icon.png">
<link rel="stylesheet" href="../style.css">
<script src="../sky.js"></script>{extra}
{json_ld(data)}
</head>
<body>
<header class="nav"><div class="nav-inner">
  <a class="brand" href="../"><img src="../icon.png" alt="" width="30" height="30">BumpCast</a>
  <nav aria-label="Site">{learn}{routes}<a class="hide-sm" href="../support.html">Support</a><a class="hide-sm" href="../privacy.html">Privacy</a><a class="pill" href="{attr(app_link(campaign))}">Get the app</a></nav>
</div></header>
"""


def foot(section: str) -> str:
    learn = "./" if section == "learn" else "../learn/"
    routes = "./" if section == "routes" else "../routes/"
    return f"""<footer>
  <nav aria-label="Footer"><a href="../">Home</a><a href="{learn}">Learn</a><a href="{routes}">Routes</a><a href="../support.html">Support</a><a href="../privacy.html">Privacy Policy</a><a href="../email.html">Email access</a><a href="../terms.html">Terms of Use</a></nav>
  <p>© 2026 Akinyemi &amp; Co Ltd · <a href="mailto:support@akinyemi.ca">support@akinyemi.ca</a></p>
</footer>
</body>
</html>
"""


def cta(campaign: str, heading: str = "Know when the bumps will come.",
        body: str = ("Live flight status and a calm turbulence forecast for your exact route: when the bumps will "
                     "come, how strong they'll be, and when they'll end.")) -> str:
    return f"""<aside class="app-cta" aria-labelledby="cta-h">
  <div>
    <p class="eyebrow">BumpCast for iPhone</p>
    <h2 id="cta-h">{text(heading)}</h2>
    <p class="muted">{text(body)} Covers the continental United States and southern Canada.</p>
  </div>
  <div class="actions"><a class="button" href="{attr(app_link(campaign))}">Download on the App Store</a><span class="muted small">Free · No ads · No account</span></div>
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


def source_ld(key: str) -> dict:
    s = SOURCES[key]
    return {"@type": "CreativeWork", "name": s.title, "url": s.url, "publisher": {"@type": "Organization", "name": s.publisher}}


def source_href(key: str) -> str:
    """A source's link from a Learn page: our own pages relative, the rest as they are."""
    url = SOURCES[key].url
    return "../" + url.removeprefix(f"{SITE_URL}/") if url.startswith(SITE_URL) else url


def source_note(keys: tuple[str, ...]) -> str:
    links = "; ".join(f'<a href="{attr(source_href(k))}">{text(SOURCES[k].title)}</a>' for k in keys)
    return f'<p class="cite">Source: {links}</p>'


# ---------- Learn pages

def article_html(e: Explainer, by_id: dict[str, Explainer], route_chips: dict[str, list]) -> str:
    w = e.web
    qa = [(q, a) for _, q, a in e.sections()] + [(d.question, d.answer) for d in e.more]
    data = {"@context": "https://schema.org", "@graph": [
        {"@type": "Article", "@id": f"{e.url}#article", "headline": e.title, "alternativeHeadline": e.subtitle,
         "description": w.summary, "url": e.url, "mainEntityOfPage": e.url, "inLanguage": "en",
         "articleSection": GROUPS[e.group], "datePublished": PUBLISHED, "dateModified": UPDATED, "image": ICON_URL,
         "author": {"@id": ORG["@id"]}, "publisher": {"@id": ORG["@id"]},
         "isPartOf": {"@id": f"{SITE_URL}/learn/#collection"}, "mentions": {"@id": APP["@id"]},
         **({"citation": [source_ld(k) for k in e.sources()]} if e.more else {})},
        {"@type": "FAQPage", "@id": f"{e.url}#faq", "url": e.url, "mainEntity": [
            {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in qa]},
        breadcrumb_ld(("Home", f"{SITE_URL}/"), ("Learn", f"{SITE_URL}/learn/"), (e.title, None)),
        ORG, APP]}
    sections = "\n".join(
        f'  <section aria-labelledby="{anchor}"><h2 id="{anchor}">{text(q)}</h2><p>{text(a)}</p></section>'
        for anchor, q, a in e.sections())
    detail = ""
    if e.more:
        items = "\n".join(
            f'  <section aria-labelledby="more-{i}"><h2 id="more-{i}">{text(d.question)}</h2><p>{text(d.answer)}</p>'
            f'{source_note(d.sources)}</section>' for i, d in enumerate(e.more, 1))
        refs = "".join(f'<li><a href="{attr(source_href(k))}">{text(SOURCES[k].title)}</a>, '
                       f'{text(SOURCES[k].publisher)}</li>' for k in e.sources())
        detail = f"""  <div class="detail">
  <p class="eyebrow">In more detail</p>
{items}
  <section class="sources" aria-labelledby="sources-h"><h2 id="sources-h">Sources</h2><ol>{refs}</ol></section>
  </div>
"""
    if e.related_ids:
        more_title, more = "More turbulence types", [by_id[r] for r in e.related_ids]
    else:
        more_title, more = "More to know", [o for o in by_id.values() if o.group == e.group and o.id != e.id]
    chips = "".join(f'<li><a href="{o.file}" title="{attr(o.subtitle)}">{text(o.title)}</a></li>' for o in more)
    on_routes = ""
    if route_chips.get(e.id):
        title, routes = route_chips[e.id]
        links = "".join(f'<li><a href="../routes/{r.file}">{text(r.pair)}</a></li>' for r in routes)
        on_routes = (f'  <section class="more" aria-labelledby="routes-h"><h2 id="routes-h">{text(title)}</h2>'
                     f'<ul class="chips">{links}</ul></section>\n')
    return (head(title=page_title(w.title), description=w.summary, url=e.url, og_type="article", og_title=e.title,
                 markdown=f"{e.file}.md", data=data, section="learn", hub=False, campaign=f"web-learn-{e.id}",
                 app_argument=f"bumpcast://learn/{e.id}", published=PUBLISHED, modified=UPDATED)
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
{detail}  <p class="updated muted small">Updated <time datetime="{UPDATED}">{long_date(UPDATED)}</time> · From the Learn library in the BumpCast app · <a href="{e.file}.md">Markdown</a></p>
  <section class="more" aria-labelledby="more-h"><h2 id="more-h">{more_title}</h2><ul class="chips">{chips}</ul></section>
{on_routes}</article>
{cta(f"web-learn-{e.id}")}</main>

""" + foot("learn"))


HUB_TITLE = "Turbulence, explained."
HUB_SEO_TITLE = "Turbulence Explained: Why Flights Get Bumpy"
HUB_SUMMARY = ("Why flights get bumpy, what the crew is doing, and what you'll feel. Short, factual explainers from "
               "the BumpCast app: clear-air turbulence, mountain waves, clouds, windy takeoffs and landings, and why "
               "planes are built for it.")
HUB_DESCRIPTION = ("Why flights get bumpy: clear-air turbulence, mountain waves, clouds, windy takeoffs and landings, "
                   "and why planes are built for it. Calm explainers from BumpCast.")


def hub_html(explainers: list[Explainer], has_routes: bool) -> str:
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
    routes = ("""<p class="learn-next">Flying soon? See <a href="../routes/">turbulence by route</a>: where and when pilots reported bumps on popular routes in the US and Canada.</p>
""" if has_routes else "")
    return (head(title=page_title(HUB_SEO_TITLE), description=HUB_DESCRIPTION, url=url, og_type="website",
                 og_title=HUB_SEO_TITLE, markdown="index.html.md", data=data, section="learn", hub=True,
                 campaign="web-learn")
            + f"""
<main class="learn">
{crumbs(("Home", "../"), ("Learn", None))}
<header class="learn-head">
  <p class="eyebrow">Learn</p>
  <h1>{text(HUB_TITLE)}</h1>
  <p class="lede">{text(HUB_SUMMARY)}</p>
</header>
{chr(10).join(groups)}
{routes}{cta("web-learn")}</main>

""" + foot("learn"))


# ---------- Routes: a year of pilot reports along popular routes (scripts/data/routes.json)

MIN_REPORTS = 400  # a route needs this many reports near it for a page
MIN_MONTH = 25  # and a month this many for its bar
NM_TO_MI = 1.150779
NM_TO_KM = 1.852
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
          "November", "December"]
CENTERS = {"ZAB": "Albuquerque", "ZAU": "Chicago", "ZBW": "Boston", "ZDC": "Washington", "ZDV": "Denver",
           "ZFW": "Fort Worth", "ZHU": "Houston", "ZID": "Indianapolis", "ZJX": "Jacksonville", "ZKC": "Kansas City",
           "ZLA": "Los Angeles", "ZLC": "Salt Lake City", "ZMA": "Miami", "ZME": "Memphis", "ZMP": "Minneapolis",
           "ZNY": "New York", "ZOA": "Oakland", "ZOB": "Cleveland", "ZSE": "Seattle", "ZTL": "Atlanta"}


def total(c: dict) -> int:
    return sum(c.values())


def bumpy(c: dict) -> int:
    """Moderate or stronger."""
    return c["moderate"] + c["severe"]


def duration(minutes: float) -> str:
    h, m = divmod(int(5 * round(minutes / 5)), 60)
    if not h:
        return f"{m} min"
    return f"{h} h" if not m else f"{h} h {m} min"


def rough_duration(minutes: float) -> str:
    """To the quarter hour, for sentences: "5 hours", "2¼ hours", "an hour", "45 minutes"."""
    if minutes < 50:
        return f"{5 * round(minutes / 5)} minutes"
    quarters = round(minutes / 15)
    whole, part = divmod(quarters, 4)
    if quarters == 4:
        return "an hour"
    return f"{whole}{['', '¼', '½', '¾'][part]} hours"


def month_name(key: str, short: bool = False) -> str:
    name = MONTHS[int(key[5:7]) - 1]
    return name[:3] if short else name


def month_year(key: str) -> str:
    return f"{month_name(key)} {key[:4]}"


def share(n: int, of: int) -> str:
    p = 100 * n / of
    return f"{p:.1f}%" if p < 10 else f"{round(p)}%"


def nice_max(v: float) -> float:
    if v <= 0:
        return 1
    mag = 10 ** math.floor(math.log10(v))
    return next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= v)


class Route:
    def __init__(self, r: dict, data: dict):
        self.r, self.data = r, data
        self.a, self.b = r["a"], r["b"]
        self.A, self.B = self.a["iata"], self.b["iata"]
        self.pair = f"{self.A}–{self.B}"
        self.name = f"{self.A} to {self.B}"
        self.slug = f"{self.A.lower()}-to-{self.B.lower()}-turbulence"
        self.file = f"{self.slug}.html"
        self.url = f"{SITE_URL}/routes/{self.file}"
        self.n = total(r["reports"])
        self.severe = r["reports"]["severe"]
        self.miles = int(round(r["direct_nm"] * NM_TO_MI, -1))
        self.km = int(round(r["direct_nm"] * NM_TO_KM, -1))
        self.minutes = r["airborne_min"]["ab"]

    # Places and times along the route

    def far_side(self, s: dict) -> bool:
        """The nearest station is in a country neither airport is in (a US route over Lake Erie)."""
        canada = s["region_name"] in PROVINCE_NAMES
        return canada != (self.a["country"] == "CA" or self.b["country"] == "CA") and canada

    def place(self, s: dict) -> str:
        if s["from"] == 0:
            return f"near {self.A}, where flights climb out or come in to land"
        if s["to"] >= 0.999:
            return f"near {self.B}, where flights climb out or come in to land"
        region, near = s["region_name"], s["near"]
        if s["offshore"] or self.far_side(s):  # no station within 40 nm (remote land or water), or over the border
            return f"near {near}" if near else f"over or near {region}"
        if region and near and near != region:
            return f"over {region}, near {near}"
        return f"near {near}" if near else f"over {region}"

    def short_place(self, s: dict) -> str:
        if s["from"] == 0:
            return f"near {self.A}"
        if s["to"] >= 0.999:
            return f"near {self.B}"
        if s["offshore"] or self.far_side(s) or not s["region_name"]:
            return f"near {s['near']}" if s["near"] else f"over or near {s['region_name']}"
        return f"over {s['region_name']}"

    def when(self, s: dict) -> str:
        return (f"about {duration(s['minute_ab'])} after leaving {self.A} "
                f"({duration(s['minute_ba'])} after leaving {self.B})")

    def cause(self, s: dict) -> tuple[str, list[str]]:
        """Why bumps are likely there, and the explainers that say more."""
        if s["alt_ft"] < 18000:
            end = self.A if s["from"] < 0.5 else self.B
            mountains = s["ground_ft"] >= 4500
            gusty = self.r["gusts"][end]["gusty_days"] >= 60
            reason = ("Close to the ground, wind over the mountains stirs the air" if mountains
                      else "Close to the ground, wind over buildings and land stirs the air")
            if gusty:
                reason += f", and gusty days at {end} add to it"
            return reason, ["low-level"] + (["mountain-wave"] if mountains else []) + (["gusty-airport"] if gusty else [])
        if s["ground_ft"] >= 4500:
            return "The ground below is high, and wind over mountains makes waves that reach cruising height", ["mountain-wave"]
        return ("At cruising height, bumps usually come from clear-air turbulence near the jet stream, or from "
                "clouds and storms"), ["clear-air", "clouds"]

    def hotspot_sentences(self) -> list[tuple[str, list[str]]]:
        """(sentence, explainer ids) for each place moderate bumps were reported most."""
        out = []
        for i, s in enumerate(self.hotspots()):
            lead = "Moderate bumps were reported most often" if i == 0 else "The next most were"
            reason, ids = self.cause(s)
            out.append((f"{lead} {self.place(s)}, {self.when(s)}: {bumpy(s['counts']):,} of "
                        f"{total(s['counts']):,} reports there. {reason}.", ids))
        return out

    def hotspots(self) -> list[dict]:
        stretches = sorted(self.r["along"], key=lambda s: -bumpy(s["counts"]))
        top = stretches[0]
        if bumpy(top["counts"]) < 5:
            return []
        picks = [top]
        for s in stretches[1:]:
            if bumpy(s["counts"]) < 0.6 * bumpy(top["counts"]):
                break
            far = abs(s["from"] - top["from"]) >= 0.15
            if far and self.short_place(s) != self.short_place(top):
                picks.append(s)
                break
        return picks

    # Months

    def months(self) -> list[tuple[str, dict, float | None]]:
        """(month, counts, moderate-or-stronger share as a multiple of this route's yearly share)."""
        rows = list(self.r["months"].items())
        counted = [c for _, c in rows if total(c) >= MIN_MONTH]
        overall = sum(bumpy(c) for c in counted) / max(1, sum(total(c) for c in counted))
        out = []
        for key, c in rows:
            index = (bumpy(c) / total(c)) / overall if total(c) >= MIN_MONTH and overall > 0 else None
            out.append((key, c, index))
        return out

    def season(self) -> tuple[list[str], list[str]]:
        """Months with a clearly bigger and a clearly smaller share of moderate bumps (up to three each)."""
        rows = [(k, i) for k, _, i in self.months() if i is not None]
        order = [k for k, _, _ in self.months()]
        bumpier = sorted([r for r in rows if r[1] >= 1.15], key=lambda r: -r[1])[:3]
        calmer = sorted([r for r in rows if r[1] <= 0.85], key=lambda r: r[1])[:3]
        by_time = lambda picks: [month_name(k) for k in sorted((k for k, _ in picks), key=order.index)]  # noqa: E731
        return by_time(bumpier), by_time(calmer)

    def season_sentence(self) -> str:
        bumpier, calmer = self.season()
        if bumpier and calmer:
            return (f"Moderate bumps made up a bigger share of reports in {join(bumpier)}, and a smaller share in "
                    f"{join(calmer)}.")
        if bumpier:
            return f"Moderate bumps made up a bigger share of reports in {join(bumpier)}."
        if calmer:
            return f"Moderate bumps made up a smaller share of reports in {join(calmer)}."
        return "Moderate bumps made up a similar share of reports all year."

    # Airports

    def gusts(self, code: str) -> tuple[int, str | None, int]:
        g = self.r["gusts"][code]
        by_month = g["gusty_days_by_month"]
        peak = max(by_month, key=lambda k: by_month[k]) if g["gusty_days"] else None
        return g["gusty_days"], (month_name(peak) if peak else None), (by_month[peak] if peak else 0)

    def gust_sentence(self, code: str) -> str:
        days, peak, peak_days = self.gusts(code)
        if not days:
            return f"{code} had no days with gusts of 25 knots or more in the past year."
        return (f"{code} had gusts of 25 knots or more on {days} days in the past year, most often in {peak} "
                f"({peak_days} days).")

    # Summary text

    def direction_note(self) -> str:
        dlon = self.b["lon"] - self.a["lon"]
        if abs(dlon) < 8:
            return ""
        west, east = (self.A, self.B) if dlon > 0 else (self.B, self.A)
        return (f" Flights from {west} to {east} usually take less time than the way back, with the prevailing "
                "westerly winds behind them.")

    def lede(self) -> str:
        spots = self.hotspots()
        bumpier, _ = self.season()
        where = (f" In the past year, pilots near this route reported moderate bumps most often "
                 f"{self.short_place(spots[0])}" + (f", and more often in {join(bumpier)}" if bumpier else "") + "."
                 ) if spots else " In the past year, pilots near this route rarely reported moderate bumps."
        return (f"Flights between {self.a['city']} ({self.A}) and {self.b['city']} ({self.B}) fly about "
                f"{self.miles:,} miles, roughly {rough_duration(self.minutes)} in the air.{where} Severe reports were rare: "
                f"{self.severe:,} of {self.n:,}.")

    def description(self) -> str:
        spots = self.hotspots()
        bumpier, _ = self.season()
        base = f"Where and when it's bumpy on {self.pair} flights, from {self.n:,} pilot reports"
        options = []
        if spots:
            options.append(f"{base}: moderate bumps most often {self.short_place(spots[0])}"
                           + (f", more in {join([m[:3] for m in bumpier])}" if bumpier else "") + ".")
            options.append(f"{base}: moderate bumps most often {self.short_place(spots[0])}.")
        options.append(f"{base}, and gusty days at {self.A} and {self.B}.")
        return next(o for o in options if len(o) <= 160)

    def faq(self, period: str) -> list[tuple[str, str]]:
        spots = self.hotspots()
        bumpier, calmer = self.season()
        severe_line = f"severe reports were rare: {self.severe:,} of {self.n:,} ({share(self.severe, self.n)})"
        out = [(f"Is {self.name} a bumpy flight?",
                f"Most flights see light chop at most. From {period}, pilots near the {self.pair} route filed "
                f"{self.n:,} turbulence reports, and {severe_line}. Pilots report bumpy air more readily than smooth, "
                "so the share of flights with strong bumps is lower still. On the day, the weather decides: BumpCast "
                "forecasts your exact flight from 48 hours before departure.")]
        if spots:
            out.append((f"Where is it bumpiest between {self.A} and {self.B}?",
                        " ".join(sentence for sentence, _ in self.hotspot_sentences())))
        out.append((f"When is the smoothest time of year to fly {self.name}?",
                    (f"In the past year, moderate bumps made up a smaller share of reports in {join(calmer)}"
                     + (f" and a bigger share in {join(bumpier)}" if bumpier else "") + ". "
                     if calmer else self.season_sentence() + " ")
                    + "Any month can have a smooth or a bumpy day, so the forecast for your flight matters more."))
        out.append((f"Is {self.B} to {self.A} the same?",
                    "Yes. It's the same air, so bumps are reported in the same places, just at different times into "
                    f"the flight.{self.direction_note()}"))
        out.append((f"Are takeoffs and landings bumpy at {self.A} and {self.B}?",
                    f"On windy days they can be, for a few minutes. {self.gust_sentence(self.A)} "
                    f"{self.gust_sentence(self.B)}"))
        out.append((f"Can I get a turbulence forecast for my {self.name} flight?",
                    f"Yes. BumpCast forecasts the turbulence on your exact {self.pair} flight from 48 hours before "
                    "departure: when the bumps will come, how strong they'll be and when they'll end, and whether "
                    "takeoff and landing look gusty. It's free to download on the App Store for iPhone."))
        return out

    def related(self, routes: list["Route"]) -> list["Route"]:
        ends = {self.A, self.B}
        return [o for o in routes if o is not self and ({o.A, o.B} & ends)][:8]


# Charts: one series each, in the accent color, with a tooltip on every bar (charts.js) and the
# numbers in a table below. Text uses the text colors, never the bar color.

CHART_W, LEFT, RIGHT = 640, 48, 12


def bar_path(x: float, y: float, w: float, base: float, r: float = 4) -> str:
    """A bar from the baseline `base` up (or down) to `y`, rounded at the data end only."""
    h = abs(base - y)
    if h < 0.5:
        return ""
    r = min(r, h, w / 2)
    if y <= base:
        return (f"M{x:.1f} {base:.1f}V{y + r:.1f}Q{x:.1f} {y:.1f} {x + r:.1f} {y:.1f}H{x + w - r:.1f}"
                f"Q{x + w:.1f} {y:.1f} {x + w:.1f} {y + r:.1f}V{base:.1f}Z")
    return (f"M{x:.1f} {base:.1f}V{y - r:.1f}Q{x:.1f} {y:.1f} {x + r:.1f} {y:.1f}H{x + w - r:.1f}"
            f"Q{x + w:.1f} {y:.1f} {x + w:.1f} {y - r:.1f}V{base:.1f}Z")


def along_chart(route: Route) -> str:
    along = route.r["along"]
    n = len(along)
    pw = CHART_W - LEFT - RIGHT
    band = pw / n
    bw = min(24, band - 4)
    top, base = 16, 150
    p_top, p_base = 176, 236
    vmax = nice_max(max(bumpy(s["counts"]) for s in along))
    y = lambda v: base - (base - top) * v / vmax  # noqa: E731
    out = [f'<line class="grid" x1="{LEFT}" x2="{CHART_W - RIGHT}" y1="{y(t):.1f}" y2="{y(t):.1f}"/>'
           f'<text class="tick" x="{LEFT - 8}" y="{y(t) + 4:.1f}" text-anchor="end">{t:,.0f}</text>'
           for t in (0, vmax / 2, vmax)]
    # Flight height (top) over the ground (bottom), on one height scale.
    h = lambda ft: p_base - (p_base - p_top) * ft / 45000  # noqa: E731
    xs = [LEFT] + [LEFT + band * (i + 0.5) for i in range(n)] + [LEFT + pw]
    ground = [route.a["elev_ft"]] + [s["ground_ft"] for s in along] + [route.b["elev_ft"]]
    flight = [route.a["elev_ft"]] + [s["alt_ft"] for s in along] + [route.b["elev_ft"]]
    ground_pts = " ".join(f"{x:.1f},{h(g):.1f}" for x, g in zip(xs, ground))
    out.append(f'<polygon class="ground" points="{LEFT},{p_base} {ground_pts} {LEFT + pw},{p_base}"/>')
    out.append(f'<line class="grid" x1="{LEFT}" x2="{CHART_W - RIGHT}" y1="{p_base}" y2="{p_base}"/>')
    out.append('<polyline class="alt" points="' + " ".join(f"{x:.1f},{h(a):.1f}" for x, a in zip(xs, flight)) + '"/>')
    out.append(f'<text class="tick" x="{LEFT - 8}" y="{h(route.r["cruise_ft"]) + 4:.1f}" text-anchor="end">'
               f'{route.r["cruise_ft"] // 1000}k ft</text>')
    for i, s in enumerate(along):
        x = LEFT + band * i
        v = bumpy(s["counts"])
        tip = (f"{route.place(s)[0].upper()}{route.place(s)[1:]}, {route.when(s)}. {total(s['counts']):,} reports, "
               f"{v:,} moderate or stronger.")
        out.append(f'<g class="band" data-tip="{attr(tip)}"><rect class="hit" x="{x:.1f}" y="{top}" '
                   f'width="{band:.1f}" height="{p_base - top}"/>'
                   + (f'<path class="bar" d="{bar_path(x + (band - bw) / 2, y(v), bw, base)}"/>' if v else "")
                   + "</g>")
    # Place names under the chart: the two airports, and the longest runs of one state or province.
    labels = [(LEFT, route.A, "start"), (LEFT + pw, route.B, "end")]

    def extent(x: float, t: str, anchor: str) -> tuple[float, float]:
        w = 7.0 * len(t)  # about 7 px a character at the chart's 12 px
        return {"start": (x, x + w), "end": (x - w, x), "middle": (x - w / 2, x + w / 2)}[anchor]

    runs, start = [], 0
    for i in range(1, n + 1):
        if i == n or along[i]["region_name"] != along[start]["region_name"]:
            if along[start]["region_name"] and not along[start]["offshore"]:
                runs.append((i - start, start, along[start]["region_name"]))
            start = i
    for length, first, name in sorted(runs, key=lambda r: (-r[0], r[1])):
        cx = LEFT + band * (first + length / 2)
        lo, hi = extent(cx, name, "middle")
        clear = all(hi + 12 < a or lo - 12 > b for a, b in (extent(*l) for l in labels))
        if length >= 2 and clear and lo >= LEFT and hi <= LEFT + pw:
            labels.append((cx, name, "middle"))
    out += [f'<text class="place" x="{x:.1f}" y="256" text-anchor="{a}">{text(t)}</text>' for x, t, a in labels]
    desc = (f"Bars show how many reports of moderate or stronger turbulence came from each of {n} stretches between "
            f"{route.A} and {route.B}. Below, the height a flight would be at, over the ground.")
    return (f'<figure class="chart"><div class="chart-scroll"><svg viewBox="0 0 {CHART_W} 266" role="img" '
            f'aria-labelledby="along-t along-d"><title id="along-t">Reports of moderate or stronger turbulence along '
            f'the route</title><desc id="along-d">{text(desc)}</desc>{"".join(out)}</svg></div>'
            f'<figcaption>Moderate-or-stronger reports by stretch of the route, {route.A} on the left. Below: the '
            f'height of a typical flight, over the ground.</figcaption></figure>')


def months_chart(rows: list[tuple[str, dict, float | None]], label: str, ident: str) -> str:
    n = len(rows)
    pw = CHART_W - LEFT - RIGHT
    band = pw / n
    bw = min(24, band - 8)
    top, bottom = 16, 176
    values = [i for _, _, i in rows if i is not None]
    span = max(1.0, math.ceil(max(abs(v - 1) for v in values) * 4) / 4) if values else 1.0
    y = lambda v: top + (bottom - top) * (1 + span - v) / (2 * span)  # noqa: E731
    out = []
    for t in (1 - span, 1 - span / 2, 1 + span / 2, 1 + span):
        out.append(f'<line class="grid" x1="{LEFT}" x2="{CHART_W - RIGHT}" y1="{y(t):.1f}" y2="{y(t):.1f}"/>'
                   f'<text class="tick" x="{LEFT - 8}" y="{y(t) + 4:.1f}" text-anchor="end">{t:g}×</text>')
    out.append(f'<line class="base" x1="{LEFT}" x2="{CHART_W - RIGHT}" y1="{y(1):.1f}" y2="{y(1):.1f}"/>'
               f'<text class="tick" x="{LEFT - 8}" y="{y(1) + 4:.1f}" text-anchor="end">1×</text>')
    for j, (key, c, index) in enumerate(rows):
        x = LEFT + band * j
        if index is None:
            tip = f"{month_year(key)}: too few reports ({total(c):,}) to compare."
            bar = f'<text class="tick" x="{x + band / 2:.1f}" y="{y(1) - 6:.1f}" text-anchor="middle">–</text>'
        else:
            tip = (f"{month_year(key)}: {total(c):,} reports, {bumpy(c):,} moderate or stronger: "
                   f"{index:.2f}× {label}.")
            bar = f'<path class="bar" d="{bar_path(x + (band - bw) / 2, y(index), bw, y(1))}"/>'
        out.append(f'<g class="band" data-tip="{attr(tip)}"><rect class="hit" x="{x:.1f}" y="{top}" width="{band:.1f}" '
                   f'height="{bottom - top}"/>{bar}</g>')
        out.append(f'<text class="place" x="{x + band / 2:.1f}" y="{bottom + 18}" text-anchor="middle">'
                   f'{month_name(key, short=True)}</text>')
        if j == 0 or key.endswith("-01"):
            out.append(f'<text class="tick" x="{x + band / 2:.1f}" y="{bottom + 34}" text-anchor="middle">{key[:4]}</text>')
    return (f'<figure class="chart"><div class="chart-scroll"><svg viewBox="0 0 {CHART_W} 216" role="img" '
            f'aria-labelledby="{ident}-t"><title id="{ident}-t">Share of moderate-or-stronger reports by month, '
            f'compared with {text(label)}</title>{"".join(out)}</svg></div>'
            f'<figcaption>Each month\'s share of moderate-or-stronger reports, as a multiple of {text(label)}. '
            f'Above 1× is bumpier than usual; below is calmer.</figcaption></figure>')


def route_tables(route: Route) -> tuple[str, str]:
    rows = "".join(
        f"<tr><td>{text(route.place(s))}</td><td>{duration(s['minute_ab'])}</td><td>{duration(s['minute_ba'])}</td>"
        f"<td>{total(s['counts']):,}</td><td>{bumpy(s['counts']):,}</td></tr>" for s in route.r["along"])
    along = (f'<details class="data"><summary>Show the numbers by stretch</summary><div class="table-wrap"><table>'
             f'<thead><tr><th>Where</th><th>From {route.A}</th><th>From {route.B}</th><th>Reports</th>'
             f'<th>Moderate or stronger</th></tr></thead><tbody>{rows}</tbody></table></div></details>')
    rows = "".join(
        f"<tr><td>{month_year(k)}</td><td>{total(c):,}</td><td>{c['smooth']:,}</td><td>{c['light']:,}</td>"
        f"<td>{c['light_moderate']:,}</td><td>{c['moderate']:,}</td><td>{c['severe']:,}</td>"
        f"<td>{f'{i:.2f}×' if i is not None else '–'}</td></tr>" for k, c, i in route.months())
    months = (f'<details class="data"><summary>Show the numbers by month</summary><div class="table-wrap"><table>'
              f'<thead><tr><th>Month</th><th>Reports</th><th>Smooth</th><th>Light</th><th>Light to moderate</th>'
              f'<th>Moderate</th><th>Severe</th><th>Vs. average</th></tr></thead><tbody>{rows}</tbody></table></div>'
              f'</details>')
    return along, months


def period_text(data: dict) -> str:
    start, end = data["period"]["start"], data["period"]["end"]
    return f"{month_year(start)} to {month_year(end)}"


def reporting_range(data: dict) -> tuple[tuple[str, float], tuple[str, float]]:
    shares = sorted((100 * c["smooth"] / total(c), k) for k, c in data["baseline"]["centers"].items())
    (lo, lo_c), (hi, hi_c) = shares[0], shares[-1]
    return (CENTERS.get(lo_c, lo_c), lo), (CENTERS.get(hi_c, hi_c), hi)


def method_html(route: Route | None, data: dict) -> str:
    m = data["method"]
    (lo_name, lo), (hi_name, hi) = reporting_range(data)
    src = data["sources"]
    scope = (f"<li><b>{route.n:,} pilot reports</b> of turbulence from airliners within {m['corridor_nm']} nautical "
             f"miles of the direct {route.pair} path, near the height a flight would be there (BumpCast's flight "
             "model: a typical climb, cruise and descent). Real flights wander off the direct path, so this is the "
             "air near the route, not a record of every flight on it.</li>") if route else (
             f"<li><b>Pilot reports</b> of turbulence from airliners within {m['corridor_nm']} nautical miles of each "
             "route's direct path, near the height a flight would be there (BumpCast's flight model: a typical "
             "climb, cruise and descent).</li>")
    return f"""<section class="method" aria-labelledby="method-h">
  <h2 id="method-h">How we made this page</h2>
  <ul>
    <li><b>Period:</b> {period_text(data)}. Pilot reports (PIREPs) and airport weather reports (METARs) from the US National Weather Service, through the <a href="{src['pireps']}">Iowa Environmental Mesonet</a> archive at Iowa State University.</li>
    {scope}
    <li><b>Airliners only:</b> mainline and regional jets and regional turboprops, not light aircraft. Each report counts at the strongest turbulence it names; "light to moderate" is kept separate, and "moderate to severe" counts as severe.</li>
    <li><b>Gusty days:</b> days with at least one hourly airport report of gusts of {m['gusty_kt']} knots or more, the same threshold the app uses for a gusty takeoff or landing.</li>
    <li><b>What the numbers can't say:</b> pilots don't report on every flight, and habits differ: in the past year, smooth air made up {lo:.0f}% of cruise reports filed with {lo_name} Center but {hi:.0f}% with {hi_name} Center. So these pages show where and when bumps were reported, compared within a route. They aren't the odds for your flight, and we don't rank routes against each other.</li>
  </ul>
</section>
"""


def route_html(route: Route, routes: list[Route], by_id: dict[str, Explainer], data: dict) -> str:
    period = period_text(data)
    spots = route.hotspots()
    faq = route.faq(period)
    along_table, month_table = route_tables(route)
    where = ""
    if spots:
        lines = []
        for sentence, ids in route.hotspot_sentences():
            links = join([f'<a href="../learn/{by_id[i].file}">{text(TOPIC_NAMES[i])}</a>' for i in ids])
            lines.append(f"<p>{text(sentence)} More on {links}.</p>")
        where = "\n  ".join(lines)
    else:
        where = f"<p>Moderate bumps were rarely reported near this route: {bumpy(route.r['reports']):,} in the year.</p>"
    gust_tiles = "".join(
        f'<div><dt>Gusty days at {code}</dt><dd>{route.gusts(code)[0]}<span>'
        f'{text(f"most in {route.gusts(code)[1]}" if route.gusts(code)[0] else "none in the year")}</span></dd></div>'
        for code in (route.A, route.B))
    regions = route.r["regions"]
    provinces = any(r in PROVINCE_NAMES for r in regions)
    states = any(r not in PROVINCE_NAMES for r in regions)
    over = "states and provinces" if provinces and states else ("provinces" if provinces else "states")
    regions_line = (f"It passes over or near {len(regions)} {over}: {join(regions)}." if len(regions) > 1 else "")
    faq_html = "\n".join(f'  <h3>{text(q)}</h3>\n  <p>{text(a)}</p>' for q, a in faq)
    rel = route.related(routes)
    rel_html = "".join(f'<li><a href="{o.file}">{text(o.pair)}</a></li>' for o in rel)
    learn_ids = []
    for s in spots:
        learn_ids += [i for i in route.cause(s)[1] if i not in learn_ids]
    for i in ("gusty-airport", "levels", "built"):
        if i not in learn_ids:
            learn_ids.append(i)
    learn_html = "".join(f'<li><a href="../learn/{by_id[i].file}">{text(by_id[i].title)}</a></li>' for i in learn_ids)
    title = f"{route.name} Turbulence: Where and When It Gets Bumpy"
    generated = data["generated"]
    dataset = {"@type": "Dataset", "@id": f"{route.url}#data",
               "name": f"Turbulence reports near the {route.pair} route, {period}",
               "description": (f"{route.n:,} pilot reports (PIREPs) of turbulence from airliners within "
                               f"{data['method']['corridor_nm']} nautical miles of the direct {route.pair} path, by "
                               f"stretch of the route and by month, with days of gusts of {data['method']['gusty_kt']} "
                               f"knots or more at {route.A} and {route.B}. Compiled by BumpCast from US National Weather "
                               "Service reports archived by the Iowa Environmental Mesonet."),
               "url": route.url, "temporalCoverage": f"{data['period']['start']}/{data['period']['end']}",
               "spatialCoverage": {"@type": "Place", "name": f"{route.a['city']} to {route.b['city']}"},
               "variableMeasured": ["Turbulence intensity in pilot reports", "Days with wind gusts of 25 knots or more"],
               "isBasedOn": [data["sources"]["pireps"], data["sources"]["metars"]],
               "creator": {"@id": ORG["@id"]}, "dateModified": generated,
               "distribution": {"@type": "DataDownload", "encodingFormat": "text/markdown",
                                "contentUrl": f"{route.url}.md"}}
    ld = {"@context": "https://schema.org", "@graph": [
        {"@type": "Article", "@id": f"{route.url}#article", "headline": title, "description": route.description(),
         "url": route.url, "mainEntityOfPage": route.url, "inLanguage": "en", "dateModified": generated,
         "datePublished": generated, "image": ICON_URL, "author": {"@id": ORG["@id"]},
         "publisher": {"@id": ORG["@id"]}, "isPartOf": {"@id": f"{SITE_URL}/routes/#collection"},
         "about": {"@id": f"{route.url}#data"}, "mentions": {"@id": APP["@id"]}},
        dataset,
        {"@type": "FAQPage", "@id": f"{route.url}#faq", "url": route.url, "mainEntity": [
            {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in faq]},
        breadcrumb_ld(("Home", f"{SITE_URL}/"), ("Routes", f"{SITE_URL}/routes/"), (route.name, None)),
        ORG, APP]}
    campaign = f"web-route-{route.A.lower()}-{route.B.lower()}"
    return (head(title=page_title(title), description=route.description(), url=route.url, og_type="article",
                 og_title=f"{route.name} turbulence", markdown=f"{route.file}.md", data=ld, section="routes",
                 hub=False, campaign=campaign, published=generated, modified=generated, scripts=("charts.js",))
            + f"""
<main class="learn route">
{crumbs(("Home", "../"), ("Routes", "./"), (route.name, None))}
<article class="explainer">
  <header>
    <p class="eyebrow">{text(route.a['city'])} ⇄ {text(route.b['city'])} · both directions</p>
    <h1>{text(route.name)} turbulence</h1>
    <p class="lede">{text(route.lede())}</p>
  </header>
  <dl class="stats">
    <div><dt>Distance</dt><dd>{route.miles:,} mi<span>{route.km:,} km</span></dd></div>
    <div><dt>In the air</dt><dd>{duration(route.minutes)}<span>typical jet, still air</span></dd></div>
    <div><dt>Pilot reports</dt><dd>{route.n:,}<span>near the route, in a year</span></dd></div>
    <div><dt>Severe reports</dt><dd>{route.severe:,}<span>{share(route.severe, route.n)} of them</span></dd></div>
  </dl>
  <section aria-labelledby="where-h">
  <h2 id="where-h">Where on the route it gets bumpy</h2>
  {where}
  {along_chart(route)}
  {along_table}
  <p class="muted small">{text(regions_line)}</p>
  </section>
  <section aria-labelledby="when-h">
  <h2 id="when-h">When in the year</h2>
  <p>{text(route.season_sentence())} Compared within this route, so differences in how often pilots report don't skew it.</p>
  {months_chart(route.months(), "this route's average month", "months")}
  {month_table}
  </section>
  <section aria-labelledby="ends-h">
  <h2 id="ends-h">Takeoff and landing</h2>
  <p>{text(route.gust_sentence(route.A))} {text(route.gust_sentence(route.B))} On a gusty day, expect a few minutes of bumps and some sway on the climb out and the way in to land. <a href="../learn/{by_id['gusty-airport'].file}">Why gusty days are bumpy</a>.</p>
  <dl class="stats two">{gust_tiles}</dl>
  </section>
  <aside class="good" aria-labelledby="day-h"><h2 id="day-h">What this means for your flight</h2><p>A year of reports shows where and when bumps are more likely, not what your flight will be like. That depends on the weather on the day, which is what BumpCast forecasts for your exact flight.</p></aside>
  <section class="faq-list" aria-labelledby="faq-h">
  <h2 id="faq-h">Questions</h2>
{faq_html}
  </section>
{method_html(route, data)}  <p class="updated muted small">Data from {period} · Page built <time datetime="{generated}">{long_date(generated)}</time> · <a href="{route.file}.md">Markdown</a></p>
  <section class="more" aria-labelledby="rel-h"><h2 id="rel-h">More routes</h2><ul class="chips">{rel_html}<li><a href="./">All routes</a></li></ul></section>
  <section class="more" aria-labelledby="learn-h"><h2 id="learn-h">Learn more</h2><ul class="chips">{learn_html}</ul></section>
</article>
{cta(campaign, "Get the forecast for your flight.", f"Flying {route.pair}? BumpCast forecasts the turbulence on your exact flight from 48 hours before departure: when the bumps will come, how strong they'll be, and when they'll end.")}</main>

""" + foot("routes"))


# How route pages name an explainer in a sentence ("More on mountain waves").
TOPIC_NAMES = {"clear-air": "clear-air turbulence", "mountain-wave": "mountain waves", "clouds": "turbulence near clouds",
               "low-level": "bumps near the ground", "gusty-airport": "gusty takeoffs and landings"}

PROVINCE_NAMES = {"British Columbia", "Alberta", "Saskatchewan", "Manitoba", "Ontario", "Quebec", "New Brunswick",
                  "Nova Scotia", "Prince Edward Island"}

ROUTES_TITLE = "Turbulence by route."
ROUTES_SEO_TITLE = "Turbulence by Route: A Year of Pilot Reports"


def national(data: dict) -> dict:
    b = data["baseline"]
    cruise = b["cruise"]
    months = b["cruise_months"]

    def season(keys):
        keys = [k for k in months if int(k[5:7]) in keys]
        return sum(bumpy(months[k]) for k in keys) / max(1, sum(total(months[k]) for k in keys))

    (lo_name, lo), (hi_name, hi) = reporting_range(data)
    overall = bumpy(cruise) / total(cruise)
    rows = [(k, c, (bumpy(c) / total(c)) / overall) for k, c in months.items()]
    return {"cruise_n": total(cruise), "cruise_severe": cruise["severe"], "winter": season({12, 1, 2}),
            "summer": season({6, 7, 8}), "lo": (lo_name, lo), "hi": (hi_name, hi), "rows": rows}


def routes_hub_html(routes: list[Route], data: dict) -> str:
    url = f"{SITE_URL}/routes/"
    period = period_text(data)
    nat = national(data)
    ratio = nat["winter"] / nat["summer"] if nat["summer"] else 0
    total_reports = sum(r.n for r in routes)
    summary = (f"Where and when pilots reported bumps on {len(routes)} popular routes in the US and Canada, from a "
               f"year of airline pilot reports ({period}), with gusty days at each airport.")
    description = (f"Where and when it's bumpy on {len(routes)} popular US and Canada routes, from a year of airline "
                   "pilot reports and airport weather. Calm, sourced and free.")
    rows = []
    for r in routes:
        spots = r.hotspots()
        bumpier, _ = r.season()
        rows.append(f'<tr><td><a href="{r.file}">{text(r.pair)}</a><span class="muted">{text(r.a["city"])} – '
                    f'{text(r.b["city"])}</span></td><td>{duration(r.minutes)}</td>'
                    f'<td>{r.n:,}</td><td>{text(r.short_place(spots[0]) if spots else "–")}</td>'
                    f'<td>{text(join([m[:3] for m in bumpier]) or "–")}</td>'
                    f'<td>{r.gusts(r.A)[0]} / {r.gusts(r.B)[0]}</td></tr>')
    findings = [
        f"<li><b>Severe turbulence is rare.</b> Of {nat['cruise_n']:,} airliner reports at cruising height over the "
        f"US and southern Canada, {nat['cruise_severe']:,} were severe ({share(nat['cruise_severe'], nat['cruise_n'])}),"
        " and pilots report bumpy air more readily than smooth.</li>",
        (f"<li><b>Cruise is bumpier in winter.</b> Moderate-or-stronger bumps made up about {ratio:.1f} times as large "
         "a share of cruise reports from December to February as from June to August, when the jet stream is "
         f'weaker. <a href="../learn/{WEB["clear-air"].slug}.html">Why</a>.</li>') if ratio >= 1.1 else "",
        f"<li><b>Reporting habits differ.</b> Smooth air made up {nat['lo'][1]:.0f}% of cruise reports filed with "
        f"{nat['lo'][0]} Center but {nat['hi'][1]:.0f}% with {nat['hi'][0]} Center. So each route page compares "
        "places and months within the route, and we don't rank routes against each other.</li>",
    ]
    ld = {"@context": "https://schema.org", "@graph": [
        {"@type": "CollectionPage", "@id": f"{url}#collection", "name": ROUTES_SEO_TITLE, "description": description,
         "url": url, "inLanguage": "en", "dateModified": data["generated"], "isPartOf": {"@id": WEBSITE["@id"]},
         "publisher": {"@id": ORG["@id"]}, "mainEntity": {"@id": f"{url}#list"}},
        {"@type": "ItemList", "@id": f"{url}#list", "numberOfItems": len(routes), "itemListElement": [
            {"@type": "ListItem", "position": i, "url": r.url, "name": f"{r.name} turbulence"}
            for i, r in enumerate(routes, 1)]},
        {"@type": "Dataset", "@id": f"{url}#data", "name": f"Airliner turbulence reports, US and southern Canada, {period}",
         "description": (f"{total_reports:,} pilot reports of turbulence from airliners near {len(routes)} popular routes, "
                         "by stretch and by month, with gusty days at each airport. Compiled by BumpCast from US "
                         "National Weather Service reports archived by the Iowa Environmental Mesonet."),
         "url": url, "temporalCoverage": f"{data['period']['start']}/{data['period']['end']}",
         "isBasedOn": [data["sources"]["pireps"], data["sources"]["metars"]], "creator": {"@id": ORG["@id"]},
         "variableMeasured": ["Turbulence intensity in pilot reports", "Days with wind gusts of 25 knots or more"]},
        breadcrumb_ld(("Home", f"{SITE_URL}/"), ("Routes", None)),
        WEBSITE, ORG]}
    return (head(title=page_title(ROUTES_SEO_TITLE), description=description, url=url, og_type="website",
                 og_title=ROUTES_SEO_TITLE, markdown="index.html.md", data=ld, section="routes", hub=True,
                 campaign="web-routes", scripts=("charts.js",))
            + f"""
<main class="learn route">
{crumbs(("Home", "../"), ("Routes", None))}
<header class="learn-head">
  <p class="eyebrow">Routes</p>
  <h1>{text(ROUTES_TITLE)}</h1>
  <p class="lede">{text(summary)}</p>
</header>
<section aria-labelledby="find-h">
  <h2 id="find-h">What a year of pilot reports shows</h2>
  <ul class="ticks">{"".join(f for f in findings if f)}</ul>
  {months_chart(nat["rows"], "the year's average", "national")}
</section>
<section aria-labelledby="list-h">
  <h2 id="list-h">Popular routes</h2>
  <div class="table-wrap"><table class="route-table">
    <thead><tr><th>Route</th><th>In the air</th><th>Reports</th><th>Moderate bumps most often</th><th>Bumpier months</th><th>Gusty days</th></tr></thead>
    <tbody>{"".join(rows)}</tbody>
  </table></div>
</section>
{method_html(None, data)}<p class="updated muted small">Data from {period} · Page built <time datetime="{data['generated']}">{long_date(data['generated'])}</time> · <a href="index.html.md">Markdown</a></p>
{cta("web-routes", "Get the forecast for your flight.", "A year of reports shows where bumps are more likely. BumpCast forecasts your exact flight from 48 hours before departure: when the bumps will come, how strong they'll be, and when they'll end.")}</main>

""" + foot("routes"))


def load_routes() -> tuple[list[Route], dict | None]:
    if not ROUTE_DATA.exists():
        return [], None
    data = json.loads(ROUTE_DATA.read_text())
    routes = [Route(r, data) for r in data["routes"]]
    return [r for r in routes if r.n >= MIN_REPORTS], data


def learn_route_links(routes: list[Route]) -> dict[str, tuple[str, list[Route]]]:
    """Real routes for the explainers they show best."""
    if not routes:
        return {}
    high = sorted(routes, key=lambda r: -max(s["ground_ft"] for s in r.r["along"]))
    high = [r for r in high if max(s["ground_ft"] for s in r.r["along"]) >= 4500][:6]
    gusty = sorted(routes, key=lambda r: -max(r.gusts(r.A)[0], r.gusts(r.B)[0]))[:6]
    return {"mountain-wave": ("Routes over high ground", high), "gusty-airport": ("Routes with gusty airports", gusty)}


def data_details(explainers: list[Explainer], routes: list[Route], data: dict | None) -> None:
    """Questions answered from the route data, added to MORE's."""
    if not routes or not data:
        return
    by_id = {e.id: e for e in explainers}
    nat = national(data)
    period = period_text(data)
    if nat["summer"] and nat["winter"] / nat["summer"] >= 1.1:
        by_id["clear-air"].more.append(Detail(
            "Is it bumpier at cruise in winter?",
            f"In pilot reports, yes. In BumpCast's analysis of {nat['cruise_n']:,} airliner reports at cruising "
            f"height over the US and southern Canada ({period}), moderate or stronger bumps made up about "
            f"{nat['winter'] / nat['summer']:.1f} times as large a share of reports from December to February as from "
            "June to August.",
            ("bumpcast-routes",)))
    airports = {}
    for r in routes:
        for code in (r.A, r.B):
            airports[code] = r.gusts(code)[0]
    ranked = sorted(airports.items(), key=lambda kv: (-kv[1], kv[0]))
    most = join([f"{c} ({d} days)" for c, d in ranked[:3]])
    least = join([f"{c} ({d} days)" for c, d in sorted(airports.items(), key=lambda kv: (kv[1], kv[0]))[:3]])
    by_id["gusty-airport"].more.append(Detail(
        "Which airports have the most gusty days?",
        f"Of the {len(airports)} airports on BumpCast's route pages, the ones with the most days with gusts of 25 knots "
        f"or more in {period} were {most}. The fewest were {least}.",
        ("bumpcast-routes",)))


# ---------- Home page

HOME_START = "<!-- learn:start (generated by scripts/build_site.py) -->"
HOME_END = "<!-- learn:end -->"
HOME_ROUTES = ["JFK-LAX", "ATL-MCO", "LGA-ORD", "DEN-PHX", "LAS-LAX", "DEN-SFO", "BOS-DCA", "YVR-YYZ"]


def home_section(explainers: list[Explainer], routes: list[Route]) -> str:
    cols = []
    for group, label in GROUPS.items():
        links = "".join(f'<li><a href="learn/{e.file}">{text(e.title)}</a> <span class="muted">{text(e.subtitle)}</span></li>'
                        for e in explainers if e.group == group)
        cols.append(f'<div><h3>{text(label)}</h3><ul class="links">{links}</ul></div>')
    learn = f"""<section class="split" id="learn" aria-labelledby="learn-h">
  <div>
    <p class="eyebrow">Learn</p>
    <h2 id="learn-h">{text(HUB_TITLE)}</h2>
    <p class="muted">The app's short, factual explainers, open to everyone: why flights get bumpy, what the crew is doing, and what you'll feel.</p>
    <p><a href="learn/">Read all the explainers</a></p>
  </div>
  <div class="plan-list">
    {(chr(10) + '    ').join(cols)}
  </div>
</section>"""
    picks = [r for key in HOME_ROUTES for r in routes if f"{r.A}-{r.B}" == key]
    routes_html = ""
    if picks:
        links = "".join(f'<li><a href="routes/{r.file}">{text(r.pair)}</a> <span class="muted">{text(r.a["city"])} – '
                        f'{text(r.b["city"])}</span></li>' for r in picks)
        routes_html = f"""
<section class="split" id="routes" aria-labelledby="routes-h">
  <div>
    <p class="eyebrow">Routes</p>
    <h2 id="routes-h">{text(ROUTES_TITLE)}</h2>
    <p class="muted">Where and when pilots reported bumps on {len(routes)} popular routes, from a year of reports, with gusty days at each airport.</p>
    <p><a href="routes/">See every route</a></p>
  </div>
  <div><ul class="links two-col">{links}</ul></div>
</section>"""
    return f"{HOME_START}\n{learn}{routes_html}\n{HOME_END}"


# ---------- Markdown, llms.txt, llms-full.txt

def md_link(e: Explainer) -> str:
    return f"[{e.title}]({e.url}.md)"


def article_md(e: Explainer, by_id: dict[str, Explainer], level: int = 1) -> str:
    h = "#" * level
    out = [f"{h} {e.title}", "", f"> {e.subtitle}.", "", e.web.summary, ""]
    for _, q, a in e.sections():
        out += [f"{h}# {q}", "", a, ""]
    out += [f"{h}# Good to know", "", e.good_to_know, ""]
    if e.more:
        out += [f"{h}# In more detail", ""]
        for d in e.more:
            refs = "; ".join(f"[{SOURCES[k].title}]({SOURCES[k].url})" for k in d.sources)
            out += [f"{h}## {d.question}", "", d.answer, "", f"Source: {refs}", ""]
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


def md_table(header: list[str], rows: list[list[str]]) -> list[str]:
    return (["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
            + ["| " + " | ".join(r) + " |" for r in rows] + [""])


def method_md(data: dict) -> list[str]:
    (lo_name, lo), (hi_name, hi) = reporting_range(data)
    m = data["method"]
    return [
        f"- Period: {period_text(data)}. Pilot reports (PIREPs) and airport weather reports (METARs) from the US "
        f"National Weather Service, via the Iowa Environmental Mesonet archive: {data['sources']['pireps']}",
        f"- Reports from airliners within {m['corridor_nm']} nautical miles of the direct path, near the height a "
        "flight would be there (BumpCast's flight model). Each report counts at the strongest turbulence it names; "
        "\"moderate to severe\" counts as severe.",
        f"- Gusty days: days with at least one hourly report of gusts of {m['gusty_kt']} knots or more.",
        f"- Reporting habits differ: smooth air made up {lo:.0f}% of cruise reports at {lo_name} Center but {hi:.0f}% "
        f"at {hi_name} Center. These numbers show where and when bumps were reported, compared within a route. They "
        "aren't the odds for a given flight, and routes aren't ranked against each other.",
        "",
    ]


def route_md(route: Route, data: dict, level: int = 1) -> str:
    h = "#" * level
    period = period_text(data)
    out = [f"{h} {route.name} turbulence", "",
           f"> {route.a['city']} ({route.A}) ⇄ {route.b['city']} ({route.B}), both directions. {period}.", "",
           route.lede(), "",
           f"- Distance: {route.miles:,} miles ({route.km:,} km)",
           f"- In the air: about {duration(route.minutes)} (typical jet, still air)",
           f"- Pilot reports near the route: {route.n:,}",
           f"- Severe reports: {route.severe:,} ({share(route.severe, route.n)})",
           f"- Gusty days: {route.A} {route.gusts(route.A)[0]}, {route.B} {route.gusts(route.B)[0]}",
           "", f"{h}# Where on the route it gets bumpy", ""]
    for sentence, _ in route.hotspot_sentences():
        out += [sentence, ""]
    out += md_table(["Where", f"From {route.A}", f"From {route.B}", "Reports", "Moderate or stronger"],
                    [[route.place(s), duration(s["minute_ab"]), duration(s["minute_ba"]), f"{total(s['counts']):,}",
                      f"{bumpy(s['counts']):,}"] for s in route.r["along"]])
    out += [f"{h}# When in the year", "", route.season_sentence(), ""]
    out += md_table(["Month", "Reports", "Smooth", "Light", "Light to moderate", "Moderate", "Severe", "Vs. average"],
                    [[month_year(k), f"{total(c):,}", f"{c['smooth']:,}", f"{c['light']:,}", f"{c['light_moderate']:,}",
                      f"{c['moderate']:,}", f"{c['severe']:,}", f"{i:.2f}×" if i is not None else "–"]
                     for k, c, i in route.months()])
    out += [f"{h}# Takeoff and landing", "", f"{route.gust_sentence(route.A)} {route.gust_sentence(route.B)}", ""]
    out += [f"{h}# Questions", ""]
    for q, a in route.faq(period):
        out += [f"{h}## {q}", "", a, ""]
    out += [f"{h}# How this page was made", ""] + method_md(data)
    out += [f"Source: {route.url} (data {period}). From BumpCast, the flight tracker with turbulence forecasts for "
            f"nervous flyers: {APP_URL}", ""]
    return "\n".join(out)


def routes_hub_md(routes: list[Route], data: dict) -> str:
    nat = national(data)
    period = period_text(data)
    out = [f"# {ROUTES_SEO_TITLE}", "",
           f"> Where and when pilots reported bumps on {len(routes)} popular routes in the US and Canada ({period}).", "",
           "## What a year of pilot reports shows", "",
           f"- Severe turbulence is rare: {nat['cruise_severe']:,} of {nat['cruise_n']:,} airliner reports at cruising "
           f"height ({share(nat['cruise_severe'], nat['cruise_n'])}).",
           f"- Moderate-or-stronger bumps made up about {nat['winter'] / nat['summer']:.1f} times as large a share of "
           "cruise reports from December to February as from June to August.",
           f"- Smooth air made up {nat['lo'][1]:.0f}% of cruise reports at {nat['lo'][0]} Center but {nat['hi'][1]:.0f}% "
           f"at {nat['hi'][0]} Center, so routes aren't ranked against each other.", "", "## Routes", ""]
    for r in routes:
        out.append(f"- [{r.name} turbulence]({r.url}.md): {r.lede()}")
    out += ["", "## How these pages were made", ""] + method_md(data)
    out += [f"Source: {SITE_URL}/routes/ (data {period}).", ""]
    return "\n".join(out)


def llms_learn_section(explainers: list[Explainer]) -> str:
    out = ["## Learn: turbulence explained", "",
           f"The app's Learn library, published at {SITE_URL}/learn/. Short, factual explainers: why flights get bumpy, "
           "what the crew is doing, and what you'll feel, with sourced detail (FAA, NTSB, US regulations). Each link "
           f"is the Markdown copy of the page (drop the .md for the web page). All of them in full: {SITE_URL}/llms-full.txt",
           ""]
    for group, label in GROUPS.items():
        out += [f"### {label}", ""]
        out += [f"- {md_link(e)}: {e.web.summary}" for e in explainers if e.group == group]
        out.append("")
    return "\n".join(out)


def llms_routes_section(routes: list[Route], data: dict) -> str:
    out = ["## Routes: turbulence by route", "",
           f"Where and when pilots reported bumps on {len(routes)} popular routes in the US and Canada, from a year of "
           f"airline pilot reports ({period_text(data)}), with gusty days at each airport. Published at "
           f"{SITE_URL}/routes/ (Markdown: {SITE_URL}/routes/index.html.md).", ""]
    out += [f"- [{r.name} turbulence]({r.url}.md): {r.description()}" for r in routes]
    out.append("")
    return "\n".join(out)


def with_section(llms: str, name: str, section: str) -> str:
    m = re.search(rf"^## {name}\b.*?(?=^## )", llms, re.S | re.M)
    if m:
        return llms[:m.start()] + section + "\n" + llms[m.end():]
    m = re.search(r"^## Pages\b", llms, re.M)
    if not m:
        fail(f"llms.txt has no '## Pages' section to put {name} before")
    return llms[:m.start()] + section + "\n" + llms[m.start():]


def llms_full(llms: str, explainers: list[Explainer], by_id: dict[str, Explainer], routes: list[Route],
              data: dict | None) -> str:
    out = [llms.rstrip(), "", "---", "", "# Learn library: every explainer in full", ""]
    for group, label in GROUPS.items():
        out += [f"## {label}", ""]
        out += [article_md(e, by_id, level=3) for e in explainers if e.group == group]
    if routes and data:
        out += ["---", "", "# Turbulence by route: every route in full", ""]
        out += [route_md(r, data, level=2) for r in routes]
    return "\n".join(out).rstrip() + "\n"


# ---------- Sitemap

def sitemap(explainers: list[Explainer], routes: list[Route], data: dict | None) -> str:
    pages = sorted(p.name for p in SITE.glob("*.html") if p.name not in {"404.html", "index.html"})
    urls = [(f"{SITE_URL}/", None), (f"{SITE_URL}/learn/", UPDATED)]
    urls += [(e.url, UPDATED) for e in explainers]
    if routes and data:
        urls += [(f"{SITE_URL}/routes/", data["generated"])] + [(r.url, data["generated"]) for r in routes]
    urls += [(f"{SITE_URL}/{p}", None) for p in pages]
    rows = "".join(f"  <url><loc>{u}</loc>{f'<lastmod>{d}</lastmod>' if d else ''}</url>\n" for u, d in urls)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + rows + "</urlset>\n")


# ---------- Main

def build() -> dict[Path, str]:
    explainers = read_explainers()
    by_id = {e.id: e for e in explainers}
    routes, data = load_routes()
    data_details(explainers, routes, data)
    chips = learn_route_links(routes)

    out: dict[Path, str] = {LEARN / "index.html": hub_html(explainers, bool(routes)),
                            LEARN / "index.html.md": hub_md(explainers)}
    for e in explainers:
        out[LEARN / e.file] = article_html(e, by_id, chips)
        out[LEARN / f"{e.file}.md"] = article_md(e, by_id)
    if routes and data:
        out[ROUTES / "index.html"] = routes_hub_html(routes, data)
        out[ROUTES / "index.html.md"] = routes_hub_md(routes, data)
        for r in routes:
            out[ROUTES / r.file] = route_html(r, routes, by_id, data)
            out[ROUTES / f"{r.file}.md"] = route_md(r, data)

    llms = with_section((SITE / "llms.txt").read_text(), "Learn", llms_learn_section(explainers))
    if routes and data:
        llms = with_section(llms, "Routes", llms_routes_section(routes, data))
    out[SITE / "llms.txt"] = llms
    out[SITE / "llms-full.txt"] = llms_full(llms, explainers, by_id, routes, data)
    out[SITE / "sitemap.xml"] = sitemap(explainers, routes, data)

    home = (SITE / "index.html").read_text()
    start = home.find("<!-- learn:start")
    end = home.find(HOME_END)
    if start < 0 or end < 0:
        fail(f"site/index.html needs the {HOME_START!r} and {HOME_END!r} markers")
    out[SITE / "index.html"] = home[:start] + home_section(explainers, routes) + home[end + len(HOME_END):]
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="exit 1 if any generated file is out of date")
    args = parser.parse_args()

    out = build()
    stale = [p for p, content in out.items() if not p.exists() or p.read_text() != content]
    extra = sorted(p for folder in (LEARN, ROUTES) if folder.exists() for p in folder.glob("*") if p not in out)
    rel = lambda p: str(p.relative_to(ROOT))  # noqa: E731

    if args.check:
        if stale or extra:
            for p in stale:
                print(f"out of date: {rel(p)}")
            for p in extra:
                print(f"not generated: {rel(p)}")
            sys.exit("Run python3 scripts/build_site.py and commit the result.")
        print(f"Generated pages are up to date ({len(out)} files).")
        return

    for p in stale:
        p.parent.mkdir(exist_ok=True)
        p.write_text(out[p])
        print(f"wrote {rel(p)}")
    for p in extra:
        p.unlink()
        print(f"removed {rel(p)}")
    if not stale and not extra:
        print("Nothing to change.")


if __name__ == "__main__":
    main()
