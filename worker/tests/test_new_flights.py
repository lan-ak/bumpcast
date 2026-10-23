from datetime import UTC, datetime, timedelta

import pytest

import smooth_worker
from smooth_worker import forecast, run_new_flights


@pytest.fixture(autouse=True)
def fresh_inputs(monkeypatch):
    # The weather inputs are cached across calls; each test starts without them.
    monkeypatch.setattr(smooth_worker, "_shared_inputs", None)


class FakeDb:
    def __init__(self, flights):
        self.flights = flights
        self.forecasts: dict[str, dict] = {}
        self.queries = 0

    def new_flights_without_forecast(self, now, lookback):
        self.queries += 1
        return [f for f in self.flights if f["id"] not in self.forecasts]

    def insert_forecast(self, flight_id, row):
        self.forecasts[flight_id] = row

    def prune_forecasts(self, flight_id, keep_after):
        pass


def flight(id: str, departs_in: timedelta) -> dict:
    return {"id": id, "origin": "CYYZ", "destination": "KEWR", "departure_at": (datetime.now(UTC) + departs_in).isoformat()}


def test_nothing_new_takes_no_lock():
    db = FakeDb([])
    assert run_new_flights(db, {}) == 0
    assert db.queries == 1


def test_too_early_needs_no_weather():
    db = FakeDb([flight("a", timedelta(hours=60))])
    assert run_new_flights(db, {}) == 1
    assert db.forecasts["a"]["status"] == "too_early"


def test_forecast_within_window(monkeypatch):
    calls = []

    def compute(origin, destination, departure, now, sources, hazards):
        calls.append((origin.iata, destination.iata))
        return forecast.Forecast(status="ready", grade="some_bumps")

    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: ["source"])
    monkeypatch.setattr(forecast, "compute", compute)
    db = FakeDb([flight("a", timedelta(hours=10)), flight("b", timedelta(hours=30))])
    assert run_new_flights(db, {}) == 2
    assert calls == [("YYZ", "EWR"), ("YYZ", "EWR")]
    assert db.forecasts["a"]["grade"] == "some_bumps"


def test_inputs_are_shared_between_calls(monkeypatch):
    loads = []
    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: loads.append(now) or ["source"])
    monkeypatch.setattr(forecast, "compute", lambda *args: forecast.Forecast(status="ready", grade="smooth"))
    run_new_flights(FakeDb([flight("a", timedelta(hours=10))]), {})
    run_new_flights(FakeDb([flight("b", timedelta(hours=10))]), {})
    assert len(loads) == 1


def test_failed_flight_waits_before_retrying(monkeypatch):
    def broken(now):
        raise RuntimeError("NOMADS down")

    monkeypatch.setattr(smooth_worker, "load_sources", broken)
    db, failed = FakeDb([flight("a", timedelta(hours=10))]), {}
    assert run_new_flights(db, failed) == 0
    assert "a" in failed
    queries = db.queries
    assert run_new_flights(db, failed) == 0  # skipped: no lock, no weather
    assert db.queries == queries + 1


def test_poll_skips_a_flight_the_watcher_just_forecast():
    from smooth_worker import forecast_issued, run_once

    now = datetime.now(UTC)
    departs = (now + timedelta(hours=60)).isoformat()
    row = {"id": "a", "origin": "CYYZ", "destination": "KEWR", "departure_at": departs, "updated_at": departs, "forecasts": []}

    class PollDb(FakeDb):
        def flights_with_latest_forecast(self, now):
            return [row]

    db = PollDb([])
    forecast_issued["a"] = now + timedelta(minutes=1)  # the watcher finished after the poll started
    assert run_once(db) == 0
    assert "a" not in db.forecasts
    forecast_issued.clear()
    assert run_once(db) == 1


def test_the_poll_refreshes_inputs_for_the_watcher(monkeypatch):
    loads = []
    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: loads.append(now) or [])
    smooth_worker.refresh_inputs(datetime.now(UTC))
    monkeypatch.setattr(forecast, "compute", lambda *args: forecast.Forecast(status="ready", grade="smooth"))
    run_new_flights(FakeDb([flight("a", timedelta(hours=10))]), {})
    assert len(loads) == 1  # the watcher used what the poll loaded


def test_unchanged_runs_keep_the_warm_inputs(monkeypatch):
    class Source:
        name, cycle = "gfs", datetime(2026, 10, 22, 12, tzinfo=UTC)

    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: [Source()])
    smooth_worker.refresh_inputs(datetime.now(UTC))
    first = smooth_worker._shared_inputs
    smooth_worker.refresh_inputs(datetime.now(UTC) + timedelta(minutes=5))
    assert smooth_worker._shared_inputs is first


