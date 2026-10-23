"""A flight's GTG forecast is never replaced by one with less GTG (an outlook only, or an older
run) while the run it came from still reaches the departure. On 2026-10-22 a fresh worker with
nothing decoded and a throttled NOMADS listing swapped AC 1507's confirmed light forecast for a
GFS-only 'bumpy' one, 75 minutes before departure."""

import logging
from datetime import UTC, datetime, timedelta

import pytest

import smooth_worker
from smooth_worker import forecast, gtg, run_new_flights, run_once, store_forecast


@pytest.fixture(autouse=True)
def fresh_state(monkeypatch):
    # The weather inputs are cached across calls; each test starts without them.
    monkeypatch.setattr(smooth_worker, "_shared_inputs", None)
    smooth_worker.forecast_issued.clear()
    smooth_worker.outlook_tried.clear()
    yield
    smooth_worker.forecast_issued.clear()
    smooth_worker.outlook_tried.clear()


class FakeDb:
    def __init__(self, flights):
        self.flights = flights
        self.inserted: list[tuple[str, dict]] = []
        self.retimed: list[tuple[str, datetime]] = []

    def flights_with_latest_forecast(self, now):
        return self.flights

    def new_flights_without_forecast(self, now, lookback):
        return [f for f in self.flights if not f.get("forecasts")]

    def insert_forecast(self, flight_id, row):
        self.inserted.append((flight_id, row))

    def prune_forecasts(self, flight_id, keep_after):
        pass

    def retime_forecast(self, forecast_id, departure):
        self.retimed.append((forecast_id, departure))


NOW = datetime.now(UTC)
DEPARTURE = (NOW + timedelta(hours=2)).replace(microsecond=0)


def confirmed(source="gtg", run_ago=timedelta(hours=3), departure=DEPARTURE) -> dict:
    return {
        "id": "f1",
        "status": "ready",
        "source": source,
        "model_run": (NOW - run_ago).isoformat(),
        "issued_at": (NOW - timedelta(minutes=70)).isoformat(),
        "departure_at": departure.isoformat(),
    }


def flight(forecasts: list[dict], departure=DEPARTURE) -> dict:
    return {
        "id": "a",
        "origin": "KEWR",
        "destination": "CYYZ",
        "departure_at": departure.isoformat(),
        "updated_at": (NOW - timedelta(days=1)).isoformat(),
        "flight_number": None,
        "forecasts": forecasts,
        "status": None,
    }


def result(source: str, run_ago: timedelta, grade="bumpy") -> forecast.Forecast:
    return forecast.Forecast(status="ready", source=source, model_run=NOW - run_ago, grade=grade)


@pytest.fixture
def compute(monkeypatch):
    """Make forecast.compute return what the test sets in `compute.result`."""
    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: ["source"])

    class Compute:
        result = None

        def __call__(self, *args):
            return self.result

    fake = Compute()
    monkeypatch.setattr(forecast, "compute", fake)
    return fake


def test_gfs_only_never_replaces_gtg(compute):
    db = FakeDb([flight([confirmed()])])
    compute.result = result("gfs", timedelta(hours=6))
    assert run_once(db) == 0
    assert db.inserted == [] and db.retimed == []
    compute.result = result("gtg", timedelta(hours=1), grade="some_bumps")  # GTG is back
    assert run_once(db) == 1
    [(flight_id, row)] = db.inserted
    assert flight_id == "a" and row["source"] == "gtg"


def test_mixed_is_protected_too(compute):
    db = FakeDb([flight([confirmed(source="mixed")])])
    compute.result = result("gfs", timedelta(hours=6))
    assert run_once(db) == 0 and db.inserted == []


def test_older_gtg_run_never_replaces_newer(compute):
    db = FakeDb([flight([confirmed(run_ago=timedelta(hours=3))])])
    compute.result = result("gtg", timedelta(hours=4))
    assert run_once(db) == 0 and db.inserted == []
    compute.result = result("gtg", timedelta(hours=3))  # the same run (say, for a new departure) is fine
    assert run_once(db) == 1


def test_outlook_allowed_once_the_delay_outruns_the_run(compute):
    departure = NOW + timedelta(hours=3)
    # The 17 h old run reaches NOW + 1 h, short of the departure: only the outlook is left.
    db = FakeDb([flight([confirmed(run_ago=timedelta(hours=17), departure=departure)], departure=departure)])
    compute.result = result("gfs", timedelta(hours=6))
    assert run_once(db) == 1
    assert db.inserted[0][1]["source"] == "gfs"


def test_first_forecast_may_be_an_outlook(compute):
    db = FakeDb([flight([])])
    compute.result = result("gfs", timedelta(hours=6))
    assert run_once(db) == 1
    assert run_new_flights(FakeDb([flight([])]), {}) == 1


