#!/usr/bin/env python3
"""Data for the website's route pages: a year of pilot reports along each route, and gusts at
each end. Writes scripts/data/routes.json, which scripts/build_site.py turns into site/routes/.

It uses the worker's flight model (route.py: the great-circle path, a typical climb, cruise and
descent), so run it in the worker's environment:

    cd worker && uv run python ../scripts/route_data.py                    # the last 12 full months
    cd worker && uv run python ../scripts/route_data.py --end 2026-11-01   # the 12 months before a date

Sources, all from Iowa State University's Iowa Environmental Mesonet (IEM), which archives the
US National Weather Service's feeds (downloads are cached in ~/.cache/bumpcast):
- Pilot reports (PIREPs): https://mesonet.agron.iastate.edu/request/gis/pireps.php
- Airport weather reports (METARs): https://mesonet.agron.iastate.edu/request/download.phtml
- Weather station lists, for the state or province below each part of a route and a rough idea of
  the height of the ground: https://mesonet.agron.iastate.edu/sites/networks.php

What counts:
- Only reports from airliners (AIRLINER_TYPES): what passengers fly in, not light aircraft.
- A report is on the route when it's within CORRIDOR_NM of the direct path and near the height a
  flight would be there (vertical_ok). Real flights wander off the great circle, so this is "near
  the route", not "on every flight".
- Near an airport: within NEAR_AIRPORT_NM and below NEAR_AIRPORT_FT above it.
- A gusty hour: an hourly report with gusts of GUSTY_KT or more, the app's own threshold for
  "Gusty at the airport" (worker/src/smooth_worker/airfield.py).
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

csv.field_size_limit(sys.maxsize)
from scipy.spatial import cKDTree

from smooth_worker import airports, route

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "scripts/data/routes.json"
CACHE = Path.home() / ".cache/bumpcast"
IEM = "https://mesonet.agron.iastate.edu"
SCHEMA = 1

# City pairs, one page each (both directions). Busy routes inside the app's coverage (the
# continental US and southern Canada), plus a few over the Rockies that nervous flyers ask about.
ROUTES = [
    ("JFK", "LAX"), ("LAX", "SFO"), ("JFK", "SFO"), ("EWR", "SFO"), ("ATL", "MCO"), ("LAS", "LAX"),
    ("LGA", "ORD"), ("ATL", "LGA"), ("DEN", "PHX"), ("LAX", "SEA"), ("BOS", "DCA"), ("BOS", "LGA"),
    ("LAX", "ORD"), ("ATL", "DFW"), ("DEN", "LAS"), ("DEN", "LAX"), ("SEA", "SFO"), ("EWR", "MCO"),
    ("DEN", "ORD"), ("DFW", "LAX"), ("JFK", "MIA"), ("LAS", "SFO"), ("DFW", "ORD"), ("ATL", "ORD"),
    ("LAX", "PHX"), ("ATL", "BOS"), ("DEN", "SFO"), ("DEN", "SEA"), ("LAX", "SLC"), ("MSP", "ORD"),
    ("DEN", "DFW"), ("BOS", "ORD"), ("YUL", "YYZ"), ("YVR", "YYZ"), ("YYC", "YYZ"), ("YVR", "YYC"),
    ("LGA", "YYZ"),
]

CORRIDOR_NM = 60
NEAR_AIRPORT_NM = 30
NEAR_AIRPORT_FT = 10000
GUSTY_KT = 25
CRUISE_FT = 20000  # reports at or above this are "at cruising height"
BINS = 20  # stretches along each route
REPORTING_MIN = 3000  # a control center's cruise reports needed to judge its reporting habit
EARTH_NM = 3440.065

# ICAO type designators of airliners: mainline and regional jets, and regional turboprops.
AIRLINER_TYPES = frozenset("""
A306 A30B A310 A318 A319 A320 A321 A19N A20N A21N A332 A333 A338 A339 A342 A343 A346 A359 A35K A388
BCS1 BCS3 B712 B717 B732 B733 B734 B735 B736 B737 B738 B739 B37M B38M B39M B3XM B744 B748 B752 B753
B762 B763 B764 B772 B773 B77L B77W B778 B779 B788 B789 B78X MD11 MD82 MD83 MD87 MD88 MD90
E135 E145 E170 E175 E75L E75S E190 E195 E290 E295 CRJ1 CRJ2 CRJ7 CRJ9 CRJX
DH8A DH8B DH8C DH8D AT43 AT45 AT72 AT75 AT76 SF34
""".split())

# Turbulence words in a report's TB group, by strength. A range ("LGT-MOD") is its own step, and a
# report counts at its strongest ("CONS LGT OCNL MOD" is moderate).
CATEGORIES = ["smooth", "light", "light_moderate", "moderate", "severe"]
WORDS = {"NEG": 0, "SMOOTH": 0, "SMTH": 0, "NONE": 0, "NIL": 0, "LGT": 1, "LT": 1, "LIGHT": 1,
         "MOD": 3, "MDT": 3, "MODERATE": 3, "SEV": 4, "SEVR": 4, "SEVERE": 4, "EXTRM": 4, "EXTM": 4, "EXTREME": 4}

US_STATES = {
    "AL": "Alabama", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado", "CT": "Connecticut",
    "DE": "Delaware", "FL": "Florida", "GA": "Georgia", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
    "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts",
    "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska",
    "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
    "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
    "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah",
    "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
}
PROVINCES = {"BC": "British Columbia", "AB": "Alberta", "SK": "Saskatchewan", "MB": "Manitoba", "ON": "Ontario",
             "QC": "Quebec", "NB": "New Brunswick", "NS": "Nova Scotia", "PE": "Prince Edward Island"}


# ---------- Downloads (cached)

def fetch(url: str, path: Path, attempts: int = 4) -> Path:
    if path.exists() and path.stat().st_size > 0:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=600) as r:
                tmp = path.with_suffix(path.suffix + ".part")
                tmp.write_bytes(r.read())
                tmp.replace(path)
                return path
        except OSError as e:
            if attempt == attempts - 1:
                raise
            print(f"  retrying {url}: {e}", file=sys.stderr)
            time.sleep(2 ** (attempt + 1))
    return path


def months(start: dt.date, end: dt.date) -> list[dt.date]:
    out, d = [], start
    while d < end:
        out.append(d)
        d = (d.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
    return out


def pirep_month(month: dt.date) -> Path:
    nxt = (month.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
    q = urllib.parse.urlencode({"sts": f"{month:%Y-%m-%d}T00:00Z", "ets": f"{nxt:%Y-%m-%d}T00:00Z", "fmt": "csv"})
    return fetch(f"{IEM}/cgi-bin/request/gis/pireps.py?{q}", CACHE / "pireps" / f"{month:%Y-%m}.csv")


def stations() -> tuple[np.ndarray, np.ndarray, np.ndarray, list[str]]:
    """Every US (lower 48) and Canadian ASOS station: lat, lon, elevation (ft) and state/province."""
    lats, lons, elevs, regions = [], [], [], []
    networks = [f"{s}_ASOS" for s in US_STATES] + [f"CA_{p}_ASOS" for p in PROVINCES]
    for net in networks:
        data = json.loads(fetch(f"{IEM}/geojson/network/{net}.geojson", CACHE / "networks" / f"{net}.geojson").read_text())
        region = net.removesuffix("_ASOS").split("_")[-1]  # CO_ASOS -> CO, CA_ON_ASOS -> ON
        for f in data["features"]:
            lon, lat = f["geometry"]["coordinates"]
            elev = f["properties"].get("elevation")
            if elev is None or lat is None:
                continue
            lats.append(lat)
            lons.append(lon)
            elevs.append(float(elev) * 3.28084)
            regions.append(region)
    return np.array(lats), np.array(lons), np.array(elevs), regions


def metar_id(icao: str) -> str:
    return icao[1:] if icao.startswith("K") else icao


def gusts(icao: str, start: dt.date, end: dt.date) -> dict:
    sid = metar_id(icao)
    q = urllib.parse.urlencode({
        "station": sid, "data": "gust", "tz": "Etc/UTC", "format": "onlycomma", "latlon": "no", "missing": "M",
        "trace": "T", "direct": "no", "report_type": "3",
        "year1": start.year, "month1": start.month, "day1": start.day,
        "year2": end.year, "month2": end.month, "day2": end.day,
    })
    path = fetch(f"{IEM}/cgi-bin/request/asos.py?{q}", CACHE / "metars" / f"{sid}_{start:%Y%m%d}_{end:%Y%m%d}.csv")
    hours = gusty_hours = 0
    days, gusty_days = set(), set()
    by_month = Counter()
    with path.open() as f:
        for row in csv.DictReader(f):
            when = row["valid"][:10]
            hours += 1
            days.add(when)
            g = row["gust"]
            if g not in ("M", "") and float(g) >= GUSTY_KT:
                gusty_hours += 1
                if when not in gusty_days:
                    gusty_days.add(when)
                    by_month[when[:7]] += 1
    return {"station": sid, "hours": hours, "days": len(days), "gusty_hours": gusty_hours,
            "gusty_days": len(gusty_days),
            "gusty_days_by_month": {f"{m:%Y-%m}": by_month.get(f"{m:%Y-%m}", 0) for m in months(start, end)}}


# ---------- Pilot reports

def category(tb: str) -> int | None:
    """The report's strongest turbulence as an index into CATEGORIES, or None for no TB group."""
    if tb in ("None", ""):
        return None
    best = None
    for word in tb.replace("/", "-").split():
        parts = word.split("-")
        steps = [WORDS[p] for p in parts if p in WORDS]
        if not steps:
            continue
        step = 2 if len(steps) == 2 and min(steps) == 1 and max(steps) == 3 else max(steps)
        best = step if best is None else max(best, step)
    return best


