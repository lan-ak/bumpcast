"""Flight schedules and live status from the flight data provider (AeroDataBox).

Only this module knows the provider. Everything user-facing stays source-free.

  AERODATABOX_API_KEY     required to look anything up; without it lookups return nothing
  AERODATABOX_API_URL     default: the direct API (a RapidAPI URL switches to RapidAPI's headers)
  AERODATABOX_KEY_HEADER  header that carries the key off RapidAPI (default x-api-key)
"""

import logging
import os
import re
from dataclasses import dataclass
from datetime import UTC, date, datetime
from functools import cache

import httpx

log = logging.getLogger(__name__)

DIRECT_URL = "https://api.aerodatabox.com"
NUMBER = re.compile(r"^([A-Z]{3}|[A-Z0-9]{2})(\d{1,4})([A-Z]?)$")

# Provider statuses that mean the aircraft has pushed back or taken off.
DEPARTED = {"Departed", "EnRoute", "Approaching", "Arrived"}


def normalize_number(text: str) -> str | None:
    """'b6 23', 'B6-023', 'JBU23' -> 'B6 23', 'B6 23', 'JBU 23'. None if it isn't a flight number."""
    compact = re.sub(r"[\s\-]", "", text.upper())
    m = NUMBER.match(compact)
    if not m or not any(c.isalpha() for c in m.group(1)):
        return None
    return f"{m.group(1)} {int(m.group(2))}{m.group(3)}"


@dataclass
class Movement:
    icao: str | None
    iata: str | None
    scheduled: datetime | None
    revised: datetime | None  # estimated, or actual once it has happened
    runway: datetime | None
    gate: str | None
    terminal: str | None
    live: bool


@dataclass
class Leg:
    number: str  # 'B6 23'
    airline: str | None
    status: str  # provider status, e.g. 'Expected', 'Delayed', 'Departed', 'Canceled'
    departure: Movement
    arrival: Movement
    codeshare: bool

    @property
    def cancelled(self) -> bool:
        return self.status == "Canceled"

    @property
    def diverted(self) -> bool:
        return self.status == "Diverted"

    @property
    def departed(self) -> bool:
        return self.status in DEPARTED


def parse_time(value: dict | None) -> datetime | None:
    """Provider times look like {'utc': '2026-10-22 11:15Z', 'local': '2026-10-22 07:15-04:00'}."""
    utc = (value or {}).get("utc")
    if not utc:
        return None
    return datetime.fromisoformat(utc.replace("Z", "+00:00").replace(" ", "T")).astimezone(UTC)


def _movement(m: dict | None) -> Movement:
    m = m or {}
    airport = m.get("airport") or {}
    return Movement(
        icao=airport.get("icao"),
        iata=airport.get("iata"),
        scheduled=parse_time(m.get("scheduledTime")),
        revised=parse_time(m.get("revisedTime")),
        runway=parse_time(m.get("runwayTime")),
        gate=m.get("gate"),
        terminal=m.get("terminal"),
        live="Live" in (m.get("quality") or []),
    )


def parse_leg(f: dict) -> Leg:
    return Leg(
        number=normalize_number(f.get("number") or "") or (f.get("number") or ""),
        airline=(f.get("airline") or {}).get("name"),
        status=f.get("status") or "Unknown",
        departure=_movement(f.get("departure")),
        arrival=_movement(f.get("arrival")),
        codeshare=f.get("codeshareStatus") == "IsCodeshared",
    )


class FlightData:
    def __init__(self, key: str, url: str = DIRECT_URL, key_header: str = "x-api-key"):
        url = url.rstrip("/")
        if "rapidapi" in url:
            headers = {"X-RapidAPI-Key": key, "X-RapidAPI-Host": httpx.URL(url).host}
        else:
            headers = {key_header: key}
        self.http = httpx.Client(base_url=url, headers=headers, timeout=20)

    @staticmethod
    @cache
    def from_env() -> "FlightData | None":
        """The poll loop's client, made once."""
        return FlightData.create()

    @staticmethod
    def create() -> "FlightData | None":
        """A new client (each thread has its own), or None without a key."""
        key = os.environ.get("AERODATABOX_API_KEY")
        if not key:
            return None
        return FlightData(
            key,
            os.environ.get("AERODATABOX_API_URL", DIRECT_URL),
            os.environ.get("AERODATABOX_KEY_HEADER", "x-api-key"),
        )

    def legs(self, number: str, day: date) -> list[Leg]:
        """Every leg flown under `number` departing on `day` (local to the departure airport)."""
        r = self.http.get(
            f"/flights/number/{number.replace(' ', '')}/{day.isoformat()}",
            params={"withAircraftImage": "false", "withLocation": "false", "dateLocalRole": "Departure"},
        )
        if r.status_code in (204, 404):
            return []
        r.raise_for_status()
        return [parse_leg(f) for f in r.json() or []]


def find_leg(legs: list[Leg], origin: str, destination: str | None = None) -> Leg | None:
    """The operating leg from `origin` (ICAO), preferring one to `destination`."""
    candidates = [leg for leg in legs if leg.departure.icao == origin and not leg.codeshare] or [
        leg for leg in legs if leg.departure.icao == origin
    ]
    if destination:
        exact = [leg for leg in candidates if leg.arrival.icao == destination]
        candidates = exact or candidates
    return candidates[0] if candidates else None
