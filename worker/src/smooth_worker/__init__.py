"""Smooth turbulence forecast worker.

  smooth-worker forecast JFK LAX 2026-10-19T14:00Z   # one-off forecast, prints a summary
  smooth-worker run                                  # keep forecasts, notifications and map data fresh
"""

import argparse
import json
import logging
import os
import threading
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from . import aircraft, airfield, airports, archive, flightdata, forecast, hazards, mapdata, notify, status
from .apns import Apns
from .flightdata import FlightData
from .sources import EcmwfSource, GfsSource, GtgEnsemble, GtgSource, Outlook, ecmwf, gfs, gtg

log = logging.getLogger("smooth_worker")

CACHE_DIR = Path(os.environ.get("SMOOTH_CACHE", Path.home() / ".cache/smooth"))
POLL_SECONDS = 300
# New flights get their first forecast within seconds (onboarding waits for it), not at the next poll.
NEW_FLIGHT_POLL_SECONDS = 2
NEW_FLIGHT_LOOKBACK = timedelta(minutes=30)
# After a failure, leave the flight to the regular poll for a while instead of retrying every 5 s.
NEW_FLIGHT_RETRY = timedelta(minutes=2)
# GTG hours are decoded ahead of time on their own thread. Each hour is ~22 NOMADS requests, and
# NOMADS blocks a client for a while above ~120 a minute, so hours are spaced out: a new hourly
# run takes ~10 minutes, during which forecasts use the run before.
GTG_CHECK_SECONDS = 60
GTG_PACE_SECONDS = 30
# NOMADS throttling us (429, or a 302 with nowhere to go): back off for longer than a normal check.
GTG_THROTTLED_SECONDS = 300
# ECMWF runs every 6 hours; each step is one ~17 MB download and ~4 s of work under the lock.
ECMWF_CHECK_SECONDS = 600
ECMWF_PACE_SECONDS = 5
# The outlook blends ECMWF in with GFS (sources/outlook.py). SMOOTH_ECMWF=0 turns it off.
ECMWF_ENABLED = os.environ.get("SMOOTH_ECMWF", "1") != "0"
# A decoded ECMWF run older than this (the thread stalled) is left out rather than used stale.
ECMWF_MAX_AGE = timedelta(hours=24)
GTG_REFRESH = timedelta(hours=1)  # GTG cycles hourly
GFS_REFRESH = timedelta(hours=6)  # GFS cycles every 6 hours
# A GFS-only forecast for a flight GTG reaches (GTG was unavailable, e.g. right after a restart, or
# a flight added then) is retried every few minutes instead of waiting out the hourly refresh.
GTG_REACH = timedelta(hours=gtg.MAX_FHR - 3)  # the newest GTG run is ~2 h old and runs 18 h
# The same goes for a GTG forecast kept through a delay and copied to the new departure.
OUTLOOK_RETRY = timedelta(minutes=10)
HISTORY = timedelta(days=3)
# NOAA's detailed forecast (GTG) is never swapped for less of it while the run it came from still
# reaches the flight: coverage only grows as a flight gets closer, so losing it means GTG was
# unavailable this pass (NOMADS throttling, a fresh worker with nothing decoded), not new weather.
GTG_SOURCES = ("gtg", "mixed")

# Held while weather data is loaded or used (a forecast, the map, cache pruning), so its files
# are never loaded twice at once and a flight is never forecast twice in parallel. The poll takes
# it per forecast, so a new flight usually waits for one flight at most (longer while the map
# step loads a new GTG cycle).
work_lock = threading.Lock()
# Weather inputs shared by the poll and the new-flight watcher (only touched under work_lock), so
# the two never hold separate copies of the weather fields in memory. Each poll refreshes them
# (finding the newest runs is a NOAA request that can take seconds), so a new flight finds them
# ready; they're only rebuilt on demand if the poll has stalled.
INPUTS_MAX_AGE = timedelta(minutes=15)
_shared_inputs: "ForecastInputs | None" = None
# When each flight was last forecast in this process, so the poll skips a flight the new-flight
# watcher forecast while the poll was running.
forecast_issued: dict[str, datetime] = {}
# When an outlook was last retried for GTG and came back the same (see unchanged_outlook): the
# next try waits OUTLOOK_RETRY from then, as no new row was stored to time it from.
outlook_tried: dict[str, datetime] = {}