def load_reports(start: dt.date, end: dt.date) -> dict[str, np.ndarray]:
    """Airliner turbulence reports, one row per report (the archive lists some twice)."""
    seen = set()
    cols = defaultdict(list)
    for month in months(start, end):
        path = pirep_month(month)
        with path.open(newline="") as f:
            for row in csv.DictReader(f):
                aircraft = "".join(ch for ch in (row["AIRCRAFT"] or "").upper() if ch.isalnum())[:4]
                if aircraft not in AIRLINER_TYPES:
                    continue
                cat = category(row["TURBULENCE"] or "")
                if cat is None:
                    continue
                try:
                    lat, lon, fl = float(row["LAT"]), float(row["LON"]), float(row["FL"])
                except (TypeError, ValueError):
                    continue
                key = (row["VALID"], round(lat, 2), round(lon, 2), fl, aircraft, row["TURBULENCE"])
                if key in seen:
                    continue
                seen.add(key)
                cols["month"].append(int(row["VALID"][:6]))
                cols["lat"].append(lat)
                cols["lon"].append(lon)
                cols["fl"].append(fl)
                cols["cat"].append(cat)
                cols["center"].append(row["ATRCC"] or "")
        print(f"  {month:%Y-%m}: {len(seen):,} airliner turbulence reports so far", file=sys.stderr)
    return {k: np.array(v) for k, v in cols.items()}


