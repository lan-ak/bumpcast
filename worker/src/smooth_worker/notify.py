"""Forecast notifications: "ready" at 48 h, updates at 24 / 6 / 2 h, and "forecast confirmed".

User-facing text never names data sources: forecasts are "advance" until confirmed.

Every notification is recorded in Supabase (it doubles as the app's "what changed"
feed). Only the first ("ready") goes to everyone; updates are pushed to Pro users and
flights unlocked with a flight pass, and shown locked in the app for everyone else.
"""

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from . import airports, changes, flightdata, status
from .apns import Apns

log = logging.getLogger(__name__)

# (hours before departure, label), latest first.
MILESTONES = [(48, "48h"), (24, "24h"), (6, "6h"), (2, "2h")]
# Don't notify about flights that have already left.
DEPARTED_GRACE = timedelta(minutes=15)
# Quiet overnight (local time): held until morning, unless the flight leaves soon.
QUIET_START_HOUR, QUIET_END_HOUR = 22, 7
EARLY_FLIGHT = timedelta(hours=4)
# A push that failed only because the phone hadn't registered yet (permission is asked right
# after saving a flight, often after the first forecast lands) is retried for a while.
RETRYABLE_ERRORS = {"no device", "no apns"}
RETRY_WINDOW = timedelta(hours=1)
# Schedule pushes that landed in quiet hours go out in the morning, if still recent.
HELD = "held: quiet hours"
HELD_WINDOW = timedelta(hours=12)
# How long a delay push waits for the forecast at the new time before going without it.
FORECAST_WAIT = timedelta(minutes=15)


def is_quiet(now: datetime, tz: str | None, departure: datetime) -> bool:
    """Hold notifications overnight in the user's time zone, unless they fly early."""
    if departure - now <= EARLY_FLIGHT:
        return False
    try:
        local = now.astimezone(ZoneInfo(tz)) if tz else now
    except (KeyError, ValueError):
        local = now
    return local.hour >= QUIET_START_HOUR or local.hour < QUIET_END_HOUR


@dataclass
class Plan:
    milestone: str
    kind: str  # ready | update | confirmed
    pro_only: bool


def current_milestone(hours_to_departure: float) -> str | None:
    """The most recent milestone the flight has passed, e.g. 30 h out -> '48h', 5 h out -> '6h'."""
    passed = [label for hours, label in MILESTONES if hours_to_departure <= hours]
    return passed[-1] if passed else None


def plan(hours_to_departure: float, forecast: dict, sent: list[dict]) -> Plan | None:
    """What (if anything) to send now. `sent` is this flight's notifications, oldest first."""
    if forecast.get("status") != "ready":
        return None
    sent_milestones = {n["milestone"] for n in sent}
    milestone = current_milestone(hours_to_departure)
    if milestone and milestone not in sent_milestones:
        if not sent:
            return Plan(milestone, "ready", pro_only=False)
        return Plan(milestone, "update", pro_only=True)
    # The forecast is confirmed between milestones (about 17 h out); tell people who saw the advance one.
    if (
        sent
        and "noaa" not in sent_milestones
        and forecast.get("source") in ("gtg", "mixed")
        and forecast.get("noaa_possible") is not False
        and all(n.get("source") not in ("gtg", "mixed") for n in sent)
    ):
        return Plan("noaa", "confirmed", pro_only=True)
    return None


def retry(sent: list[dict], now: datetime) -> dict | None:
    """The latest notification, if it never reached a phone for want of a device or APNs key."""
    if not sent:
        return None
    last = sent[-1]
    if last.get("delivered") or last.get("error") not in RETRYABLE_ERRORS:
        return None
    created = datetime.fromisoformat(last["created_at"].replace("Z", "+00:00"))
    return last if now - created <= RETRY_WINDOW else None


def compose(p: Plan, flight: dict, forecast: dict, previous: dict | None, tz: str | None) -> tuple[str, str, list[str]]:
    origin, destination = airports.lookup(flight["origin"]), airports.lookup(flight["destination"])
    route = f"{origin.iata}→{destination.iata}"
    grade = changes.grade_title(forecast.get("grade"))
    points = changes.describe(previous if p.kind != "ready" else None, forecast, tz)
    early = changes.confidence(forecast.get("source"), forecast.get("noaa_possible")) == "early"

    if p.kind == "ready":
        title = f"Your {route} forecast is ready"
        detail = "Tap to see when the bumps are." if forecast.get("segments") else "Tap for the details."
        body = f"{grade}{' (advance forecast)' if early else ''}. {detail}"
    elif p.kind == "confirmed":
        title = f"{route}: forecast confirmed"
        body = f"{grade}. " + " ".join(points[:-1][:2])
    else:
        hours = p.milestone.removesuffix("h")
        title = f"{route} in {hours} hours: {grade.lower()}"
        body = " ".join(points[:2])
    return title, body, points