def load_sources(now: datetime, global_coverage: bool | None = None) -> list:
    global_coverage = forecast.GLOBAL_COVERAGE if global_coverage is None else global_coverage
    sources = []
    if global_coverage:
        # Blend the newest GTG run with the one before; the older run's files are usually cached already.
        if cycles := gtg.latest_cycles(now, 2):
            sources.append(GtgEnsemble([GtgSource(c, CACHE_DIR) for c in cycles]))
    elif cycle := gtg_cycle(now):
        sources.append(GtgSource(cycle, CACHE_DIR))
    if not sources:
        log.warning("gtg: no run available (none decoded, no NOMADS listing); outlook only, GTG forecasts are kept")
    gfs_source = GfsSource(cycle, CACHE_DIR) if (cycle := gfs.latest_cycle(now)) else None
    ecmwf_source = EcmwfSource(cycle, CACHE_DIR) if (cycle := ecmwf_cycle(now)) else None
    if gfs_source or ecmwf_source:
        sources.append(Outlook(gfs_source, ecmwf_source))
    if not sources:
        raise RuntimeError("No GTG, GFS or ECMWF cycle available")
    log.info("sources: %s", ", ".join(_describe(s) for s in sources))
    return sources


def _describe(source) -> str:
    members = getattr(source, "members", [source])
    return " + ".join(f"{m.name}@{m.cycle:%Y-%m-%d %HZ}" for m in members)


def ecmwf_cycle(now: datetime) -> datetime | None:
    """The newest ECMWF run decoded in full (`watch_ecmwf`), if it's recent: forecasts never wait
    for ECMWF downloads."""
    if not ECMWF_ENABLED:
        return None
    ready = ecmwf.ready_cycles(CACHE_DIR)
    return ready[0] if ready and now - ready[0] <= ECMWF_MAX_AGE else None


def gtg_cycle(now: datetime) -> datetime | None:
    """The GTG run to forecast with: the newest one already decoded (`watch_gtg`), so a forecast
    never waits for decoding; for a few minutes after a run comes out, that's the one before.
    The published list only decides when nothing decoded is recent (the gtg thread is behind);
    a throttled listing finds nothing, and the decoded run is used."""
    ready = gtg.ready_cycles(CACHE_DIR)
    listed = gtg.latest_cycle(now)
    if ready and (listed is None or ready[0] >= listed - timedelta(hours=1)):
        return ready[0]
    return listed


def _parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def cmd_forecast(args: argparse.Namespace) -> None:
    now = datetime.now(UTC)
    origin, destination = airports.lookup(args.origin), airports.lookup(args.destination)
    departure = _parse_time(args.departure)
    wide = args.global_coverage or forecast.GLOBAL_COVERAGE
    result = forecast.compute(
        origin, destination, departure, now, load_sources(now, wide), hazards.load() if wide else None, wide
    )
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
    if result.extended:
        stretches = ", ".join(f"{s['source']} {s['start_min']}-{s['end_min']}" for s in result.sources)
        print(f"sources: {stretches}  noaa_possible={result.noaa_possible}")
        for w in result.warnings:
            print(f"  warning {w['start_min']:>4}-{w['end_min']:<4} min  {w['severity']:<8} {w['label']}")


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
    if latest["status"] == "out_of_coverage" and not forecast.GLOBAL_COVERAGE:
        return False  # with worldwide coverage, earlier "outside coverage" flights get forecast now
    forecast_for = _parse_time(latest["departure_at"]) if latest.get("departure_at") else scheduled
    if forecast_for != departure and latest["status"] != "too_early":
        return True  # the departure moved: forecast the new time now
    if departure - now > forecast.FORECAST_WINDOW:
        return False  # still too early; app shows when the forecast unlocks
    if latest["status"] == "too_early":
        return True  # just entered the 48 h window
    refresh = regular_refresh(departure, now)
    if latest.get("source") == "gfs" and departure - now <= GTG_REACH and _gtg_can_cover(latest):
        # An outlook that came back unchanged isn't stored again: the next try counts from that one.
        tried = outlook_tried.get(flight.get("id"))
        if tried and now - tried < OUTLOOK_RETRY and now - issued < refresh:
            return False
        refresh = OUTLOOK_RETRY
    if latest.get("retimed"):
        refresh = OUTLOOK_RETRY  # kept and moved to a delay: never computed for this departure
    return now - issued >= refresh


