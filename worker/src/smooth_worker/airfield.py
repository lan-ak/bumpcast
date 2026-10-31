"""Gusty takeoffs and landings, from the airports' own wind forecasts (TAFs).

Near the ground, gusty wind makes the climb out and the approach bumpy for a few minutes. The
route forecast can show those bumps but not why. Where an airport's forecast has gusts of 25 kt or
more within an hour of takeoff or landing, the climb or descent stretch there is tagged with the
cause ("wind_origin" or "wind_destination"), and the app says so calmly. Tagging never changes the
numbers: the grade, the stretches and every push stay as they were.

Only confirmed (GTG) stretches are tagged, never the 18-48 h outlook, and only one whose bumpiest
minute is within 4,000 ft of the airport. What was decided for each end, and what was left out and
why, is kept on the forecast as airport_wind: never shown, it's there to tune the rules.
docs/design/gate-and-wind-brief.md.
"""

import logging
import threading
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import httpx

from .airports import Airport
from .http import client

log = logging.getLogger(__name__)

TAF_URL = "https://aviationweather.gov/api/data/taf"
GUSTY_KT = 25
# Once an end is gusty it stays so until the forecast gusts drop below this, so the line doesn't
# come and go between hourly updates.
SETTLED_KT = 20
WINDOW = timedelta(minutes=60)
LAYER_FT = 4000
CACHE = timedelta(minutes=10)
# Flights taking off or landing within this long have their airports' forecasts fetched in one go.
AHEAD = timedelta(hours=30)
# Shadow data only: light chop near the ground at a gusty end with no stretch there. Whether to
# ever add it is a later, separate decision.
FLOOR_EDR = 0.12

ORIGIN, DESTINATION = "origin", "destination"
CAUSE = {ORIGIN: "wind_origin", DESTINATION: "wind_destination"}
PHASE = {ORIGIN: "climb", DESTINATION: "descent"}


class FeedDown(Exception):
    """The forecasts couldn't be fetched (as opposed to an airport having none)."""


@dataclass
class Taf:
    issued: datetime
    valid_from: datetime
    valid_to: datetime
    # (start, end, gust kt) for every group that counts: the base, FM, BECMG and TEMPO groups.
    # A group with a probability (PROB30, PROB40, PROB30 TEMPO) is a maybe and never counts.
    groups: list[tuple[datetime, datetime, float]]

    def gust_kt(self, start: datetime, end: datetime) -> float | None:
        """The strongest gust forecast in [start, end], 0 for none, or None when this forecast
        doesn't cover the whole window."""
        if start < self.valid_from or end > self.valid_to:
            return None
        return max((gust for a, b, gust in self.groups if a < end and b > start), default=0.0)


def _at(seconds) -> datetime:
    return datetime.fromtimestamp(seconds, UTC)


def parse(taf: dict) -> Taf:
    valid_from, valid_to = _at(taf["validTimeFrom"]), _at(taf["validTimeTo"])
    fcsts = sorted(taf.get("fcsts") or [], key=lambda f: f["timeFrom"])
    # A BECMG change lasts until the next base or FM group (its own times are the transition).
    starts = [_at(f["timeFrom"]) for f in fcsts if f.get("fcstChange") in (None, "FM")]
    groups = []
    for f in fcsts:
        if f.get("probability") or f.get("fcstChange") == "PROB":
            continue
        start, end = _at(f["timeFrom"]), _at(f["timeTo"])
        if f.get("fcstChange") == "BECMG":
            end = next((s for s in starts if s > start), valid_to)
        groups.append((start, end, float(f.get("wgst") or 0)))
    issued = datetime.fromisoformat(taf["issueTime"].replace("Z", "+00:00"))
    return Taf(issued=issued, valid_from=valid_from, valid_to=valid_to, groups=groups)


_lock = threading.Lock()
_cache: dict[str, tuple[datetime, Taf | None]] = {}
_failed: dict[str, datetime] = {}


def _fetch(icaos: list[str]) -> dict[str, Taf]:
    r = client().get(TAF_URL, params={"ids": ",".join(icaos), "format": "json"}, timeout=15)
    if r.status_code == 204:
        return {}
    r.raise_for_status()
    latest: dict[str, Taf] = {}
    for raw in r.json() or []:
        try:
            taf = parse(raw)
        except (KeyError, TypeError, ValueError):
            log.warning("TAF for %s unreadable; skipped", raw.get("icaoId"))
            continue
        icao = raw.get("icaoId")
        if icao and (icao not in latest or taf.issued > latest[icao].issued):
            latest[icao] = taf
    return latest


def prefetch(icaos: set[str], now: datetime) -> None:
    """Fetch the forecasts not cached in the last 10 minutes, in one request."""
    with _lock:
        stale = sorted(i for i in icaos if i not in _cache or now - _cache[i][0] > CACHE)
        if not stale:
            return
        try:
            fetched = _fetch(stale)
        except (httpx.HTTPError, ValueError) as e:
            log.warning("airport forecasts unavailable (%s)", e)
            for icao in stale:
                _failed[icao] = now
            return
        for icao in stale:
            _cache[icao] = (now, fetched.get(icao))
            _failed.pop(icao, None)


