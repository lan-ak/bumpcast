import json
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import smooth_worker
from smooth_worker.apns import SendResult
from smooth_worker import flightdata, notify, status

# flight_b6_23.json is a made-up delay in the provider's shape; flight_b6_123_recorded.json is a
# real response (recorded 2026-10-18 for the next day's flight).
FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "flight_b6_23.json").read_text())
RECORDED = json.loads((Path(__file__).parent / "fixtures" / "flight_b6_123_recorded.json").read_text())
SCHEDULED = datetime(2026, 10, 22, 11, 15, tzinfo=UTC)  # 7:15 AM EDT
FLIGHT = {
    "id": "f1",
    "user_id": "u1",
    "origin": "KJFK",
    "destination": "KLAX",
    "departure_at": "2026-10-22T11:15:00+00:00",
    "updated_at": "2026-10-20T00:00:00+00:00",
    "flight_number": "B6 23",
    "notify": True,
}


def legs(**overrides) -> list[flightdata.Leg]:
    raw = json.loads(json.dumps(FIXTURE))
    raw[0].update(overrides)
    return [flightdata.parse_leg(f) for f in raw]


def leg(**overrides) -> flightdata.Leg:
    return legs(**overrides)[0]


# Provider parsing


def test_normalize_number():
    assert flightdata.normalize_number("b6 23") == "B6 23"
    assert flightdata.normalize_number("B6-023") == "B6 23"
    assert flightdata.normalize_number("jbu23") == "JBU 23"
    assert flightdata.normalize_number("AA100") == "AA 100"
    assert flightdata.normalize_number("UA 456A") == "UA 456A"
    assert flightdata.normalize_number("123") is None
    assert flightdata.normalize_number("JFK") is None
    assert flightdata.normalize_number("12 34") is None


def test_parse_leg():
    b6 = leg()
    assert (b6.number, b6.airline, b6.status) == ("B6 23", "JetBlue", "Delayed")
    assert b6.departure.icao == "KJFK" and b6.arrival.icao == "KLAX"
    assert b6.departure.scheduled == SCHEDULED
    assert b6.departure.revised == SCHEDULED + timedelta(minutes=40)
    assert (b6.departure.gate, b6.departure.terminal, b6.departure.live) == ("B22", "5", True)
    assert not b6.codeshare and legs()[1].codeshare


def test_recorded_response_is_a_scheduled_flight_without_live_times():
    b6 = flightdata.parse_leg(RECORDED[0])
    assert (b6.number, b6.airline, b6.status) == ("B6 123", "JetBlue Airways", "Expected")
    assert b6.departure.scheduled == datetime(2026, 10, 19, 10, 0, tzinfo=UTC)
    assert b6.arrival.icao == "KLAX" and b6.departure.terminal == "5" and b6.departure.gate is None
    flight = {**FLIGHT, "flight_number": "B6 123", "departure_at": "2026-10-19T10:00:00+00:00"}
    row = status.build(b6, flight, None, datetime(2026, 10, 18, 20, 0, tzinfo=UTC))
    assert (row["status"], row["live"], row["delay_min"]) == ("scheduled", False, 0)
    # 14 hours out: hourly from here.
    assert row["next_check_at"] == "2026-10-18T21:00:00+00:00"


def test_departed_uses_the_gate_time():
    departure = {
        "airport": {"icao": "KJFK"},
        "scheduledTime": {"utc": "2026-10-18 19:00Z"},
        "revisedTime": {"utc": "2026-10-18 19:01Z"},
        "runwayTime": {"utc": "2026-10-18 19:34Z"},
        "quality": ["Basic", "Live"],
    }
    leg = flightdata.parse_leg({"number": "DL 5859", "status": "Departed", "departure": departure, "arrival": {"airport": {"icao": "KDCA"}}})
    row = status.build(leg, {**FLIGHT, "destination": "KDCA"}, None, datetime(2026, 10, 18, 19, 40, tzinfo=UTC))
    assert (row["status"], row["departure_actual"], row["delay_min"]) == ("departed", "2026-10-18T19:01:00+00:00", 1)
    assert row["takeoff_at"] == "2026-10-18T19:34:00+00:00"  # wheels-up is the runway time


def test_takeoff_is_only_a_runway_time_that_has_passed():
    # Off the gate at 11:55 with no runway time yet: no guess (the app estimates gate plus taxi).
    departed = status.build(leg(status="Departed"), FLIGHT, None, SCHEDULED + timedelta(minutes=45))
    assert departed["status"] == "departed" and departed["takeoff_at"] is None
    assert status.build(leg(), FLIGHT, None, NOW)["takeoff_at"] is None
    # A runway time still ahead is the airline's estimate.
    runway = {**FIXTURE[0]["departure"], "runwayTime": {"utc": "2026-10-22 12:20Z"}}
    taxiing = status.build(leg(status="Departed", departure=runway), FLIGHT, None, SCHEDULED + timedelta(minutes=50))
    assert taxiing["takeoff_at"] is None
    up = status.build(leg(status="Departed", departure=runway), FLIGHT, None, SCHEDULED + timedelta(minutes=70))
    assert up["takeoff_at"] == "2026-10-22T12:20:00+00:00"


def test_arrival_is_actual_only_once_it_has_happened():
    # AC 1507 showed a 19:57 landing as "actual" at 19:19: it was the airline's estimate.
    arrival = {**FIXTURE[0]["arrival"], "runwayTime": {"utc": "2026-10-22 18:05Z"}}
    flying = status.build(leg(status="EnRoute", arrival=arrival), FLIGHT, None, SCHEDULED + timedelta(hours=3))
    assert flying["arrival_actual"] is None
    assert flying["arrival_expected"] == "2026-10-22T18:15:00+00:00"  # the gate arrival estimate
    landed = status.build(leg(status="Arrived", arrival=arrival), FLIGHT, None, datetime(2026, 10, 22, 18, 10, tzinfo=UTC))
    assert (landed["arrival_actual"], landed["arrival_expected"]) == ("2026-10-22T18:05:00+00:00", None)
    assert not landed["finished"] and landed["next_check_at"] == "2026-10-22T18:35:00+00:00"  # last check


def test_find_leg_prefers_the_operating_flight():
    found = flightdata.find_leg(list(reversed(legs())), "KJFK", "KLAX")
    assert found.number == "B6 23"
    assert flightdata.find_leg(legs(), "KBOS") is None


