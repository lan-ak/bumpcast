"""The Sky Report: grades for popular routes at set departure times, today and tomorrow.

It feeds the public route pages and the daily social cards (`marketing/skyreport`). It carries
the grade only, per departure time, so a page can say which time of day looks smoothest. When
and how long the bumps last is what Pro sells, so it never leaves the app: no stretches, no
minutes, no timeline.
"""

import logging
from collections.abc import Callable
from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from . import airports, changes, forecast
from .airports import Airport

log = logging.getLogger(__name__)

# Busy routes inside coverage (the continental US and southern Canada), weighted to the
# Thanksgiving and December holiday flows. Each direction is its own route: winds and cruise
# levels differ. tests/test_skyreport.py checks every route is in coverage.
ROUTES = [
    ("JFK", "LAX"), ("LAX", "JFK"), ("JFK", "SFO"), ("SFO", "JFK"), ("EWR", "SFO"), ("SFO", "EWR"),
    ("BOS", "LAX"), ("LAX", "BOS"), ("ORD", "LAX"), ("LAX", "ORD"), ("ATL", "LAX"), ("LAX", "ATL"),
    ("DFW", "LAX"), ("DEN", "LAX"), ("LAX", "SEA"), ("SEA", "LAX"), ("LAX", "SFO"), ("LAS", "LAX"),
    ("DEN", "ORD"), ("ORD", "DEN"), ("DFW", "ORD"), ("ATL", "ORD"), ("LGA", "ORD"), ("ORD", "LGA"),
    ("LGA", "ATL"), ("ATL", "LGA"), ("BOS", "DCA"), ("JFK", "MIA"), ("MIA", "JFK"), ("EWR", "FLL"),
    ("JFK", "MCO"), ("EWR", "MCO"), ("BOS", "MCO"), ("ORD", "MCO"), ("ATL", "MCO"), ("PHL", "MCO"),
    ("DFW", "ATL"), ("IAH", "DEN"), ("DEN", "PHX"), ("SEA", "DEN"), ("MSP", "PHX"), ("SLC", "LAX"),
    ("YYZ", "YUL"), ("YUL", "YYZ"), ("YYZ", "LGA"), ("YYZ", "MCO"), ("YYZ", "FLL"), ("YVR", "YYC"),
    ("YYC", "YVR"), ("YVR", "LAX"),
]

# Departure times, at the origin's local time, that each route is forecast for.
DEPARTURES = [("morning", time(8)), ("afternoon", time(13)), ("evening", time(18))]
# A departure closer than this is left out: people searching now are flying later.
MIN_LEAD = timedelta(minutes=30)
# How long a report stays current before the poll builds a new one (GTG runs hourly).
REFRESH = timedelta(hours=1)

# The app's wording: "Early outlook" until the detailed forecast covers the flight. Never the
# data sources' names (house rule for anything public).
CONFIDENCE = {"gfs": "early", "mixed": "partly_confirmed", "gtg": "confirmed"}
CONFIDENCE_TITLES = {"early": "Early outlook", "partly_confirmed": "Partly confirmed", "confirmed": "Confirmed forecast"}

Compute = Callable[[Airport, Airport, datetime], forecast.Forecast]


def slug(origin: str, destination: str) -> str:
    return f"{origin}-{destination}".lower()


def _place(a: Airport) -> dict:
    return {"iata": a.iata, "city": a.city, "name": a.name, "country": a.country, "tz": a.tz}


def _departure(day: date, at: time, tz: str) -> datetime:
    return datetime.combine(day, at, ZoneInfo(tz)).astimezone(UTC)


def _entry(name: str, departure: datetime, result: forecast.Forecast) -> dict:
    entry = {"slot": name, "departure_at": departure.isoformat(), "status": result.status}
    if result.status == "ready":
        confidence = CONFIDENCE.get(result.source or "", "early")
        entry |= {
            "grade": result.grade,
            "grade_title": changes.grade_title(result.grade),
            "score": result.score,
            "confidence": confidence,
            "confidence_title": CONFIDENCE_TITLES[confidence],
        }
    return entry


def route_report(origin: Airport, destination: Airport, now: datetime, compute: Compute) -> dict:
    """One route's departures today and tomorrow (origin's local dates), soonest first."""
    today = now.astimezone(ZoneInfo(origin.tz)).date()
    days = []
    duration = None
    for day in (today, today + timedelta(days=1)):
        departures = []
        for name, at in DEPARTURES:
            departure = _departure(day, at, origin.tz)
            if departure - now < MIN_LEAD or departure - now > forecast.FORECAST_WINDOW:
                continue
            result = compute(origin, destination, departure)
            duration = duration or result.duration_min
            departures.append(_entry(name, departure, result))
        if departures:
            days.append({"date": day.isoformat(), "departures": departures})
    return {
        "slug": slug(origin.iata, destination.iata),
        "origin": _place(origin),
        "destination": _place(destination),
        "duration_min": duration,
        "days": days,
    }


def build(now: datetime, compute: Compute, routes: list[tuple[str, str]] = ROUTES) -> dict:
    """The full report. `compute` forecasts one departure; the caller decides how weather is
    loaded and locked. A route that fails is left out rather than failing the report."""
    out, failed = [], []
    for o, d in routes:
        try:
            out.append(route_report(airports.lookup(o), airports.lookup(d), now, compute))
        except Exception:
            log.exception("sky report: %s-%s failed", o, d)
            failed.append(slug(o, d))
    return {
        "version": 1,
        "generated_at": now.isoformat(),
        "slots": [{"slot": name, "local_time": at.strftime("%H:%M")} for name, at in DEPARTURES],
        "routes": out,
        "failed": failed,
    }


def is_due(generated_at: str | None, now: datetime) -> bool:
    if not generated_at:
        return True
    return now - datetime.fromisoformat(generated_at.replace("Z", "+00:00")) >= REFRESH
