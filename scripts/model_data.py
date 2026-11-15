#!/usr/bin/env python3
"""Data for the website's model pages: a year of the app's global outlook, checked against pilot reports.
Writes scripts/data/model.json, which scripts/build_site.py turns into the international route pages
(site/routes/, "model estimate") and the forecast-accuracy page (site/learn/forecast-accuracy.html).

Why: outside North America the pilot-report feeds the other route pages use are nearly empty, so those
routes are described from a weather model instead, and only by season (months). docs/plans/
international-route-pages.md has the reasoning and the check that limited them to months.

What it does, for every 6-hourly analysis (00/06/12/18Z) in the 12 months before --end:
- Downloads the analysis (hour 0) of ECMWF's open data and of NOAA's GFS from their AWS buckets
  (only the fields the outlook needs, by byte range: ~24 MB + ~29 MB), and runs the worker's own
  turbulence diagnostics on each (ecmwf.global_edr, which is gfs.blend_edr), without the app's 0.20 cap.
- Reads the EDR, averaged over the two models as the app's outlook does, every 5 minutes along each
  route's flight profile (route.build_profile) and at every airliner pilot report within 3 hours.
- Keeps one small .npz per analysis in ~/.cache/bumpcast/model, so a run can stop and resume.
Then it scores the model against the reports and summarises each route by month.

Run it in the worker's environment (the pilot reports come from route_data.py's cache, so run that first):

    cd worker && uv run python ../scripts/model_data.py                    # the last 12 full months
    cd worker && uv run python ../scripts/model_data.py --end 2026-11-01   # the 12 months before a date

A year takes ~30 min on a laptop, downloads ~77 GB (nothing large is kept) and costs nothing.
Credit: "Contains ECMWF open data (CC BY 4.0)"; GFS is US government data (public domain).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import eccodes
import numpy as np
from scipy.ndimage import uniform_filter
from scipy.spatial import cKDTree
from scipy.stats import rankdata, spearmanr

from smooth_worker import airports, route
from smooth_worker.http import get_with_retry
from smooth_worker.sources import ecmwf

sys.path.insert(0, str(Path(__file__).resolve().parent))
import route_data  # noqa: E402  (pilot-report parsing, airliner types, the IEM cache)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "scripts/data/model.json"
CACHE = Path.home() / ".cache/bumpcast/model"
SCHEMA = 1

# Routes with dense pilot reports, to check the model's picture against the pilot-report pages.
CHECK = [("BOS", "LAS"), ("ORD", "MIA"), ("JFK", "LAX"), ("SFO", "IAD"), ("DEN", "DCA"), ("BOS", "DFW"),
         ("ATL", "ORD"), ("DFW", "LAX"), ("DEN", "PHX"), ("LAX", "SEA"), ("ATL", "MCO"), ("LGA", "ORD"),
         ("YVR", "YYZ"), ("YYC", "YYZ"), ("SEA", "SFO"), ("DEN", "SLC")]
# International routes sampled. PAGES are the ones published (busy routes; months only).
INTL = [("JFK", "LHR"), ("EWR", "LHR"), ("BOS", "LHR"), ("IAD", "LHR"), ("ORD", "LHR"), ("YYZ", "LHR"),
        ("YUL", "LHR"), ("JFK", "CDG"), ("JFK", "FRA"), ("YYZ", "FRA"), ("LAX", "NRT"), ("SFO", "NRT"),
        ("LAX", "HND"), ("SEA", "HND"), ("YVR", "NRT"), ("LAX", "ICN"), ("SFO", "HKG"), ("LHR", "DXB"),
        ("FRA", "DXB"), ("CDG", "DXB"), ("LHR", "DOH"), ("DXB", "BOM"), ("DXB", "DEL"), ("SIN", "HKG"),
        ("SYD", "SIN"), ("HND", "ICN"), ("HKG", "NRT"), ("DEL", "BOM"), ("LHR", "MAD"), ("LHR", "BCN"),
        ("LHR", "FRA"), ("LHR", "CDG"), ("LHR", "AMS"), ("LHR", "IST"), ("CDG", "BCN"), ("FRA", "IST")]
PAGES = {("JFK", "LHR"), ("YYZ", "LHR"), ("ORD", "LHR"), ("JFK", "CDG"), ("LHR", "DXB"), ("LHR", "DOH"),
         ("LAX", "NRT"), ("SFO", "HKG"), ("SYD", "SIN"), ("SIN", "HKG"), ("HKG", "NRT"), ("LHR", "MAD")}
# airports.json names some cities by the airport's town; the pages use the city people fly to.
CITY = {"CDG": "Paris", "NRT": "Tokyo", "HND": "Tokyo", "SYD": "Sydney", "DEL": "Delhi", "BOM": "Mumbai",
        "FRA": "Frankfurt", "ICN": "Seoul", "IST": "Istanbul", "AMS": "Amsterdam", "BCN": "Barcelona"}

LIGHT = 0.10  # severity.LIGHT_EDR
EVERY_MIN = 5
REPORT_WINDOW_H = 3
GFS = "https://noaa-gfs-bdp-pds.s3.amazonaws.com"
GFS_LEVELS = {f"{mb} mb" for mb in [850, 700, 600, 500, 400, 350, 300, 250, 200, 150]}
UPGRADE = dt.datetime(2026, 5, 12, tzinfo=dt.UTC)  # ECMWF Cy50r1: 06/18Z runs moved from "scda" to "oper"
SOURCES = {"ecmwf": "https://registry.opendata.aws/ecmwf-forecasts/",
           "gfs": "https://registry.opendata.aws/noaa-gfs-bdp-pds/",
           "pireps": "https://mesonet.agron.iastate.edu/request/gis/pireps.php"}


def ecmwf_url(cycle: dt.datetime, step: int, ext: str) -> str:
    stream = "oper" if cycle.hour in (0, 12) or cycle >= UPGRADE else "scda"
    return f"{ecmwf.BASE}/{cycle:%Y%m%d}/{cycle:%H}z/ifs/0p25/{stream}/{cycle:%Y%m%d%H}0000-{step}h-{stream}-fc.{ext}"


ecmwf._url = ecmwf_url


# ---------- Inputs

def load_pireps(start: dt.date, end: dt.date) -> dict[str, np.ndarray]:
    """Airliner turbulence reports with their times, from route_data.py's monthly downloads."""
    import csv
    rows = set()
    for month in route_data.months(start, end):
        with route_data.pirep_month(month).open(newline="") as f:
            for r in csv.DictReader(f):
                ac = "".join(c for c in (r["AIRCRAFT"] or "").upper() if c.isalnum())[:4]
                cat = route_data.category(r["TURBULENCE"] or "") if ac in route_data.AIRLINER_TYPES else None
                if cat is None:
                    continue
                try:
                    t = dt.datetime.strptime(r["VALID"], "%Y%m%d%H%M").replace(tzinfo=dt.UTC).timestamp()
                    rows.add((t, float(r["LAT"]), float(r["LON"]), float(r["FL"]), cat))
                except (TypeError, ValueError):
                    continue
    a = np.array(sorted(rows))
    return {"t": a[:, 0], "lat": a[:, 1], "lon": a[:, 2], "ft": a[:, 3], "cat": a[:, 4].astype(int)}