# Building the status row


NOW = SCHEDULED - timedelta(hours=3)


def test_build_delayed():
    row = status.build(leg(), FLIGHT, None, NOW)
    assert row["status"] == "delayed"
    assert row["delay_min"] == 40
    assert row["departure_expected"] == "2026-10-22T11:55:00+00:00"
    assert row["departure_actual"] is None
    assert (row["departure_gate"], row["departure_terminal"], row["live"]) == ("B22", "5", True)
    # Within 18 h: hourly. The first status sets what the user knew: the schedule.
    assert row["next_check_at"] == (NOW + timedelta(hours=1)).isoformat()
    assert row["notified_departure"] == SCHEDULED.isoformat()
    assert not row["finished"]


def test_build_on_time_departed_cancelled_diverted():
    on_time = leg(status="Expected", departure={**FIXTURE[0]["departure"], "revisedTime": {"utc": "2026-10-22 11:17Z"}})
    assert status.build(on_time, FLIGHT, None, NOW)["status"] == "scheduled"

    departed = status.build(leg(status="Departed"), FLIGHT, None, SCHEDULED + timedelta(minutes=45))
    assert departed["status"] == "departed"
    assert departed["departure_actual"] == "2026-10-22T11:55:00+00:00"

    cancelled = status.build(leg(status="Canceled"), FLIGHT, None, NOW)
    assert cancelled["status"] == "cancelled" and cancelled["finished"] and cancelled["next_check_at"] is None

    arrival = {**FIXTURE[0]["arrival"], "airport": {"icao": "KDEN", "iata": "DEN"}}
    diverted = status.build(leg(status="Diverted", arrival=arrival), FLIGHT, None, NOW)
    assert (diverted["status"], diverted["diverted_to"]) == ("diverted", "KDEN")


def test_build_keeps_what_the_user_was_told():
    previous = {"notified_departure": "2026-10-22T11:35:00+00:00", "notified_status": "delayed"}
    row = status.build(leg(), FLIGHT, previous, NOW)
    assert row["notified_departure"] == "2026-10-22T11:35:00+00:00"
    assert row["notified_status"] == "delayed"


def test_status_continues_until_landing():
    # Off the gate at 11:55, landing expected 18:15: checked every 30 minutes in the air.
    now = SCHEDULED + timedelta(hours=2)
    row = status.build(leg(status="Departed"), FLIGHT, None, now)
    assert not row["finished"]
    assert row["next_check_at"] == (now + timedelta(minutes=30)).isoformat()
    # The last check is half an hour after the expected landing.
    late = status.build(leg(status="Departed"), FLIGHT, None, datetime(2026, 10, 22, 18, 30, tzinfo=UTC))
    assert late["next_check_at"] == "2026-10-22T18:45:00+00:00"
    assert status.build(leg(status="Departed"), FLIGHT, None, datetime(2026, 10, 22, 18, 46, tzinfo=UTC))["finished"]


def test_ends_follows_the_landing():
    dep = SCHEDULED
    assert status.ends(FLIGHT, {"status": "departed", "arrival_actual": "2026-10-22T13:00:00+00:00"}, dep) == datetime(
        2026, 10, 22, 13, 30, tzinfo=UTC
    )
    expected = {"status": "departed", "arrival_expected": "2026-10-22T17:00:00+00:00"}
    assert status.ends(FLIGHT, expected, dep) == datetime(2026, 10, 22, 17, 30, tzinfo=UTC)
    # Only the schedule: moved by the delay.
    late = {"status": "delayed", "departure_scheduled": dep.isoformat(), "arrival_scheduled": "2026-10-22T17:41:00+00:00"}
    assert status.ends(FLIGHT, late, dep + timedelta(hours=2)) == datetime(2026, 10, 22, 20, 11, tzinfo=UTC)
    with_arrival = {**FLIGHT, "arrival_at": "2026-10-22T17:41:00+00:00"}
    assert status.ends(with_arrival, None, dep) == datetime(2026, 10, 22, 18, 11, tzinfo=UTC)
    # Nothing known yet: the longest flights. Never found: an hour after departure.
    assert status.ends(FLIGHT, None, dep) == dep + status.MAX_FLIGHT + status.AFTER_ARRIVAL
    assert status.ends(FLIGHT, {"checked_at": NOW.isoformat()}, dep) == dep + timedelta(hours=1, minutes=30)


# When to refresh: the forecast's rhythm


def test_status_refresh_rhythm():
    assert not status.is_due(None, SCHEDULED, SCHEDULED - timedelta(hours=49))  # too early
    assert status.is_due(None, SCHEDULED, SCHEDULED - timedelta(hours=47))
    checked = {"status": "scheduled", "checked_at": (SCHEDULED - timedelta(hours=30)).isoformat()}
    assert not status.is_due(checked, SCHEDULED, SCHEDULED - timedelta(hours=27))  # 6-hourly before 18 h
    assert status.is_due(checked, SCHEDULED, SCHEDULED - timedelta(hours=24))
    checked = {"status": "scheduled", "checked_at": (SCHEDULED - timedelta(hours=5)).isoformat()}
    assert status.is_due(checked, SCHEDULED, SCHEDULED - timedelta(hours=4))  # hourly in the last 18 h
    assert not status.is_due(checked, SCHEDULED, SCHEDULED - timedelta(hours=4, minutes=30))
    assert not status.is_due({**checked, "finished": True}, SCHEDULED, SCHEDULED)
    assert not status.is_due({**checked, "status": "cancelled"}, SCHEDULED, SCHEDULED)
    # Saved in the air: the first status is due until the flight should have landed.
    assert status.is_due(None, SCHEDULED, SCHEDULED + timedelta(hours=2))
    with_arrival = {**FLIGHT, "arrival_at": "2026-10-22T17:41:00+00:00"}
    assert status.is_due(None, SCHEDULED, SCHEDULED + timedelta(hours=6), flight=with_arrival)
    assert not status.is_due(None, SCHEDULED, SCHEDULED + timedelta(hours=7), flight=with_arrival)  # landed
    assert not status.is_due(None, SCHEDULED, SCHEDULED + timedelta(hours=19))  # long gone