def test_only_ready_gtg_forecasts_are_protected(compute):
    compute.result = result("gfs", timedelta(hours=6))
    for previous in ({**confirmed(), "status": "too_early"}, {**confirmed(), "source": "gfs"}, {**confirmed(), "model_run": None}):
        db = FakeDb([flight([previous])])
        assert run_once(db) == 1, previous


def test_kept_forecast_moves_with_a_delay(compute):
    delayed = DEPARTURE + timedelta(minutes=20)
    previous = confirmed()
    db = FakeDb([])
    compute.result = result("gfs", timedelta(hours=6))
    inputs = smooth_worker.ForecastInputs(NOW)
    assert store_forecast(db, flight([previous]), delayed, NOW, inputs, previous) is False
    assert db.retimed == [("f1", delayed)] and db.inserted == []
    # Same departure: kept as it is.
    assert store_forecast(db, flight([previous]), DEPARTURE, NOW, inputs, previous) is False
    assert db.retimed == [("f1", delayed)] and db.inserted == []


def test_cold_start_without_gtg_keeps_the_confirmed_forecast(monkeypatch, tmp_path, caplog):
    """Nothing decoded yet and NOMADS throttling the listing: the real sources are GFS only."""
    from smooth_worker import gfs

    class OutlookStub:
        name = "gfs"

        def __init__(self, cycle, cache_dir):
            self.cycle = cycle

        def covers(self, valid):
            return True

        def covers_point(self, lat, lon):
            return True

        def edr(self, lat, lon, altitude_ft, valid):
            return 0.3

    monkeypatch.setattr(smooth_worker, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(gtg, "latest_cycle", lambda now=None: None)
    monkeypatch.setattr(gfs, "latest_cycle", lambda now=None: datetime(2026, 10, 22, 12, tzinfo=UTC))
    monkeypatch.setattr(smooth_worker, "GfsSource", OutlookStub)
    db = FakeDb([flight([confirmed()])])
    with caplog.at_level(logging.WARNING, logger="smooth_worker"):
        assert run_once(db) == 0
    assert db.inserted == []
    messages = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert any("gtg: no run available" in m for m in messages)
    assert any("keeping its gtg forecast" in m and "got gfs bumpy" in m for m in messages)


def test_gtg_unavailable_keeps_the_forecast_quietly(monkeypatch, caplog):
    def throttled(*args):
        raise gtg.Unavailable("https://nomads.example/dafs.t14z.gtg.3km.conus.f004.grib2.idx", 302)

    monkeypatch.setattr(smooth_worker, "load_sources", lambda now: ["source"])
    monkeypatch.setattr(forecast, "compute", throttled)
    db = FakeDb([flight([confirmed()])])
    with caplog.at_level(logging.INFO):
        assert run_once(db) == 0
        failed: dict = {}
        assert run_new_flights(FakeDb([flight([])]), failed) == 0
    assert db.inserted == [] and "a" in failed
    assert [r for r in caplog.records if r.levelno == logging.WARNING]
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]


def test_an_unchanged_outlook_is_not_stored_again_while_gtg_is_out(compute, monkeypatch):
    """GTG unavailable: the early retry for a GFS-only forecast gets the same GFS run back. No
    new row, so its issued time stays put and the Live Activity isn't sent the plan again."""
    calls = []
    monkeypatch.setattr(forecast, "compute", lambda *args: calls.append(1) or compute.result)
    outlook = {**confirmed(source="gfs", run_ago=timedelta(hours=6)), "issued_at": (NOW - timedelta(minutes=15)).isoformat()}
    db = FakeDb([flight([outlook])])
    compute.result = result("gfs", timedelta(hours=6))
    assert run_once(db) == 0 and db.inserted == [] and len(calls) == 1
    assert run_once(db) == 0 and len(calls) == 1  # the next try waits the usual few minutes
    smooth_worker.outlook_tried["a"] = NOW - smooth_worker.OUTLOOK_RETRY
    compute.result = result("gtg", timedelta(hours=2))  # GTG is back
    assert run_once(db) == 1 and db.inserted[0][1]["source"] == "gtg"
    assert "a" not in smooth_worker.outlook_tried


def test_an_outlook_is_stored_when_it_changed_or_its_refresh_is_due(compute):
    outlook = {**confirmed(source="gfs", run_ago=timedelta(hours=6)), "issued_at": (NOW - timedelta(minutes=15)).isoformat()}
    compute.result = result("gfs", timedelta(hours=1))  # a newer GFS run
    db = FakeDb([flight([outlook])])
    assert run_once(db) == 1
    compute.result = result("gfs", timedelta(hours=6))
    hourly = {**outlook, "issued_at": (NOW - timedelta(minutes=61)).isoformat()}
    db = FakeDb([flight([hourly])])
    assert run_once(db) == 1  # the regular hourly refresh, as before
    edited = {**flight([outlook]), "updated_at": NOW.isoformat()}
    db = FakeDb([edited])
    assert run_once(db) == 1
