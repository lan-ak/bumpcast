"""Combine a flight profile with turbulence data into a grade and a timeline."""

import logging
import os
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Protocol

from . import hazards as hazards_mod
from . import severity
from .airports import Airport
from .route import PROFILE_VERSION, RoutePoint, Wind, build_profile

log = logging.getLogger(__name__)

FORECAST_WINDOW = timedelta(hours=48)

# Worldwide forecasts (per-source coverage, warnings, per-stretch sources). Off until the
# app ships the matching screens and the forecasts table has the new columns.
GLOBAL_COVERAGE = os.environ.get("SMOOTH_GLOBAL") == "1"

# Rough box around the US GTG (HRRR) domain: the whole coverage area while GLOBAL_COVERAGE is off.
COVERAGE_LAT = (22.0, 52.0)
COVERAGE_LON = (-128.0, -64.0)

# A stretch of bumps ends after this many smooth minutes.
SEGMENT_GAP_MIN = 2
MIN_SEGMENT_MIN = 2

# Over GTG's last hours, ease towards the GFS outlook so the forecast doesn't jump where
# one hands over to the other. GTG keeps most of the weight: it's the better forecast.
HANDOFF_HOURS = 3
HANDOFF_MIN_WEIGHT = 0.75


class Source(Protocol):
    name: str
    cycle: datetime

    def covers(self, valid: datetime) -> bool: ...
    def edr(self, lat: float, lon: float, altitude_ft: float, valid: datetime) -> float: ...


@dataclass
class Forecast:
    status: str  # ready | too_early | out_of_coverage
    source: str | None = None
    model_run: datetime | None = None
    grade: str | None = None
    score: int | None = None
    duration_min: int | None = None
    cruise_ft: int | None = None
    segments: list[dict] = field(default_factory=list)
    samples: list[dict] = field(default_factory=list)
    route: list[list[float]] = field(default_factory=list)
    # Worldwide fields, written only when GLOBAL_COVERAGE is on.
    sources: list[dict] = field(default_factory=list)  # [{start_min, end_min, source}]
    warnings: list[dict] = field(default_factory=list)  # [{start_min, end_min, kind, hazard, severity, region, label}]
    noaa_possible: bool | None = None  # can GTG ever cover the whole route?
    extended: bool = False
    profile: int | None = None  # route.PROFILE_VERSION the path was built with

    def to_row(self) -> dict:
        row = {
            "status": self.status,
            "source": self.source,
            "model_run": self.model_run.isoformat() if self.model_run else None,
            "grade": self.grade,
            "score": self.score,
            "duration_min": self.duration_min,
            "cruise_ft": self.cruise_ft,
            "segments": self.segments,
            "samples": self.samples,
            "route": self.route,
            "profile": self.profile,
        }
        if self.extended:
            row |= {"sources": self.sources, "warnings": self.warnings, "noaa_possible": self.noaa_possible}
        return row


def in_coverage(points: list[RoutePoint]) -> bool:
    return all(
        COVERAGE_LAT[0] <= p.lat <= COVERAGE_LAT[1] and COVERAGE_LON[0] <= p.lon <= COVERAGE_LON[1] for p in points
    )


def _covers_point(source: Source, lat: float, lon: float) -> bool:
    check = getattr(source, "covers_point", None)
    return check(lat, lon) if check else True


def _handoff_weight(source: Source, valid: datetime) -> float:
    """GTG's share near the end of its horizon (1 = GTG only)."""
    horizon = getattr(source, "horizon_h", None)
    if horizon is None:
        return 1.0
    hours_left = horizon - (valid - source.cycle).total_seconds() / 3600
    if hours_left >= HANDOFF_HOURS:
        return 1.0
    return HANDOFF_MIN_WEIGHT + (1 - HANDOFF_MIN_WEIGHT) * max(hours_left, 0) / HANDOFF_HOURS


def _valid_time(sources: list[Source], time: datetime, now: datetime) -> datetime:
    """The time to read the weather at for a minute of the flight. A flight saved in the air can
    have flown minutes from before the oldest run began: those use that run's start instead."""
    if time >= now or not sources or any(s.covers(time) for s in sources):
        return time
    return max(time, min(s.cycle for s in sources))