def regular_refresh(departure: datetime, now: datetime) -> timedelta:
    """How long a forecast stays fresh, when nothing hurries it: as often as its model runs."""
    return GTG_REFRESH if departure - now <= timedelta(hours=gtg.MAX_FHR) else GFS_REFRESH


def _gtg_can_cover(latest: dict) -> bool:
    """Whether GTG could have covered this forecast's route. Worldwide, routes outside the US are
    outlook-only by design, so only those GTG reaches are retried early."""
    return not forecast.GLOBAL_COVERAGE or latest.get("noaa_possible") is True


def loses_gtg(previous: dict | None, result: forecast.Forecast, departure: datetime) -> bool:
    """Whether storing `result` would swap the flight's GTG forecast for less of it: GFS only, or an
    older GTG run, while the run `previous` came from still reaches the departure."""
    if not previous or previous.get("status") != "ready" or previous.get("source") not in GTG_SOURCES:
        return False
    if result.status != "ready" or not previous.get("model_run"):
        return False
    run = _parse_time(previous["model_run"])
    if departure > run + timedelta(hours=gtg.MAX_FHR):
        return False  # delayed beyond that run's reach: the outlook is all there is
    if result.source == "gfs":
        return True
    # For gtg and mixed results, model_run is the GTG run (sources go in priority order).
    return result.model_run is not None and result.model_run < run


def unchanged_outlook(
    flight: dict, previous: dict | None, result: forecast.Forecast, departure: datetime, now: datetime
) -> bool:
    """Whether `result` is the outlook the flight has already, retried early for GTG (OUTLOOK_RETRY)
    while GTG is still unavailable: from the same GFS run, for the same departure, before its
    regular refresh. Storing it would only move its issued time and resend the plan to the Live
    Activity every few minutes."""
    if not previous or previous.get("status") != "ready" or previous.get("source") != "gfs" or previous.get("retimed"):
        return False
    if result.status != "ready" or result.source != "gfs" or not previous.get("model_run"):
        return False
    issued = _parse_time(previous["issued_at"])
    forecast_for = _parse_time(previous.get("departure_at") or flight["departure_at"])
    edited = flight.get("updated_at") and _parse_time(flight["updated_at"]) > issued
    return (
        not edited
        and forecast_for == departure
        and _parse_time(previous["model_run"]) == result.model_run
        and now - issued < regular_refresh(departure, now)
    )


def status_flights(flights: list[dict]) -> set[str]:
    """Flights with live status: every flight saved with a number. Status is free."""
    return {f["id"] for f in flights if f.get("flight_number")}


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
    log.info(
        "flight %s %s: %s (%s)", flight["id"], flight["flight_number"], row.get("status") or "not found",
        row.get("aircraft_model") or "plane not named",
    )
    if leg is not None:
        try:
            # Measured only: a failure here never holds up status or the forecast.
            if seen := aircraft.observation(leg, previous, status.effective_departure(flight, row), now):
                db.note_aircraft({"flight_id": flight["id"], **seen})
        except Exception:
            log.exception("flight %s: aircraft note failed", flight["id"])
    return row


