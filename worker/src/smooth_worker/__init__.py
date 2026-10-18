"""Smooth turbulence forecast worker.

  smooth-worker forecast JFK LAX 2026-10-19T14:00Z   # one-off forecast, prints a summary
  smooth-worker run                                  # keep forecasts, notifications and map data fresh
"""

import argparse
import json
import logging
import os
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from . import airports, flightdata, forecast, mapdata, notify, status
from .apns import Apns
from .flightdata import FlightData
from .sources import GfsSource, GtgSource, gfs, gtg

log = logging.getLogger("smooth_worker")

CACHE_DIR = Path(os.environ.get("SMOOTH_CACHE", Path.home() / ".cache/smooth"))
POLL_SECONDS = 300
GTG_REFRESH = timedelta(hours=1)  # GTG cycles hourly
GFS_REFRESH = timedelta(hours=6)  # GFS cycles every 6 hours
HISTORY = timedelta(days=3)


def load_sources(now: datetime) -> list:
    sources = []
    if cycle := gtg.latest_cycle(now):
        sources.append(GtgSource(cycle, CACHE_DIR))
    if cycle := gfs.latest_cycle(now):
        sources.append(GfsSource(cycle, CACHE_DIR))
    if not sources:
        raise RuntimeError("No GTG or GFS cycle available")
    log.info("sources: %s", ", ".join(f"{s.name}@{s.cycle:%Y-%m-%d %HZ}" for s in sources))
    return sources


def _parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def cmd_forecast(args: argparse.Namespace) -> None:
    now = datetime.now(UTC)
    origin, destination = airports.lookup(args.origin), airports.lookup(args.destination)
    departure = _parse_time(args.departure)
    result = forecast.compute(origin, destination, departure, now, load_sources(now))
    if args.json:
        print(json.dumps(result.to_row(), indent=2))
        return
    print(f"{origin.iata} -> {destination.iata}  departs {departure:%Y-%m-%d %H:%MZ}  status={result.status}")
    if result.status != "ready":
        return
    print(
        f"grade={result.grade} score={result.score} source={result.source} run={result.model_run:%Y-%m-%d %HZ} "
        f"duration={result.duration_min}min cruise=FL{result.cruise_ft // 100}"
    )
    for seg in result.segments:
        print(
            f"  {seg['start_min']:>4}-{seg['end_min']:<4} min  {seg['severity']:<8} "
            f"peak EDR {seg['peak_edr']:.2f}  {seg['phase']} {seg['altitude_ft']} ft"
        )


def is_due(flight: dict, now: datetime, departure: datetime | None = None) -> bool:
    """Whether to recompute the forecast. `departure` is the expected departure when a delay moved it."""
    scheduled = _parse_time(flight["departure_at"])
    departure = departure or scheduled
    latest = (flight.get("forecasts") or [None])[0]
    if latest is None:
        return True
    issued = _parse_time(latest["issued_at"])
    if _parse_time(flight["updated_at"]) > issued:
        return True  # flight was edited
    if latest["status"] == "out_of_coverage":
        return False
    forecast_for = _parse_time(latest["departure_at"]) if latest.get("departure_at") else scheduled
    if forecast_for != departure and latest["status"] != "too_early":
        return True  # the departure moved: forecast the new time now
    if departure - now > forecast.FORECAST_WINDOW:
        return False  # still too early; app shows when the forecast unlocks
    if latest["status"] == "too_early":
        return True  # just entered the 48 h window
    refresh = GTG_REFRESH if departure - now <= timedelta(hours=gtg.MAX_FHR) else GFS_REFRESH
    return now - issued >= refresh


def entitled_flights(db, flights: list[dict]) -> set[str]:
    """Flights with live status: the user is Pro, or bought a flight pass for the flight."""
    numbered = [f for f in flights if f.get("flight_number")]
    if not numbered:
        return set()
    profiles = db.profiles(sorted({f["user_id"] for f in numbered}))
    passes = db.flights_with_passes([f["id"] for f in numbered])
    return {f["id"] for f in numbered if profiles.get(f["user_id"], {}).get("is_pro") or f["id"] in passes}