def profiles() -> dict[str, dict]:
    out = {}
    for a, b in CHECK + INTL:
        pts = route.build_profile(airports.lookup(a), airports.lookup(b), dt.datetime(2026, 1, 1, tzinfo=dt.UTC))
        pts = [p for p in pts if p.minute % EVERY_MIN == 0]
        out[f"{a}-{b}"] = {"lat": np.array([p.lat for p in pts]), "lon": np.array([p.lon for p in pts]),
                           "ft": np.array([p.altitude_ft for p in pts], float),
                           "phase": np.array([p.phase for p in pts]), "minute": np.array([p.minute for p in pts])}
    return out


def gfs_grib(t: dt.datetime) -> Path:
    base = f"{GFS}/gfs.{t:%Y%m%d}/{t:%H}/atmos/gfs.t{t:%H}z.pgrb2.0p25.f000"
    idx = get_with_retry(base + ".idx")
    idx.raise_for_status()
    lines = [line.split(":") for line in idx.text.strip().splitlines()]
    ranges = []
    for k, f in enumerate(lines):
        if (f[3] in ("UGRD", "VGRD", "TMP", "HGT") and f[4] in GFS_LEVELS) or (f[3] == "HGT" and f[4] == "surface"):
            ranges.append((int(f[1]), int(lines[k + 1][1]) - 1 if k + 1 < len(lines) else ""))
    path = CACHE / "tmp" / f"gfs_{t:%Y%m%d%H}.grib2"
    with path.open("wb") as out:
        for s, e in ranges:
            r = get_with_retry(base, headers={"Range": f"bytes={s}-{e}"})
            r.raise_for_status()
            out.write(r.content)
    return path