def run_once(db, data: FlightData | None = None) -> int:
    now = datetime.now(UTC)
    flights = db.flights_with_latest_forecast(now)
    numbered = status_flights(flights) if data else set()
    # Every numbered flight is watched for wheels-up, not just those with a Live Activity: the app
    # times the countdown from it, and starts one for flights already in the air.
    watched = numbered
    count = 0
    for seen in (forecast_issued, outlook_tried):
        for flight_id, at in list(seen.items()):
            if now - at > timedelta(hours=1):
                del seen[flight_id]
    try:
        airfield.prefetch(wind_airports(flights, now), now)
    except Exception:
        log.exception("airport forecasts failed")
    for flight in flights:
        try:
            # Status only counts for flights that have live status.
            current = flight.get("status") if flight["id"] in numbered else None
            if flight["id"] in numbered and status.is_due(
                current, status.effective_departure(flight, current), now, watching=flight["id"] in watched, flight=flight
            ):
                current = refresh_status(db, data, flight, current, now)
                count += 1
            departure = status.effective_departure(flight, current)
            # Forecasts stop an hour after departure, except a first one for a flight saved (or
            # edited) in the air, until it lands.
            first = not flight.get("forecasts")
            if departure < now - timedelta(hours=1) and not (first and now < status.forecast_ends(flight, current, departure)):
                continue
            if not is_due(flight, now, departure):
                continue
            previous = (flight.get("forecasts") or [None])[0]
            with work_lock:
                if forecast_issued.get(flight["id"], now) > now:
                    continue  # the new-flight watcher just did it
                if not store_forecast(db, flight, departure, now, shared_inputs(now), previous):
                    continue  # kept the forecast it has; still due, so the next pass tries again
            count += 1
        except gtg.Unavailable as e:
            log.warning("flight %s: GTG not available (%s); keeping its forecast", flight["id"], e)
        except Exception:
            log.exception("flight %s failed", flight["id"])
    return count


class ForecastInputs:
    """Weather sources and hazards, loaded on first use and shared by one pass's flights."""

    def __init__(self, now: datetime):
        self.now = now
        self._sources: list | None = None
        self._hazards = None
        self._hazards_loaded = False

    def sources(self) -> list:
        if self._sources is None:
            self._sources = load_sources(self.now)
        return self._sources

    def runs(self) -> list[tuple[str, datetime]] | None:
        """Which model runs these inputs hold, once loaded."""
        if self._sources is None:
            return None
        return [(s.name, s.cycle, getattr(s, "runs", None)) for s in self._sources]

    def hazards(self):
        if forecast.GLOBAL_COVERAGE and not self._hazards_loaded:
            self._hazards, self._hazards_loaded = hazards.load(), True
        return self._hazards


def refresh_inputs(now: datetime) -> str:
    """Find the newest weather runs outside the lock, then swap them in. Unchanged runs keep the
    current inputs, and with them the GFS tiles already decoded into memory."""
    global _shared_inputs
    fresh = ForecastInputs(now)
    fresh.sources()
    fresh.hazards()
    with work_lock:
        if _shared_inputs is not None and _shared_inputs.runs() == fresh.runs():
            _shared_inputs.now = now
        else:
            _shared_inputs = fresh
    return ", ".join(_describe(s) for s in fresh.sources())


def shared_inputs(now: datetime) -> ForecastInputs:
    """The current weather inputs, fresh at least every few minutes. Call with work_lock held."""
    global _shared_inputs
    if _shared_inputs is None or now - _shared_inputs.now > INPUTS_MAX_AGE:
        _shared_inputs = ForecastInputs(now)
    return _shared_inputs


def store_forecast(
    db, flight: dict, departure: datetime, now: datetime, inputs: ForecastInputs, previous: dict | None = None
) -> bool:
    """Compute the flight's forecast for `departure` and save it, unless it has less GTG than
    `previous` (the flight's latest forecast). Returns whether it was stored."""
    origin = airports.lookup(flight["origin"])
    destination = airports.lookup(flight["destination"])
    if departure - now > forecast.FORECAST_WINDOW:
        result = forecast.Forecast(status="too_early")
    else:
        result = forecast.compute(origin, destination, departure, now, inputs.sources(), inputs.hazards())
        try:
            airport_wind(flight, departure, result, previous, now)
        except Exception:
            log.exception("flight %s: airport wind failed; stored without it", flight["id"])
    if loses_gtg(previous, result, departure):
        log.warning(
            "flight %s %s->%s: no GTG this pass (got %s %s); keeping its %s forecast from %s",
            flight["id"], origin.iata, destination.iata, result.source, result.grade or "",
            previous["source"], previous["issued_at"],
        )
        forecast_for = _parse_time(previous.get("departure_at") or flight["departure_at"])
        if forecast_for != departure:
            # Marked retimed: retried within minutes, and never described as updated.
            db.retime_forecast(previous["id"], departure)
        return False
    if unchanged_outlook(flight, previous, result, departure, now):
        outlook_tried[flight["id"]] = now
        log.info("flight %s %s->%s: still no GTG; keeping its outlook", flight["id"], origin.iata, destination.iata)
        return False
    db.insert_forecast(flight["id"], {**result.to_row(), "departure_at": departure.isoformat()})
    forecast_issued[flight["id"]] = datetime.now(UTC)
    outlook_tried.pop(flight["id"], None)
    db.prune_forecasts(flight["id"], now - HISTORY)
    log.info("flight %s %s->%s: %s %s", flight["id"], origin.iata, destination.iata, result.status, result.grade or "")
    return True


