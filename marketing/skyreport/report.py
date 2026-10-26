"""Load the Sky Report and summarise it for the route pages and the social cards.

The worker builds the report (`smooth-worker sky-report`, and hourly in `run`) and stores it in
Supabase `sky_reports`. Standard library only, so these scripts run anywhere.
"""

import json
import os
import urllib.request
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FONTS = ROOT / "ios" / "Shared" / "Fonts"
APP_STORE_URL = "https://apps.apple.com/app/id6824269447"
APP_ID = "6824269447"

GRADES = ["smooth", "mostly_smooth", "some_bumps", "bumpy", "rough"]
# Severity colours from docs/design/DESIGN_SPEC.md (light, dark). Never red.
GRADE_COLORS = {
    "smooth": ("#3A9A8F", "#5CC0B3"),
    "mostly_smooth": ("#3A9A8F", "#5CC0B3"),
    "some_bumps": ("#C99A2E", "#E0B54E"),
    "bumpy": ("#C9733A", "#E38F55"),
    "rough": ("#8E4A6B", "#C57EA0"),
}
# The app's titles (worker/src/smooth_worker/changes.py GRADE_TITLES).
GRADE_TITLES = {
    "smooth": "Smooth flight",
    "mostly_smooth": "Mostly smooth",
    "some_bumps": "A few bumps",
    "bumpy": "Bumpy in places",
    "rough": "Some rough patches",
}
# The same grades in a sentence: "JFK to LAX looks mostly smooth".
GRADE_PHRASES = {
    "smooth": "looks smooth",
    "mostly_smooth": "looks mostly smooth",
    "some_bumps": "has a few bumps",
    "bumpy": "looks bumpy in places",
    "rough": "has some rough patches",
}
SLOT_TITLES = {"morning": "Morning", "afternoon": "Afternoon", "evening": "Evening"}
# The report is rebuilt hourly. Older than this, something is stuck: don't publish it as current.
MAX_AGE = timedelta(hours=3)


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def load(path: str | None = None) -> dict:
    """From a JSON file, or the latest report in Supabase (SUPABASE_URL and SUPABASE_ANON_KEY)."""
    if path:
        return json.loads(Path(path).read_text())
    url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_ANON_KEY")
    if not url or not key:
        raise SystemExit("Pass a report file, or set SUPABASE_URL and SUPABASE_ANON_KEY")
    req = urllib.request.Request(
        f"{url.rstrip('/')}/rest/v1/sky_reports?select=report&id=eq.latest",
        headers={"apikey": key, "Authorization": f"Bearer {key}"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        rows = json.load(r)
    if not rows:
        raise SystemExit("No Sky Report in Supabase yet")
    return rows[0]["report"]


def accuracy(report_path: str | None = None) -> dict | None:
    """The public after-landing accuracy (accuracy_stats()), when Supabase is configured."""
    url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_ANON_KEY")
    if report_path or not url or not key:
        return None
    req = urllib.request.Request(
        f"{url.rstrip('/')}/rest/v1/rpc/accuracy_stats",
        data=b"{}",
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            rows = json.load(r)
    except OSError:
        return None
    return rows[0] if rows else None


def check_fresh(report: dict, now: datetime, allow_stale: bool = False, allow_sample: bool = False) -> None:
    if report.get("sample") and not allow_sample:
        raise SystemExit("This is the sample report (made-up weather). Pass --allow-sample to preview it.")
    age = now - parse_time(report["generated_at"])
    if age > MAX_AGE and not allow_stale:
        raise SystemExit(f"The report is {age} old (limit {MAX_AGE}); is the worker running? --allow-stale to build anyway")


def ready(departures: list[dict]) -> list[dict]:
    return [d for d in departures if d.get("status") == "ready"]


def worst(departures: list[dict]) -> str | None:
    grades = [d["grade"] for d in ready(departures)]
    return max(grades, key=GRADES.index) if grades else None


def smoothest(departures: list[dict]) -> dict | None:
    """The departure with the best score; the earliest on a tie."""
    options = ready(departures)
    return max(options, key=lambda d: (d["score"], -options.index(d))) if options else None


def day(route: dict, on: date) -> list[dict]:
    for d in route["days"]:
        if d["date"] == on.isoformat():
            return d["departures"]
    return []


def local(value: str, tz: str) -> datetime:
    return parse_time(value).astimezone(ZoneInfo(tz))


def clock(at: datetime) -> str:
    """8 am, 1:30 pm."""
    hour = at.strftime("%I").lstrip("0")
    minutes = "" if at.minute == 0 else f":{at:%M}"
    return f"{hour}{minutes} {'am' if at.hour < 12 else 'pm'}"


def day_title(on: date) -> str:
    return f"{on:%A}, {on:%B} {on.day}"


def short_day(on: date) -> str:
    return f"{on:%a}, {on:%b} {on.day}"


def tomorrow(now: datetime, tz: str = "America/New_York") -> date:
    return now.astimezone(ZoneInfo(tz)).date() + timedelta(days=1)


def route_title(route: dict, sep: str = "→") -> str:
    return f"{route['origin']['iata']} {sep} {route['destination']['iata']}"


def city_title(route: dict, sep: str = "→") -> str:
    return f"{route['origin']['city']} {sep} {route['destination']['city']}"


def summary(route: dict, on: date) -> dict | None:
    """One line about a route's day: its worst grade, and the smoothest time to leave when the
    time of day makes a difference."""
    departures = day(route, on)
    grade = worst(departures)
    if grade is None:
        return None
    best = smoothest(departures)
    options = ready(departures)
    varies = len({d["grade"] for d in options}) > 1
    return {
        "route": route,
        "grade": grade,
        "best": best,
        "varies": varies,
        "min_score": min(d["score"] for d in options),
        "departures": departures,
    }