def test_a_check_that_found_nothing_waits_too():
    missing = {"flight_id": "f1", "checked_at": (SCHEDULED - timedelta(hours=5)).isoformat()}
    assert not status.is_due(missing, SCHEDULED, SCHEDULED - timedelta(hours=4, minutes=30))
    assert status.is_due(missing, SCHEDULED, SCHEDULED - timedelta(hours=4))
    late = {"flight_id": "f1", "checked_at": (SCHEDULED + timedelta(minutes=50)).isoformat()}
    assert not status.is_due(late, SCHEDULED, SCHEDULED + timedelta(hours=2))  # never found: done


def test_effective_departure():
    assert status.effective_departure(FLIGHT, None) == SCHEDULED
    later = SCHEDULED + timedelta(minutes=40)
    assert status.effective_departure(FLIGHT, {"departure_expected": later.isoformat()}) == later
    actual = {"departure_expected": None, "departure_actual": (later + timedelta(minutes=3)).isoformat()}
    assert status.effective_departure(FLIGHT, actual) == later + timedelta(minutes=3)


def test_forecast_waits_for_the_new_departure():
    forecast = {"issued_at": "2026-10-22T07:30:00+00:00", "status": "ready", "departure_at": FLIGHT["departure_at"]}
    flight = {**FLIGHT, "forecasts": [forecast]}
    now = SCHEDULED - timedelta(hours=3, minutes=30)
    assert not smooth_worker.is_due(flight, now)
    assert smooth_worker.is_due(flight, now, SCHEDULED + timedelta(minutes=40))
    # Forecasts from before 1.1 have no departure_at and used the schedule.
    old = {**flight, "forecasts": [{**forecast, "departure_at": None}]}
    assert not smooth_worker.is_due(old, now)
    assert smooth_worker.is_due(old, now, SCHEDULED + timedelta(minutes=40))


# What to tell the user


def row(**fields) -> dict:
    return {
        "status": "delayed",
        "departure_scheduled": SCHEDULED.isoformat(),
        "departure_expected": (SCHEDULED + timedelta(minutes=40)).isoformat(),
        "delay_min": 40,
        "notified_departure": SCHEDULED.isoformat(),
        "notified_status": None,
        "checked_at": NOW.isoformat(),
        **fields,
    }


def test_plan_delays_of_15_minutes_or_more():
    event = status.plan(row())
    assert (event.kind, event.milestone, event.moved_min) == ("delay", "delay:20261022T1155", 40)
    assert status.plan(row(departure_expected=(SCHEDULED + timedelta(minutes=10)).isoformat(), delay_min=10)) is None
    # Told about the delay already: nothing more until it moves again by 15 min.
    assert status.plan(row(notified_departure=row()["departure_expected"])) is None
    earlier = status.plan(row(notified_departure=(SCHEDULED + timedelta(minutes=60)).isoformat()))
    assert earlier.moved_min == -20
    assert status.plan(row(status="departed")) is None
    assert status.plan(None) is None and status.plan({"checked_at": NOW.isoformat()}) is None


def test_plan_cancelled_and_diverted_once():
    assert status.plan(row(status="cancelled")).kind == "cancelled"
    assert status.plan(row(status="cancelled", notified_status="cancelled")) is None
    assert status.plan(row(status="diverted")).milestone == "diverted"


SMOOTH = {"status": "ready", "grade": "mostly_smooth", "segments": [{"severity": "light", "start_min": 70, "end_min": 80}]}


def test_compose_delay_messages():
    event = status.plan(row())
    bumpier = {**SMOOTH, "grade": "some_bumps", "segments": [{"severity": "moderate", "start_min": 70, "end_min": 85}]}
    title, body = status.compose(event, FLIGHT, row(), SMOOTH, bumpier)
    assert title == "Delayed 40 min, forecast updated"
    assert body == "B6 23 now leaves at 7:55 AM. Now a few bumps, with moderate bumps 1 h 10 min in."

    title, body = status.compose(event, FLIGHT, row(), SMOOTH, dict(SMOOTH))
    assert (title, body) == ("Delayed 40 min", "B6 23 now leaves at 7:55 AM. We checked: your forecast hasn't changed.")

    title, body = status.compose(event, FLIGHT, row(), None, None)
    assert (title, body) == ("Delayed 40 min", "B6 23 now leaves at 7:55 AM.")

    earlier = status.plan(row(notified_departure=(SCHEDULED + timedelta(minutes=60)).isoformat()))
    assert status.compose(earlier, FLIGHT, row(), SMOOTH, SMOOTH)[0] == "Leaving earlier than expected"


def test_compose_cancelled_and_diverted_never_name_a_source():
    title, body = status.compose(status.Event("cancelled", "cancelled"), FLIGHT, row(status="cancelled"), None, None)
    assert title == "B6 23 is cancelled"
    assert "airline will be in touch" in body
    title, _ = status.compose(status.Event("diverted", "diverted"), FLIGHT, row(diverted_to="KDEN"), None, None)
    assert title == "B6 23 is diverting to Denver"


# Published schedules


PENDING = {**FLIGHT, "flight_number": "UA 456", "origin": "KJFK", "destination": "KSFO", "departure_at": "2027-09-09T12:00:00+00:00"}


def published_leg(dep_utc: str, origin: str = "KJFK") -> flightdata.Leg:
    return flightdata.parse_leg(
        {
            "number": "UA 456",
            "status": "Expected",
            "airline": {"name": "United"},
            "departure": {"airport": {"icao": origin}, "scheduledTime": {"utc": dep_utc}},
            "arrival": {"airport": {"icao": "KSFO"}, "scheduledTime": {"utc": "2027-09-09 18:31Z"}},
        }
    )


def test_published_schedule_time_differs():
    result = status.published(PENDING, published_leg("2027-09-09 13:40Z"))
    assert result.push and result.title == "UA 456 times confirmed"
    assert result.body == "Your flight on Sep 9 leaves at 9:40 AM, not 8:00 AM. We'll forecast for the new time."
    assert result.update["departure_at"] == "2027-09-09T13:40:00+00:00" and not result.update["schedule_pending"]
    small = status.published(PENDING, published_leg("2027-09-09 12:05Z"))
    assert not small.push
    assert small.note == ["Schedule published. UA 456 leaves at 8:05 AM, not 8:00 AM. Your forecast will use 8:05 AM."]