def airport_wind(
    flight: dict, departure: datetime, result: forecast.Forecast, previous: dict | None, now: datetime
) -> None:
    """Tag the gusty takeoff and landing stretches of a confirmed forecast (airfield.py). Takeoff and
    landing are timed as the pushes time them: the reported runway time once it has passed, else
    departure plus taxi, and landing by the airline's arrival when it's near the plan."""
    if result.status != "ready" or result.source == "gfs":
        return
    origin, destination = airports.lookup(flight["origin"]), airports.lookup(flight["destination"])
    live = flight.get("status") or {}
    reported = _parse_time(live["takeoff_at"]) if live.get("takeoff_at") else None
    takeoff = reported if reported and reported <= now else departure + timedelta(minutes=status.TAXI_OUT_MIN)
    landing = takeoff + timedelta(minutes=notify.duration_min(result.to_row(), takeoff, live))
    before = {wind.get("end"): wind for wind in (previous or {}).get("airport_wind") or []}
    ends = [
        airfield.decide(end, airport, (at - airfield.WINDOW, at + airfield.WINDOW), before.get(end), now)
        for end, airport, at in ((airfield.ORIGIN, origin, takeoff), (airfield.DESTINATION, destination, landing))
    ]
    result.airport_wind = airfield.tag(
        result, ends, {airfield.ORIGIN: origin, airfield.DESTINATION: destination}, forecast._grade
    )


def wind_airports(flights: list[dict], now: datetime) -> set[str]:
    """The airports of flights taking off or landing within airfield.AHEAD, fetched in one go."""
    icaos = set()
    for flight in flights:
        departure = status.effective_departure(flight, flight.get("status"))
        if now - timedelta(hours=18) <= departure <= now + airfield.AHEAD:
            icaos |= {flight["origin"], flight["destination"]}
    return icaos


def run_new_flights(db, failed: dict[str, datetime], data: FlightData | None = None) -> int:
    """First forecasts for flights saved in the last few minutes. Returns how many were made.
    `failed` holds when each flight last failed, so a broken one isn't retried every pass.
    Numbered flights get their status first, so a flight saved in the air knows its takeoff
    within seconds and the forecast uses the real departure."""

    def pending(now: datetime) -> list[dict]:
        flights = db.new_flights_without_forecast(now, NEW_FLIGHT_LOOKBACK)
        return [
            f
            for f in flights
            if now - failed.get(f["id"], datetime.min.replace(tzinfo=UTC)) >= NEW_FLIGHT_RETRY
            and now < status.forecast_ends(f, f.get("status"), status.effective_departure(f, f.get("status")))
        ]

    waiting = pending(datetime.now(UTC))
    if not waiting:
        return 0
    # Status is a network call: fetched outside the lock, on this thread's own client.
    statuses = {f["id"]: new_flight_status(db, data, f) for f in waiting}
    with work_lock:
        # Check again: the regular poll may have forecast them while this waited for the lock.
        now = datetime.now(UTC)
        count = 0
        for flight in pending(now):
            if flight["id"] not in statuses:
                continue  # saved since: its status comes first, on the next pass
            try:
                departure = status.effective_departure(flight, statuses[flight["id"]] or flight.get("status"))
                store_forecast(db, flight, departure, now, shared_inputs(now))
                failed.pop(flight["id"], None)
                count += 1
            except gtg.Unavailable as e:
                failed[flight["id"]] = now
                log.warning("new flight %s: GTG not available (%s); trying again later", flight["id"], e)
            except Exception:
                failed[flight["id"]] = now
                log.exception("new flight %s failed", flight["id"])
        return count


