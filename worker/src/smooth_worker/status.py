"""Live flight status and published schedules, free for every flight with a number.

Status is refreshed in the same pass as the forecast: every 6 hours from 48 h out, hourly
from 18 h out, every 15 minutes from 3 h before departure, every poll from 30 minutes before
departure until wheels-up (at most an hour after departure), then every 30 minutes until the
flight lands. When the departure
moves, the forecast is recomputed for the new time in that pass, and one push says both
("Delayed 40 min, forecast updated"). Gate changes never push.

Times are only "actual" once they've happened: the airline's runway times can be estimates.

User-facing text never names where status comes from.
"""

from dataclasses import dataclass
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from . import airports, changes
from .flightdata import Leg
from .route import TAXI_OUT_MIN

WINDOW = timedelta(hours=48)
HOURLY_FROM = timedelta(hours=18)
SLOW_REFRESH = timedelta(hours=6)
FAST_REFRESH = timedelta(hours=1)
# The last 3 hours before departure, until it's checked off: every 15 minutes.
DEPARTURE_WINDOW = timedelta(hours=3)
DEPARTURE_REFRESH = timedelta(minutes=15)
# Status keeps updating until this long after landing, then stops. The landing is the actual,
# then expected, then scheduled arrival (moved by any delay), at least an hour after departure.
AFTER_ARRIVAL = timedelta(minutes=30)
AFTER_DEPARTURE = timedelta(hours=1)
# When the arrival isn't known at all: the longest flights.
MAX_FLIGHT = timedelta(hours=18)
# In the air: every 30 minutes, for the landing time.
AIRBORNE_REFRESH = timedelta(minutes=30)
# Smaller moves than this stay in the app.
PUSH_THRESHOLD = timedelta(minutes=15)
# "Delayed" from this many minutes late; under it is "On time".
DELAYED_FROM_MIN = 5
# Around departure, numbered flights are checked every poll so wheels-up reaches the app and the
# countdown within minutes and nobody has to tap "We've taken off". The watch ends this long after
# the gate departure, for airports that never report a runway time.
TAKEOFF_WATCH_FROM = timedelta(minutes=30)
TAKEOFF_WATCH_UNTIL = timedelta(hours=1)
TAKEOFF_REFRESH = timedelta(minutes=5)
# Polls run every 5 minutes; don't miss a refresh by a few seconds.
SLACK = timedelta(minutes=2)

# Unpublished schedules are checked once a day until the airline publishes them.
SCHEDULE_CHECK = timedelta(days=1)


def _time(value) -> datetime | None:
    if value is None or isinstance(value, datetime):
        return value
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def effective_departure(flight: dict, status: dict | None) -> datetime:
    """The departure the forecast should use: actual, then expected, then the schedule."""
    status = status or {}
    return _time(status.get("departure_actual")) or _time(status.get("departure_expected")) or _time(flight["departure_at"])


def ends(flight: dict | None, status: dict | None, departure: datetime) -> datetime:
    """When status checks stop for a flight leaving at `departure`: half an hour after it lands,
    and never before an hour after departure. With no arrival time known, MAX_FLIGHT after
    departure, so a flight saved in the air still gets its first status. One the airline didn't
    have (a check found nothing) is looked up again until the schedule, else its forecast, says
    it lands, so a flight saved in the air gets another try; with neither, an hour after departure."""
    flight, status = flight or {}, status or {}
    if landed := _time(status.get("arrival_actual")):
        return landed + AFTER_ARRIVAL
    if status and not status.get("status"):
        landing = _time(flight.get("arrival_at")) or _forecast_landing(flight) or departure
    else:
        landing = _time(status.get("arrival_expected"))
        if landing is None and (scheduled := _time(status.get("arrival_scheduled")) or _time(flight.get("arrival_at"))):
            planned = _time(status.get("departure_scheduled")) or _time(flight.get("departure_at")) or departure
            landing = scheduled + max(departure - planned, timedelta(0))  # a late departure lands late
        landing = landing or departure + MAX_FLIGHT
    return max(landing, departure + AFTER_DEPARTURE) + AFTER_ARRIVAL