def gfs_decode(path: Path):
    fields, lats, lons = {}, None, None
    with path.open("rb") as f:
        while (gid := eccodes.codes_grib_new_from_file(f)) is not None:
            try:
                ny, nx = eccodes.codes_get(gid, "Nj"), eccodes.codes_get(gid, "Ni")
                if lats is None:
                    lats = eccodes.codes_get_array(gid, "latitudes").reshape(ny, nx)[:, 0]
                    lons = eccodes.codes_get_array(gid, "longitudes").reshape(ny, nx)[0, :] % 360
                v = eccodes.codes_get_values(gid).reshape(ny, nx).astype(np.float32)
                kind = eccodes.codes_get(gid, "typeOfLevel")
                if kind == "isobaricInhPa":
                    fields[(eccodes.codes_get(gid, "shortName"), eccodes.codes_get(gid, "level"))] = v
                elif kind == "surface":
                    fields[("orog", 0)] = v
            finally:
                eccodes.codes_release(gid)
    return fields, lats, lons


def sampler(mids, edr, lats, lons):
    """EDR at (lat, lon, ft) points, read as EcmwfSource.edr does: the 3x3 neighbourhood mean of each
    layer, interpolated to the height. Not capped."""
    smooth = uniform_filter(edr.astype(np.float32), size=(1, 3, 3), mode=("nearest", "nearest", "wrap")) * ecmwf.EDR_UNIT
    heights = mids.astype(np.float32) * ecmwf.FT_UNIT
    dlat, dlon = lats[0] - lats[1], lons[1] - lons[0]

    def at(lat, lon, ft):
        j = np.clip(np.rint((lats[0] - lat) / dlat).astype(int), 0, len(lats) - 1)
        i = np.rint((lon % 360 - lons[0]) / dlon).astype(int) % len(lons)
        prof, h = smooth[:, j, i], heights[:, j, i]
        return np.array([np.interp(ft[k], h[:, k], prof[:, k]) for k in range(len(j))], np.float32)
    return at


def retry(fn, *a):
    for attempt in range(6):
        try:
            return fn(*a)
        except Exception as e:  # noqa: BLE001
            if attempt == 5 or "404" in str(e):
                raise
            time.sleep(4 * (attempt + 1))  # S3 answers 503 "slow down" now and then


def analyse(t: dt.datetime, profs: dict, rep: dict) -> None:
    path = CACHE / f"{t:%Y%m%d%H}.npz"
    if path.exists():
        return
    near = np.abs(rep["t"] - t.timestamp()) <= REPORT_WINDOW_H * 3600
    save = {"pirep_idx": np.nonzero(near)[0]}
    for model in ("ecmwf", "gfs"):
        if model == "ecmwf":
            grib = retry(ecmwf.EcmwfSource(t, CACHE / "tmp")._download, 0)
            fields, lats, lons = ecmwf.decode(grib)
        else:
            grib = retry(gfs_grib, t)
            fields, lats, lons = gfs_decode(grib)
        mids, edr = ecmwf.global_edr(fields, lats, lons)
        del fields
        grib.unlink(missing_ok=True)
        at = sampler(mids, edr, lats, lons)
        for key, p in profs.items():
            save[f"{model}/{key}"] = at(p["lat"], p["lon"], p["ft"])
        save[f"{model}/pireps"] = at(rep["lat"][near], rep["lon"][near], rep["ft"][near])
    tmp = path.with_suffix(".part.npz")
    np.savez(tmp, **save)
    tmp.rename(path)


# ---------- Summary

def auc(score: np.ndarray, positive: np.ndarray) -> float:
    """The chance the model rates a random positive report above a random other one (ties count half)."""
    ok = ~np.isnan(score)
    s, y = score[ok], positive[ok]
    r = rankdata(s)
    n1, n0 = int(y.sum()), int((~y).sum())
    return round(float((r[y].sum() - n1 * (n1 + 1) / 2) / (n1 * n0)), 3)


def spear(x, y) -> float | None:
    x, y = np.asarray(x, float), np.asarray(y, float)
    ok = ~np.isnan(x) & ~np.isnan(y)
    return round(float(spearmanr(x[ok], y[ok])[0]), 2) if ok.sum() >= 5 else None


def frac_along(p: dict) -> np.ndarray:
    la, lo = np.radians(p["lat"]), np.radians(p["lon"])
    d = np.arccos(np.clip(np.sin(la[0]) * np.sin(la) + np.cos(la[0]) * np.cos(la) * np.cos(lo - lo[0]), -1, 1))
    return d / d[-1]


def share(c: dict, lo: str) -> float:
    order = route_data.CATEGORIES
    t = sum(c.values())
    return sum(c[k] for k in order[order.index(lo):]) / t if t else np.nan


