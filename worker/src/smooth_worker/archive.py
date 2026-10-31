"""Keep NOAA's GTG turbulence forecast, sampled, so our own outlook can be trained against it.

NOMADS keeps GTG for about two days and nobody archives it, unlike the GFS and ECMWF runs (both
on AWS for years) and pilot reports (Iowa State's archive): those can be fetched again for
training, GTG can't. So as the gtg thread decodes a run, some of its hours are sampled and kept:

- Every 3 hours (00, 03 ... 21Z), the run's f000: GTG's best view of that hour, the target the
  outlook learns from. Those are the GFS and ECMWF steps' valid times.
- Every 6 hours (00, 06, 12, 18Z, as GFS and ECMWF run), f006, f012 and f018: GTG's own
  forecasts, so ours can be compared with NOAA's at the same lead time.

Each hour is sampled on a 0.25 deg grid (the GFS and ECMWF grid) inside GTG's domain: the max and
the mean EDR over the 3 km cells within ~13 km of each point, at every GTG height we decode, as
uint8 in steps of 0.01 (well inside the 0.10 / 0.22 / 0.34 severity steps), heights first, which
compresses best. ~27,500 points x 21 heights, ~390 KB an hour, 20 a day (~230 MB a month: the
free Supabase plan's 1 GB lasts about four months). Each goes to the private
`archive` bucket in Supabase Storage at gtg/YYYY/MM/DD/HHz_fFFF.npz, via a pending folder on the
volume so a failed upload is retried at the next poll.
"""

import logging
import os
import time
from datetime import datetime
from functools import cache
from pathlib import Path

import httpx
import numpy as np

from .sources import gtg
from .sources.grid import lonlat_to_xyz

log = logging.getLogger(__name__)

ENABLED = os.environ.get("SMOOTH_ARCHIVE", "1") != "0"
BUCKET = "archive"
SCHEMA = 1
STEP_DEG = 0.25
# +/- 3 km cells around each sample point: a 27 km box, about one 0.25 deg cell.
WINDOW = 4
EDR_UNIT = 0.01
CHUNK = 1024  # points per gather, to keep the working array small (~1024 x 81 x levels)
# Pending files only pile up while uploads fail; past this the oldest go, so the volume never fills.
PENDING_MAX_BYTES = 300 * 1024**2
# Markers of hours already archived, kept past NOMADS' two days so an hour is never sampled twice.
DONE_KEEP_SECONDS = 4 * 86400
UPLOADS_PER_POLL = 100


def wanted(cycle: datetime, fhr: int) -> bool:
    if fhr == 0:
        return cycle.hour % 3 == 0
    return cycle.hour % 6 == 0 and fhr % 6 == 0


def key(cycle: datetime, fhr: int) -> str:
    return f"gtg/{cycle:%Y/%m/%d}/{cycle:%H}z_f{fhr:03d}.npz"


def _dirs(cache_dir: Path) -> tuple[Path, Path]:
    root = cache_dir / "archive"
    return root / "pending", root / "done"


_points: tuple[np.ndarray, ...] | None = None


def points(grid: gtg.Grid) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """The 0.25 deg points inside GTG's domain, with a whole window of 3 km cells around them:
    lat and lon as quarter degrees (int16), and the nearest cell's row and column. The grid never
    changes, so they're found once per process."""
    global _points
    if _points is None:
        lat4 = np.arange(np.ceil(grid.lats.min() * 4), np.floor(grid.lats.max() * 4) + 1)
        lon4 = np.arange(np.ceil(grid.lons.min() * 4), np.floor(grid.lons.max() * 4) + 1)
        lat4, lon4 = (a.ravel() for a in np.meshgrid(lat4, lon4, indexing="ij"))
        dist, flat = grid.tree.query(lonlat_to_xyz(lat4 * STEP_DEG, lon4 * STEP_DEG))
        j, i = np.unravel_index(flat, grid.shape)
        ny, nx = grid.shape
        inside = (
            (dist < 5.0 / 6371.0)
            & (j >= WINDOW) & (j < ny - WINDOW)
            & (i >= WINDOW) & (i < nx - WINDOW)
        )
        _points = (
            lat4[inside].astype(np.int16), lon4[inside].astype(np.int16),
            j[inside].astype(np.int32), i[inside].astype(np.int32),
        )
    return _points


def _to_uint8(edr: np.ndarray) -> np.ndarray:
    return np.clip(np.rint(edr / EDR_UNIT), 0, 255).astype(np.uint8)