def _forecast_landing(flight: dict) -> datetime | None:
    """When the flight's latest forecast lands it: its departure, taxi, then the flight time."""
    latest = (flight.get("forecasts") or [None])[0] or {}
    departure = _time(latest.get("departure_at") or flight.get("departure_at"))
    if not latest.get("duration_min") or departure is None:
        return None
    return departure + timedelta(minutes=TAXI_OUT_MIN + int(latest["duration_min"]))


def forecast_ends(flight: dict, status: dict | None, departure: datetime) -> datetime:
    """Until when a flight without a forecast (saved or edited in the air) still gets its first
    one: until it lands, by the schedule alone when no check has found it, so a lookup that
    found nothing never costs it the forecast the schedule would give."""
    return ends(flight, status if (status or {}).get("status") else None, departure)


def is_due(
    status: dict | None, departure: datetime, now: datetime, watching: bool = False, flight: dict | None = None
) -> bool:
    """Whether to fetch a fresh status for a flight leaving at `departure`. `watching`: check every
    poll around departure until wheels-up. `flight` (its arrival_at) tells when it should land."""
    if status and (status.get("finished") or status.get("status") == "cancelled"):
        return False
    if departure - now > WINDOW or now > ends(flight, status, departure):
        return False
    # A row without a status is a check that didn't find the flight; it waits like any other.
    checked = _time((status or {}).get("checked_at"))
    if checked is None:
        return True
    return now - checked >= check_interval(status, departure, now, watching) - SLACK


def check_interval(status: dict | None, departure: datetime, now: datetime, watching: bool = False) -> timedelta:
    """How long a status stays fresh: short around takeoff, longer in the air and further out."""
    status = status or {}
    airborne = status.get("takeoff_at") or status.get("status") == "departed"
    watch = departure - TAKEOFF_WATCH_FROM <= now <= departure + TAKEOFF_WATCH_UNTIL
    if watching and watch and not status.get("takeoff_at"):
        return TAKEOFF_REFRESH
    # Past the watch, a flight the airline never marks departed is as good as in the air.
    if airborne or now > departure + TAKEOFF_WATCH_UNTIL:
        return AIRBORNE_REFRESH
    return refresh_interval(departure, now)


def refresh_interval(departure: datetime, now: datetime) -> timedelta:
    if departure - now <= DEPARTURE_WINDOW:
        return DEPARTURE_REFRESH
    return FAST_REFRESH if departure - now <= HOURLY_FROM else SLOW_REFRESH


def build(leg: Leg, flight: dict, previous: dict | None, now: datetime) -> dict:
    """The flight_status row for this leg. Keeps what the user was last told."""
    dep, arr = leg.departure, leg.arrival
    scheduled = dep.scheduled or _time(flight["departure_at"])
    departed = leg.departed or (dep.runway is not None and dep.runway <= now)
    actual = (dep.revised or dep.runway) if departed else None
    expected = None if departed else dep.revised
    moved = (actual or expected or scheduled) - scheduled
    delay = round(moved.total_seconds() / 60)

    if leg.cancelled:
        state = "cancelled"
    elif leg.diverted:
        state = "diverted"
    elif departed:
        state = "departed"
    elif delay >= DELAYED_FROM_MIN:
        state = "delayed"
    else:
        state = "scheduled"

    departure = actual or expected or scheduled
    # Wheels-up only once a runway time has passed. Never a guess: the app estimates gate time
    # plus taxi itself, and the countdown and "Wheels up" push treat this as the real takeoff.
    takeoff = dep.runway if departed and dep.runway and dep.runway <= now else None
    # A runway time still ahead is the airline's estimate, not a landing.
    landed = arr.runway if arr.runway and arr.runway <= now else None
    previous = previous or {}
    diverted_to = arr.icao if leg.diverted and arr.icao and arr.icao != flight["destination"] else None
    row = {
        "flight_id": flight["id"],
        "status": state,
        "live": dep.live or arr.live,
        "departure_scheduled": _iso(scheduled),
        "departure_expected": _iso(expected),
        "departure_actual": _iso(actual),
        "arrival_scheduled": _iso(arr.scheduled),
        "arrival_expected": _iso(None if landed else (arr.revised or arr.runway)),
        "arrival_actual": _iso(landed),
        "delay_min": delay,
        "departure_gate": dep.gate,
        "departure_terminal": dep.terminal,
        "arrival_terminal": arr.terminal,
        "diverted_to": diverted_to,
        "takeoff_at": _iso(takeoff),
        "checked_at": now.isoformat(),
        "next_check_at": None,
        "finished": False,
        # The first status sets the baseline: the user knew the scheduled time.
        "notified_departure": previous.get("notified_departure") or _iso(scheduled),
        "notified_status": previous.get("notified_status"),
    }
    end = ends(flight, row, departure)
    row["finished"] = state == "cancelled" or now > end
    if not row["finished"]:
        row["next_check_at"] = _iso(min(now + check_interval(row, departure, now, watching=True), end))
    return row


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


