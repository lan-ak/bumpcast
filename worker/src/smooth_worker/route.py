"""Turn an airport pair and departure time into a minute-by-minute flight profile.

Without a flight-number feed we don't know the real routing, so we assume a
great-circle track and a typical jet profile: climb, cruise, descent.
"""

import math
from dataclasses import dataclass
from datetime import datetime, timedelta

from .airports import Airport

EARTH_RADIUS_NM = 3440.065
TAXI_OUT_MIN = 15  # scheduled departure is gate time; wheels-up is later

CLIMB_FPM = 2000
CLIMB_KT = 300
CRUISE_KT = 460
DESCENT_FPM = 1500
DESCENT_KT = 320


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
    return 2 * EARTH_RADIUS_NM * math.asin(math.sqrt(h))


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


def cruise_altitude_ft(dist_nm: float) -> int:
    if dist_nm < 250:
        return 24000
    if dist_nm < 500:
        return 31000
    if dist_nm < 1000:
        return 35000
    return 37000


def build_profile(origin: Airport, destination: Airport, departure: datetime) -> list[RoutePoint]:
    total = distance_nm(origin, destination)
    cruise = cruise_altitude_ft(total)

    # Short hops can't reach the nominal level: cap cruise so climb + descent fit.
    def climb_descent_nm(alt: int) -> float:
        climb = (alt - origin.elev_ft) / CLIMB_FPM * CLIMB_KT / 60
        descent = (alt - destination.elev_ft) / DESCENT_FPM * DESCENT_KT / 60
        return climb + descent

    while cruise > 10000 and climb_descent_nm(cruise) > total:
        cruise -= 1000

    takeoff = departure + timedelta(minutes=TAXI_OUT_MIN)
    descent_nm = (cruise - destination.elev_ft) / DESCENT_FPM * DESCENT_KT / 60

    points: list[RoutePoint] = []
    flown = 0.0
    alt = float(origin.elev_ft)
    minute = 0
    while True:
        remaining = total - flown
        if remaining <= descent_nm and flown > 0:
            phase = "descent"
            alt = destination.elev_ft + (cruise - destination.elev_ft) * max(remaining, 0) / descent_nm
            speed = DESCENT_KT
        elif alt < cruise:
            phase = "climb"
            speed = CLIMB_KT
        else:
            phase = "cruise"
            speed = CRUISE_KT
        lat, lon = _intermediate(origin, destination, min(flown / total, 1.0) if total else 1.0)
        points.append(
            RoutePoint(minute, takeoff + timedelta(minutes=minute), lat, lon, int(round(alt, -2)), phase)
        )
        if remaining <= 0:
            break
        flown = min(total, flown + speed / 60)
        if phase == "climb":
            alt = min(cruise, alt + CLIMB_FPM)
        minute += 1
    return points