def xyz(lat, lon) -> np.ndarray:
    lat, lon = np.radians(lat), np.radians(lon)
    return np.column_stack([np.cos(lat) * np.cos(lon), np.cos(lat) * np.sin(lon), np.sin(lat)])


def nm(chord: np.ndarray) -> np.ndarray:
    return 2 * np.arcsin(np.clip(chord / 2, 0, 1)) * EARTH_NM


def counts(cats: np.ndarray) -> dict[str, int]:
    c = np.bincount(cats.astype(int), minlength=len(CATEGORIES))
    return {name: int(c[i]) for i, name in enumerate(CATEGORIES)}


def vertical_ok(fl: np.ndarray, alt: np.ndarray) -> np.ndarray:
    """Near the height a flight would be at that point: a margin that grows with height, since
    cruise levels vary by a few thousand feet."""
    return np.abs(fl - alt) <= 3000 + 0.15 * alt


# ---------- Routes

class Places:
    def __init__(self):
        lat, lon, self.elev, self.region = stations()
        self.tree = cKDTree(xyz(lat, lon))
        big = [a for a in json.loads((ROOT / "worker/src/smooth_worker/data/airports.json").read_text())
               if a.get("large") and 22 <= a["lat"] <= 52 and -128 <= a["lon"] <= -64]
        self.cities = [a["city"] for a in big]
        self.city_tree = cKDTree(xyz(np.array([a["lat"] for a in big]), np.array([a["lon"] for a in big])))

    def describe(self, lat: float, lon: float) -> dict:
        p = xyz(np.array([lat]), np.array([lon]))
        dist, idx = self.tree.query(p, k=8)
        dist_nm = nm(dist[0])
        region = self.region[idx[0][0]]
        near = dist_nm <= 40
        ground = float(np.median(self.elev[idx[0][near]])) if near.any() else (
            float(self.elev[idx[0][0]]) if dist_nm[0] <= 60 else 0.0)
        cdist, cidx = self.city_tree.query(p, k=1)
        city = self.cities[int(cidx[0])] if nm(cdist)[0] <= 90 else None
        return {"region": region, "region_name": US_STATES.get(region) or PROVINCES.get(region),
                "offshore": bool(dist_nm[0] > 40), "near": city, "ground_ft": round(ground, -1)}


