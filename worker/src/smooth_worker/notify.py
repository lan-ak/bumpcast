"""Forecast notifications: "ready" at 48 h, updates at 24 / 6 / 2 h, and "forecast confirmed".

User-facing text never names data sources: forecasts are "advance" until confirmed.

Every notification is recorded in Supabase (it doubles as the app's "what changed"
feed). Only the first ("ready") goes to everyone; updates are pushed to Pro users and
flights unlocked with a flight pass, and shown locked in the app for everyone else.
"""

import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
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
# A takeoff found later than this is too stale to move the countdown.
TAKEOFF_PUSH_LIMIT = timedelta(hours=2)
# Connecting flights: a leg that leaves from where the user's earlier flight lands, within this
# long of that flight's departure, is the same trip.
CONNECTION_WINDOW = timedelta(hours=30)
# Milestones two legs share as one push, and the most the legs' departures can differ (hours).
# The first leg waits for the second to reach the milestone, so later milestones only fold for
# short layovers: the first leg never waits past its own next update. "2h" never folds: the next
# leg's 2-hour update usually lands during the layover, where it's useful on its own.
FOLD_GAP = {"48h": 8, "24h": 8, "6h": 3}
# Extra time the first leg waits for the second leg's forecast before going alone.
FOLD_GRACE = 1
MILESTONE_HOURS = {label: hours for hours, label in MILESTONES}
WAIT = "wait"


# Outlook-only flights (routes NOAA can't confirm) are pushed an update only for a real
# change: the grade moving this many steps, or a new official warning or pilot report.
# Smaller changes are still recorded for the app's "what changed" feed, just not pushed.
OUTLOOK_PUSH_GRADE_STEPS = 2
QUIET_OUTLOOK = "quiet: small outlook change"


BETA_INVITE = "beta"


def outlook_held(forecast: dict, profile: dict) -> bool:
    """Routes only the global outlook covers are forecast for everyone, but only people who
    turned the beta on hear about them."""
    return forecast.get("noaa_possible") is False and profile.get("global_beta") is not True


def beta_invite_due(forecast: dict, profile: dict, waitlisted: bool, sent: list[dict]) -> bool:
    """People on the waitlist hear once that their route is covered, unless they already chose."""
    return (
        forecast.get("status") == "ready"
        and forecast.get("noaa_possible") is False
        and profile.get("global_beta") is None
        and waitlisted
        and all(n["milestone"] != BETA_INVITE for n in sent)
    )


def compose_beta_invite(flight: dict) -> tuple[str, str]:
    origin, destination = airports.lookup(flight["origin"]), airports.lookup(flight["destination"])
    departure = datetime.fromisoformat(flight["departure_at"].replace("Z", "+00:00"))
    try:
        departure = departure.astimezone(ZoneInfo(origin.tz))
    except (KeyError, ValueError):
        pass
    day = f"{departure:%a} {departure.day} {departure:%b}"
    return (
        "A forecast for your flight is ready to try",
        f"{origin.iata} → {destination.iata} on {day} can use our beta global outlook. Tap to turn it on.",
    )


def outlook_change_worth_pushing(previous: dict | None, forecast: dict) -> bool:
    if previous is None or forecast.get("noaa_possible") is not False:
        return True
    old, new = previous.get("grade"), forecast.get("grade")
    if old in changes.GRADE_ORDER and new in changes.GRADE_ORDER:
        if abs(changes.GRADE_ORDER.index(new) - changes.GRADE_ORDER.index(old)) >= OUTLOOK_PUSH_GRADE_STEPS:
            return True
    old_warnings = previous.get("warnings") or []
    return any(not any(changes.overlaps(w, o) for o in old_warnings) for w in forecast.get("warnings") or [])


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


def _departure(flight: dict) -> datetime:
    return datetime.fromisoformat(flight["departure_at"].replace("Z", "+00:00"))


def connections(flights: list[dict]) -> dict[str, dict]:
    """Each flight's next leg: same user, leaves from where it lands, within CONNECTION_WINDOW."""
    by_user: dict[str, list[dict]] = {}
    for f in flights:
        by_user.setdefault(f["user_id"], []).append(f)
    following = {}
    for legs in by_user.values():
        legs.sort(key=_departure)
        for i, first in enumerate(legs):
            for second in legs[i + 1 :]:
                gap = _departure(second) - _departure(first)
                if gap > CONNECTION_WINDOW:
                    break
                if gap > timedelta(0) and second["origin"] == first["destination"]:
                    following[first["id"]] = second
                    break
    return following


def folds(milestone: str, first: dict, second: dict) -> bool:
    """Whether two legs share this milestone's push."""
    gap = (_departure(second) - _departure(first)).total_seconds() / 3600
    return milestone in FOLD_GAP and 0 < gap <= FOLD_GAP[milestone]


