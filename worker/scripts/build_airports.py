"""Build the airport list shared by the worker and the iOS app.

Source: OurAirports (public domain). Keeps large and medium airports with
scheduled passenger service worldwide, so flights outside US coverage can
still be saved and shown an honest "not covered yet" state.

Usage: uv run python scripts/build_airports.py
"""

import csv
import io
import json
from pathlib import Path

import httpx
from timezonefinder import TimezoneFinder

SOURCE = "https://davidmegginson.github.io/ourairports-data/airports.csv"
ROOT = Path(__file__).resolve().parents[2]
OUTPUTS = [
    ROOT / "worker/src/smooth_worker/data/airports.json",
    ROOT / "ios/Smooth/Resources/airports.json",
]


def main() -> None:
    text = httpx.get(SOURCE, follow_redirects=True, timeout=60).text
    tf = TimezoneFinder()
    airports = []
    for row in csv.DictReader(io.StringIO(text)):
        if row["type"] not in ("large_airport", "medium_airport"):
            continue
        if row["scheduled_service"] != "yes":
            continue
        icao = row["icao_code"] or row["gps_code"]
        if len(icao) != 4 or not row["iata_code"]:
            continue
        lat, lon = float(row["latitude_deg"]), float(row["longitude_deg"])
        tz = tf.timezone_at(lat=lat, lng=lon)
        if not tz:
            continue
        airports.append(
            {
                "icao": icao,
                "iata": row["iata_code"],
                "name": row["name"],
                "city": row["municipality"],
                "country": row["iso_country"],
                "lat": round(lat, 4),
                "lon": round(lon, 4),
                "elev_ft": int(row["elevation_ft"] or 0),
                "tz": tz,
                "large": row["type"] == "large_airport",
            }
        )
    airports.sort(key=lambda a: a["icao"])
    payload = json.dumps(airports, separators=(",", ":"), ensure_ascii=False)
    for out in OUTPUTS:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(payload)
    print(f"{len(airports)} airports -> {', '.join(str(o.relative_to(ROOT)) for o in OUTPUTS)}")


if __name__ == "__main__":
    main()