# Status first: a flight saved in the air (AC 1507, re-added 40 minutes after it left the gate)


class StatusDb(FakeDb):
    """Keeps status rows like the database, so the next query embeds them."""

    def __init__(self, flights):
        super().__init__(flights)
        self.statuses: dict[str, dict] = {}
        self.order: list[str] = []

    def new_flights_without_forecast(self, now, lookback):
        return [{**f, "status": self.statuses.get(f["id"])} for f in super().new_flights_without_forecast(now, lookback)]

    def upsert_flight_status(self, row):
        self.statuses[row["flight_id"]] = row
        self.order.append("status")

    def insert_forecast(self, flight_id, row):
        super().insert_forecast(flight_id, row)
        self.order.append("forecast")


class FakeData:
    def __init__(self, legs):
        self.found, self.calls = legs, 0

    def legs(self, number, day):
        self.calls += 1
        return self.found


def in_the_air(now: datetime):
    from smooth_worker import flightdata

    def utc(t: datetime) -> dict:
        return {"utc": t.strftime("%Y-%m-%d %H:%MZ")}

    scheduled = (now - timedelta(minutes=40)).replace(second=0, microsecond=0)
    leg = flightdata.parse_leg(
        {
            "number": "AC 1507",
            "status": "EnRoute",
            "departure": {
                "airport": {"icao": "KEWR"},
                "scheduledTime": utc(scheduled),
                "revisedTime": utc(scheduled - timedelta(minutes=2)),
                "runwayTime": utc(scheduled + timedelta(minutes=18)),
            },
            "arrival": {"airport": {"icao": "CYYZ"}, "scheduledTime": utc(scheduled + timedelta(minutes=90))},
        }
    )
    row = {
        "id": "re-added",
        "origin": "KEWR",
        "destination": "CYYZ",
        "departure_at": scheduled.isoformat(),
        "arrival_at": (scheduled + timedelta(minutes=90)).isoformat(),
        "flight_number": "AC 1507",
    }
    return row, leg, scheduled


def test_new_flight_gets_its_status_before_its_forecast(monkeypatch):
    now = datetime.now(UTC)
    row, leg, scheduled = in_the_air(now)
    computed = []
    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: ["source"])
    monkeypatch.setattr(
        forecast, "compute", lambda o, d, departure, *rest: computed.append(departure) or forecast.Forecast("ready")
    )
    db, data = StatusDb([row]), FakeData([leg])
    assert run_new_flights(db, {}, data) == 1
    assert db.order == ["status", "forecast"]
    status_row = db.statuses["re-added"]
    assert status_row["status"] == "departed"
    assert status_row["takeoff_at"] == (scheduled + timedelta(minutes=18)).isoformat()  # wheels-up, within seconds
    # The forecast is for when it really left the gate, not the schedule.
    assert computed == [scheduled - timedelta(minutes=2)]
    assert db.forecasts["re-added"]["departure_at"] == (scheduled - timedelta(minutes=2)).isoformat()


def test_status_is_fetched_once_even_if_the_forecast_waits(monkeypatch):
    now = datetime.now(UTC)
    row, leg, _ = in_the_air(now)

    def broken(now):
        raise RuntimeError("NOMADS down")

    monkeypatch.setattr(smooth_worker, "load_sources", broken)
    monkeypatch.setattr(smooth_worker, "NEW_FLIGHT_RETRY", timedelta(0))  # retry at once
    db, data = StatusDb([row]), FakeData([leg])
    assert run_new_flights(db, {}, data) == 0
    assert run_new_flights(db, {}, data) == 0
    assert data.calls == 1  # just checked: the second pass reuses it


def test_a_failed_status_still_forecasts_the_schedule(monkeypatch):
    now = datetime.now(UTC)
    row, _, scheduled = in_the_air(now)

    class Down(FakeData):
        def legs(self, number, day):
            raise RuntimeError("provider down")

    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: ["source"])
    monkeypatch.setattr(forecast, "compute", lambda *args: forecast.Forecast("ready"))
    db = StatusDb([row])
    assert run_new_flights(db, {}, Down([])) == 1
    assert db.forecasts["re-added"]["departure_at"] == scheduled.isoformat()