# Notifications


@dataclass
class Event:
    kind: str  # delay | cancelled | diverted
    milestone: str
    departure: datetime | None = None  # the new departure, for delays
    moved_min: int = 0  # later is positive


def plan(status: dict | None) -> Event | None:
    """What to tell the user now, comparing the status with what they were last told."""
    if not status or not status.get("status"):
        return None
    state = status["status"]
    if state in ("cancelled", "diverted"):
        return Event(state, state) if status.get("notified_status") != state else None
    if state == "departed":
        return None
    expected = _time(status.get("departure_expected")) or _time(status.get("departure_scheduled"))
    told = _time(status.get("notified_departure"))
    if expected is None or told is None or abs(expected - told) < PUSH_THRESHOLD:
        return None
    moved = round((expected - told).total_seconds() / 60)
    return Event("delay", f"delay:{expected:%Y%m%dT%H%M}", departure=expected, moved_min=moved)


def local_time(value: datetime, icao: str) -> str:
    try:
        tz = ZoneInfo(airports.lookup(icao).tz)
    except (KeyError, ValueError):
        tz = None
    local = value.astimezone(tz) if tz else value
    return local.strftime("%-I:%M %p") + ("" if tz else " UTC")


def forecast_changed(old: dict | None, new: dict | None) -> bool | None:
    """True/False when both forecasts exist; None when there's nothing to compare."""
    if not old or not new or old.get("status") != "ready" or new.get("status") != "ready":
        return None
    if old.get("grade") != new.get("grade"):
        return True
    return _shape(changes.on_timeline(old, new)) != _shape(new.get("segments") or [])


def _shape(segments: list[dict]) -> list[tuple]:
    """Bumpy stretches by severity and rough start (10-minute buckets), to ignore tiny shifts."""
    return sorted((s["severity"], round(s["start_min"] / 10)) for s in segments)


def compose(event: Event, flight: dict, status: dict, old: dict | None, new: dict | None) -> tuple[str, str]:
    """Title and body. `old`/`new`: the forecasts before and after the departure moved."""
    name = flight.get("flight_number") or _route(flight)
    if event.kind == "cancelled":
        return (
            f"{name} is cancelled",
            "Your airline will be in touch about other options. Add your new flight for a fresh forecast.",
        )
    if event.kind == "diverted":
        to = status.get("diverted_to")
        try:
            city = airports.lookup(to).city if to else None
        except KeyError:
            city = to
        title = f"{name} is diverting to {city}" if city else f"{name} is diverting"
        return title, "Diversions are routine for the crew. Your airline will share what happens next."

    when = local_time(event.departure, flight["origin"])
    changed = forecast_changed(old, new)
    if event.moved_min < 0:
        return "Leaving earlier than expected", f"{name} now leaves at {when}." + (" Forecast updated." if new else "")
    delay = status.get("delay_min") or event.moved_min
    late = f"Delayed {changes.minutes_text(delay)}"
    if changed:
        return f"{late}, forecast updated", f"{name} now leaves at {when}. {_forecast_line(old, new)}"
    if changed is False:
        return late, f"{name} now leaves at {when}. We checked: your forecast hasn't changed."
    return late, f"{name} now leaves at {when}."


