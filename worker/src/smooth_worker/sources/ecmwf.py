"""Our clear-air turbulence outlook from ECMWF's free IFS model, alongside the GFS one.

ECMWF (the European model) is usually the better of the two global models, most of all over
the Atlantic and Europe, where GTG doesn't reach. Its open data (CC BY 4.0, commercial use
allowed with credit) has the same pressure-level winds, heights and temperatures GFS gives us,
so the turbulence diagnostics are GFS's own (`gfs.blend_edr`), run on ECMWF's fields.

Runs at 00/06/12/18Z, 3-hourly steps to 144 h, published ~6.5 h after the run begins, on AWS
(the same files as data.ecmwf.int, without its connection limits). Fields only come as the
whole globe, so each step is byte-ranged out of its ~120 MB file (~17 MB of it), turned into
EDR once, and kept on disk as small integers (~17 MB a step). A thread decodes a new run's
steps ahead of the forecasts, as for GTG; forecasts only use a run decoded in full.
"""

import json
import logging
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path

import eccodes
import numpy as np

from ..http import client, get_with_retry
from .gfs import G, MAX_OUTLOOK_EDR, NEEDED_FHR, NEIGHBOURHOOD, blend_edr

log = logging.getLogger(__name__)

BASE = "https://ecmwf-forecasts.s3.eu-central-1.amazonaws.com"
# GFS's levels, less 350 hPa (not in the open data).
LEVELS_MB = [850, 700, 600, 500, 400, 300, 250, 200, 150]
PARAMS = ("u", "v", "t", "gh")
STEP_H = 3
MAX_STEP = 144  # 3-hourly to here in every run
NEEDED_STEP = -(-NEEDED_FHR // STEP_H) * STEP_H
# Rows per band when turning a step into EDR: keeps the working arrays small.
BAND_ROWS = 60
# Stored as uint8: EDR in steps of 0.002 (to 0.51), layer heights in steps of 250 ft (to 63,750).
EDR_UNIT = 0.002
FT_UNIT = 250
KEEP_CYCLES = 2
CREDIT = "Contains ECMWF open data (CC BY 4.0)"


def _url(cycle: datetime, step: int, ext: str) -> str:
    return f"{BASE}/{cycle:%Y%m%d}/{cycle:%H}z/ifs/0p25/oper/{cycle:%Y%m%d%H}0000-{step}h-oper-fc.{ext}"


def latest_cycle(now: datetime | None = None) -> datetime | None:
    """Newest run with every step we need published."""
    now = now or datetime.now(UTC)
    start = now.replace(hour=now.hour - now.hour % 6, minute=0, second=0, microsecond=0)
    for k in range(6):
        cycle = start - timedelta(hours=6 * k)
        if client().head(_url(cycle, NEEDED_STEP, "index")).status_code == 200:
            return cycle
    return None


def _ranges(index_text: str, step: int) -> list[tuple[int, int]]:
    """Byte ranges (start, end inclusive) of the fields we read, neighbours merged into one."""
    wanted = []
    for line in index_text.splitlines():
        entry = json.loads(line)
        if entry.get("levtype") == "pl" and entry.get("param") in PARAMS and int(entry.get("levelist", 0)) in LEVELS_MB:
            wanted.append((entry["_offset"], entry["_offset"] + entry["_length"] - 1))
        elif step == 0 and entry.get("levtype") == "sfc" and entry.get("param") == "z":
            wanted.append((entry["_offset"], entry["_offset"] + entry["_length"] - 1))  # terrain
    merged: list[tuple[int, int]] = []
    for start, end in sorted(wanted):
        if merged and start == merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], end)
        else:
            merged.append((start, end))
    return merged


