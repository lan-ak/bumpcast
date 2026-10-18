"""Supabase access through PostgREST with the service role key (bypasses RLS)."""

import os
from collections import defaultdict
from datetime import datetime, timedelta

import httpx

FORECAST_FIELDS = "id,issued_at,status,source,model_run,grade,score,duration_min,segments"


def _in(values) -> str:
    return f"in.({','.join(values)})"


class Database:
    def __init__(self, url: str | None = None, service_key: str | None = None):
        url = url or os.environ["SUPABASE_URL"]
        key = service_key or os.environ["SUPABASE_SERVICE_ROLE_KEY"]
        self.http = httpx.Client(
            base_url=f"{url.rstrip('/')}/rest/v1",
            headers={"apikey": key, "Authorization": f"Bearer {key}"},
            timeout=30,
        )

    def _get(self, path: str, params: dict) -> list[dict]:
        r = self.http.get(path, params=params)
        r.raise_for_status()
        return r.json()

    # Forecasts

    def flights_with_latest_forecast(self, now: datetime) -> list[dict]:
        """Upcoming flights (not yet landed) with their most recent forecast, if any."""
        return self._get(
            "/flights",
            {
                "select": "id,origin,destination,departure_at,updated_at,forecasts:forecasts!forecasts_flight_id_fkey(issued_at,status,source)",
                "departure_at": f"gte.{(now - timedelta(hours=1)).isoformat()}",
                "forecasts.order": "issued_at.desc",
                "forecasts.limit": "1",
                "order": "departure_at.asc",
            },
        )

    def insert_forecast(self, flight_id: str, row: dict) -> None:
        r = self.http.post("/forecasts", json={"flight_id": flight_id, **row}, headers={"Prefer": "return=minimal"})
        r.raise_for_status()

    def prune_forecasts(self, flight_id: str, keep_after: datetime) -> None:
        """Drop superseded forecasts; keep recent history for 'what changed' messages."""
        r = self.http.delete(
            "/forecasts", params={"flight_id": f"eq.{flight_id}", "issued_at": f"lt.{keep_after.isoformat()}"}
        )
        r.raise_for_status()

    def forecast(self, forecast_id: str) -> dict | None:
        rows = self._get("/forecasts", {"select": FORECAST_FIELDS, "id": f"eq.{forecast_id}"})
        return rows[0] if rows else None

    # Notifications

    def upcoming_flights_with_latest_forecast(self, now: datetime) -> list[dict]:
        """Flights departing within the next 48 h (or just now), with their full latest forecast."""
        return self._get(
            "/flights",
            {
                "select": f"id,user_id,origin,destination,departure_at,forecasts:forecasts!forecasts_flight_id_fkey({FORECAST_FIELDS})",
                "and": f"(departure_at.gte.{(now - timedelta(hours=1)).isoformat()},"
                f"departure_at.lte.{(now + timedelta(hours=48, minutes=5)).isoformat()})",
                "forecasts.order": "issued_at.desc",
                "forecasts.limit": "1",
            },
        )

    def notifications_for(self, flight_ids: list[str]) -> dict[str, list[dict]]:
        """Each flight's notifications, oldest first, with the source of the forecast they described."""
        if not flight_ids:
            return {}
        rows = self._get(
            "/notifications",
            {
                "select": "flight_id,milestone,kind,forecast_id,created_at,forecast:forecasts(source)",
                "flight_id": _in(flight_ids),
                "order": "created_at.asc",
            },
        )
        by_flight: dict[str, list[dict]] = defaultdict(list)
        for row in rows:
            row["source"] = (row.pop("forecast") or {}).get("source")
            by_flight[row["flight_id"]].append(row)
        return by_flight

    def insert_notification(self, row: dict) -> str | None:
        """Insert unless this flight already has this milestone; returns the new id or None."""
        r = self.http.post(
            "/notifications",
            params={"on_conflict": "flight_id,milestone", "select": "id"},
            json=row,
            headers={"Prefer": "return=representation,resolution=ignore-duplicates"},
        )
        r.raise_for_status()
        rows = r.json()
        return rows[0]["id"] if rows else None

    def update_notification(self, notification_id: str, delivered: bool, error: str | None) -> None:
        r = self.http.patch(
            "/notifications",
            params={"id": f"eq.{notification_id}"},
            json={"delivered": delivered, "error": error},
            headers={"Prefer": "return=minimal"},
        )
        r.raise_for_status()

    def profiles(self, user_ids: list[str]) -> dict[str, dict]:
        if not user_ids:
            return {}
        rows = self._get("/profiles", {"select": "user_id,is_pro,timezone", "user_id": _in(user_ids)})
        return {r["user_id"]: r for r in rows}

    def flights_with_passes(self, flight_ids: list[str]) -> set[str]:
        if not flight_ids:
            return set()
        rows = self._get("/flight_passes", {"select": "flight_id", "flight_id": _in(flight_ids)})
        return {r["flight_id"] for r in rows}

    def devices(self, user_ids: list[str]) -> dict[str, list[dict]]:
        if not user_ids:
            return {}
        rows = self._get("/devices", {"select": "token,user_id,environment", "user_id": _in(user_ids)})
        by_user: dict[str, list[dict]] = defaultdict(list)
        for row in rows:
            by_user[row["user_id"]].append(row)
        return by_user

    def delete_device(self, token: str) -> None:
        self.http.delete("/devices", params={"token": f"eq.{token}"}).raise_for_status()

    # Map data

    def upsert_pireps(self, rows: list[dict]) -> None:
        if rows:
            r = self.http.post(
                "/pireps",
                params={"on_conflict": "id"},
                json=rows,
                headers={"Prefer": "return=minimal,resolution=merge-duplicates"},
            )
            r.raise_for_status()

    def prune_pireps(self, before: datetime) -> None:
        self.http.delete("/pireps", params={"observed_at": f"lt.{before.isoformat()}"}).raise_for_status()

    def latest_grid_cycle(self) -> str | None:
        rows = self._get("/turbulence_grids", {"select": "cycle", "order": "cycle.desc", "limit": "1"})
        return rows[0]["cycle"] if rows else None

    def replace_grids(self, cycle: datetime, rows: list[dict]) -> None:
        """Store a new cycle's map layers, then drop older cycles."""
        for i in range(0, len(rows), 10):
            r = self.http.post(
                "/turbulence_grids",
                params={"on_conflict": "valid_at,level_ft"},
                json=rows[i : i + 10],
                headers={"Prefer": "return=minimal,resolution=merge-duplicates"},
            )
            r.raise_for_status()
        self.http.delete("/turbulence_grids", params={"cycle": f"lt.{cycle.isoformat()}"}).raise_for_status()