def _forecast_line(old: dict, new: dict) -> str:
    title = changes.grade_title(new.get("grade")).lower()
    lead = "Still" if old.get("grade") == new.get("grade") else "Now"
    segs = new.get("segments") or []
    if not segs:
        return f"{lead} {title}, with calm air the whole way."
    worst = max(segs, key=lambda s: changes.severity.ORDER.index(s["severity"]))
    label = changes.SEVERITY_TITLES.get(worst["severity"], worst["severity"])
    return f"{lead} {title}, with {label} {changes.when_text(worst['start_min'])}."


def _route(flight: dict) -> str:
    try:
        return f"{airports.lookup(flight['origin']).iata}→{airports.lookup(flight['destination']).iata}"
    except KeyError:
        return "Your flight"


# Published schedules (free)


def schedule_due(status: dict | None, now: datetime) -> bool:
    checked = _time((status or {}).get("checked_at"))
    return checked is None or now - checked >= SCHEDULE_CHECK - SLACK


@dataclass
class Published:
    """A schedule the airline published for a flight saved before it was out."""

    update: dict  # columns to set on the flight
    title: str
    body: str
    note: list[str]  # the one-time in-app note
    push: bool


def published(flight: dict, leg: Leg) -> Published | None:
    """Compare what the user entered with the airline's schedule."""
    dep, arr = leg.departure, leg.arrival
    if not dep.scheduled or not dep.icao or not arr.icao:
        return None
    entered = _time(flight["departure_at"])
    number = flight["flight_number"]
    day = dep.scheduled.astimezone(_tz(dep.icao)).strftime("%b %-d") if _tz(dep.icao) else f"{dep.scheduled:%b %-d}"
    update = {
        "origin": dep.icao,
        "destination": arr.icao,
        "departure_at": dep.scheduled.isoformat(),
        "arrival_at": _iso(arr.scheduled),
        "airline_name": leg.airline,
        "schedule_pending": False,
    }
    moved = abs(dep.scheduled - entered)
    new_time = local_time(dep.scheduled, dep.icao)
    if dep.icao != flight["origin"] or arr.icao != flight["destination"]:
        wrong, right = (flight["origin"], dep.icao) if dep.icao != flight["origin"] else (flight["destination"], arr.icao)
        was, now_code = _iata(wrong), _iata(right)
        verb = "flies from" if dep.icao != flight["origin"] else "flies to"
        note = f"Schedule published. {number} {verb} {now_code}, not {was}. Your forecast will use {now_code}."
        body = f"Your flight on {day} {'leaves from' if verb == 'flies from' else 'flies to'} {now_code}, not {was}. We'll forecast for the right route."
        return Published(update, f"{number} details confirmed", body, [note], push=True)
    if moved >= timedelta(minutes=1):
        old_time = local_time(entered, dep.icao)
        note = f"Schedule published. {number} leaves at {new_time}, not {old_time}. Your forecast will use {new_time}."
        body = f"Your flight on {day} leaves at {new_time}, not {old_time}. We'll forecast for the new time."
        return Published(update, f"{number} times confirmed", body, [note], push=moved >= PUSH_THRESHOLD)
    arrives = f" Arrives {local_time(arr.scheduled, arr.icao)}." if arr.scheduled else ""
    note = f"Schedule published. It matches what you entered.{arrives}"
    return Published(update, f"{number} times confirmed", note, [note], push=False)


def _tz(icao: str) -> ZoneInfo | None:
    try:
        return ZoneInfo(airports.lookup(icao).tz)
    except (KeyError, ValueError):
        return None


def _iata(icao: str) -> str:
    try:
        return airports.lookup(icao).iata
    except KeyError:
        return icao
