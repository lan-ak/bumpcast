"""What the worker asks Supabase for, checked against a fake PostgREST."""

import json
from datetime import UTC, datetime, timedelta

import httpx

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