def run(db, apns: Apns | None, now: datetime) -> int:
    flights = db.upcoming_flights_with_latest_forecast(now)
    if not flights:
        return 0
    flight_ids = [f["id"] for f in flights]
    user_ids = sorted({f["user_id"] for f in flights})
    sent_by_flight = db.notifications_for(flight_ids)
    profiles = db.profiles(user_ids)
    passes = db.flights_with_passes(flight_ids)
    devices = db.devices(user_ids)

    count = 0
    for flight in flights:
        forecast = (flight.get("forecasts") or [None])[0]
        try:
            count += _status_event(db, apns, flight, forecast, profiles, passes, devices, now)
        except Exception:
            log.exception("status notification for flight %s failed", flight["id"])
        if not forecast:
            continue
        departure = datetime.fromisoformat(flight["departure_at"].replace("Z", "+00:00"))
        if departure < now - DEPARTED_GRACE:
            continue
        sent = sent_by_flight.get(flight["id"], [])
        targets = devices.get(flight["user_id"])
        if apns and targets and flight.get("notify") is not False and (last := retry(sent, now)):
            try:
                count += _deliver(db, apns, last["id"], flight, last["kind"], last["milestone"], last["title"], last["body"], targets)
            except Exception:
                log.exception("retrying notification for flight %s failed", flight["id"])
        p = plan((departure - now).total_seconds() / 3600, forecast, sent)
        if p is None:
            continue
        if is_quiet(now, profiles.get(flight["user_id"], {}).get("timezone"), departure):
            continue  # planned again on the first poll after quiet hours
        try:
            count += _send(db, apns, p, flight, forecast, sent, profiles, passes, devices)
        except Exception:
            log.exception("notification for flight %s failed", flight["id"])
    return count


def _send(db, apns, p, flight, forecast, sent, profiles, passes, devices) -> int:
    profile = profiles.get(flight["user_id"], {})
    previous = db.forecast(sent[-1]["forecast_id"]) if sent and sent[-1].get("forecast_id") else None
    title, body, points = compose(p, flight, forecast, previous, profile.get("timezone"))
    entitled = not p.pro_only or profile.get("is_pro") or flight["id"] in passes

    notification_id = db.insert_notification(
        {
            "flight_id": flight["id"],
            "user_id": flight["user_id"],
            "milestone": p.milestone,
            "kind": p.kind,
            "forecast_id": forecast["id"],
            "grade": forecast.get("grade"),
            "title": title,
            "body": body,
            "changes": [{"text": t} for t in points],
            "pro_only": p.pro_only,
        }
    )
    if notification_id is None:
        return 0  # another worker already recorded this milestone

    if not entitled:
        db.update_notification(notification_id, delivered=False, error="locked: needs Pro or a flight pass")
        return 1
    if flight.get("notify") is False:
        db.update_notification(notification_id, delivered=False, error="notifications off for this flight")
        return 1
    targets = devices.get(flight["user_id"], [])
    if apns is None or not targets:
        db.update_notification(notification_id, delivered=False, error="no apns" if apns is None else "no device")
        return 1
    return _deliver(db, apns, notification_id, flight, p.kind, p.milestone, title, body, targets)


def _deliver(db, apns, notification_id, flight, kind, milestone, title, body, targets) -> int:
    payload = {
        # content-available wakes the app in the background to save the new forecast offline.
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "thread-id": flight["id"],
            "content-available": 1,
        },
        "flight_id": flight["id"],
        "kind": kind,
        "milestone": milestone,
    }
    delivered, errors = False, []
    for device in targets:
        result = apns.send(device["token"], device["environment"], payload, collapse_id=f"{flight['id']}-{milestone}")
        delivered |= result.ok
        if not result.ok:
            errors.append(result.reason or "unknown")
        if result.token_dead:
            db.delete_device(device["token"])
    db.update_notification(notification_id, delivered=delivered, error=None if delivered else ", ".join(errors))
    log.info("notified %s %s (%s): %s", flight["id"], milestone, "delivered" if delivered else errors, title)
    return 1


# Live status (Pro or a flight pass) and published schedules (free)


