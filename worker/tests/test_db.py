"""What the worker asks Supabase for, checked against a fake PostgREST."""

import json
from datetime import UTC, datetime, timedelta

import httpx

from smooth_worker import status
from smooth_worker.db import Database

NOW = datetime(2026, 10, 23, 17, tzinfo=UTC)


def database(handler) -> Database:
    db = Database("https://example.supabase.co", "service-key")
    db.http = httpx.Client(base_url="https://example.supabase.co/rest/v1", transport=httpx.MockTransport(handler))
    return db


def test_flights_stay_in_play_until_the_longest_flights_land():
    """Status is checked until landing: a 16 h flight, or a long one delayed, is still polled."""
    asked = []

    def handler(request):
        asked.append(request.url.params)
        return httpx.Response(200, json=[])

    db = database(handler)
    db.flights_with_latest_forecast(NOW)
    db.new_flights_without_forecast(NOW, timedelta(minutes=30))
    db.upcoming_flights_with_latest_forecast(NOW)
    db.live_activities_to_retime(NOW)
    day_ago = (NOW - timedelta(hours=24)).isoformat()
    assert asked[0]["departure_at"] == f"gte.{day_ago}"
    assert asked[1]["departure_at"] == f"gte.{day_ago}"
    assert asked[2]["and"].startswith(f"(departure_at.gte.{day_ago},")
    # Live Activities end 8 hours after they start.
    assert asked[3]["flight.departure_at"] == f"gte.{(NOW - timedelta(hours=12)).isoformat()}"
    assert "retimed" in asked[0]["select"] and "retimed" in asked[2]["select"]
    # A flight the airline didn't have is looked up until its forecast says it lands.
    assert "duration_min" in asked[0]["select"]
    # "Wheels up" once per flight: when it was saved, and what its other activities were sent.
    assert "created_at" in asked[3]["select"] and "activities:live_activities(pushed_takeoff)" in asked[3]["select"]


def test_old_status_is_purged_by_age_finished_or_not():
    """The flight data allows no permanent copies: status goes 6 days after its last check, including
    rows that were never marked finished."""
    asked = []

    def handler(request):
        asked.append(request)
        return httpx.Response(200, json=[{"flight_id": "a"}, {"flight_id": "b"}])

    deleted = database(handler).prune_flight_status(NOW - status.KEEP)
    [request] = asked
    assert request.method == "DELETE" and request.url.path.endswith("/flight_status")
    assert request.url.params["checked_at"] == f"lt.{(NOW - timedelta(days=6)).isoformat()}"
    assert "finished" not in request.url.params
    assert deleted == 2


def test_a_kept_forecast_copied_to_a_delay_is_marked_retimed():
    original = {
        "id": "f1",
        "flight_id": "a",
        "issued_at": "2026-10-23T16:55:00.123456+00:00",
        "status": "ready",
        "source": "gtg",
        "departure_at": "2026-10-23T18:00:00+00:00",
        "retimed": False,
        "segments": [],
    }
    posted = []

    def handler(request):
        if request.method == "GET":
            return httpx.Response(200, json=[original])
        posted.append(json.loads(request.content))
        return httpx.Response(201)

    delayed = datetime(2026, 10, 23, 18, 40, tzinfo=UTC)
    database(handler).retime_forecast("f1", delayed)
    [row] = posted
    assert "id" not in row and row["flight_id"] == "a" and row["source"] == "gtg"
    assert row["retimed"] is True and row["departure_at"] == delayed.isoformat()
    assert row["issued_at"] == "2026-10-23T16:55:00.124456+00:00"  # just after: the latest


def test_only_verified_passes_count():
    """Notifications count a pass once Apple confirmed it; before the migration, every pass."""
    asked = []

    def handler(request):
        asked.append(request.url.params)
        return httpx.Response(200, json=[{"flight_id": "f1"}])

    assert database(handler).flights_with_passes(["f1", "f2"]) == {"f1"}
    assert asked[0]["verified_at"] == "not.is.null"

    asked.clear()

    def old_database(request):
        asked.append(request.url.params)
        if "verified_at" in request.url.params:
            return httpx.Response(400, json={"code": "42703", "message": "column flight_passes.verified_at does not exist"})
        return httpx.Response(200, json=[{"flight_id": "f2"}])

    assert database(old_database).flights_with_passes(["f2"]) == {"f2"}
    assert "verified_at" not in asked[-1]
    assert database(old_database).passes_waiting() is False


def test_waiting_passes_go_to_the_verify_function():
    """Passes apps up to 1.0.3 saved themselves are handed to verify-pass, with the service key."""
    calls = []

    def handler(request):
        calls.append(request)
        if request.url.path.endswith("/flight_passes"):
            return httpx.Response(200, json=[{"transaction_id": "2000001"}])
        return httpx.Response(200, json={"verified": 1, "rejected": 0, "unavailable": 0})

    db = Database("https://example.supabase.co", "service-key")
    db.http = httpx.Client(
        base_url="https://example.supabase.co/rest/v1",
        headers={"Authorization": "Bearer service-key"},
        transport=httpx.MockTransport(handler),
    )
    assert db.passes_waiting()
    waiting = calls[0].url.params
    assert (waiting["verified_at"], waiting["rejected_at"]) == ("is.null", "is.null")
    assert db.verify_passes() == {"verified": 1, "rejected": 0, "unavailable": 0}
    sweep = calls[1]
    assert str(sweep.url) == "https://example.supabase.co/functions/v1/verify-pass"
    assert json.loads(sweep.content) == {"sweep": True}
    assert sweep.headers["Authorization"] == "Bearer service-key"