def new_flight_status(db, data: FlightData | None, flight: dict) -> dict | None:
    """A new numbered flight's status, fetched now unless it was just checked. A failure only
    means the forecast uses the schedule; the poll tries the status again."""
    current = flight.get("status")
    if data is None or not flight.get("flight_number"):
        return current
    now = datetime.now(UTC)
    if not status.is_due(current, status.effective_departure(flight, current), now, watching=True, flight=flight):
        return current
    try:
        return refresh_status(db, data, flight, current, now)
    except Exception:
        log.exception("new flight %s: status failed", flight["id"])
        return current


def watch_new_flights(db, data: FlightData | None = None) -> None:
    """Runs beside the poll loop for the life of the worker."""
    failed: dict[str, datetime] = {}
    while True:
        try:
            if count := run_new_flights(db, failed, data):
                log.info("new flights: %d first forecast(s)", count)
        except Exception:
            log.exception("new flights failed")
        time.sleep(NEW_FLIGHT_POLL_SECONDS)


def prune_cache(max_age: timedelta = timedelta(days=1)) -> None:
    cutoff = time.time() - max_age.total_seconds()
    for path in CACHE_DIR.glob("*/*.grib2"):
        if path.stat().st_mtime < cutoff:
            path.unlink(missing_ok=True)
    gtg.prune(CACHE_DIR)
    ecmwf.prune(CACHE_DIR)
    archive.prune(CACHE_DIR)


def prepare_gtg(now: datetime, pace: float = GTG_PACE_SECONDS) -> int:
    """Decode every hour of the newest GTG run(s) to disk ahead of the forecasts and map that read
    them. One hour per lock, so a new flight's forecast can go between, and `pace` seconds apart
    to stay well inside NOMADS' rate limit. The hours the archive keeps are sampled once decoded
    (archive.py), including ones decoded before a restart. Returns hours decoded."""
    cycles = gtg.latest_cycles(now, 2 if forecast.GLOBAL_COVERAGE else 1)
    # Never older than what's decoded already (a listing can lag, or fall back to yesterday's runs).
    if ready := gtg.ready_cycles(CACHE_DIR):
        cycles = [c for c in cycles if c >= ready[0]]
    decoded = 0
    for cycle in cycles:
        source = GtgSource(cycle, CACHE_DIR)
        for fhr in range(gtg.MAX_FHR + 1):
            if not source.is_cached(fhr):
                with work_lock:
                    source.cache(fhr)
                decoded += 1
                time.sleep(pace)
            if archive.wanted(cycle, fhr):
                with work_lock:
                    archive.save_gtg(source, fhr, CACHE_DIR)
    if decoded:
        with work_lock:
            gtg.prune(CACHE_DIR)
    return decoded


def gtg_step() -> int:
    """One check for new GTG hours to decode. Returns the seconds to wait before the next."""
    try:
        if count := prepare_gtg(datetime.now(UTC)):
            log.info("gtg: %d hour(s) decoded", count)
    except gtg.Unavailable as e:
        # Hours decoded before this stay on disk; the next check carries on from there.
        log.info("gtg: not available yet (%s); trying again later", e)
        return GTG_CHECK_SECONDS if e.status == 404 else GTG_THROTTLED_SECONDS
    except Exception:
        log.exception("gtg failed")
    return GTG_CHECK_SECONDS


def watch_gtg() -> None:
    """Runs beside the poll loop: decodes each new GTG run as it's published."""
    while True:
        time.sleep(gtg_step())


def prepare_ecmwf(now: datetime, pace: float = ECMWF_PACE_SECONDS) -> int:
    """Decode every step the outlook reads of the newest ECMWF run, one per lock so forecasts can
    go between. Returns steps decoded."""
    cycle = ecmwf.latest_cycle(now)
    if cycle is None or (ready := ecmwf.ready_cycles(CACHE_DIR)) and ready[0] >= cycle:
        return 0
    source = EcmwfSource(cycle, CACHE_DIR)
    decoded = 0
    for step in range(0, ecmwf.NEEDED_STEP + 1, ecmwf.STEP_H):
        if source.is_cached(step):
            continue
        with work_lock:
            source.cache(step)
        decoded += 1
        time.sleep(pace)
    with work_lock:
        ecmwf.prune(CACHE_DIR)
    return decoded


def watch_ecmwf() -> None:
    """Runs beside the poll loop: decodes each new ECMWF run as it's published."""
    while True:
        try:
            if count := prepare_ecmwf(datetime.now(UTC)):
                log.info("ecmwf: %d step(s) decoded", count)
        except Exception:
            log.exception("ecmwf failed")
        time.sleep(ECMWF_CHECK_SECONDS)