def test_published_schedule_airport_differs_or_matches():
    result = status.published(PENDING, published_leg("2027-09-09 12:00Z", origin="KEWR"))
    assert result.push and result.title == "UA 456 details confirmed"
    assert result.note == ["Schedule published. UA 456 flies from EWR, not JFK. Your forecast will use EWR."]
    same = status.published(PENDING, published_leg("2027-09-09 12:00Z"))
    assert not same.push
    assert same.note == ["Schedule published. It matches what you entered. Arrives 11:31 AM."]


# The worker loop, against fakes


class FakeData:
    def __init__(self, found: list[flightdata.Leg]):
        self.found, self.calls = found, []

    def legs(self, number: str, day: date):
        self.calls.append((number, day))
        return self.found


class FakeDB:
    def __init__(self, flights, pro=True):
        self.flights, self.pro = flights, pro
        self.statuses, self.forecasts, self.notifications, self.flight_updates = [], [], [], []
        self.status_updates = []

    def flights_with_latest_forecast(self, now):
        return self.flights

    def upcoming_flights_with_latest_forecast(self, now):
        return self.flights

    def profiles(self, user_ids):
        return {u: {"user_id": u, "is_pro": self.pro, "timezone": "America/New_York"} for u in user_ids}

    def flights_with_passes(self, ids):
        return set()

    def devices(self, user_ids):
        return {}

    def notifications_for(self, ids):
        return {}

    def upsert_flight_status(self, row):
        self.statuses.append(row)

    def update_flight_status(self, flight_id, fields):
        self.status_updates.append(fields)

    def delete_flight_status(self, flight_id):
        pass

    def insert_forecast(self, flight_id, row):
        self.forecasts.append(row)

    def prune_forecasts(self, flight_id, keep_after):
        pass

    def forecast_for_departure(self, flight_id, departure, scheduled):
        return SMOOTH

    def insert_notification(self, row):
        self.notifications.append(row)
        return f"n{len(self.notifications)}"

    def update_notification(self, notification_id, delivered, error):
        self.notifications[int(notification_id[1:]) - 1]["error"] = error

    def pending_schedules(self, now):
        return self.flights

    def update_flight(self, flight_id, fields):
        self.flight_updates.append(fields)

    def held_notifications(self, error, since):
        return []


def test_run_once_refreshes_status_and_forecasts_the_new_departure(monkeypatch):
    now = datetime.now(UTC)
    departure = now + timedelta(hours=3)
    fixture = json.loads(json.dumps(FIXTURE))
    fixture[0]["departure"]["scheduledTime"]["utc"] = departure.strftime("%Y-%m-%d %H:%MZ")
    fixture[0]["departure"]["revisedTime"]["utc"] = (departure + timedelta(minutes=40)).strftime("%Y-%m-%d %H:%MZ")
    flight = {
        **FLIGHT,
        "departure_at": departure.replace(second=0, microsecond=0).isoformat(),
        "forecasts": [{"issued_at": now.isoformat(), "status": "ready", "departure_at": None}],
        "status": None,
    }
    computed = []
    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: [])
    monkeypatch.setattr(
        smooth_worker.forecast, "compute", lambda o, d, dep, now, sources, *rest: computed.append(dep) or smooth_worker.forecast.Forecast("ready")
    )
    db, data = FakeDB([flight]), FakeData([flightdata.parse_leg(f) for f in fixture])

    smooth_worker.run_once(db, data)

    assert data.calls == [("B6 23", departure.astimezone(smooth_worker.ZoneInfo("America/New_York")).date())]
    assert db.statuses[0]["status"] == "delayed" and db.statuses[0]["delay_min"] == 40
    expected = departure.replace(second=0, microsecond=0) + timedelta(minutes=40)
    assert computed == [expected]
    assert db.forecasts[0]["departure_at"] == expected.isoformat()


def test_run_once_checks_status_for_free_users(monkeypatch):
    now = datetime.now(UTC)
    flight = {**FLIGHT, "departure_at": (now + timedelta(hours=3)).isoformat(), "forecasts": [], "status": None}
    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: [])
    monkeypatch.setattr(smooth_worker.forecast, "compute", lambda *a: smooth_worker.forecast.Forecast("ready"))
    db, data = FakeDB([flight], pro=False), FakeData(legs())
    smooth_worker.run_once(db, data)
    assert len(data.calls) == 1 and len(db.statuses) == 1  # live status is free


def test_delay_push_reaches_free_users():
    now = datetime.now(UTC).replace(hour=15)
    scheduled = now + timedelta(hours=6)
    expected = scheduled + timedelta(minutes=40)
    current = row(
        departure_scheduled=scheduled.isoformat(),
        departure_expected=expected.isoformat(),
        notified_departure=scheduled.isoformat(),
        checked_at=now.isoformat(),
    )
    new = {**SMOOTH, "id": "fc2", "departure_at": expected.isoformat()}
    db = FakeDB([{**FLIGHT, "departure_at": scheduled.isoformat(), "status": current, "forecasts": [new]}], pro=False)
    notify.run(db, None, now)
    delay = [n for n in db.notifications if n["kind"] == "delay"]
    assert len(delay) == 1 and not delay[0]["pro_only"]


def test_every_15_minutes_in_the_last_3_hours():
    checked = row(checked_at=(SCHEDULED - timedelta(hours=2, minutes=20)).isoformat())
    assert not status.is_due(checked, SCHEDULED, SCHEDULED - timedelta(hours=2, minutes=10))
    assert status.is_due(checked, SCHEDULED, SCHEDULED - timedelta(hours=2, minutes=5))
    after = row(checked_at=(SCHEDULED + timedelta(minutes=30)).isoformat())
    assert status.is_due(after, SCHEDULED, SCHEDULED + timedelta(minutes=45))


def test_every_30_minutes_in_the_air_until_landing():
    flying = row(
        status="departed",
        takeoff_at=(SCHEDULED + timedelta(minutes=20)).isoformat(),
        arrival_expected=(SCHEDULED + timedelta(hours=5)).isoformat(),
        checked_at=(SCHEDULED + timedelta(minutes=70)).isoformat(),
    )
    assert not status.is_due(flying, SCHEDULED, SCHEDULED + timedelta(minutes=90), watching=True)
    assert status.is_due(flying, SCHEDULED, SCHEDULED + timedelta(minutes=100), watching=True)  # past an hour
    assert status.is_due(flying, SCHEDULED, SCHEDULED + timedelta(hours=5, minutes=10), watching=True)
    assert not status.is_due(flying, SCHEDULED, SCHEDULED + timedelta(hours=5, minutes=31), watching=True)