def refresh_status(db, data: FlightData, flight: dict, previous: dict | None, now: datetime) -> dict | None:
    """Fetch and store the flight's latest status. Returns the stored row."""
    origin = airports.lookup(flight["origin"])
    day = _parse_time(flight["departure_at"]).astimezone(ZoneInfo(origin.tz)).date()
    leg = flightdata.find_leg(data.legs(flight["flight_number"], day), origin.icao, flight["destination"])
    if leg is None:
        # Not found today: note the check so the next try waits for the usual interval.
        row = {**(previous or {}), "flight_id": flight["id"], "checked_at": now.isoformat()}
    else:
        row = status.build(leg, flight, previous, now)
    db.upsert_flight_status(row)
    log.info("flight %s %s: %s", flight["id"], flight["flight_number"], row.get("status") or "not found")
    return row


def run_once(db, data: FlightData | None = None) -> int:
    now = datetime.now(UTC)
    flights = db.flights_with_latest_forecast(now)
    entitled = entitled_flights(db, flights) if data else set()
    count, sources = 0, None
    for flight in flights:
        try:
            # Status only counts for flights that have live status.
            current = flight.get("status") if flight["id"] in entitled else None
            if flight["id"] in entitled and status.is_due(current, status.effective_departure(flight, current), now):
                current = refresh_status(db, data, flight, current, now)
                count += 1
            departure = status.effective_departure(flight, current)
            if departure < now - timedelta(hours=1) or not is_due(flight, now, departure):
                continue
            origin = airports.lookup(flight["origin"])
            destination = airports.lookup(flight["destination"])
            if departure - now > forecast.FORECAST_WINDOW:
                result = forecast.Forecast(status="too_early")
            else:
                sources = sources or load_sources(now)
                result = forecast.compute(origin, destination, departure, now, sources)
            db.insert_forecast(flight["id"], {**result.to_row(), "departure_at": departure.isoformat()})
            db.prune_forecasts(flight["id"], now - HISTORY)
            count += 1
            log.info("flight %s %s->%s: %s %s", flight["id"], origin.iata, destination.iata, result.status, result.grade or "")
        except Exception:
            log.exception("flight %s failed", flight["id"])
    return count


def prune_cache(max_age: timedelta = timedelta(days=1)) -> None:
    cutoff = time.time() - max_age.total_seconds()
    for path in CACHE_DIR.glob("*/*.grib2"):
        if path.stat().st_mtime < cutoff:
            path.unlink(missing_ok=True)


def poll(db, apns: Apns | None, data: FlightData | None = None) -> None:
    """One pass: status and forecasts first (notifications describe them), then notifications,
    then published schedules, then map data. Each step is isolated so a failure in one doesn't
    block the others."""
    steps = [
        ("forecasts", lambda: f"processed {run_once(db, data)} status/forecast update(s)"),
        ("notifications", lambda: f"{notify.run(db, apns, datetime.now(UTC))} notification(s)"),
        ("schedules", lambda: f"{notify.check_schedules(db, data, apns, datetime.now(UTC))} schedule(s) published"),
        ("pireps", lambda: f"{mapdata.refresh_pireps(db, datetime.now(UTC))} pilot report(s)"),
        ("map", lambda: f"{refresh_map(db)} map layer(s)"),
    ]
    for name, step in steps:
        try:
            log.info("%s: %s", name, step())
        except Exception:
            log.exception("%s failed", name)
    prune_cache()


def refresh_map(db) -> int:
    cycle = gtg.latest_cycle()
    return mapdata.refresh_grids(db, GtgSource(cycle, CACHE_DIR)) if cycle else 0


def cmd_run(args: argparse.Namespace) -> None:
    from .db import Database

    db = Database()
    apns = Apns.from_env()
    if apns is None:
        log.warning("APNs not configured (APNS_KEY_ID / APNS_TEAM_ID / APNS_KEY): notifications are recorded, not pushed")
    data = FlightData.from_env()
    if data is None:
        log.warning("Flight data not configured (AERODATABOX_API_KEY): no live status or schedule checks")
    while True:
        poll(db, apns, data)
        if args.once:
            return
        time.sleep(POLL_SECONDS)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    parser = argparse.ArgumentParser(prog="smooth-worker")
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("forecast", help="Compute one forecast and print it")
    p.add_argument("origin")
    p.add_argument("destination")
    p.add_argument("departure", help="Scheduled departure, ISO 8601 UTC, e.g. 2026-10-19T14:00Z")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_forecast)

    p = sub.add_parser("run", help="Keep forecasts in Supabase fresh")
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=cmd_run)

    args = parser.parse_args()
    args.func(args)