def compose_trip(p: Plan, first: dict, second: dict, f1: dict, f2: dict) -> tuple[str, str]:
    """One push for two legs of a trip: "Your trip via DEN: forecasts ready"."""
    via = airports.lookup(first["destination"]).iata
    legs = []
    for flight, forecast in ((first, f1), (second, f2)):
        route = f"{airports.lookup(flight['origin']).iata}→{airports.lookup(flight['destination']).iata}"
        legs.append(f"{route}: {changes.grade_title(forecast.get('grade')).lower()}")
    summary = ". ".join(legs) + "."
    if p.kind == "ready":
        return f"Your trip via {via}: forecasts ready", f"{summary} Tap to see when the bumps are."
    return f"Your trip via {via} in {p.milestone.removesuffix('h')} hours", summary


def run(db, apns: Apns | None, now: datetime) -> int:
    flights = db.upcoming_flights_with_latest_forecast(now)
    if not flights:
        return 0
    flight_ids = [f["id"] for f in flights]
    user_ids = sorted({f["user_id"] for f in flights})
    sent_by_flight = db.notifications_for(flight_ids)
    profiles = db.profiles(user_ids)
    waitlisted = db.waitlisted(user_ids) if any(
        (f.get("forecasts") or [{}])[0].get("noaa_possible") is False for f in flights
    ) else set()
    passes = db.flights_with_passes(flight_ids)
    devices = db.devices(user_ids)
    following = connections(flights)
    by_id = {f["id"]: f for f in flights}
    leading = {second["id"]: by_id[first_id] for first_id, second in following.items()}

    def entitled(flight: dict) -> bool:
        return bool(profiles.get(flight["user_id"], {}).get("is_pro")) or flight["id"] in passes

    def leg_plan(flight: dict) -> Plan | None:
        forecast = (flight.get("forecasts") or [None])[0]
        if not forecast or outlook_held(forecast, profiles.get(flight["user_id"], {})):
            return None
        return plan((_departure(flight) - now).total_seconds() / 3600, forecast, sent_by_flight.get(flight["id"], []))

    def together(p: Plan, first: dict, second: dict, other: dict) -> bool:
        """Whether `other` (one of the two legs) is due the same push now, so they can share it."""
        if not folds(p.milestone, first, second) or (p.pro_only and entitled(first) != entitled(second)):
            return False
        q = leg_plan(other)
        return q is not None and (q.milestone, q.kind) == (p.milestone, p.kind)

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
        profile = profiles.get(flight["user_id"], {})
        if outlook_held(forecast, profile):
            if beta_invite_due(forecast, profile, flight["user_id"] in waitlisted, sent) and not is_quiet(
                now, profile.get("timezone"), departure
            ):
                try:
                    count += _send_beta_invite(db, apns, flight, forecast, devices)
                except Exception:
                    log.exception("beta invite for flight %s failed", flight["id"])
            continue
        hours = (departure - now).total_seconds() / 3600
        p = plan(hours, forecast, sent)
        if p is None:
            continue
        if is_quiet(now, profiles.get(flight["user_id"], {}).get("timezone"), departure):
            continue  # planned again on the first poll after quiet hours
        # Connecting flights: the second leg's news travels with the first leg's push.
        first = leading.get(flight["id"])
        if first and together(p, first, flight, other=first):
            continue
        then = None
        second = following.get(flight["id"])
        if second and folds(p.milestone, flight, second):
            if together(p, flight, second, other=second):
                then = second
            else:
                second_hours = (_departure(second) - now).total_seconds() / 3600
                if second_hours > MILESTONE_HOURS[p.milestone] - FOLD_GRACE:
                    continue  # give the next leg time to reach the milestone (plus a little for its forecast)
        try:
            count += _send(db, apns, p, flight, forecast, sent, profiles, passes, devices, then=then, sent_by_flight=sent_by_flight)
        except Exception:
            log.exception("notification for flight %s failed", flight["id"])
    return count


def _send_beta_invite(db, apns, flight: dict, forecast: dict, devices: dict) -> int:
    title, body = compose_beta_invite(flight)
    notification_id = db.insert_notification(
        {
            "flight_id": flight["id"],
            "user_id": flight["user_id"],
            "milestone": BETA_INVITE,
            "kind": BETA_INVITE,
            "forecast_id": forecast["id"],
            "grade": None,
            "title": title,
            "body": body,
            "changes": [],
            "pro_only": False,
        }
    )
    if notification_id is None:
        return 0
    if flight.get("notify") is False:
        db.update_notification(notification_id, delivered=False, error="notifications off for this flight")
        return 1
    targets = devices.get(flight["user_id"], [])
    if apns is None or not targets:
        db.update_notification(notification_id, delivered=False, error="no apns" if apns is None else "no device")
        return 1
    return _deliver(db, apns, notification_id, flight, BETA_INVITE, BETA_INVITE, title, body, targets)


