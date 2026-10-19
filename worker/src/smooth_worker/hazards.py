"""Official warnings and pilot reports that correct a model forecast.

Models can miss what's happening right now, and neither GTG nor our GFS
outlook models thunderstorm turbulence. So where a SIGMET (an official
warning, worldwide) or a recent pilot report covers a minute of the flight,
that minute's EDR is raised to at least the warned or reported severity.
Corrections only ever raise: averaging can hide a real rough patch, and a
warning should always come through.
"""

import logging
import math
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from . import severity
from .http import client
from .mapdata import PIREP_INTENSITY

log = logging.getLogger(__name__)

ISIGMET_URL = "https://aviationweather.gov/api/data/isigmet"
AIRSIGMET_URL = "https://aviationweather.gov/api/data/airsigmet"
PIREP_URL = "https://aviationweather.gov/api/data/pirep"

# The EDR each warning or report lifts a minute to (at least).
FLOOR = {severity.LIGHT: 0.12, severity.MODERATE: 0.24, severity.SEVERE: 0.34}
# International SIGMET hazard -> (our hazard name, severity). Icing, volcanic ash etc. aren't turbulence.
SIGMET_HAZARDS = {
    "TURB": ("turbulence", severity.SEVERE),
    "TS": ("thunderstorms", severity.MODERATE),
    "TC": ("tropical_cyclone", severity.MODERATE),
}
PIREP_RADIUS_NM = 50
PIREP_ALT_FT = 4000
PIREP_WINDOW = timedelta(hours=2)
SEVERE_PIREP_WINDOW = timedelta(hours=1)  # a severe report only says so much about later
EARTH_RADIUS_NM = 3440.065
NO_TOP_FT = 60000


@dataclass(frozen=True)
class Hazard:
    kind: str  # sigmet | pirep
    hazard: str  # turbulence | mountain_wave | thunderstorms | tropical_cyclone
    severity: str
    valid_from: datetime
    valid_to: datetime
    base_ft: int
    top_ft: int
    region: str | None = None
    polygon: tuple[tuple[float, float], ...] = ()  # (lat, lon); SIGMETs
    point: tuple[float, float] | None = None  # (lat, lon); pilot reports

    @property
    def label(self) -> str:
        name = {
            "turbulence": "turbulence",
            "mountain_wave": "mountain-wave turbulence",
            "thunderstorms": "thunderstorms",
            "tropical_cyclone": "tropical cyclone",
        }[self.hazard]
        if self.kind == "pirep":
            return f"Pilot reported {self.severity} {name}"
        where = f" ({self.region})" if self.region else ""
        return f"Official warning: {name}{where}"

    def applies(self, lat: float, lon: float, altitude_ft: float, when: datetime) -> bool:
        if not (self.valid_from <= when <= self.valid_to and self.base_ft <= altitude_ft <= self.top_ft):
            return False
        if self.point:
            return _distance_nm(lat, lon, *self.point) <= PIREP_RADIUS_NM
        return _inside(lat, lon, self.polygon)

    @property
    def floor(self) -> float:
        return FLOOR[self.severity]