def path(a, b) -> dict:
    """The worker's still-air profile both ways, with the distance flown at each minute."""
    depart = dt.datetime(2026, 1, 15, 14, tzinfo=dt.UTC)
    ab, ba = route.build_profile(a, b, depart), route.build_profile(b, a, depart)

    def along(points):
        lat = np.array([p.lat for p in points])
        lon = np.array([p.lon for p in points])
        steps = nm(np.linalg.norm(np.diff(xyz(lat, lon), axis=0), axis=1))
        dist = np.concatenate([[0], np.cumsum(steps)])
        return lat, lon, np.array([p.altitude_ft for p in points], float), dist / dist[-1]

    lat, lon, alt, frac = along(ab)
    _, _, _, frac_ba = along(ba)
    return {"lat": lat, "lon": lon, "alt": alt, "frac": frac, "frac_ba": frac_ba,
            "minutes": (len(ab) - 1, len(ba) - 1), "cruise_ft": int(alt.max())}


def minute_at(frac: np.ndarray, f: float) -> int:
    """The minute (index) at which a profile has flown fraction f of the way."""
    return int(np.searchsorted(frac, f))


def analyse(code_a: str, code_b: str, reports: dict, rtree: cKDTree, places: Places) -> dict:
    a, b = airports.lookup(code_a), airports.lookup(code_b)
    p = path(a, b)
    pts = xyz(p["lat"], p["lon"])
    ptree = cKDTree(pts)

    # Candidates: reports within the corridor of any point, then the nearest point for each.
    radius = 2 * math.sin(CORRIDOR_NM / EARTH_NM / 2)
    cand = sorted(set(i for lst in rtree.query_ball_point(pts, r=radius) for i in lst))
    cand = np.array(cand, dtype=int)
    dist, near = ptree.query(xyz(reports["lat"][cand], reports["lon"][cand]))
    on = (nm(dist) <= CORRIDOR_NM) & vertical_ok(reports["fl"][cand], p["alt"][near])
    idx, near = cand[on], near[on]
    cats, fl, frac = reports["cat"][idx], reports["fl"][idx], p["frac"][near]

    along = []
    for i in range(BINS):
        lo, hi = i / BINS, (i + 1) / BINS
        sel = (frac >= lo) & ((frac < hi) | (i == BINS - 1))
        mid = (lo + hi) / 2
        m = minute_at(p["frac"], mid)
        along.append({
            "from": lo, "to": hi,
            "minute_ab": m, "minute_ba": minute_at(p["frac_ba"], 1 - mid),
            "alt_ft": int(p["alt"][m]),
            **places.describe(float(p["lat"][m]), float(p["lon"][m])),
            "counts": counts(cats[sel]),
        })

    month_keys = sorted(set(int(k) for k in reports["month"]))
    by_month = {f"{k // 100}-{k % 100:02d}": counts(cats[reports["month"][idx] == k]) for k in month_keys}

    ends = {}
    for ap in (a, b):
        cand = rtree.query_ball_point(xyz(np.array([ap.lat]), np.array([ap.lon]))[0],
                                      r=2 * math.sin(NEAR_AIRPORT_NM / EARTH_NM / 2))
        cand = np.array(cand, dtype=int)
        low = reports["fl"][cand] - ap.elev_ft <= NEAR_AIRPORT_FT if len(cand) else np.array([], bool)
        ends[ap.iata] = counts(reports["cat"][cand[low]] if len(cand) else np.array([], int))

    regions = [places.describe(a.lat, a.lon)["region_name"]]
    for stretch in along:
        name = stretch["region_name"]
        if name and not stretch["offshore"] and name not in regions:
            regions.append(name)
    end_region = places.describe(b.lat, b.lon)["region_name"]
    if end_region not in regions:
        regions.append(end_region)
    regions = [r for r in regions if r]

    def airport(ap):
        return {"iata": ap.iata, "icao": ap.icao, "name": ap.name, "city": ap.city, "country": ap.country,
                "lat": ap.lat, "lon": ap.lon, "elev_ft": ap.elev_ft, "tz": ap.tz,
                "region": places.describe(ap.lat, ap.lon)["region_name"]}

    return {
        "a": airport(a), "b": airport(b),
        "direct_nm": round(route.distance_nm(a, b)),
        "flown_nm": round(route.flown_nm(route.distance_nm(a, b))),
        "airborne_min": {"ab": p["minutes"][0], "ba": p["minutes"][1]},
        "cruise_ft": p["cruise_ft"],
        "regions": regions,
        "reports": counts(cats),
        "cruise": counts(cats[fl >= CRUISE_FT]),
        "along": along,
        "months": by_month,
        "ends": ends,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--end", type=dt.date.fromisoformat, default=dt.date.today().replace(day=1),
                        help="first day after the period (default: the 1st of this month)")
    args = parser.parse_args()
    end = args.end.replace(day=1)
    start = end.replace(year=end.year - 1)

    print(f"Pilot reports {start} to {end}", file=sys.stderr)
    reports = load_reports(start, end)
    rtree = cKDTree(xyz(reports["lat"], reports["lon"]))
    places = Places()

    # Baselines: every airliner report inside the app's coverage box.
    box = (reports["lat"] >= 22) & (reports["lat"] <= 52) & (reports["lon"] >= -128) & (reports["lon"] <= -64)
    cruise = box & (reports["fl"] >= CRUISE_FT)
    baseline = {"cruise": counts(reports["cat"][cruise]),
                "low": counts(reports["cat"][box & (reports["fl"] < NEAR_AIRPORT_FT)]),
                "all": counts(reports["cat"][box]),
                "cruise_months": {f"{k // 100}-{k % 100:02d}": counts(reports["cat"][cruise & (reports["month"] == k)])
                                  for k in sorted(set(int(k) for k in reports["month"]))}}
    # How often smooth air gets reported, by control center: the reporting habit that makes
    # shares of reports a poor guide to how often flights are bumpy.
    centers = {}
    for c in sorted(set(reports["center"][cruise])):
        sel = cruise & (reports["center"] == c)
        if c and sel.sum() >= REPORTING_MIN:
            centers[c] = counts(reports["cat"][sel])
    baseline["centers"] = centers

    routes = []
    for code_a, code_b in ROUTES:
        print(f"Route {code_a}-{code_b}", file=sys.stderr)
        r = analyse(code_a, code_b, reports, rtree, places)
        r["gusts"] = {r["a"]["iata"]: gusts(r["a"]["icao"], start, end), r["b"]["iata"]: gusts(r["b"]["icao"], start, end)}
        routes.append(r)

    data = {
        "schema": SCHEMA,
        "period": {"start": start.isoformat(), "end": (end - dt.timedelta(days=1)).isoformat()},
        "generated": dt.date.today().isoformat(),
        "method": {
            "corridor_nm": CORRIDOR_NM, "near_airport_nm": NEAR_AIRPORT_NM, "near_airport_ft": NEAR_AIRPORT_FT,
            "cruise_ft": CRUISE_FT, "gusty_kt": GUSTY_KT, "categories": CATEGORIES,
            "airliner_types": sorted(AIRLINER_TYPES),
        },
        "sources": {
            "pireps": f"{IEM}/request/gis/pireps.php",
            "metars": f"{IEM}/request/download.phtml",
            "stations": f"{IEM}/sites/networks.php",
        },
        "baseline": baseline,
        "routes": routes,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n")
    total = sum(sum(r["reports"].values()) for r in routes)
    print(f"Wrote {OUT.relative_to(ROOT)}: {len(routes)} routes, {total:,} reports on them", file=sys.stderr)


if __name__ == "__main__":
    main()
