"""Turn an airport pair and departure time into a minute-by-minute flight profile.

Without a flight-number feed we don't know the real routing, so we assume the great-circle
track, stretched to a typical flown distance, and a typical jet profile: climb, cruise (with
step climbs on long flights), descent. The numbers are fitted to ADS-B tracks of 20 real flights
(FlightAware, 15-23 Oct 2026: 160 to 2,990 nm, A220 to 777): see the constants below. With
winds (GFS), ground speeds follow them, so eastbound flights land earlier than westbound ones.
"""

import math
from bisect import bisect_right
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta

from .airports import Airport

# Bumped whenever the profile model changes, so a forecast built with an older one isn't read as a
# change in the weather (2: fitted to real flights, with winds, 2026-10-23).
PROFILE_VERSION = 2

EARTH_RADIUS_NM = 3440.065
TAXI_OUT_MIN = 15  # scheduled departure is gate time; wheels-up is later (the app's Forecast.taxiOut)

# Flown distance: the great circle plus airways and terminal procedures (departure, arrival and
# approach). Short hops fly proportionally further: AC 1507 EWR-YYZ flew 352 nm for 302 direct.
ROUTE_STRETCH = 0.025
TERMINAL_NM = 25.0

# Initial cruise level by great-circle distance (nm): heavier long flights start lower and step
# up later. The semicircular rule then picks the level: odd thousands eastbound (course 0-179),
# even westbound, rounding down. 18 of the 20 tracks flew that parity.
CRUISE_LEVELS = [(200, 22000), (350, 28000), (500, 32000), (1000, 36000), (1800, 34000), (math.inf, 36000)]
# Step climbs: 2,000 ft every 150 min of cruise, at 1,000 fpm, up to FL390, while at least 40 min
# of cruise remain (AAL2 LAX-JFK: FL310 to FL370; UAL548 EWR-SFO: FL360 to FL380).
STEP_EVERY_MIN = 150
STEP_FT = 2000
STEP_FPM = 1000
STEP_MAX_FT = 39000
STEP_MARGIN_MIN = 40
# Short hops cap the level so climb and descent fit (with no cruise), but never below this
# height above the higher airport.
FLOOR_AGL_FT = 2000

# Climb rates (fpm) up to each altitude (ft MSL): fast to 10,000 ft, slower while accelerating
# past the 250 kt limit, then easing off with height. Time-weighted means of the 20 tracks.
CLIMB_FPM = [(10000, 1900), (12000, 1500), (18000, 1900), (24000, 1550), (30000, 1100), (math.inf, 950)]
# Descent rates: the approach (the last 3,000 ft above the runway) at 700 fpm, including the
# level-offs before final, then 850 fpm up to 12,000 ft, 1,400 fpm to FL300, 1,000 above.
APPROACH_FT = 3000
APPROACH_FPM = 700
DESCENT_FPM = [(12000, 850), (30000, 1400), (math.inf, 1000)]
# Airspeeds (kt, no wind) by height above the airport, from the tracks' ground speeds.
CLIMB_KT = ([0, 1500, 4500, 8000, 12000, 16000, 21000, 27000, 33000], [150, 175, 250, 280, 345, 370, 400, 435, 450])
DESCENT_KT = ([0, 1500, 4500, 8000, 12000, 16000, 21000, 27000, 33000], [140, 150, 195, 235, 305, 340, 375, 430, 445])
# Cruise true airspeed by level (ft): lower levels fly slower. After taking GFS winds out of the
# tracks' ground speeds, narrowbodies cruised at 447-470 kt and the two widebodies across the
# Atlantic at 476-478: flights this long (nm) are widebodies, a little faster.
CRUISE_KT = ([21000, 28000, 33000], [415, 443, 460])
LONG_HAUL_KT = ([2500, 3000], [0, 20])

# Integration steps (minutes).
DT_MIN = 0.1
CRUISE_DT_MIN = 0.5
# Stronger winds are treated as bad data; ground speed never drops below half the airspeed.
MAX_WIND_KT = 250
MIN_GROUND_SPEED = 0.5

# (lat, lon, altitude_ft, time) -> (eastward, northward) wind in knots, or None where unknown.
Wind = Callable[[float, float, float, datetime], tuple[float, float] | None]