def compute(
    origin: Airport,
    destination: Airport,
    departure: datetime,
    now: datetime,
    sources: list[Source],
    hazards: list | None = None,
    global_coverage: bool | None = None,
) -> Forecast:
    """`sources` in priority order (most accurate first); each minute uses the first that covers it.

    With global coverage a source must cover the minute's place as well as its time, and
    `hazards` (warnings and pilot reports) can raise any minute they cover.
    """
    global_coverage = GLOBAL_COVERAGE if global_coverage is None else global_coverage
    if departure - now > FORECAST_WINDOW:
        return Forecast(status="too_early", extended=global_coverage)

    # Coverage first, in still air: winds change the timing, not the path, and a route outside it
    # shouldn't fetch winds for every hour of the flight.
    if not global_coverage and not in_coverage(build_profile(origin, destination, departure)):
        return Forecast(status="out_of_coverage")
    points = _profile(origin, destination, departure, sources)
    hazards = hazards or []

    samples, used, ahead, per_minute, flagged = [], set(), set(), [], []
    for p in points:
        usable = [s for s in sources if _covers_point(s, p.lat, p.lon)] if global_coverage else sources
        valid = _valid_time(usable, p.time, now)
        candidates = [s for s in usable if s.covers(valid)]
        if not candidates:
            if global_coverage:
                return Forecast(status="out_of_coverage", extended=True)
            raise RuntimeError(f"No turbulence data covers {p.time.isoformat()}")
        source = candidates[0]
        used.add(source)
        if p.time >= now:
            ahead.add(source)
        per_minute.append(source.name)
        edr = source.edr(p.lat, p.lon, p.altitude_ft, valid)
        weight = _handoff_weight(source, valid)
        if weight < 1 and len(candidates) > 1:
            edr = weight * edr + (1 - weight) * candidates[1].edr(p.lat, p.lon, p.altitude_ft, valid)
        hazard = hazards_mod.strongest(hazards, p.lat, p.lon, p.altitude_ft, p.time) if hazards else None
        if hazard and hazard.floor > edr:
            edr = hazard.floor
        flagged.append(hazard)
        samples.append({"min": p.minute, "edr": round(edr, 3), "altitude_ft": p.altitude_ft, "phase": p.phase})

    segments = _segments(samples)
    grade, score = _grade(samples)
    # In the air, how confirmed the forecast is depends on the minutes still ahead: ones already
    # flown, from before the detailed run began, read the outlook and don't make it "mixed".
    kinds = ahead or used
    primary = min(kinds, key=sources.index)
    gtg = next((s for s in sources if s.name == "gtg"), None)
    if not global_coverage:
        noaa_possible = True
    elif gtg is not None and hasattr(gtg, "in_domain"):
        noaa_possible = all(gtg.in_domain(p.lat, p.lon) for p in points)
    else:
        noaa_possible = in_coverage(points)
    return Forecast(
        status="ready",
        profile=PROFILE_VERSION,
        source=primary.name if len(kinds) == 1 else "mixed",
        model_run=primary.cycle,
        grade=grade,
        score=score,
        duration_min=points[-1].minute,
        cruise_ft=max(p.altitude_ft for p in points),
        segments=segments,
        samples=[{k: s[k] for k in ("min", "edr", "altitude_ft")} for s in samples],
        route=[[round(p.lat, 3), round(p.lon, 3)] for p in points[:: max(len(points) // 40, 1)]] + [
            [round(points[-1].lat, 3), round(points[-1].lon, 3)]
        ],
        sources=_stretches(
            [(p.minute, name) for p, name in zip(points, per_minute) if not ahead or p.time >= now],
            key=lambda v: {"source": v},
        ),
        warnings=_stretches(
            [(p.minute, h) for p, h in zip(points, flagged)],
            key=lambda h: {
                "kind": h.kind, "hazard": h.hazard, "severity": h.severity, "region": h.region, "label": h.label
            },
        ),
        noaa_possible=noaa_possible,
        extended=global_coverage,
    )


def _winds(sources: list[Source]) -> Wind | None:
    """Winds from the first source that has them (GFS), so ground speeds follow the forecast."""
    return next((s.wind for s in sources if callable(getattr(s, "wind", None))), None)


def _profile(origin: Airport, destination: Airport, departure: datetime, sources: list[Source]) -> list[RoutePoint]:
    """The flight path, with winds when a source has them. Winds only refine the timing: when they
    can't be read (a GFS download failing), the path is planned in still air."""
    wind = _winds(sources)
    if wind is not None:
        try:
            return build_profile(origin, destination, departure, wind=wind)
        except Exception:
            log.warning("%s->%s: no winds, planning in still air", origin.icao, destination.icao, exc_info=True)
    return build_profile(origin, destination, departure)


def _stretches(values: list[tuple[int, object]], key) -> list[dict]:
    """Runs of consecutive minutes with the same value (None = no stretch)."""
    out: list[dict] = []
    for minute, value in values:
        if value is None:
            continue
        fields = key(value)
        if out and out[-1]["end_min"] == minute - 1 and all(out[-1][k] == v for k, v in fields.items()):
            out[-1]["end_min"] = minute
        else:
            out.append({"start_min": minute, "end_min": minute, **fields})
    return out


def _segments(samples: list[dict]) -> list[dict]:
    segments: list[dict] = []
    current: dict | None = None
    smooth_run = 0
    for s in samples:
        level = severity.classify(s["edr"])
        if level == severity.SMOOTH:
            smooth_run += 1
            if current and smooth_run > SEGMENT_GAP_MIN:
                segments.append(current)
                current = None
            continue
        smooth_run = 0
        if current is None:
            current = {
                "start_min": s["min"],
                "end_min": s["min"],
                "severity": level,
                "peak_edr": s["edr"],
                "phase": s["phase"],
                "altitude_ft": s["altitude_ft"],
            }
        else:
            current["end_min"] = s["min"]
            current["severity"] = severity.worse(current["severity"], level)
            if s["edr"] > current["peak_edr"]:
                current["peak_edr"] = s["edr"]
                current["phase"] = s["phase"]
                current["altitude_ft"] = s["altitude_ft"]
    if current:
        segments.append(current)
    # Single-minute light blips are noise at this resolution.
    return [
        seg
        for seg in segments
        if seg["end_min"] - seg["start_min"] + 1 >= MIN_SEGMENT_MIN or seg["severity"] != severity.LIGHT
    ]


def _grade(samples: list[dict]) -> tuple[str, int]:
    minutes = {level: 0 for level in severity.ORDER}
    for s in samples:
        minutes[severity.classify(s["edr"])] += 1
    duration = max(len(samples), 1)
    light, moderate, severe = minutes[severity.LIGHT], minutes[severity.MODERATE], minutes[severity.SEVERE]

    badness = (light * 0.3 + moderate * 1.5 + severe * 4) / duration
    score = max(0, min(100, round(100 - 100 * badness)))

    if severe >= 2:
        grade = "rough"
    elif moderate >= 10 or severe:
        grade = "bumpy"
    elif moderate >= 2 or light >= duration * 0.2:
        grade = "some_bumps"
    elif light or moderate:
        grade = "mostly_smooth"
    else:
        grade = "smooth"
    return grade, score