def _send(db, apns, p, flight, forecast, sent, profiles, passes, devices, then=None, sent_by_flight=None) -> int:
    """Record and push one milestone. With `then`, the connecting leg shares the push and gets
    its own record (each flight keeps its own "what changed" feed)."""
    profile = profiles.get(flight["user_id"], {})
    previous = db.forecast(sent[-1]["forecast_id"]) if sent and sent[-1].get("forecast_id") else None
    title, body, points = compose(p, flight, forecast, previous, profile.get("timezone"))
    entitled = not p.pro_only or profile.get("is_pro") or flight["id"] in passes

    legs = [(flight, forecast, points)]
    if then is not None:
        then_forecast = (then.get("forecasts") or [None])[0]
        then_sent = (sent_by_flight or {}).get(then["id"], [])
        then_previous = (
            db.forecast(then_sent[-1]["forecast_id"]) if then_sent and then_sent[-1].get("forecast_id") else None
        )
        _, _, then_points = compose(p, then, then_forecast, then_previous, profile.get("timezone"))
        title, body = compose_trip(p, flight, then, forecast, then_forecast)
        legs.append((then, then_forecast, then_points))

    ids = []
    for leg, leg_forecast, leg_points in legs:
        notification_id = db.insert_notification(
            {
                "flight_id": leg["id"],
                "user_id": leg["user_id"],
                "milestone": p.milestone,
                "kind": p.kind,
                "forecast_id": leg_forecast["id"],
                "grade": leg_forecast.get("grade"),
                "title": title,
                "body": body,
                "changes": [{"text": t} for t in leg_points],
                "pro_only": p.pro_only,
            }
        )
        if notification_id is None:
            if not ids:
                return 0  # another worker already recorded this milestone
            continue
        ids.append(notification_id)
    notification_id, also = ids[0], ids[1:]

    def mark(**outcome):
        for i in ids:
            db.update_notification(i, **outcome)

    if p.kind == "update" and not outlook_change_worth_pushing(previous, forecast):
        db.update_notification(notification_id, delivered=False, error=QUIET_OUTLOOK)
        return 1
    if not entitled:
        mark(delivered=False, error="locked: needs Pro or a flight pass")
        return 1
    if flight.get("notify") is False:
        mark(delivered=False, error="notifications off for this flight")
        return 1
    targets = devices.get(flight["user_id"], [])
    if apns is None or not targets:
        mark(delivered=False, error="no apns" if apns is None else "no device")
        return 1
    return _deliver(db, apns, notification_id, flight, p.kind, p.milestone, title, body, targets, also=also)


def _deliver(db, apns, notification_id, flight, kind, milestone, title, body, targets, also=()) -> int:
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
    for i in (notification_id, *also):
        db.update_notification(i, delivered=delivered, error=None if delivered else ", ".join(errors))
    log.info("notified %s %s (%s): %s", flight["id"], milestone, "delivered" if delivered else errors, title)
    return 1


# Live status and published schedules (free for everyone)


def _status_event(db, apns, flight, forecast, profiles, passes, devices, now) -> int:
    """Push a delay, cancellation or diversion once, combined with the forecast it caused."""
    current = flight.get("status")
    profile = profiles.get(flight["user_id"], {})
    if not current:
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
            "pro_only": False,
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


# Wheels-up: re-time the in-flight countdown from the airline's data


# Apple's reference date for Date values in Live Activity content state.
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=UTC)


def push_takeoffs(db, apns: Apns | None, now: datetime) -> int:
    """Send each open Live Activity the real wheels-up once the airline reports it, and wake the
    app so its local stretch reminders move too. Each takeoff time is pushed once per activity."""
    if apns is None:
        return 0
    count = 0
    woken: set[str] = set()
    for activity in db.live_activities_to_retime(now):
        flight = activity.get("flight") or {}
        takeoff = status._time((flight.get("status") or {}).get("takeoff_at"))
        if takeoff is None or takeoff < now - TAKEOFF_PUSH_LIMIT:
            continue
        if status._time(activity.get("pushed_takeoff")) == takeoff:
            continue
        reference = (takeoff - APPLE_EPOCH).total_seconds()
        when = status.local_time(takeoff, flight.get("origin") or "")
        payload = {
            "aps": {
                "timestamp": int(now.timestamp()),
                "event": "update",
                "content-state": {"takeoff": reference, "updatedAt": (now - APPLE_EPOCH).total_seconds()},
                "alert": {
                    "title": "Wheels up",
                    "body": f"Your countdown is timed to takeoff at {when}.",
                },
            }
        }
        result = apns.send(activity["token"], activity["environment"], payload, push_type="liveactivity")
        if result.ok:
            db.mark_live_activity(activity["token"], pushed_takeoff=takeoff.isoformat())
            count += 1
        elif result.token_dead or result.reason == "ExpiredToken":
            db.mark_live_activity(activity["token"], ended=True)
        if result.ok and activity["flight_id"] not in woken:
            woken.add(activity["flight_id"])
            for device in db.devices([activity["user_id"]]).get(activity["user_id"], []):
                apns.send(
                    device["token"],
                    device["environment"],
                    {"aps": {"content-available": 1}, "flight_id": activity["flight_id"], "kind": "takeoff"},
                    push_type="background",
                )
        log.info("takeoff %s at %s: %s", activity["flight_id"], takeoff, "pushed" if result.ok else result.reason)
    return count