def taf(icao: str, now: datetime) -> Taf | None:
    """The airport's latest forecast, or None when it has none. Raises FeedDown when it couldn't
    be fetched."""
    prefetch({icao}, now)
    with _lock:
        if icao in _failed:
            raise FeedDown(icao)
        return _cache[icao][1]


def reset() -> None:
    """Forget cached forecasts (tests)."""
    with _lock:
        _cache.clear()
        _failed.clear()


@dataclass
class End:
    """The decision for one end of the flight, kept as shadow data."""

    end: str  # origin | destination
    airport: str
    window: tuple[datetime, datetime]
    gusty: bool = False
    gust_kt: float | None = None
    issued: datetime | None = None
    valid_to: datetime | None = None
    # ok | no_forecast | not_covered | feed_down | outlook
    status: str = "ok"
    held: bool = False  # still gusty under 25 kt, because it was before (SETTLED_KT)
    carried: bool = False  # the feed was down: the previous forecast's answer still covered it


def decide(end: str, airport: Airport, window: tuple[datetime, datetime], previous: dict | None, now: datetime) -> End:
    """Whether this end of the flight is gusty. `previous` is the same end in the flight's last
    forecast's airport_wind, for the settle rule and for riding out a feed failure."""
    decision = End(end=end, airport=airport.icao, window=window)
    was_gusty = bool(previous and previous.get("gusty"))
    try:
        forecast = taf(airport.icao, now)
    except FeedDown:
        decision.status = "feed_down"
        valid_to = previous and previous.get("taf_valid_to")
        if was_gusty and valid_to and datetime.fromisoformat(valid_to) >= window[1]:
            decision.gusty = decision.carried = True
            decision.gust_kt = previous.get("gust_kt")
        return decision
    if forecast is None:
        decision.status = "no_forecast"
        return decision
    decision.issued, decision.valid_to = forecast.issued, forecast.valid_to
    gust = forecast.gust_kt(*window)
    if gust is None:
        decision.status = "not_covered"
        return decision
    decision.gust_kt = gust
    decision.gusty = gust >= GUSTY_KT or (was_gusty and gust >= SETTLED_KT)
    decision.held = decision.gusty and gust < GUSTY_KT
    return decision


def _confirmed(segment: dict, source: str | None, stretches: list[dict]) -> bool:
    """Every minute of the stretch comes from the detailed forecast, not the outlook."""
    if source == "gtg":
        return True
    if source != "mixed":
        return False
    minutes = range(segment["start_min"], segment["end_min"] + 1)
    gtg = [range(s["start_min"], s["end_min"] + 1) for s in stretches if s["source"] == "gtg"]
    return all(any(m in r for r in gtg) for m in minutes)


def _near_ground(samples: list[dict], end: str, ceiling_ft: int) -> list[int]:
    """Indexes of the samples within the layer at that end of the flight."""
    order = range(len(samples)) if end == ORIGIN else range(len(samples) - 1, -1, -1)
    near = []
    for i in order:
        if samples[i]["altitude_ft"] > ceiling_ft:
            break
        near.append(i)
    return near


def tag(result, ends: list[End], airports: dict[str, Airport], grade) -> list[dict]:
    """Tag the qualifying stretches of `result` (a forecast.Forecast) in place and return the
    shadow data for its airport_wind. `grade` is forecast's grading function, for the would-be
    floor."""
    shadow = []
    for decision in ends:
        airport = airports[decision.end]
        ceiling = airport.elev_ft + LAYER_FT
        row = {
            "end": decision.end,
            "airport": decision.airport,
            "gusty": decision.gusty,
            "gust_kt": decision.gust_kt,
            "status": decision.status,
            "held": decision.held,
            "carried": decision.carried,
            "taf_issued": decision.issued.isoformat() if decision.issued else None,
            "taf_valid_to": decision.valid_to.isoformat() if decision.valid_to else None,
            "window_from": decision.window[0].isoformat(),
            "window_to": decision.window[1].isoformat(),
            "tagged": [],
            "excluded": [],
        }
        if decision.gusty:
            for segment in result.segments:
                if segment["phase"] != PHASE[decision.end]:
                    continue
                if not _confirmed(segment, result.source, result.sources):
                    reason = "outlook"
                elif segment["altitude_ft"] > ceiling:
                    reason = "above_layer"
                else:
                    segment["cause"] = CAUSE[decision.end]
                    row["tagged"].append(segment["start_min"])
                    continue
                row["excluded"].append(
                    {"start_min": segment["start_min"], "reason": reason, "altitude_ft": segment["altitude_ft"]}
                )
            # What a floor would add, if one were ever decided on: never applied.
            near = _near_ground(result.samples, decision.end, ceiling)
            raised = {i for i in near if result.samples[i]["edr"] < FLOOR_EDR}
            floored = [
                {**s, "edr": max(s["edr"], FLOOR_EDR)} if i in raised else s for i, s in enumerate(result.samples)
            ]
            row["floor_min"] = len(raised)
            row["floor_grade"] = grade(floored)[0] if raised else result.grade
        shadow.append(row)
    return shadow
