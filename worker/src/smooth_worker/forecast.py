"""Combine a flight profile with turbulence data into a grade and a timeline."""

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Protocol

from . import severity
from .airports import Airport
from .route import RoutePoint, build_profile

FORECAST_WINDOW = timedelta(hours=48)

# Rough box around the US GTG (HRRR) domain, used before any grid is loaded.
COVERAGE_LAT = (22.0, 52.0)
COVERAGE_LON = (-128.0, -64.0)

# A stretch of bumps ends after this many smooth minutes.
SEGMENT_GAP_MIN = 2
MIN_SEGMENT_MIN = 2


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

    def to_row(self) -> dict:
        return {
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
        }


def in_coverage(points: list[RoutePoint]) -> bool:
    return all(
        COVERAGE_LAT[0] <= p.lat <= COVERAGE_LAT[1] and COVERAGE_LON[0] <= p.lon <= COVERAGE_LON[1] for p in points
    )


def compute(
    origin: Airport,
    destination: Airport,
    departure: datetime,
    now: datetime,
    sources: list[Source],
) -> Forecast:
    """`sources` in priority order (most accurate first); each minute uses the first that covers it."""
    if departure - now > FORECAST_WINDOW:
        return Forecast(status="too_early")

    points = build_profile(origin, destination, departure)
    if not in_coverage(points):
        return Forecast(status="out_of_coverage")

    samples, used = [], set()
    for p in points:
        source = next((s for s in sources if s.covers(p.time)), None)
        if source is None:
            raise RuntimeError(f"No turbulence data covers {p.time.isoformat()}")
        used.add(source)
        edr = source.edr(p.lat, p.lon, p.altitude_ft, p.time)
        samples.append({"min": p.minute, "edr": round(edr, 3), "altitude_ft": p.altitude_ft, "phase": p.phase})

    segments = _segments(samples)
    grade, score = _grade(samples)
    primary = min(used, key=sources.index)
    return Forecast(
        status="ready",
        source=primary.name if len(used) == 1 else "mixed",
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
    )


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
