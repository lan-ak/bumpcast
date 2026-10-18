import json
from dataclasses import dataclass
from functools import cache
from importlib import resources


@dataclass(frozen=True)
class Airport:
    icao: str
    iata: str
    name: str
    city: str
    country: str
    lat: float
    lon: float
    elev_ft: int
    tz: str


@cache
def _index() -> dict[str, Airport]:
    raw = json.loads(resources.files("smooth_worker.data").joinpath("airports.json").read_text())
    index = {}
    for a in raw:
        airport = Airport(
            a["icao"], a["iata"], a["name"], a["city"], a["country"], a["lat"], a["lon"], a["elev_ft"], a["tz"]
        )
        index[airport.icao] = airport
        index.setdefault(airport.iata, airport)
    return index


def lookup(code: str) -> Airport:
    """Find an airport by ICAO (KJFK) or IATA (JFK) code."""
    try:
        return _index()[code.strip().upper()]
    except KeyError:
        raise KeyError(f"Unknown airport: {code}") from None