def test_takeoff_watch_checks_every_poll_near_departure():
    checked = row(checked_at=(SCHEDULED - timedelta(minutes=25)).isoformat())
    now = SCHEDULED - timedelta(minutes=20)
    assert not status.is_due(checked, SCHEDULED, now)  # hourly without a Live Activity
    assert status.is_due(checked, SCHEDULED, now, watching=True)
    landed = {**checked, "takeoff_at": SCHEDULED.isoformat()}
    assert not status.is_due(landed, SCHEDULED, now, watching=True)  # wheels-up known: back to normal
    # No runway time ever (some airports): the watch ends an hour after the gate departure.
    taxi = row(status="departed", checked_at=(SCHEDULED + timedelta(minutes=50)).isoformat())
    assert status.is_due(taxi, SCHEDULED, SCHEDULED + timedelta(minutes=55), watching=True)
    taxi = row(status="departed", checked_at=(SCHEDULED + timedelta(minutes=65)).isoformat())
    assert not status.is_due(taxi, SCHEDULED, SCHEDULED + timedelta(minutes=70), watching=True)


def test_delay_push_once_with_the_new_forecast():
    now = datetime.now(UTC).replace(hour=15)  # 11 AM in New York: not quiet hours
    scheduled = now + timedelta(hours=6)
    expected = scheduled + timedelta(minutes=40)
    current = row(
        departure_scheduled=scheduled.isoformat(),
        departure_expected=expected.isoformat(),
        notified_departure=scheduled.isoformat(),
        checked_at=now.isoformat(),
    )
    new = {**SMOOTH, "id": "fc2", "departure_at": expected.isoformat()}
    flight = {**FLIGHT, "departure_at": scheduled.isoformat(), "status": current, "forecasts": [new]}
    db = FakeDB([flight])
    notify.run(db, None, now)
    delay = [n for n in db.notifications if n["kind"] == "delay"]
    assert len(delay) == 1
    assert delay[0]["title"] == "Delayed 40 min"  # same forecast at the new time
    assert not delay[0]["pro_only"] and delay[0]["forecast_id"] == "fc2"
    assert db.status_updates == [{"notified_status": "delayed", "notified_departure": expected.isoformat()}]


def test_delay_push_waits_for_the_forecast_at_the_new_time():
    now = datetime.now(UTC).replace(hour=15)
    scheduled = now + timedelta(hours=6)
    current = row(
        departure_scheduled=scheduled.isoformat(),
        departure_expected=(scheduled + timedelta(minutes=40)).isoformat(),
        notified_departure=scheduled.isoformat(),
        checked_at=now.isoformat(),
    )
    old_forecast = {**SMOOTH, "id": "fc1", "departure_at": scheduled.isoformat()}
    db = FakeDB([{**FLIGHT, "departure_at": scheduled.isoformat(), "status": current, "forecasts": [old_forecast]}])
    notify.run(db, None, now)
    assert not [n for n in db.notifications if n["kind"] == "delay"]


def test_schedule_check_fills_in_the_flight():
    now = datetime(2027, 1, 10, 15, tzinfo=UTC)
    db, data = FakeDB([{**PENDING, "status": None}]), FakeData([published_leg("2027-09-09 13:40Z")])
    assert notify.check_schedules(db, data, None, now) == 1
    assert db.flight_updates[0]["departure_at"] == "2027-09-09T13:40:00+00:00"
    note = db.notifications[0]
    assert (note["kind"], note["milestone"], note["pro_only"]) == ("schedule", "schedule", False)
    # Checked today already: no lookup until tomorrow.
    data.calls.clear()
    db.flights = [{**PENDING, "status": {"checked_at": now.isoformat()}}]
    notify.check_schedules(db, data, None, now + timedelta(hours=3))
    assert data.calls == []


class FakeApns:
    def __init__(self):
        self.sent = []

    def send(self, token, environment, payload, collapse_id=None, push_type="alert", priority=None):
        self.sent.append((token, push_type, payload))
        return SendResult(True)


class PriorityApns(FakeApns):
    """An APNs client that can set the priority."""

    def __init__(self):
        super().__init__()
        self.priorities = []

    def send(self, token, environment, payload, collapse_id=None, push_type="alert", priority=None):
        self.priorities.append((push_type, priority))
        return super().send(token, environment, payload, collapse_id, push_type)


class TakeoffDB:
    def __init__(self, activities):
        self.activities, self.marked = activities, []

    def live_activities_to_retime(self, now):
        return self.activities

    def mark_live_activity(self, token, **fields):
        self.marked.append((token, fields))

    def devices(self, user_ids):
        return {u: [{"token": "dev", "environment": "sandbox"}] for u in user_ids}


TAKEOFF = SCHEDULED + timedelta(minutes=20)
PLAN = {
    "issued_at": "2026-10-22T10:20:56.123456+00:00",
    "status": "ready",
    "source": "gtg",
    "duration_min": 52,
    "segments": [
        {"start_min": 11, "end_min": 13, "severity": "light", "phase": "climb", "peak_edr": 0.12},
        {"start_min": 21, "end_min": 29, "severity": "light"},
    ],
}


def activity(**fields) -> dict:
    return {
        "token": "la",
        "flight_id": "f1",
        "user_id": "u1",
        "environment": "sandbox",
        "pushed_takeoff": None,
        "pushed_forecast_at": None,
        "flight": {"id": "f1", "origin": "KJFK", "status": {"takeoff_at": TAKEOFF.isoformat()}, "forecasts": [PLAN]},
        **fields,
    }


def apple(t: datetime) -> float:
    return (t - notify.APPLE_EPOCH).total_seconds()