@dataclass(frozen=True)
class RoutePoint:
    minute: int  # minutes since takeoff
    time: datetime  # UTC
    lat: float
    lon: float
    altitude_ft: int
    phase: str  # climb | cruise | descent


def distance_nm(a: Airport, b: Airport) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (a.lat, a.lon, b.lat, b.lon))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * EARTH_RADIUS_NM * math.asin(min(math.sqrt(h), 1.0))


def _intermediate(a: Airport, b: Airport, fraction: float) -> tuple[float, float]:
    lat1, lon1, lat2, lon2 = map(math.radians, (a.lat, a.lon, b.lat, b.lon))
    d = distance_nm(a, b) / EARTH_RADIUS_NM
    if d == 0:
        return a.lat, a.lon
    s1 = math.sin((1 - fraction) * d) / math.sin(d)
    s2 = math.sin(fraction * d) / math.sin(d)
    x = s1 * math.cos(lat1) * math.cos(lon1) + s2 * math.cos(lat2) * math.cos(lon2)
    y = s1 * math.cos(lat1) * math.sin(lon1) + s2 * math.cos(lat2) * math.sin(lon2)
    z = s1 * math.sin(lat1) + s2 * math.sin(lat2)
    return math.degrees(math.atan2(z, math.hypot(x, y))), math.degrees(math.atan2(y, x))