def _status_event(db, apns, flight, forecast, profiles, passes, devices, now) -> int:
    """Push a delay, cancellation or diversion once, combined with the forecast it caused."""
    current = flight.get("status")
    profile = profiles.get(flight["user_id"], {})
    if not current or not (profile.get("is_pro") or flight["id"] in passes):
        return 0
    event = status.plan(current)
    if event is None:
        return 0
    departure = status.effective_departure(flight, current)
    if departure < now - DEPARTED_GRACE and event.kind == "delay":
        return 0
    if is_quiet(now, profile.get("timezone"), departure):
        return 0  # planned again on the first poll after quiet hours

    new = None
    if event.kind == "delay" and forecast and forecast.get("departure_at"):
        if datetime.fromisoformat(forecast["departure_at"].replace("Z", "+00:00")) == event.departure:
            new = forecast
    old = None
    if event.kind == "delay" and current.get("notified_departure"):
        told = datetime.fromisoformat(current["notified_departure"].replace("Z", "+00:00"))
        scheduled = datetime.fromisoformat(flight["departure_at"].replace("Z", "+00:00"))
        old = db.forecast_for_departure(flight["id"], told, scheduled=told == scheduled)
    checked = datetime.fromisoformat(current["checked_at"].replace("Z", "+00:00"))
    if event.kind == "delay" and new is None and (forecast or {}).get("status") == "ready" and now - checked < FORECAST_WAIT:
        return 0  # the forecast for the new time is still being computed: say both at once
    title, body = status.compose(event, flight, current, old, new)
    told = {"notified_status": current["status"]}
    if event.departure:
        told["notified_departure"] = event.departure.isoformat()
    db.update_flight_status(flight["id"], told)
    return _record(
        db,
        apns,
        flight,
        devices.get(flight["user_id"], []),
        {
            "milestone": event.milestone,
            "kind": event.kind,
            "forecast_id": (new or forecast or {}).get("id"),
            "grade": (new or forecast or {}).get("grade"),
            "title": title,
            "body": body,
            "changes": [{"text": body}],
            "pro_only": True,
        },
    )


def _record(db, apns, flight, targets, fields: dict, hold: bool = False) -> int:
    """Record a notification in the feed and push it when the user can get it."""
    notification_id = db.insert_notification({"flight_id": flight["id"], "user_id": flight["user_id"], **fields})
    if notification_id is None:
        return 0  # already recorded
    if flight.get("notify") is False:
        db.update_notification(notification_id, delivered=False, error="notifications off for this flight")
    elif hold:
        db.update_notification(notification_id, delivered=False, error=HELD)
    elif apns is None or not targets:
        db.update_notification(notification_id, delivered=False, error="no apns" if apns is None else "no device")
    else:
        _deliver(db, apns, notification_id, flight, fields["kind"], fields["milestone"], fields["title"], fields["body"], targets)
    return 1


def check_schedules(db, data: flightdata.FlightData | None, apns: Apns | None, now: datetime) -> int:
    """Once a day, look up flights saved before their schedule was out; fill them in when it is."""
    if data is None:
        return 0
    flights = [f for f in db.pending_schedules(now) if status.schedule_due(f.get("status"), now)]
    user_ids = sorted({f["user_id"] for f in flights})
    profiles = db.profiles(user_ids) if flights else {}
    devices = db.devices(user_ids) if flights else {}
    count = 0
    for flight in flights:
        try:
            count += _check_schedule(db, data, apns, flight, profiles, devices, now)
        except Exception:
            log.exception("schedule check for flight %s failed", flight["id"])
    _deliver_held(db, apns, now)
    return count


def _check_schedule(db, data, apns, flight, profiles, devices, now) -> int:
    origin = airports.lookup(flight["origin"])
    day = datetime.fromisoformat(flight["departure_at"].replace("Z", "+00:00")).astimezone(ZoneInfo(origin.tz)).date()
    legs = data.legs(flight["flight_number"], day)
    leg = flightdata.find_leg(legs, origin.icao, flight["destination"]) or next(
        (leg for leg in legs if not leg.codeshare), None
    )
    result = status.published(flight, leg) if leg else None
    if result is None:
        db.upsert_flight_status({"flight_id": flight["id"], "checked_at": now.isoformat()})
        return 0
    # Changing the time or route resets forecasts, notifications and this check (see the trigger),
    # so the note is recorded after the update.
    db.update_flight(flight["id"], result.update)
    db.delete_flight_status(flight["id"])
    profile = profiles.get(flight["user_id"], {})
    departure = datetime.fromisoformat(result.update["departure_at"])
    fields = {
        "milestone": "schedule",
        "kind": "schedule",
        "title": result.title,
        "body": result.body,
        "changes": [{"text": t} for t in result.note],
        "pro_only": False,
    }
    if not result.push:
        notification_id = db.insert_notification({"flight_id": flight["id"], "user_id": flight["user_id"], **fields})
        if notification_id:
            db.update_notification(notification_id, delivered=False, error="in app only")
        return 1
    hold = is_quiet(now, profile.get("timezone"), departure)
    return _record(db, apns, flight, devices.get(flight["user_id"], []), fields, hold=hold)


def _deliver_held(db, apns, now: datetime) -> None:
    """Send schedule pushes held overnight, once it's morning for the user."""
    held = db.held_notifications(HELD, now - HELD_WINDOW)
    if not held or apns is None:
        return
    user_ids = sorted({n["user_id"] for n in held})
    profiles, devices = db.profiles(user_ids), db.devices(user_ids)
    for n in held:
        flight = n["flight"]
        departure = datetime.fromisoformat(flight["departure_at"].replace("Z", "+00:00"))
        targets = devices.get(n["user_id"], [])
        if not targets or is_quiet(now, profiles.get(n["user_id"], {}).get("timezone"), departure):
            continue
        _deliver(db, apns, n["id"], {**flight, "user_id": n["user_id"]}, n["kind"], n["milestone"], n["title"], n["body"], targets)