def test_takeoff_pushed_once_to_the_live_activity_and_wakes_the_app():
    db, apns = TakeoffDB([activity()]), FakeApns()
    now = TAKEOFF + timedelta(minutes=5)
    assert notify.push_takeoffs(db, apns, now) == 1
    (token, kind, payload), (device, wake, woke) = apns.sent
    assert (token, kind, device, wake) == ("la", "liveactivity", "dev", "background")
    assert woke["kind"] == "takeoff"
    aps = payload["aps"]
    assert aps["alert"]["title"] == "Wheels up" and aps["event"] == "update"
    # The whole plan goes with the takeoff: a push replaces the activity's content state.
    assert aps["content-state"] == {
        "takeoff": apple(TAKEOFF),
        "updatedAt": apple(now),
        "durationMin": 52,
        "stretches": [
            {"startMin": 11, "endMin": 13, "severity": "light", "phase": "climb"},
            {"startMin": 21, "endMin": 29, "severity": "light", "phase": "cruise"},
        ],
        "confidenceTitle": "Confirmed forecast",
        "issuedAt": apple(datetime(2026, 10, 22, 10, 20, 56, 123456, tzinfo=UTC)),
    }
    # Re-rendered when the first stretch starts, 11 minutes after takeoff.
    assert aps["stale-date"] == int((TAKEOFF + timedelta(minutes=11)).timestamp())
    assert db.marked == [("la", {"pushed_takeoff": TAKEOFF.isoformat(), "pushed_forecast_at": PLAN["issued_at"]})]

    pushed = activity(pushed_takeoff=TAKEOFF.isoformat(), pushed_forecast_at=PLAN["issued_at"])
    assert notify.push_takeoffs(TakeoffDB([pushed]), FakeApns(), TAKEOFF + timedelta(minutes=10)) == 0
    # The airline revising its runway time moves the countdown without another alert.
    revised = activity(pushed_takeoff=(TAKEOFF - timedelta(minutes=1)).isoformat(), pushed_forecast_at=PLAN["issued_at"])
    apns = FakeApns()
    assert notify.push_takeoffs(TakeoffDB([revised]), apns, TAKEOFF + timedelta(minutes=10)) == 1
    assert "alert" not in apns.sent[0][2]["aps"]
    assert apns.sent[0][2]["aps"]["content-state"]["takeoff"] == apple(TAKEOFF)


def test_takeoff_without_a_forecast_sends_only_the_time():
    bare = activity()
    bare["flight"] = {**bare["flight"], "forecasts": []}
    db, apns = TakeoffDB([bare]), FakeApns()
    now = TAKEOFF + timedelta(minutes=5)
    assert notify.push_takeoffs(db, apns, now) == 1
    aps = apns.sent[0][2]["aps"]
    assert aps["content-state"] == {"takeoff": apple(TAKEOFF), "updatedAt": apple(now)}
    assert "stale-date" not in aps
    assert db.marked == [("la", {"pushed_takeoff": TAKEOFF.isoformat()})]


def test_no_push_for_a_takeoff_still_ahead_or_long_past():
    assert notify.push_takeoffs(TakeoffDB([activity()]), FakeApns(), TAKEOFF - timedelta(minutes=1)) == 0
    assert notify.push_takeoffs(TakeoffDB([activity()]), FakeApns(), TAKEOFF + timedelta(hours=3)) == 0


def test_a_newer_forecast_reaches_the_activity_quietly():
    newer = {
        **PLAN,
        "issued_at": "2026-10-22T11:35:00+00:00",
        "source": "mixed",
        "segments": [{"start_min": 30, "end_min": 40, "severity": "moderate", "phase": "cruise"}],
    }
    pushed = activity(pushed_takeoff=TAKEOFF.isoformat(), pushed_forecast_at=PLAN["issued_at"])
    pushed["flight"] = {**pushed["flight"], "forecasts": [newer]}
    db, apns = TakeoffDB([pushed]), PriorityApns()
    now = TAKEOFF + timedelta(minutes=35)
    assert notify.push_takeoffs(db, apns, now) == 1
    (_, kind, payload), (_, wake, woke) = apns.sent
    assert (kind, wake, woke["kind"]) == ("liveactivity", "background", "plan")
    aps = payload["aps"]
    assert "alert" not in aps  # no sound or banner: only the Lock Screen changes
    assert apns.priorities[0] == ("liveactivity", 5)
    state = aps["content-state"]
    assert state["takeoff"] == apple(TAKEOFF) and state["confidenceTitle"] == "Partly confirmed"
    assert state["stretches"] == [{"startMin": 30, "endMin": 40, "severity": "moderate", "phase": "cruise"}]
    assert aps["stale-date"] == int((TAKEOFF + timedelta(minutes=41)).timestamp())  # the stretch ends
    assert db.marked == [("la", {"pushed_forecast_at": "2026-10-22T11:35:00+00:00"})]
    # Sent once, and not after landing.
    marked = {**pushed, "pushed_forecast_at": newer["issued_at"]}
    assert notify.push_takeoffs(TakeoffDB([marked]), FakeApns(), now) == 0
    assert notify.push_takeoffs(TakeoffDB([pushed]), FakeApns(), TAKEOFF + timedelta(minutes=53)) == 0


def test_plain_apns_clients_still_get_the_plan():
    pushed = activity(pushed_takeoff=TAKEOFF.isoformat())  # its takeoff went out before plans did
    apns = FakeApns()
    assert notify.push_takeoffs(TakeoffDB([pushed]), apns, TAKEOFF + timedelta(minutes=5)) == 1
    assert apns.sent[0][2]["aps"]["content-state"]["durationMin"] == 52


def test_confidence_title_matches_the_app():
    gtg, gfs = {"source": "gtg"}, {"source": "gfs"}
    assert notify.confidence_title({"sources": [gtg, gtg]}) == "Confirmed forecast"
    assert notify.confidence_title({"sources": [gtg, gfs]}) == "Partly confirmed"
    assert notify.confidence_title({"sources": [gfs], "source": "gtg"}) == "Advance forecast"
    # Older forecasts, without per-stretch sources.
    assert notify.confidence_title({"source": "gtg", "sources": []}) == "Confirmed forecast"
    assert notify.confidence_title({"source": "mixed"}) == "Partly confirmed"
    assert notify.confidence_title({"source": "gfs"}) == "Advance forecast"
    assert notify.confidence_title({"source": "gtg", "noaa_possible": False}) == "Global outlook"