def course_deg(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Initial great-circle course from the first point to the second, degrees true."""
    lat1, lon1, lat2, lon2 = map(math.radians, (lat1, lon1, lat2, lon2))
    y = math.sin(lon2 - lon1) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(lon2 - lon1)
    return math.degrees(math.atan2(y, x)) % 360


def flown_nm(direct_nm: float) -> float:
    """The distance a flight really covers for a great circle of `direct_nm`."""
    return direct_nm * (1 + ROUTE_STRETCH) + min(TERMINAL_NM, direct_nm)


def cruise_altitude_ft(dist_nm: float, course: float | None = None) -> int:
    """The initial cruise level for a great circle of `dist_nm`, by the semicircular rule when
    the course is known. Short hops may still be capped lower (see build_profile)."""
    level = next(level for limit, level in CRUISE_LEVELS if dist_nm < limit)
    if course is None:
        return level
    eastbound = course < 180
    thousands = level // 1000
    return (thousands if (thousands % 2 == 1) == eastbound else thousands - 1) * 1000


def _interp(x: float, xs: list, ys: list) -> float:
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
        return ys[-1]
    i = bisect_right(xs, x) - 1
    return ys[i] + (ys[i + 1] - ys[i]) * (x - xs[i]) / (xs[i + 1] - xs[i])


def _rate(alt: float, bands: list[tuple[float, int]]) -> int:
    return next(rate for top, rate in bands if alt < top)


def cruise_kt(level_ft: float, direct_nm: float = 0) -> float:
    return _interp(level_ft, *CRUISE_KT) + _interp(direct_nm, *LONG_HAUL_KT)


# A ground-speed function: (airspeed kt, nm from the origin, altitude ft, minute since takeoff) -> kt.
GroundSpeed = Callable[[float, float, float, float], float]


def _still_air(tas: float, nm: float, alt: float, minute: float) -> float:
    return tas


@dataclass
class _Leg:
    """A climb from takeoff, or a descent counted back from touchdown: minutes, ft MSL and nm."""

    minutes: list[float]
    alts: list[float]
    nms: list[float]

    @property
    def duration(self) -> float:
        return self.minutes[-1]

    @property
    def distance(self) -> float:
        return self.nms[-1]

    def at(self, minute: float) -> tuple[float, float]:
        return _interp(minute, self.minutes, self.alts), _interp(minute, self.minutes, self.nms)


def _climb(elev: float, level: float, gs: GroundSpeed) -> _Leg:
    leg = _Leg([0.0], [elev], [0.0])
    minute, alt, nm = 0.0, elev, 0.0
    while alt < level:
        rate = _rate(alt, CLIMB_FPM)
        dt = min(DT_MIN, (level - alt) / rate)
        mid = alt + rate * dt / 2
        nm += gs(_interp(mid - elev, *CLIMB_KT), nm, mid, minute) * dt / 60
        alt = min(level, alt + rate * dt)
        minute += dt
        leg.minutes.append(minute), leg.alts.append(alt), leg.nms.append(nm)
    return leg


def _descent(elev: float, level: float, gs: GroundSpeed, total: float, landing: float) -> _Leg:
    """Back from touchdown at minute `landing` of a `total` nm flight, up to `level`."""
    leg = _Leg([0.0], [elev], [0.0])
    before, alt, nm = 0.0, elev, 0.0
    while alt < level:
        rate = APPROACH_FPM if alt < elev + APPROACH_FT else _rate(alt, DESCENT_FPM)
        dt = min(DT_MIN, (level - alt) / rate)
        mid = alt + rate * dt / 2
        nm += gs(_interp(mid - elev, *DESCENT_KT), max(total - nm, 0.0), mid, landing - before) * dt / 60
        alt = min(level, alt + rate * dt)
        before += dt
        leg.minutes.append(before), leg.alts.append(alt), leg.nms.append(nm)
    return leg


def _fit_level(origin: Airport, destination: Airport, total: float, level: int) -> float:
    """The highest level up to `level` from which the climb and descent fit in `total` nm (still air)."""

    def fits(alt: float) -> bool:
        return (
            _climb(origin.elev_ft, alt, _still_air).distance
            + _descent(destination.elev_ft, alt, _still_air, total, 0).distance
            <= total
        )

    floor = max(origin.elev_ft, destination.elev_ft) + FLOOR_AGL_FT
    alt = float(level)
    while alt > floor and not fits(alt):
        alt -= 1000
    if alt > floor or fits(alt):
        return alt
    low, high = float(max(origin.elev_ft, destination.elev_ft)), alt
    for _ in range(20):  # a tiny hop: as high as fits exactly
        mid = (low + high) / 2
        low, high = (mid, high) if fits(mid) else (low, mid)
    return low


@dataclass
class _Plan:
    level: float
    climb: _Leg
    descent: _Leg
    cruise_minutes: list[float]  # since takeoff, from top of climb to top of descent
    cruise_nms: list[float]
    steps: list[tuple[float, float]]  # (minute the step climb starts, new level)

    @property
    def top_of_climb(self) -> float:
        return self.climb.duration

    @property
    def top_of_descent(self) -> float:
        return self.cruise_minutes[-1]

    @property
    def landing(self) -> float:
        return self.top_of_descent + self.descent.duration

    def cruise_alt(self, minute: float) -> float:
        alt = self.level
        for start, level in self.steps:
            if minute > start:
                alt = min(level, alt + (minute - start) * STEP_FPM)
        return alt


def _plan(origin: Airport, destination: Airport, total: float, level: float, gs: GroundSpeed, landing: float) -> _Plan:
    """Climb, cruise and descent for a flight expected to land at minute `landing` (for the
    descent's winds), with step climbs as the cruise allows."""
    climb = _climb(origin.elev_ft, level, gs)
    direct = distance_nm(origin, destination)

    def cruise(steps: list[tuple[float, float]]) -> _Plan:
        descent = _descent(destination.elev_ft, steps[-1][1] if steps else level, gs, total, landing)
        plan = _Plan(level, climb, descent, [climb.duration], [climb.distance], steps)
        end = total - descent.distance
        while plan.cruise_nms[-1] < end:
            minute, nm = plan.cruise_minutes[-1], plan.cruise_nms[-1]
            alt = plan.cruise_alt(minute + CRUISE_DT_MIN / 2)
            speed = gs(cruise_kt(alt, direct), nm, alt, minute)
            need = (end - nm) / speed * 60
            if need <= CRUISE_DT_MIN:
                plan.cruise_minutes.append(minute + need), plan.cruise_nms.append(end)
                break
            plan.cruise_minutes.append(minute + CRUISE_DT_MIN)
            plan.cruise_nms.append(nm + speed * CRUISE_DT_MIN / 60)
        return plan

    plan = cruise([])
    steps: list[tuple[float, float]] = []
    while len(steps) < (STEP_MAX_FT - level) // STEP_FT:
        start = climb.duration + (len(steps) + 1) * STEP_EVERY_MIN
        if start + STEP_MARGIN_MIN > plan.top_of_descent:
            break
        steps.append((start, level + (len(steps) + 1) * STEP_FT))
    # Each step lengthens the descent: drop the last while it no longer leaves the margin.
    while steps:
        plan = cruise(steps)
        if steps[-1][0] + STEP_MARGIN_MIN <= plan.top_of_descent:
            break
        steps.pop()
        if not steps:
            plan = cruise([])
    return plan


def _with_wind(origin: Airport, destination: Airport, total: float, takeoff: datetime, wind: Wind) -> GroundSpeed:
    """Ground speed along the stretched great circle, from `wind` at each place, height and time.
    Lookups are shared between nearby points (10 nm, 1,000 ft, 15 min): winds are smooth on that
    scale, and the plan is built more than once."""
    cache: dict[tuple[int, int, int], tuple[float, float]] = {}

    def components(nm: float, alt: float, minute: float) -> tuple[float, float]:
        key = (round(nm / 10), round(alt / 1000), round(minute / 15))
        if key not in cache:
            fraction = min(max(key[0] * 10 / total, 0.0), 1.0)
            lat, lon = _intermediate(origin, destination, fraction)
            ahead = _intermediate(origin, destination, min(fraction + 0.01, 1.0))
            if fraction > 0.99:
                lat0, lon0 = _intermediate(origin, destination, 0.99)
                track = course_deg(lat0, lon0, destination.lat, destination.lon)
            else:
                track = course_deg(lat, lon, *ahead)
            uv = wind(lat, lon, key[1] * 1000.0, takeoff + timedelta(minutes=key[2] * 15))
            if uv is None or not all(math.isfinite(c) for c in uv) or math.hypot(*uv) > MAX_WIND_KT:
                cache[key] = (0.0, 0.0)
            else:
                u, v = uv
                t = math.radians(track)
                cache[key] = (u * math.sin(t) + v * math.cos(t), u * math.cos(t) - v * math.sin(t))
        return cache[key]

    def gs(tas: float, nm: float, alt: float, minute: float) -> float:
        along, across = components(nm, alt, minute)
        speed = math.sqrt(max(tas * tas - across * across, 0.0)) + along
        return max(speed, tas * MIN_GROUND_SPEED)

    return gs


def build_profile(
    origin: Airport, destination: Airport, departure: datetime, wind: Wind | None = None
) -> list[RoutePoint]:
    """Minute-by-minute points from wheels-up (`departure` is the gate time) to touchdown.
    `wind` (knots east and north at a place, height and time) turns airspeeds into ground speeds."""
    takeoff = departure + timedelta(minutes=TAXI_OUT_MIN)
    direct = distance_nm(origin, destination)
    if direct < 1:
        return [RoutePoint(0, takeoff, origin.lat, origin.lon, int(round(origin.elev_ft, -2)), "climb")]
    total = flown_nm(direct)
    course = course_deg(origin.lat, origin.lon, destination.lat, destination.lon)
    level = _fit_level(origin, destination, total, cruise_altitude_ft(direct, course))

    plan = _plan(origin, destination, total, level, _still_air, 0)
    if wind is not None:
        gs = _with_wind(origin, destination, total, takeoff, wind)
        for _ in range(2):  # the descent's winds depend on when it lands
            plan = _plan(origin, destination, total, level, gs, plan.landing)

    landing = max(round(plan.landing), 1)
    points: list[RoutePoint] = []
    flown = 0.0
    for minute in range(landing + 1):
        if minute <= plan.top_of_climb:
            alt, nm = plan.climb.at(minute)
            phase = "climb" if alt < level else "cruise"
        elif minute <= plan.top_of_descent:
            alt, nm = plan.cruise_alt(minute), _interp(minute, plan.cruise_minutes, plan.cruise_nms)
            phase = "cruise"
        else:
            alt, to_go = plan.descent.at(plan.landing - minute)
            nm, phase = total - to_go, "descent"
        if minute == landing:
            alt, nm, phase = destination.elev_ft, total, "descent"
        flown = nm = min(max(nm, flown), total)  # never backwards, even on a hop too short to fit
        lat, lon = _intermediate(origin, destination, nm / total)
        points.append(RoutePoint(minute, takeoff + timedelta(minutes=minute), lat, lon, int(round(alt, -2)), phase))
    return points
