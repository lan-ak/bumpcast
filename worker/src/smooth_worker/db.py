"""Supabase access through PostgREST with the service role key (bypasses RLS)."""

import os
from datetime import datetime, timedelta

import httpx


class Database:
    def __init__(self, url: str | None = None, service_key: str | None = None):
        url = url or os.environ["SUPABASE_URL"]
        key = service_key or os.environ["SUPABASE_SERVICE_ROLE_KEY"]
        self.http = httpx.Client(
            base_url=f"{url.rstrip('/')}/rest/v1",
            headers={"apikey": key, "Authorization": f"Bearer {key}"},
            timeout=30,
        )

    def flights_with_latest_forecast(self, now: datetime) -> list[dict]:
        """Upcoming flights (not yet landed) with their most recent forecast, if any."""
        r = self.http.get(
            "/flights",
            params={
                "select": "id,origin,destination,departure_at,updated_at,"
                "forecasts(issued_at,status,source)",
                "departure_at": f"gte.{(now - timedelta(hours=1)).isoformat()}",
                "forecasts.order": "issued_at.desc",
                "forecasts.limit": "1",
                "order": "departure_at.asc",
            },
        )
        r.raise_for_status()
        return r.json()

    def insert_forecast(self, flight_id: str, row: dict) -> None:
        r = self.http.post(
            "/forecasts",
            json={"flight_id": flight_id, **row},
            headers={"Prefer": "return=minimal"},
        )
        r.raise_for_status()

    def prune_forecasts(self, flight_id: str, keep_after: datetime) -> None:
        """Drop superseded forecasts; keep recent history for 'what changed' messages."""
        r = self.http.delete(
            "/forecasts",
            params={"flight_id": f"eq.{flight_id}", "issued_at": f"lt.{keep_after.isoformat()}"},
        )
        r.raise_for_status()