def test_a_landed_flight_gets_no_first_forecast():
    now = datetime.now(UTC)
    landed = {
        "id": "old",
        "origin": "KEWR",
        "destination": "CYYZ",
        "departure_at": (now - timedelta(hours=4)).isoformat(),
        "arrival_at": (now - timedelta(hours=2)).isoformat(),
    }
    db = FakeDb([landed])
    assert run_new_flights(db, {}) == 0 and db.forecasts == {}


def test_poll_forecasts_a_flight_saved_in_the_air(monkeypatch):
    from smooth_worker import run_once

    now = datetime.now(UTC)
    departs = now - timedelta(hours=2)
    row = {
        "id": "a",
        "origin": "KEWR",
        "destination": "KLAX",
        "departure_at": departs.isoformat(),
        "arrival_at": (departs + timedelta(hours=6)).isoformat(),
        "updated_at": departs.isoformat(),
        "flight_number": None,
        "forecasts": [],
    }

    class PollDb(FakeDb):
        def flights_with_latest_forecast(self, now):
            return [self.row]

    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: ["source"])
    monkeypatch.setattr(forecast, "compute", lambda *args: forecast.Forecast("ready"))
    db = PollDb([])
    db.row = row
    assert run_once(db) == 1 and "a" in db.forecasts
    # One that already has a forecast isn't recomputed in the air, nor is one that has landed.
    db.forecasts.clear()
    db.row = {**row, "forecasts": [{"issued_at": (now - timedelta(hours=3)).isoformat(), "status": "ready"}]}
    assert run_once(db) == 0
    db.row = {**row, "arrival_at": (now - timedelta(minutes=45)).isoformat()}
    assert run_once(db) == 0


def test_every_numbered_flight_is_watched_for_takeoff(monkeypatch):
    """No Live Activity needed: the 5-minute wheels-up watch runs for every numbered flight."""
    from smooth_worker import run_once

    now = datetime.now(UTC)
    departs = now - timedelta(minutes=5)
    checked = (now - timedelta(minutes=4)).isoformat()
    row = {
        "id": "a",
        "origin": "KEWR",
        "destination": "CYYZ",
        "departure_at": departs.isoformat(),
        "arrival_at": (departs + timedelta(minutes=90)).isoformat(),
        "updated_at": departs.isoformat(),
        "flight_number": "AC 1507",
        "forecasts": [{"issued_at": now.isoformat(), "status": "ready", "departure_at": departs.isoformat()}],
        "status": {"status": "scheduled", "checked_at": checked},
    }

    class PollDb(StatusDb):
        def flights_with_latest_forecast(self, now):
            return [row]

    _, leg, _ = in_the_air(now)
    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: ["source"])
    monkeypatch.setattr(forecast, "compute", lambda *args: forecast.Forecast("ready"))
    db, data = PollDb([]), FakeData([leg])
    run_once(db, data)
    assert data.calls == 1


@pytest.mark.parametrize("arrival_known", [True, False])
def test_a_flight_the_airline_didnt_have_still_gets_its_forecast_and_more_checks(monkeypatch, arrival_known):
    """Saved 2 h into a 6 h flight, and the one status check found nothing (a number typed by
    hand, or an empty answer): the schedule's forecast goes anyway, and status is checked again."""
    from smooth_worker import run_once

    now = datetime.now(UTC)
    departs = now - timedelta(hours=2)
    row = {
        "id": "a",
        "origin": "KEWR",
        "destination": "KLAX",
        "departure_at": departs.isoformat(),
        "arrival_at": (departs + timedelta(hours=6)).isoformat() if arrival_known else None,
        "flight_number": "AC 1507",
    }
    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: ["source"])
    monkeypatch.setattr(forecast, "compute", lambda *args: forecast.Forecast("ready", duration_min=345))
    db, data = StatusDb([row]), FakeData([])
    assert run_new_flights(db, {}, data) == 1
    assert data.calls == 1 and db.statuses["a"].get("status") is None and "a" in db.forecasts

    # Half an hour later, the poll looks it up again.
    checked = {**db.statuses["a"], "checked_at": (now - timedelta(minutes=31)).isoformat()}
    issued = {"issued_at": now.isoformat(), "status": "ready", "departure_at": departs.isoformat(), "duration_min": 345}
    polled = {**row, "updated_at": departs.isoformat(), "forecasts": [issued], "status": checked}

    class PollDb(StatusDb):
        def flights_with_latest_forecast(self, now):
            return [polled]

    data = FakeData([])
    run_once(PollDb([]), data)
    assert data.calls == 1