def _distance_nm(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, l1, p2, l2 = map(math.radians, (lat1, lon1, lat2, lon2))
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin((l2 - l1) / 2) ** 2
    return 2 * EARTH_RADIUS_NM * math.asin(math.sqrt(min(h, 1.0)))


def _inside(lat: float, lon: float, polygon: tuple[tuple[float, float], ...]) -> bool:
    """Ray casting in lat/lon. The polygon is unwrapped edge by edge (so one crossing the
    dateline stays in one piece), then moved by whole turns to sit nearest the point."""
    if len(polygon) < 3:
        return False
    pts = [polygon[0]]
    for plat, plon in polygon[1:]:
        prev = pts[-1][1]
        pts.append((plat, prev + (plon - prev + 180) % 360 - 180))
    centre = sum(p[1] for p in pts) / len(pts)
    shift = 360 * round((lon - centre) / 360)
    pts = [(plat, plon + shift) for plat, plon in pts]
    inside = False
    for (y1, x1), (y2, x2) in zip(pts, pts[1:] + pts[:1]):
        if (y1 > lat) != (y2 > lat):
            x = x1 + (lat - y1) * (x2 - x1) / (y2 - y1)
            if x > lon:
                inside = not inside
    return inside


def _epoch(value) -> datetime:
    return datetime.fromtimestamp(value, UTC)


def _polygons(coords) -> list[tuple[tuple[float, float], ...]]:
    """A SIGMET's area as polygons: one for 'AREA', several for 'AREAS' (a list of lists)."""
    if not coords:
        return []
    rings = coords if isinstance(coords[0], list) else [coords]
    return [tuple((c["lat"], c["lon"]) for c in ring) for ring in rings if len(ring) >= 3]


def from_isigmets(rows: list[dict]) -> list[Hazard]:
    out = []
    for r in rows:
        try:
            mapped = SIGMET_HAZARDS.get(r.get("hazard") or "")
            if not mapped or not r.get("validTimeFrom") or not r.get("validTimeTo"):
                continue
            hazard, level = mapped
            if hazard == "turbulence" and "MTW" in (r.get("qualifier") or ""):
                hazard = "mountain_wave"
            for polygon in _polygons(r.get("coords")):
                out.append(
                    Hazard(
                        kind="sigmet",
                        hazard=hazard,
                        severity=level,
                        valid_from=_epoch(r["validTimeFrom"]),
                        valid_to=_epoch(r["validTimeTo"]),
                        base_ft=int(r.get("base") or 0),
                        top_ft=int(r.get("top") or NO_TOP_FT),
                        region=_region(r.get("firName")),
                        polygon=polygon,
                    )
                )
        except (KeyError, TypeError, ValueError):
            log.warning("hazards: skipping malformed SIGMET %s", r.get("seriesId") if isinstance(r, dict) else r)
    return out


def _region(fir: str | None) -> str | None:
    """'LPPO SANTA MARIA OCEANIC' -> 'Santa Maria Oceanic'."""
    if not fir:
        return None
    words = fir.split()
    if len(words) > 1 and len(words[0]) == 4 and words[0].isupper() and words[0].isalpha():
        words = words[1:]
    return " ".join(w.capitalize() for w in words)


def from_airsigmets(rows: list[dict]) -> list[Hazard]:
    """US SIGMETs. AIRMETs (light-moderate, very broad) are left to GTG."""
    out = []
    for r in rows:
        if r.get("airSigmetType") != "SIGMET":
            continue
        kind = (r.get("hazard") or "").upper()
        if kind == "CONVECTIVE":
            hazard, level = "thunderstorms", severity.MODERATE
        elif kind == "TURB":
            hazard, level = "turbulence", severity.SEVERE
        else:
            continue
        try:
            for polygon in _polygons(r.get("coords")):
                out.append(
                    Hazard(
                        kind="sigmet",
                        hazard=hazard,
                        severity=level,
                        valid_from=_epoch(r["validTimeFrom"]),
                        valid_to=_epoch(r["validTimeTo"]),
                        base_ft=int(r.get("altitudeLow1") or 0),
                        top_ft=int(r.get("altitudeHi1") or NO_TOP_FT),
                        region="United States",
                        polygon=polygon,
                    )
                )
        except (KeyError, TypeError, ValueError):
            log.warning("hazards: skipping malformed SIGMET %s", r.get("seriesId"))
    return out


def from_pireps(rows: list[dict]) -> list[Hazard]:
    out = []
    for r in rows:
        if not isinstance(r, dict) or r.get("lat") is None or r.get("lon") is None or not r.get("obsTime"):
            continue
        levels = [PIREP_INTENSITY.get((r.get(k) or "").upper()) for k in ("tbInt1", "tbInt2")]
        levels = [lv for lv in levels if lv in FLOOR]
        altitude = r.get("tbTop1") or r.get("tbBas1") or r.get("fltLvl")
        if not levels or not altitude:
            continue
        level = max(levels, key=severity.ORDER.index)
        observed = _epoch(r["obsTime"])
        window = SEVERE_PIREP_WINDOW if level == severity.SEVERE else PIREP_WINDOW
        alt_ft = int(altitude) * 100
        out.append(
            Hazard(
                kind="pirep",
                hazard="mountain_wave" if (r.get("tbType1") or "").upper() == "MWAVE" else "turbulence",
                severity=level,
                valid_from=observed - window,
                valid_to=observed + window,
                base_ft=alt_ft - PIREP_ALT_FT,
                top_ft=alt_ft + PIREP_ALT_FT,
                point=(r["lat"], r["lon"]),
            )
        )
    return out


def load() -> list[Hazard]:
    """Current SIGMETs worldwide and the last 2 hours of turbulence reports. Each feed is optional."""
    hazards: list[Hazard] = []
    feeds = [
        (ISIGMET_URL, {"format": "json"}, from_isigmets),
        (AIRSIGMET_URL, {"format": "json"}, from_airsigmets),
        (PIREP_URL, {"format": "json", "age": "2", "bbox": "-90,-180,90,180"}, from_pireps),
    ]
    for url, params, parse in feeds:
        try:
            r = client().get(url, params=params)
            r.raise_for_status()
            hazards += parse(r.json() or [])
        except Exception:
            log.exception("hazards: %s failed; forecasting without it", url)
    log.info("hazards: %d warnings and reports", len(hazards))
    return hazards


def strongest(hazards: list[Hazard], lat: float, lon: float, altitude_ft: float, when: datetime) -> Hazard | None:
    hits = [h for h in hazards if h.applies(lat, lon, altitude_ft, when)]
    # Official warnings outrank reports of the same severity.
    return max(hits, key=lambda h: (h.floor, h.kind == "sigmet"), default=None)
