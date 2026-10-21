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


def test_takeoff_without_a_runway_time_adds_taxi():
    departed = status.build(leg(status="Departed"), FLIGHT, None, SCHEDULED + timedelta(minutes=45))
    assert departed["takeoff_at"] == "2026-10-22T12:10:00+00:00"  # 11:55 off the gate + 15 min
    assert status.build(leg(), FLIGHT, None, NOW)["takeoff_at"] is None


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


def test_status_finishes_an_hour_after_departure():
    row = status.build(leg(status="Departed"), FLIGHT, None, SCHEDULED + timedelta(hours=2))
    assert row["finished"]


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
    assert not status.is_due(None, SCHEDULED, SCHEDULED + timedelta(hours=2))  # long gone


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

    def flights_with_live_activities(self, ids):
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


def test_takeoff_watch_checks_every_poll_near_departure():
    checked = row(checked_at=(SCHEDULED - timedelta(minutes=25)).isoformat())
    now = SCHEDULED - timedelta(minutes=20)
    assert not status.is_due(checked, SCHEDULED, now)  # hourly without a Live Activity
    assert status.is_due(checked, SCHEDULED, now, watching=True)
    landed = {**checked, "takeoff_at": SCHEDULED.isoformat()}
    assert not status.is_due(landed, SCHEDULED, now, watching=True)  # wheels-up known: back to normal


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

    def send(self, token, environment, payload, collapse_id=None, push_type="alert"):
        self.sent.append((token, push_type, payload))
        return SendResult(True)


class TakeoffDB:
    def __init__(self, activities):
        self.activities, self.marked = activities, []

    def live_activities_to_retime(self, now):
        return self.activities

    def mark_live_activity(self, token, **fields):
        self.marked.append((token, fields))

    def devices(self, user_ids):
        return {u: [{"token": "dev", "environment": "sandbox"}] for u in user_ids}


def test_takeoff_pushed_once_to_the_live_activity_and_wakes_the_app():
    takeoff = SCHEDULED + timedelta(minutes=20)
    activity = {
        "token": "la",
        "flight_id": "f1",
        "user_id": "u1",
        "environment": "sandbox",
        "pushed_takeoff": None,
        "flight": {"id": "f1", "origin": "KJFK", "status": {"takeoff_at": takeoff.isoformat()}},
    }
    db, apns = TakeoffDB([activity]), FakeApns()
    assert notify.push_takeoffs(db, apns, takeoff + timedelta(minutes=5)) == 1
    (token, kind, payload), (device, wake, _) = apns.sent
    assert (token, kind, device, wake) == ("la", "liveactivity", "dev", "background")
    state = payload["aps"]["content-state"]
    assert state["takeoff"] == (takeoff - notify.APPLE_EPOCH).total_seconds()
    assert db.marked == [("la", {"pushed_takeoff": takeoff.isoformat()})]

    pushed = {**activity, "pushed_takeoff": takeoff.isoformat()}
    assert notify.push_takeoffs(TakeoffDB([pushed]), FakeApns(), takeoff + timedelta(minutes=10)) == 0