def decode(path: Path) -> tuple[dict, np.ndarray, np.ndarray]:
    """Fields {(shortName, level_mb) or ("orog", 0): (ny, nx) float32}, lats (north first) and
    lons 0..360 ascending: the open data runs -180..180, so columns are rolled to start at 0."""
    fields, lats, lons, roll = {}, None, None, 0
    with path.open("rb") as f:
        while (gid := eccodes.codes_grib_new_from_file(f)) is not None:
            try:
                ny, nx = eccodes.codes_get(gid, "Nj"), eccodes.codes_get(gid, "Ni")
                if lats is None:
                    lats = eccodes.codes_get_array(gid, "latitudes").reshape(ny, nx)[:, 0]
                    lons = eccodes.codes_get_array(gid, "longitudes").reshape(ny, nx)[0, :] % 360
                    roll = -int(np.argmin(lons))
                    lons = np.roll(lons, roll)
                values = np.roll(eccodes.codes_get_values(gid).reshape(ny, nx).astype(np.float32), roll, axis=1)
                short = eccodes.codes_get(gid, "shortName")
                if eccodes.codes_get(gid, "typeOfLevel") == "isobaricInhPa":
                    fields[(short, eccodes.codes_get(gid, "level"))] = values
                elif short == "z":
                    fields[("orog", 0)] = values / G  # surface geopotential -> metres
            finally:
                eccodes.codes_release(gid)
    return fields, lats, lons