def sample(source: gtg.GtgSource, fhr: int) -> dict[str, np.ndarray]:
    """One decoded hour at the sample points: what goes in its archive file."""
    lat4, lon4, j, i = points(source._grid())
    field = source._load(fhr)
    offsets = np.arange(-WINDOW, WINDOW + 1)
    maxes, means = [], []
    for start in range(0, len(j), CHUNK):
        rows = j[start : start + CHUNK, None, None] + offsets[None, :, None]
        cols = i[start : start + CHUNK, None, None] + offsets[None, None, :]
        block = np.asarray(field.cells[rows, cols], dtype=np.float32)  # (points, 9, 9, levels)
        maxes.append(block.max(axis=(1, 2)))
        means.append(block.mean(axis=(1, 2)))
    return {
        "schema": np.int16(SCHEMA),
        "cycle": np.array(source.cycle.isoformat()),
        "fhr": np.int16(fhr),
        "edr_unit": np.float32(EDR_UNIT),
        "step_deg": np.float32(STEP_DEG),
        "window_cells": np.int16(WINDOW),
        "lat4": lat4,
        "lon4": lon4,
        "levels_ft": field.levels_ft.astype(np.float32),
        "edr_max": _to_uint8(np.concatenate(maxes).T),  # (levels, points)
        "edr_mean": _to_uint8(np.concatenate(means).T),
    }


def save_gtg(source: gtg.GtgSource, fhr: int, cache_dir: Path) -> bool:
    """Sample a decoded hour into the pending folder unless it was archived already. Never
    downloads (an hour not on disk is skipped) and never raises: the archive must not hold up
    decoding for the forecasts. Returns whether it saved."""
    if not ENABLED or not wanted(source.cycle, fhr) or not source.is_cached(fhr):
        return False
    pending, done = _dirs(cache_dir)
    name = key(source.cycle, fhr)
    if (done / name).exists():
        return False
    try:
        arrays = sample(source, fhr)
        path = pending / name
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".part")
        with tmp.open("wb") as f:
            np.savez_compressed(f, **arrays)
        os.replace(tmp, path)
        (done / name).parent.mkdir(parents=True, exist_ok=True)
        (done / name).touch()
        return True
    except Exception:
        log.exception("archive: sampling gtg %s f%03d failed", source.cycle.isoformat(), fhr)
        return False
    finally:
        source.release(fhr)


class Store:
    """The private archive bucket in Supabase Storage, with the service role key."""

    def __init__(self, url: str, service_key: str):
        self.http = httpx.Client(
            base_url=f"{url.rstrip('/')}/storage/v1",
            headers={"apikey": service_key, "Authorization": f"Bearer {service_key}"},
            timeout=60,
        )

    @classmethod
    def from_env(cls) -> "Store | None":
        url, service_key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        return cls(url, service_key) if url and service_key else None

    def put(self, name: str, body: bytes) -> None:
        r = self.http.post(
            f"/object/{BUCKET}/{name}",
            content=body,
            headers={"Content-Type": "application/octet-stream", "x-upsert": "true"},
        )
        r.raise_for_status()


@cache
def _store() -> Store | None:
    return Store.from_env()


def upload_pending(cache_dir: Path, store: Store | None = None, limit: int = UPLOADS_PER_POLL) -> int:
    """Upload pending files, oldest first, deleting each once stored. A failure stops the pass and
    raises, leaving the rest for the next poll. Returns files uploaded."""
    store = store or _store()
    pending, _ = _dirs(cache_dir)
    if not ENABLED or store is None or not pending.exists():
        return 0
    files = sorted(pending.rglob("*.npz"))
    uploaded = 0
    for path in files[:limit]:
        store.put(path.relative_to(pending).as_posix(), path.read_bytes())
        path.unlink()
        uploaded += 1
    return uploaded


def prune(cache_dir: Path, now: float | None = None) -> int:
    """Drop old done markers, and the oldest pending files past PENDING_MAX_BYTES. Returns files removed."""
    now = now or time.time()
    pending, done = _dirs(cache_dir)
    removed = 0
    for marker in done.rglob("*.npz") if done.exists() else []:
        if marker.stat().st_mtime < now - DONE_KEEP_SECONDS:
            marker.unlink(missing_ok=True)
            removed += 1
    files = sorted(pending.rglob("*.npz"), reverse=True) if pending.exists() else []
    total = 0
    for path in files:  # newest first: what's past the cap is the oldest
        total += path.stat().st_size
        if total > PENDING_MAX_BYTES:
            path.unlink(missing_ok=True)
            removed += 1
            log.warning("archive: dropped %s, uploads are failing", path.name)
    return removed
