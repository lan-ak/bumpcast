"""Aircraft type, step 1: the plane is measured, never shown, and the registration never kept."""

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

from smooth_worker import aircraft, flightdata, status

RECORDED = json.loads((Path(__file__).parent / "fixtures" / "flight_b6_123_recorded.json").read_text())
NOW = datetime(2026, 10, 28, 12, tzinfo=UTC)
DEPARTURE = NOW + timedelta(hours=30)


def leg(model=None, reg=None) -> flightdata.Leg:
    raw = json.loads(json.dumps(RECORDED))
    raw[0]["aircraft"] = {k: v for k, v in {"model": model, "reg": reg}.items() if v}
    return flightdata.parse_leg(raw[0])


def test_the_model_is_read_and_the_registration_only_noted():
    recorded = flightdata.parse_leg(RECORDED[0])
    assert (recorded.aircraft_model, recorded.aircraft_reg_present) == ("Airbus A320", False)
    named = leg("De Havilland Canada DHC-8-400 Dash 8Q", "C-GKQA")
    assert named.aircraft_reg_present
    flight = {"id": "f1", "origin": "KJFK", "destination": "KLAX", "departure_at": DEPARTURE.isoformat()}
    row = status.build(named, flight, None, NOW)
    assert row["aircraft_model"] == named.aircraft_model and row["aircraft_reg_present"] is True
    assert "C-GKQA" not in json.dumps(row)


def test_turboprops_by_whole_word():
    for model in ("De Havilland Canada DHC-8-400 Dash 8Q", "Bombardier Q400", "ATR 72-600", "ATR72", "ATR 42"):
        assert aircraft.is_turboprop(model), model
    for model in ("Airbus A320", "Boeing 737 MAX 8", "Embraer 175", "Cessna 208 Caravan", "Boeing 787-8"):
        assert aircraft.is_turboprop(model) is False, model
    assert aircraft.is_turboprop(None) is None


def test_what_outlasts_the_purge():
    first = aircraft.observation(leg(), None, DEPARTURE, NOW)
    assert first == {"first_check_had_model": False, "first_check_hours": 30.0}
    # Named 6 hours later: when it was first known, and what it is.
    later = NOW + timedelta(hours=6)
    previous = {"checked_at": NOW.isoformat(), "aircraft_model": None, "aircraft_first_seen_at": None}
    seen = aircraft.observation(leg("ATR 72-600"), previous, DEPARTURE, later)
    assert seen == {"model_first_seen_hours": 24.0, "turboprop": True}
    # A swap on the day is noted; the first-seen time is kept.
    named = {"checked_at": later.isoformat(), "aircraft_model": "ATR 72-600", "aircraft_first_seen_at": later.isoformat()}
    swapped = aircraft.observation(leg("Embraer 175"), named, DEPARTURE, later + timedelta(hours=20))
    assert swapped == {"model_changed": True, "turboprop": False}


def test_the_first_seen_time_is_kept():
    named = {"aircraft_first_seen_at": "2026-10-28T06:00:00+00:00"}
    assert aircraft.first_seen_at(leg("Airbus A320"), named, NOW) == "2026-10-28T06:00:00+00:00"
    assert aircraft.first_seen_at(leg("Airbus A320"), None, NOW) == NOW.isoformat()
    assert aircraft.first_seen_at(leg(), None, NOW) is None