def poll(db, apns: Apns | None, data: FlightData | None = None) -> None:
    """One pass: fresh weather inputs, status and forecasts first (notifications describe them),
    then notifications, then published schedules, then map data. Each step is isolated
    so a failure in one doesn't block the others."""
    steps = [
        ("inputs", lambda: refresh_inputs(datetime.now(UTC))),
        ("forecasts", lambda: f"processed {run_once(db, data)} status/forecast update(s)"),
        ("passes", lambda: verify_passes(db, datetime.now(UTC))),
        ("notifications", lambda: f"{notify.run(db, apns, datetime.now(UTC))} notification(s)"),
        ("takeoffs", lambda: f"{notify.push_takeoffs(db, apns, datetime.now(UTC))} takeoff(s) pushed"),
        ("schedules", lambda: f"{notify.check_schedules(db, data, apns, datetime.now(UTC))} schedule(s) published"),
        ("status purge", lambda: f"{db.prune_flight_status(datetime.now(UTC) - status.KEEP)} old status row(s) deleted"),
        ("pireps", lambda: f"{mapdata.refresh_pireps(db, datetime.now(UTC))} pilot report(s)"),
        ("map", lambda: f"{refresh_map(db)} map layer(s)"),
        ("reports archive", lambda: f"{archive.save_reports(datetime.now(UTC), CACHE_DIR)} pilot report(s) saved"),
        ("archive", lambda: f"{archive.upload_pending(CACHE_DIR)} file(s) uploaded"),
    ]
    for name, step in steps:
        try:
            # The forecasts step locks per flight; the map reads weather for the whole step.
            if name == "map":
                with work_lock:
                    result = step()
            else:
                result = step()
            log.info("%s: %s", name, result)
        except Exception:
            log.exception("%s failed", name)
    with work_lock:
        prune_cache()


PASS_SWEEP_EVERY = timedelta(minutes=10)
_last_pass_sweep: datetime | None = None


def verify_passes(db, now: datetime) -> str:
    """Passes that apps up to 1.0.3 saved themselves are checked with Apple (by the verify-pass
    function) before notifications count them. At most every 10 minutes, and only when one waits."""
    global _last_pass_sweep
    if _last_pass_sweep and now - _last_pass_sweep < PASS_SWEEP_EVERY:
        return "not due"
    _last_pass_sweep = now
    if not db.passes_waiting():
        return "none waiting"
    counts = db.verify_passes()
    return ", ".join(f"{n} {status}" for status, n in counts.items())


def refresh_map(db) -> int:
    cycle = gtg.latest_cycle()
    if not cycle:
        return 0
    source = GtgSource(cycle, CACHE_DIR)
    # Wait for the gtg thread to decode the run rather than downloading it here as well.
    if not all(source.is_cached(fhr) for fhr in mapdata.MAP_FHRS):
        return 0
    return mapdata.refresh_grids(db, source)


def cmd_run(args: argparse.Namespace) -> None:
    from .db import Database

    db = Database()
    apns = Apns.from_env()
    if apns is None:
        log.warning("APNs not configured (APNS_KEY_ID / APNS_TEAM_ID / APNS_KEY): notifications are recorded, not pushed")
    data = FlightData.from_env()
    if data is None:
        log.warning("Flight data not configured (AERODATABOX_API_KEY): no live status or schedule checks")
    if not args.once:
        # Its own connections: the poll loop's clients aren't shared across threads.
        threading.Thread(
            target=watch_new_flights, args=(Database(), FlightData.create()), name="new-flights", daemon=True
        ).start()
        threading.Thread(target=watch_gtg, name="gtg", daemon=True).start()
        if ECMWF_ENABLED:
            threading.Thread(target=watch_ecmwf, name="ecmwf", daemon=True).start()
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
    p.add_argument(
        "--global", dest="global_coverage", action="store_true", help="Worldwide coverage, as with SMOOTH_GLOBAL=1"
    )
    p.set_defaults(func=cmd_forecast)

    p = sub.add_parser("run", help="Keep forecasts in Supabase fresh")
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=cmd_run)

    args = parser.parse_args()
    args.func(args)
