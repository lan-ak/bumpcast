"""The plane a flight is planned on, measured before anything uses it (aircraft type, step 1).

Every flight is forecast with a jet's climb and cruise. A Dash 8 or an ATR flies lower and slower,
so its bumpy stretches would be sampled at the wrong height and timed too early. Before building
a turboprop profile, this measures how many real flights it would help and how early the plane is
known. Nothing here changes a forecast, a screen or a push, and the plane is never named to users.

The provider's model text is stored on flight_status only and goes with it (status.KEEP); the
registration itself is never stored. What BumpCast derives from the checks is kept on
flight_aircraft, which holds no provider data, so the measurement outlasts the purge.
"""

import re
from datetime import datetime

from .flightdata import Leg

# The Dash 8 family (Q200 to Q400) and the ATR 42 and 72, as whole words.
TURBOPROP = re.compile(r"\b(dash[ -]?8|dhc-?8|q[234]00|atr[ -]?(42|72))\b", re.IGNORECASE)


def is_turboprop(model: str | None) -> bool | None:
    """Whether the model is a Dash 8 or an ATR; None when no plane is named."""
    if not model:
        return None
    return bool(TURBOPROP.search(model))


def first_seen_at(leg: Leg, previous: dict | None, now: datetime) -> str | None:
    """When the plane was first named for this flight (flight_status.aircraft_first_seen_at)."""
    return (previous or {}).get("aircraft_first_seen_at") or (now.isoformat() if leg.aircraft_model else None)


def observation(leg: Leg, previous: dict | None, departure: datetime, now: datetime) -> dict:
    """What this check adds to flight_aircraft: only the fields it settles, so earlier ones stay."""
    previous = previous or {}
    model, before = leg.aircraft_model, previous.get("aircraft_model")
    hours = round((departure - now).total_seconds() / 3600, 1)
    fields: dict = {}
    if not previous.get("checked_at"):
        fields |= {"first_check_had_model": model is not None, "first_check_hours": hours}
    if model and not previous.get("aircraft_first_seen_at"):
        fields["model_first_seen_hours"] = hours
    if model and before and model != before:
        fields["model_changed"] = True
    if model:
        fields["turboprop"] = is_turboprop(model)
    return fields