def summarise(times: list[dt.datetime], profs: dict, rep: dict, start: dt.date, end: dt.date) -> dict:
    keys = list(profs)
    used, R = [], {m: {k: [] for k in keys} for m in ("ecmwf", "gfs")}
    P = {m: np.full(len(rep["t"]), np.nan, np.float32) for m in ("ecmwf", "gfs")}
    when = np.full(len(rep["t"]), np.nan)
    for t in times:
        f = CACHE / f"{t:%Y%m%d%H}.npz"
        if not f.exists():
            continue
        z = np.load(f)
        used.append(t)
        idx = z["pirep_idx"]
        closer = np.isnan(when[idx]) | (np.abs(rep["t"][idx] - t.timestamp()) < np.abs(rep["t"][idx] - when[idx]))
        for m in ("ecmwf", "gfs"):
            for k in keys:
                R[m][k].append(z[f"{m}/{k}"])
            P[m][idx[closer]] = z[f"{m}/pireps"][closer]
        when[idx[closer]] = t.timestamp()
    R = {m: {k: np.stack(v) for k, v in R[m].items()} for m in R}
    blend = {k: (R["ecmwf"][k] + R["gfs"][k]) / 2 for k in keys}
    pb = (P["ecmwf"] + P["gfs"]) / 2
    months = np.array([f"{t:%Y-%m}" for t in used])
    month_keys = sorted(set(months))
    cat, ft = rep["cat"], rep["ft"]

    # 1. Report by report
    point = {"reports": int((~np.isnan(pb)).sum()), "auc": {}, "bands": []}
    for name, sel in [("all", np.ones(len(ft), bool)), ("cruise", ft >= 28000), ("mid", (ft >= 20000) & (ft < 28000)), ("low", ft < 20000)]:
        point["auc"][name] = {"moderate": auc(pb[sel], cat[sel] >= 3), "any": auc(pb[sel], cat[sel] >= 1),
                              "n": int((~np.isnan(pb[sel])).sum())}
    for m in ("ecmwf", "gfs"):
        point["auc"][m] = auc(P[m], cat >= 3)
    cruise_rep = (ft >= 20000) & ~np.isnan(pb)
    bands = [0, 0.05, 0.10, 0.15, 0.20, 0.30, None]
    for lo, hi in zip(bands[:-1], bands[1:]):
        s = cruise_rep & (pb >= lo) & ((pb < hi) if hi is not None else True)
        point["bands"].append({"from": lo, "to": hi, "reports": int(s.sum()),
                               "light": round(float((cat[s] >= 1).mean()), 3),
                               "moderate": round(float((cat[s] >= 3).mean()), 3),
                               "severe": round(float((cat[s] >= 4).mean()), 4)})

    # 2. The check routes: the model's picture vs the pilot-report pages
    pages = {frozenset((r["a"]["iata"], r["b"]["iata"])): r
             for r in json.loads(route_data.OUT.read_text())["routes"]}
    tree = cKDTree(route_data.xyz(rep["lat"], rep["lon"]))
    check = {}
    for a, b in CHECK:
        k, p = f"{a}-{b}", profs[f"{a}-{b}"]
        page = pages[frozenset((a, b))]
        along = page["along"] if page["a"]["iata"] == a else page["along"][::-1]
        bins = np.minimum((frac_along(p) * 20).astype(int), 19)
        cruise = p["phase"] == "cruise"
        e = blend[k]
        model_st = [np.mean(e[:, bins == s] >= LIGHT) if (bins == s).any() else np.nan for s in range(20)]
        model_mo = [np.mean(e[months == m][:, cruise] >= LIGHT) for m in month_keys]
        rep_st = [share(s["counts"], "light_moderate") for s in along]
        rep_mo = [share(page["months"][m], "light_moderate") if m in page["months"] else np.nan for m in month_keys]
        # The same, with the model read only at the reports near the route
        picked = {}
        for n, near in enumerate(tree.query_ball_point(route_data.xyz(p["lat"], p["lon"]), r=60 / route_data.EARTH_NM)):
            for q in near:
                if q not in picked and abs(ft[q] - p["ft"][n]) <= 3000 + 0.15 * p["ft"][n]:
                    picked[q] = bins[n]
        q = np.array(list(picked), int)
        qb = np.array(list(picked.values()))
        qm = np.array([dt.datetime.fromtimestamp(rep["t"][i], dt.UTC).strftime("%Y-%m") for i in q])
        at_st = [np.nanmean(pb[q][qb == s] >= LIGHT) if (qb == s).sum() >= 30 else np.nan for s in range(20)]
        at_mo = [np.nanmean(pb[q][qm == m] >= LIGHT) if (qm == m).sum() >= 30 else np.nan for m in month_keys]
        check[k] = {"stretches": spear(model_st, rep_st), "months": spear(model_mo, rep_mo),
                    "stretches_at_reports": spear(at_st, rep_st), "months_at_reports": spear(at_mo, rep_mo),
                    "reports": len(q)}
    median = {f: round(float(np.median([c[f] for c in check.values() if c[f] is not None])), 2)
              for f in ("stretches", "months", "stretches_at_reports", "months_at_reports")}
    passed = {f: sum(1 for c in check.values() if (c[f] or 0) >= 0.5) for f in ("stretches", "months")}

    # 3. International routes, by month: each month's share of cruise minutes at light or more,
    # as a multiple of the route's yearly share (compared within the route, like the other pages).
    def airport(code: str) -> dict:
        ap = airports.lookup(code)
        return {"iata": ap.iata, "icao": ap.icao, "name": ap.name, "city": CITY.get(code, ap.city),
                "country": ap.country, "lat": ap.lat, "lon": ap.lon, "elev_ft": ap.elev_ft, "tz": ap.tz}

    routes = []
    for a, b in INTL:
        k, p = f"{a}-{b}", profs[f"{a}-{b}"]
        cruise = p["phase"] == "cruise"
        e = blend[k][:, cruise] >= LIGHT
        overall = float(e.mean())
        per_model = {m: [np.mean(R[m][k][months == x][:, cruise] >= LIGHT) for x in month_keys] for m in ("ecmwf", "gfs")}
        A, B = airports.lookup(a), airports.lookup(b)
        back = route.build_profile(B, A, dt.datetime(2026, 1, 1, tzinfo=dt.UTC))
        direct = route.distance_nm(A, B)
        routes.append({
            "a": airport(a), "b": airport(b), "page": (a, b) in PAGES,
            "direct_nm": round(direct), "flown_nm": round(route.flown_nm(direct)),
            "airborne_min": {"ab": int(p["minute"][-1]), "ba": back[-1].minute}, "cruise_ft": int(p["ft"].max()),
            "months": {m: round(float(e[months == m].mean()) / overall, 3) for m in month_keys},
            "models_agree": spear(per_model["ecmwf"], per_model["gfs"]),
        })

    return {
        "schema": SCHEMA,
        "period": {"start": start.isoformat(), "end": (end - dt.timedelta(days=1)).isoformat()},
        "generated": dt.date.today().isoformat(),
        "analyses": len(used), "analyses_planned": len(times),
        "method": {"light_edr": LIGHT, "every_min": EVERY_MIN, "report_window_h": REPORT_WINDOW_H,
                   "models": ["ECMWF IFS open data, 0.25°", "NOAA GFS, 0.25°"], "cap": None},
        "sources": SOURCES,
        "point": point,
        "check": {"routes": check, "median": median, "passed": passed, "of": len(check)},
        "routes": routes,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--end", type=dt.date.fromisoformat, help="first day after the period (default: this month's 1st)")
    parser.add_argument("--summary-only", action="store_true", help="skip downloads; summarise what's cached")
    args = parser.parse_args()
    end = args.end or dt.date.today().replace(day=1)
    start = end.replace(year=end.year - 1)
    t0 = dt.datetime(start.year, start.month, start.day, tzinfo=dt.UTC)
    times = [t0 + dt.timedelta(hours=6 * k)
             for k in range(int((dt.datetime(end.year, end.month, end.day, tzinfo=dt.UTC) - t0).total_seconds() // 21600))]
    (CACHE / "tmp").mkdir(parents=True, exist_ok=True)
    rep = load_pireps(start, end)
    profs = profiles()
    print(f"{len(times)} analyses, {len(profs)} routes, {len(rep['t']):,} pilot reports", file=sys.stderr)
    if not args.summary_only:
        began = time.time()
        with ThreadPoolExecutor(6) as pool:
            futures = {pool.submit(analyse, t, profs, rep): t for t in times}
            for n, f in enumerate(futures, 1):
                try:
                    f.result()
                except Exception as e:  # noqa: BLE001
                    print(f"  skipped {futures[f]:%Y-%m-%d %HZ}: {e}", file=sys.stderr)
                if n % 100 == 0:
                    print(f"  {n}/{len(times)} in {(time.time() - began) / 60:.0f} min", file=sys.stderr)
    data = summarise(times, profs, rep, start, end)
    OUT.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}: {data['analyses']} analyses, {len(data['routes'])} routes", file=sys.stderr)


if __name__ == "__main__":
    main()