def test_next_boundary_mirrors_the_activity():
    assert notify.next_boundary(PLAN, TAKEOFF, TAKEOFF - timedelta(minutes=3)) == TAKEOFF
    assert notify.next_boundary(PLAN, TAKEOFF, TAKEOFF + timedelta(minutes=12)) == TAKEOFF + timedelta(minutes=14)
    assert notify.next_boundary(PLAN, TAKEOFF, TAKEOFF + timedelta(minutes=31)) == TAKEOFF + timedelta(minutes=52)
    assert notify.next_boundary(None, TAKEOFF, TAKEOFF) is None


def test_past_the_watch_an_untracked_flight_is_checked_like_one_in_the_air():
    """The airline never marks it departed: every 30 minutes after the watch, not every 15."""
    with_arrival = {**FLIGHT, "arrival_at": "2026-10-22T17:41:00+00:00"}
    untracked = row(
        status="scheduled", departure_expected=None, delay_min=0, checked_at=(SCHEDULED + timedelta(hours=2)).isoformat()
    )
    assert status.check_interval(untracked, SCHEDULED, SCHEDULED + timedelta(hours=2), watching=True) == status.AIRBORNE_REFRESH
    assert not status.is_due(untracked, SCHEDULED, SCHEDULED + timedelta(hours=2, minutes=20), True, with_arrival)
    assert status.is_due(untracked, SCHEDULED, SCHEDULED + timedelta(hours=2, minutes=30), True, with_arrival)
    # Every poll during the watch, as before.
    assert status.check_interval(untracked, SCHEDULED, SCHEDULED + timedelta(minutes=50), watching=True) == status.TAKEOFF_REFRESH


def test_delay_push_with_a_kept_forecast_says_nothing_about_it():
    """The forecast couldn't be recomputed for the new time, so it was copied there: the push
    goes now, and never says the forecast was checked."""
    now = datetime.now(UTC).replace(hour=15)
    scheduled = now + timedelta(hours=6)
    expected = scheduled + timedelta(minutes=40)
    current = row(
        departure_scheduled=scheduled.isoformat(),
        departure_expected=expected.isoformat(),
        notified_departure=scheduled.isoformat(),
        checked_at=now.isoformat(),
    )
    copy = {**SMOOTH, "id": "fc2", "departure_at": expected.isoformat(), "retimed": True}
    db = FakeDB([{**FLIGHT, "departure_at": scheduled.isoformat(), "status": current, "forecasts": [copy]}])
    notify.run(db, None, now)
    [delay] = [n for n in db.notifications if n["kind"] == "delay"]
    assert delay["title"] == "Delayed 40 min"
    assert delay["body"] == f"B6 23 now leaves at {status.local_time(expected, 'KJFK')}."
    assert db.status_updates == [{"notified_status": "delayed", "notified_departure": expected.isoformat()}]


def test_the_pushed_plan_lands_when_the_app_says():
    """The airline's live arrival, when it's near ours, sets the plan's length either way, but an
    expected one never ends it before the last stretch (InFlight.airMinutes)."""
    live = {"takeoff_at": TAKEOFF.isoformat(), "live": True, "arrival_expected": (TAKEOFF + timedelta(minutes=62)).isoformat()}
    now = TAKEOFF + timedelta(minutes=5)
    assert notify.activity_state(PLAN, TAKEOFF, now, live)["durationMin"] == 62
    assert notify.landing(PLAN, TAKEOFF, live) == TAKEOFF + timedelta(minutes=62)
    assert notify.next_boundary(PLAN, TAKEOFF, TAKEOFF + timedelta(minutes=31), live) == TAKEOFF + timedelta(minutes=62)
    landed = {**live, "arrival_actual": (TAKEOFF + timedelta(minutes=58)).isoformat()}
    assert notify.duration_min(PLAN, TAKEOFF, landed) == 58
    # Earlier than ours: the airline's, but an expected arrival not before the last stretch (ends at 29).
    def at(minutes: int) -> str:
        return (TAKEOFF + timedelta(minutes=minutes)).isoformat()
    assert notify.duration_min(PLAN, TAKEOFF, {**live, "arrival_expected": at(40)}) == 40
    assert notify.duration_min(PLAN, TAKEOFF, {**live, "arrival_expected": at(20)}) == 29
    assert notify.duration_min(PLAN, TAKEOFF, {**live, "arrival_actual": at(20)}) == 20
    # Not live, or too far off: the plan's own length.
    for other in (
        {**live, "live": False},
        {**live, "arrival_expected": (TAKEOFF + timedelta(minutes=52 + 120)).isoformat()},
        None,
    ):
        assert notify.duration_min(PLAN, TAKEOFF, other) == 52, other

    # Through a push: the plan still goes after our profile's landing, until the airline's.
    newer = {**PLAN, "issued_at": "2026-10-22T11:35:00+00:00"}
    pushed = activity(pushed_takeoff=TAKEOFF.isoformat(), pushed_forecast_at=PLAN["issued_at"])
    pushed["flight"] = {**pushed["flight"], "status": live, "forecasts": [newer]}
    apns = FakeApns()
    assert notify.push_takeoffs(TakeoffDB([pushed]), apns, TAKEOFF + timedelta(minutes=55)) == 1
    assert apns.sent[0][2]["aps"]["content-state"]["durationMin"] == 62
    assert notify.push_takeoffs(TakeoffDB([pushed]), FakeApns(), TAKEOFF + timedelta(minutes=62)) == 0


def test_a_global_outlook_says_which_stretches_are_outlook():
    """Like the app's Stretch.outlook: by the stretch's middle minute, only on a global outlook."""
    sources = [{"start_min": 0, "end_min": 20, "source": "gtg"}, {"start_min": 21, "end_min": 52, "source": "gfs"}]
    outlook = {**PLAN, "noaa_possible": False, "sources": sources}
    stretches = notify.activity_state(outlook, TAKEOFF, TAKEOFF, None)["stretches"]
    assert [s["outlook"] for s in stretches] == [False, True]
    assert all("outlook" not in s for s in notify.activity_state(PLAN, TAKEOFF, TAKEOFF, None)["stretches"])
    no_sources = {**PLAN, "noaa_possible": False}
    assert [s["outlook"] for s in notify.activity_state(no_sources, TAKEOFF, TAKEOFF, None)["stretches"]] == [True, True]


