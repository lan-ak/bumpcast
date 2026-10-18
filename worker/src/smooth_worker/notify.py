"""Forecast notifications: "ready" at 48 h, updates at 24 / 6 / 2 h, and "forecast confirmed".

User-facing text never names data sources: forecasts are "advance" until confirmed.

Every notification is recorded in Supabase (it doubles as the app's "what changed"
feed). Only the first ("ready") goes to everyone; updates are pushed to Pro users and
flights unlocked with a flight pass, and shown locked in the app for everyone else.
"""

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta

from . import airports, changes
from .apns import Apns

log = logging.getLogger(__name__)

# (hours before departure, label), latest first.
MILESTONES = [(48, "48h"), (24, "24h"), (6, "6h"), (2, "2h")]
# Don't notify about flights that have already left.
DEPARTED_GRACE = timedelta(minutes=15)


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
        and all(n.get("source") not in ("gtg", "mixed") for n in sent)
    ):
        return Plan("noaa", "confirmed", pro_only=True)
    return None


def compose(p: Plan, flight: dict, forecast: dict, previous: dict | None, tz: str | None) -> tuple[str, str, list[str]]:
    origin, destination = airports.lookup(flight["origin"]), airports.lookup(flight["destination"])
    route = f"{origin.iata}→{destination.iata}"
    grade = changes.grade_title(forecast.get("grade"))
    points = changes.describe(previous if p.kind != "ready" else None, forecast, tz)
    early = changes.confidence(forecast.get("source")) == "early"

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
        if not forecast:
            continue
        departure = datetime.fromisoformat(flight["departure_at"].replace("Z", "+00:00"))
        if departure < now - DEPARTED_GRACE:
            continue
        sent = sent_by_flight.get(flight["id"], [])
        p = plan((departure - now).total_seconds() / 3600, forecast, sent)
        if p is None:
            continue
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
    targets = devices.get(flight["user_id"], [])
    if apns is None or not targets:
        db.update_notification(notification_id, delivered=False, error="no apns" if apns is None else "no device")
        return 1

    payload = {
        # content-available wakes the app in the background to save the new forecast offline.
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "thread-id": flight["id"],
            "content-available": 1,
        },
        "flight_id": flight["id"],
        "kind": p.kind,
        "milestone": p.milestone,
    }
    delivered, errors = False, []
    for device in targets:
        result = apns.send(device["token"], device["environment"], payload, collapse_id=f"{flight['id']}-{p.milestone}")
        delivered |= result.ok
        if not result.ok:
            errors.append(result.reason or "unknown")
        if result.token_dead:
            db.delete_device(device["token"])
    db.update_notification(notification_id, delivered=delivered, error=None if delivered else ", ".join(errors))
    log.info("notified %s %s (%s): %s", flight["id"], p.milestone, "delivered" if delivered else errors, title)
    return 1
