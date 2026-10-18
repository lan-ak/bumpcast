"""Data for the turbulence map: recent pilot reports and GTG layers by height."""

import hashlib
import logging
from datetime import UTC, datetime, timedelta

import numpy as np

from . import severity
from .http import client
from .sources import GtgSource

log = logging.getLogger(__name__)

PIREP_URL = "https://aviationweather.gov/api/data/pirep"
PIREP_KEEP = timedelta(hours=6)
# Lat/lon box covering the GTG (HRRR) domain.
NORTH, SOUTH, WEST, EAST, STEP = 55.0, 20.0, -130.0, -60.0, 0.25
MAP_LEVELS_FT = [10000, 18000, 24000, 30000, 34000, 38000, 42000]
MAP_FHRS = [0, 3, 6]
NO_DATA = "."

# Reported intensity -> our severity. Ranges ("LGT-MOD") take the stronger end.
PIREP_INTENSITY = {
    "NEG": "smooth",
    "SMTH": "smooth",
    "SMOOTH": "smooth",
    "NIL": "smooth",
    "LGT": "light",
    "LIGHT": "light",
    "LGT-MOD": "moderate",
    "MOD": "moderate",
    "MOD-SEV": "severe",
    "SEV": "severe",
    "SEV-EXTM": "severe",
    "EXTM": "severe",
}


def pirep_rows(reports: list[dict]) -> list[dict]:
    rows = []
    for r in reports:
        intensities = [PIREP_INTENSITY.get((r.get(k) or "").upper()) for k in ("tbInt1", "tbInt2")]
        intensities = [i for i in intensities if i]
        if not intensities or r.get("lat") is None or r.get("lon") is None:
            continue
        worst = max(intensities, key=severity.ORDER.index)
        altitude = r.get("tbTop1") or r.get("tbBas1") or r.get("fltLvl")
        raw = r.get("rawOb") or ""
        rows.append(
            {
                "id": hashlib.sha1(f"{r.get('obsTime')}|{raw}".encode()).hexdigest(),
                "observed_at": datetime.fromtimestamp(r["obsTime"], UTC).isoformat(),
                "lat": r["lat"],
                "lon": r["lon"],
                "altitude_ft": int(altitude) * 100 if altitude else None,
                "intensity": worst,
                "aircraft": r.get("acType") or None,
                "raw": raw[:500],
            }
        )
    # The API can return the same report twice; Postgres rejects duplicate keys in one upsert.
    return list({row["id"]: row for row in rows}.values())


def refresh_pireps(db, now: datetime) -> int:
    r = client().get(
        PIREP_URL, params={"format": "json", "age": "3", "bbox": f"{SOUTH},{WEST},{NORTH},{EAST}"}
    )
    r.raise_for_status()
    rows = pirep_rows(r.json() or [])
    db.upsert_pireps(rows)
    db.prune_pireps(now - PIREP_KEEP)
    return len(rows)


def grid_shape() -> tuple[int, int]:
    return round((NORTH - SOUTH) / STEP) + 1, round((EAST - WEST) / STEP) + 1


def bin_edr(lats: np.ndarray, lons: np.ndarray, edr: np.ndarray) -> np.ndarray:
    """Max EDR of the source points falling in each map cell; NaN where there's no data."""
    ny, nx = grid_shape()
    j = np.rint((NORTH - lats) / STEP).astype(int)
    i = np.rint((lons - WEST) / STEP).astype(int)
    inside = (j >= 0) & (j < ny) & (i >= 0) & (i < nx)
    out = np.full(ny * nx, -1.0)
    np.maximum.at(out, j[inside] * nx + i[inside], edr[inside])
    out[out < 0] = np.nan
    return out


def encode(binned: np.ndarray) -> str:
    chars = np.full(binned.shape, NO_DATA, dtype="<U1")
    valid = ~np.isnan(binned)
    chars[valid & (binned < severity.LIGHT_EDR)] = "0"
    chars[valid & (binned >= severity.LIGHT_EDR)] = "1"
    chars[valid & (binned >= severity.MODERATE_EDR)] = "2"
    chars[valid & (binned >= severity.SEVERE_EDR)] = "3"
    return "".join(chars)


def refresh_grids(db, source: GtgSource) -> int:
    """Rebuild the map layers when a new GTG cycle is out. Returns rows written."""
    latest = db.latest_grid_cycle()
    if latest and datetime.fromisoformat(latest.replace("Z", "+00:00")) >= source.cycle:
        return 0
    ny, nx = grid_shape()
    rows = []
    for fhr in MAP_FHRS:
        lats, lons, levels_ft, edr = source.field(fhr)
        for level in MAP_LEVELS_FT:
            k = int(np.abs(levels_ft - level).argmin())
            rows.append(
                {
                    "valid_at": (source.cycle + timedelta(hours=fhr)).isoformat(),
                    "level_ft": level,
                    "cycle": source.cycle.isoformat(),
                    "north": NORTH,
                    "west": WEST,
                    "step": STEP,
                    "ny": ny,
                    "nx": nx,
                    "cells": encode(bin_edr(lats, lons, edr[k].ravel())),
                }
            )
        source.release(fhr)  # each hour's 3D field is ~160 MB; the worker VM has 1 GB
    db.replace_grids(source.cycle, rows)
    log.info("map: stored %d layers for GTG %s", len(rows), source.cycle.isoformat())
    return len(rows)