def test_an_activity_registered_late_still_gets_the_plan_quietly():
    """Its token reached the worker hours after wheels-up: no 'Wheels up', but the plan goes."""
    late = activity()
    late["flight"] = {**late["flight"], "forecasts": [{**PLAN, "duration_min": 300}]}
    db, apns = TakeoffDB([late]), FakeApns()
    assert notify.push_takeoffs(db, apns, TAKEOFF + timedelta(hours=3)) == 1
    (_, kind, payload), (_, _, woke) = apns.sent
    assert kind == "liveactivity" and woke["kind"] == "plan"
    assert "alert" not in payload["aps"] and payload["aps"]["content-state"]["takeoff"] == apple(TAKEOFF)
    assert db.marked == [("la", {"pushed_takeoff": TAKEOFF.isoformat(), "pushed_forecast_at": PLAN["issued_at"]})]
    sent = activity(pushed_takeoff=TAKEOFF.isoformat(), pushed_forecast_at=PLAN["issued_at"])
    sent["flight"] = late["flight"]
    assert notify.push_takeoffs(TakeoffDB([sent]), FakeApns(), TAKEOFF + timedelta(hours=3, minutes=5)) == 0


def test_wheels_up_is_said_once_per_flight_and_never_after_landing():
    # (a) A new activity for the flight (a restarted one, or one carried to the flight saved again
    # under a new id): its countdown is re-timed, but quietly.
    replaced = activity(token="la2")
    replaced["flight"] = {**replaced["flight"], "activities": [{"pushed_takeoff": TAKEOFF.isoformat()}, {"pushed_takeoff": None}]}
    db, apns = TakeoffDB([replaced]), FakeApns()
    assert notify.push_takeoffs(db, apns, TAKEOFF + timedelta(minutes=5)) == 1
    aps = apns.sent[0][2]["aps"]
    assert "alert" not in aps and aps["content-state"]["takeoff"] == apple(TAKEOFF)
    assert db.marked == [("la2", {"pushed_takeoff": TAKEOFF.isoformat(), "pushed_forecast_at": PLAN["issued_at"]})]
    # A flight saved after it took off: the app knew it was in the air.
    saved_late = activity()
    saved_late["flight"] = {**saved_late["flight"], "created_at": (TAKEOFF + timedelta(minutes=22)).isoformat()}
    apns = FakeApns()
    assert notify.push_takeoffs(TakeoffDB([saved_late]), apns, TAKEOFF + timedelta(minutes=25)) == 1
    assert "alert" not in apns.sent[0][2]["aps"]
    saved_before = activity()
    saved_before["flight"] = {**saved_before["flight"], "created_at": (TAKEOFF - timedelta(hours=5)).isoformat()}
    apns = FakeApns()
    assert notify.push_takeoffs(TakeoffDB([saved_before]), apns, TAKEOFF + timedelta(minutes=5)) == 1
    assert apns.sent[0][2]["aps"]["alert"]["title"] == "Wheels up"
    # (b) A token that first reaches the worker at the arrival gate gets nothing: the plan has
    # landed, or the airline says it has (with no plan to tell).
    assert notify.push_takeoffs(TakeoffDB([activity()]), FakeApns(), TAKEOFF + timedelta(minutes=55)) == 0
    bare = activity()
    bare["flight"] = {
        **bare["flight"],
        "forecasts": [],
        "status": {"takeoff_at": TAKEOFF.isoformat(), "arrival_actual": (TAKEOFF + timedelta(minutes=50)).isoformat()},
    }
    assert notify.push_takeoffs(TakeoffDB([bare]), FakeApns(), TAKEOFF + timedelta(minutes=51)) == 0


def test_a_flight_the_airline_didnt_have_is_looked_up_until_it_lands():
    """Saved 2 h into a 6 h flight; the one check found nothing. It still gets its forecast,
    and is looked up again until the schedule (else its forecast) says it lands."""
    departs = SCHEDULED
    now = departs + timedelta(hours=2)
    missing = {"flight_id": "f1", "checked_at": (now - timedelta(minutes=31)).isoformat()}
    with_arrival = {**FLIGHT, "arrival_at": (departs + timedelta(hours=6)).isoformat()}
    assert status.ends(with_arrival, missing, departs) == departs + timedelta(hours=6, minutes=30)
    assert status.is_due(missing, departs, now, True, with_arrival)
    assert not status.is_due(missing, departs, departs + timedelta(hours=6, minutes=31), True, with_arrival)
    # No arrival known: its forecast's landing (departure, taxi, then the flight time).
    forecast = {"issued_at": now.isoformat(), "status": "ready", "departure_at": departs.isoformat(), "duration_min": 345}
    forecast_only = {**FLIGHT, "forecasts": [forecast]}
    assert status.ends(forecast_only, missing, departs) == departs + timedelta(minutes=15 + 345 + 30)
    assert status.is_due(missing, departs, now, True, forecast_only)
    # Nothing to go on: an hour after departure, as before. The first forecast still goes by the
    # schedule alone, as if nothing had been looked up.
    assert status.ends(FLIGHT, missing, departs) == departs + timedelta(hours=1, minutes=30)
    assert status.forecast_ends(FLIGHT, missing, departs) == status.ends(FLIGHT, None, departs)
    found = {"status": "departed", "arrival_actual": (departs + timedelta(hours=1)).isoformat()}
    assert status.forecast_ends(FLIGHT, found, departs) == status.ends(FLIGHT, found, departs)


def test_wheels_up_alert_once_per_trip():
    from smooth_worker.notify import wheels_up_alert

    takeoff = datetime(2026, 10, 22, 18, 53, tzinfo=UTC)
    flight = {"created_at": "2026-10-18T20:41:50+00:00", "activities": []}
    assert wheels_up_alert({"flight": flight}, takeoff)
    # Another activity already alerted for this trip (a replaced activity, or a revised runway time).
    same = {**flight, "activities": [{"pushed_takeoff": "2026-10-22T18:50:00+00:00"}]}
    assert not wheels_up_alert({"flight": same}, takeoff)
    # The flight was flown before and edited to a later date: the old trip's alert doesn't count.
    earlier = {**flight, "activities": [{"pushed_takeoff": "2026-10-19T16:20:00+00:00"}]}
    assert wheels_up_alert({"flight": earlier}, takeoff)
    # Saved after it took off: the app already knew it was in the air.
    assert not wheels_up_alert({"flight": {**flight, "created_at": "2026-10-22T19:14:56+00:00"}}, takeoff)