def global_edr(fields: dict, lats: np.ndarray, lons: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """`gfs.blend_edr` over the whole globe, stored form: (layer_mid_ft / FT_UNIT, edr / EDR_UNIT),
    each (L, ny, nx) uint8. Done in bands of latitude to save memory, with columns wrapped around
    so gradients carry across 0 deg (the Greenwich meridian: London, the Channel, western France)."""
    wrap = 2
    padded_lons = np.concatenate([lons[-wrap:] - 360, lons, lons[:wrap] + 360])
    ny = len(lats)
    mids_out = edr_out = None
    for top in range(0, ny, BAND_ROWS):
        lo, hi = max(top - 1, 0), min(top + BAND_ROWS + 1, ny)  # a row each side for gradients
        band = {k: np.concatenate([v[lo:hi, -wrap:], v[lo:hi], v[lo:hi, :wrap]], axis=1) for k, v in fields.items()}
        mids, edr = blend_edr(band, lats[lo:hi], padded_lons)
        keep = (slice(None), slice(top - lo, top - lo + min(BAND_ROWS, ny - top)), slice(wrap, -wrap))
        if mids_out is None:
            mids_out = np.empty((mids.shape[0], ny, len(lons)), np.uint8)
            edr_out = np.empty_like(mids_out)
        mids_out[:, top : top + BAND_ROWS] = np.clip(np.rint(mids[keep] / FT_UNIT), 0, 255)
        edr_out[:, top : top + BAND_ROWS] = np.clip(np.rint(edr[keep] / EDR_UNIT), 0, 255)
    return mids_out, edr_out


def _save(path: Path, array: np.ndarray) -> None:
    tmp = path.with_name(path.name + ".part")
    with tmp.open("wb") as f:
        np.save(f, array)
    os.replace(tmp, path)


def _cycle_dir(cache_dir: Path) -> Path:
    return cache_dir / "ecmwf"


def ready_cycles(cache_dir: Path) -> list[datetime]:
    """Runs with every step we need decoded on disk, newest first."""
    stems = {f.name.split("_")[0] for f in _cycle_dir(cache_dir).glob("*_s*.mids.npy")}
    cycles = {datetime.strptime(stem, "%Y%m%d%H").replace(tzinfo=UTC) for stem in stems}
    return sorted((c for c in cycles if EcmwfSource(c, cache_dir).is_ready()), reverse=True)


def prune(cache_dir: Path, keep: int = KEEP_CYCLES) -> int:
    """Delete decoded steps of all but `keep` runs: the newest (it may still be decoding) and the
    newest decoded in full. Returns files removed."""
    files = list(_cycle_dir(cache_dir).glob("*_s*.npy"))
    cycles = sorted({f.name.split("_")[0] for f in files}, reverse=True)
    complete = [f"{c:%Y%m%d%H}" for c in ready_cycles(cache_dir)]
    kept = list(dict.fromkeys(cycles[:1] + complete[:1] + cycles))[:keep]
    stale = [f for f in files if f.name.split("_")[0] not in kept]
    for f in stale:
        f.unlink(missing_ok=True)
    return len(stale)


class EcmwfSource:
    name = "ecmwf"

    def __init__(self, cycle: datetime, cache_dir: Path):
        self.cycle = cycle
        self.cache_dir = _cycle_dir(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._steps: dict[int, tuple[np.ndarray, np.ndarray]] = {}
        self._grid: tuple[np.ndarray, np.ndarray] | None = None

    def covers(self, valid: datetime) -> bool:
        hours = (valid - self.cycle).total_seconds() / 3600
        return 0 <= hours <= MAX_STEP

    def covers_point(self, lat: float, lon: float) -> bool:
        return True  # global

    def _paths(self, step: int) -> tuple[Path, Path]:
        stem = f"{self.cycle:%Y%m%d%H}_s{step:03d}"
        return self.cache_dir / f"{stem}.mids.npy", self.cache_dir / f"{stem}.edr.npy"

    def _grid_paths(self) -> tuple[Path, Path, Path]:
        return self.cache_dir / "lats.npy", self.cache_dir / "lons.npy", self.cache_dir / "orog.npy"

    def is_cached(self, step: int) -> bool:
        return all(p.exists() for p in self._paths(step))

    def is_ready(self) -> bool:
        return all(self.is_cached(s) for s in range(0, NEEDED_STEP + 1, STEP_H))

    def _download(self, step: int) -> Path:
        path = self.cache_dir / f"{self.cycle:%Y%m%d%H}_s{step:03d}.grib2"
        if path.exists():
            return path
        index = get_with_retry(_url(self.cycle, step, "index"))
        index.raise_for_status()
        url = _url(self.cycle, step, "grib2")
        tmp = path.with_suffix(".part")
        try:
            with tmp.open("wb") as out:
                for start, end in _ranges(index.text, step):
                    r = get_with_retry(url, headers={"Range": f"bytes={start}-{end}"})
                    r.raise_for_status()
                    out.write(r.content)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
        tmp.rename(path)
        return path

    def cache(self, step: int) -> bool:
        """Turn one step into EDR on disk unless it's there already. Returns whether it decoded."""
        if self.is_cached(step):
            return False
        lats_path, lons_path, orog_path = self._grid_paths()
        if step != 0 and not orog_path.exists():
            self.cache(0)  # the terrain comes with step 0 only
        grib = self._download(step)
        fields, lats, lons = decode(grib)
        if ("orog", 0) in fields:
            if not orog_path.exists():
                _save(lats_path, lats)
                _save(lons_path, lons)
                _save(orog_path, fields[("orog", 0)])
        else:
            fields[("orog", 0)] = np.load(orog_path)
        mids, edr = global_edr(fields, lats, lons)
        del fields
        mids_path, edr_path = self._paths(step)
        _save(edr_path, edr)
        _save(mids_path, mids)  # last: marks it done
        grib.unlink(missing_ok=True)
        log.info("ecmwf: decoded %s step %d", self.cycle.isoformat(), step)
        return True

    def _load(self, step: int) -> tuple[np.ndarray, np.ndarray]:
        if step not in self._steps:
            self.cache(step)
            mids_path, edr_path = self._paths(step)
            self._steps[step] = (np.load(mids_path, mmap_mode="r"), np.load(edr_path, mmap_mode="r"))
        return self._steps[step]

    def _lat_lon(self) -> tuple[np.ndarray, np.ndarray]:
        if self._grid is None:
            lats_path, lons_path, _ = self._grid_paths()
            if not lats_path.exists():
                self.cache(0)
            self._grid = np.load(lats_path), np.load(lons_path)
        return self._grid

    def edr(self, lat: float, lon: float, altitude_ft: float, valid: datetime) -> float:
        step = min(max(round((valid - self.cycle).total_seconds() / 3600 / STEP_H) * STEP_H, 0), MAX_STEP)
        mids, edr = self._load(step)
        lats, lons = self._lat_lon()
        j = int(np.abs(lats - lat).argmin())
        i = int(np.abs(lons - (lon % 360)).argmin())
        # As for GFS: average neighbouring cells, wrapping across 0 deg.
        n = NEIGHBOURHOOD
        cols = np.arange(i - n, i + n + 1) % len(lons)
        rows = slice(max(j - n, 0), j + n + 1)
        profile = edr[:, rows][:, :, cols].astype(np.float32).mean(axis=(1, 2)) * EDR_UNIT
        heights = mids[:, j, i].astype(np.float32) * FT_UNIT
        return min(float(np.interp(altitude_ft, heights, profile)), MAX_OUTLOOK_EDR)
