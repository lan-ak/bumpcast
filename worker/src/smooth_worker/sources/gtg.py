"""NOAA Graphical Turbulence Guidance v4 (DAFS) on the 3 km HRRR grid.

Hourly cycles, forecasts f000-f018, EDR at 51 heights (surface to FL500).
Each file is ~155 MB, so we read the .idx inventory and byte-range only the
EDPARM (all-turbulence EDR) messages at the heights we need, ~1 MB each.

Decoding an hour takes 3-6 s on the worker, so each hour is decoded once per cycle and kept on
disk as a raw array (~80 MB), levels innermost so one grid cell's whole column is contiguous.
Forecasts memory-map it and read only the cells along their route. The worker's poll decodes a
new cycle's hours ahead of time.
"""

import logging
import os
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

import eccodes
import numpy as np
from scipy.spatial import cKDTree

from ..http import client
from ..severity import SEVERE_EDR
from .grid import lonlat_to_xyz

log = logging.getLogger(__name__)

BASE = "https://nomads.ncep.noaa.gov/pub/data/nccf/com/dafs/prod"
MAX_FHR = 18
FT_PER_M = 1 / 0.3048
# Coarser below 10,000 ft (few minutes spent there), every 2,000 ft above.
WANTED_FT = [1000, 4000, 7000, 10000] + list(range(12000, 46000, 2000))
NEIGHBOURHOOD = 1  # +/- cells (3 km each) when taking the local max
# Decoded hours of this many cycles stay on disk (the newest, and the one before while sources
# built from it are still in use, or for the lagged ensemble).
KEEP_CYCLES = 2
# A run normally publishes within ~2.5 h. One older than this has too little of its 18 h left to
# be worth forecasting with: it only turns up when a listing failed and fell back to yesterday.
MAX_CYCLE_AGE = timedelta(hours=MAX_FHR - 6)
# NOMADS answers a file it hasn't published yet with 404, and a client it's throttling with 429 or
# a 302 that has no Location (httpx can't follow it). Neither means the run is broken: try later.
UNAVAILABLE = {302, 404, 429}


class Unavailable(Exception):
    """NOMADS didn't serve a GTG file this time: not published yet, or throttling us."""

    def __init__(self, url: str, status: int):
        super().__init__(f"HTTP {status} for {url.rsplit('/', 1)[-1]}")
        self.url = url
        self.status = status


def _get(url: str, **kwargs):
    r = client().get(url, **kwargs)
    if r.status_code in UNAVAILABLE or r.status_code >= 500:
        raise Unavailable(url, r.status_code)
    r.raise_for_status()
    return r


def _file(cycle: datetime, fhr: int) -> str:
    return f"{BASE}/dafs.{cycle:%Y%m%d}/dafs.t{cycle:%H}z.gtg.3km.conus.f{fhr:03d}.grib2"


def latest_cycle(now: datetime | None = None) -> datetime | None:
    """Newest cycle whose f018 file is published."""
    cycles = latest_cycles(now, 1)
    return cycles[0] if cycles else None


def latest_cycles(now: datetime | None = None, count: int = 2) -> list[datetime]:
    """The newest `count` cycles whose f018 file is published, newest first. Only recent runs:
    a throttled listing finds none rather than falling back to yesterday's."""
    now = now or datetime.now(UTC)
    found: list[datetime] = []
    for days_back in (0, 1):
        day = (now - timedelta(days=days_back)).date()
        listing = client().get(f"{BASE}/dafs.{day:%Y%m%d}/")
        if listing.status_code == 404:
            continue  # early in the UTC day, before today's directory exists
        if listing.status_code != 200:
            log.warning("gtg: NOMADS listing HTTP %d (throttled or down)", listing.status_code)
            break
        cycles = sorted(
            {
                int(name.split(".t")[1][:2])
                for name in listing.text.split('"')
                if name.startswith("dafs.t") and name.endswith(f".gtg.3km.conus.f{MAX_FHR:03d}.grib2")
            }
        )
        found += [datetime(day.year, day.month, day.day, h, tzinfo=UTC) for h in reversed(cycles)]
        if len(found) >= count:
            break
    return [c for c in found if now - c <= MAX_CYCLE_AGE][:count]


@dataclass
class GtgField:
    """EDR for one valid hour: levels_ft (L,), cells (ny, nx, L), memory-mapped from disk."""

    levels_ft: np.ndarray
    cells: np.ndarray


class Grid:
    """The fixed 3 km HRRR grid: flat lats and lons (-180..180), its shape, and a lookup tree.
    The same for every cycle, so it's read once per process and the tree is built once."""

    def __init__(self, lats: np.ndarray, lons: np.ndarray, shape: tuple[int, int]):
        self.lats, self.lons, self.shape = lats, lons, shape
        self._tree: cKDTree | None = None

    @property
    def tree(self) -> cKDTree:
        if self._tree is None:
            self._tree = cKDTree(lonlat_to_xyz(self.lats, self.lons))
        return self._tree


_grid: Grid | None = None


def _grid_paths(cache_dir: Path) -> tuple[Path, Path]:
    return cache_dir / "grid_lats.npy", cache_dir / "grid_lons.npy"


def _save(path: Path, array: np.ndarray) -> None:
    """Write atomically, so a crash never leaves a half-written array that looks complete."""
    tmp = path.with_name(path.name + ".part")
    with tmp.open("wb") as f:
        np.save(f, array)
    os.replace(tmp, path)


def decode(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """One hour's GRIB: levels_ft (L,), edr (L, ny, nx) float16, lats and lons (ny, nx)."""
    levels, grids, lats, lons = [], [], None, None
    with path.open("rb") as f:
        while (gid := eccodes.codes_grib_new_from_file(f)) is not None:
            try:
                ny, nx = eccodes.codes_get(gid, "Ny"), eccodes.codes_get(gid, "Nx")
                if lats is None:
                    lats = eccodes.codes_get_array(gid, "latitudes").reshape(ny, nx)
                    lons = eccodes.codes_get_array(gid, "longitudes").reshape(ny, nx)
                    lons = np.where(lons > 180, lons - 360, lons)
                values = eccodes.codes_get_values(gid).reshape(ny, nx)
                missing = eccodes.codes_get(gid, "missingValue")
                values = np.where(values == missing, 0.0, values)
                levels.append(eccodes.codes_get(gid, "level") * FT_PER_M)
                grids.append(values.astype(np.float16))  # EDR 0-1; 3 significant digits is plenty
            finally:
                eccodes.codes_release(gid)
    order = np.argsort(levels)
    return np.array(levels)[order], np.stack(grids)[order], lats, lons


def ready_cycles(cache_dir: Path) -> list[datetime]:
    """Cycles with every hour decoded on disk, newest first."""
    stems = [f.name.split("_")[0] for f in (cache_dir / "gtg").glob("*_f*.levels.npy")]
    cycles = {datetime.strptime(stem, "%Y%m%d%H").replace(tzinfo=UTC) for stem in stems}
    return sorted((c for c in cycles if all(GtgSource(c, cache_dir).is_cached(h) for h in range(MAX_FHR + 1))), reverse=True)


def prune(cache_dir: Path, keep: int = KEEP_CYCLES) -> int:
    """Delete decoded hours of all but `keep` cycles: the newest (it may still be decoding), the
    newest one decoded in full, then the newest others. A complete run is never dropped for newer
    ones that are only partly decoded (one left unfinished while NOMADS throttled us, then
    overtaken by the next): forecasts would have no run to read. Returns files removed."""
    gtg_dir = cache_dir / "gtg"
    files = list(gtg_dir.glob("*_f*.cells.npy")) + list(gtg_dir.glob("*_f*.levels.npy"))
    cycles = sorted({f.name.split("_")[0] for f in files}, reverse=True)
    complete = [f"{c:%Y%m%d%H}" for c in ready_cycles(cache_dir)]
    kept = list(dict.fromkeys(cycles[:1] + complete[:1] + cycles))[:keep]
    # Plus the level-first layout of the first version of this cache.
    stale = [f for f in files if f.name.split("_")[0] not in kept] + list(gtg_dir.glob("*_f*.edr.npy"))
    for f in stale:
        f.unlink(missing_ok=True)
    return len(stale)


class GtgSource:
    name = "gtg"

    def __init__(self, cycle: datetime, cache_dir: Path):
        self.cycle = cycle
        self.cache_dir = cache_dir / "gtg"
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._fields: dict[int, GtgField] = {}

    horizon_h = MAX_FHR

    def covers(self, valid: datetime) -> bool:
        fhr = round((valid - self.cycle).total_seconds() / 3600)
        return 0 <= fhr <= MAX_FHR

    def covers_point(self, lat: float, lon: float) -> bool:
        return self.in_domain(lat, lon)

    def _download(self, fhr: int) -> Path:
        path = self.cache_dir / f"{self.cycle:%Y%m%d%H}_f{fhr:03d}.grib2"
        if path.exists():
            return path
        url = _file(self.cycle, fhr)
        idx = _get(url + ".idx")
        lines = [line.split(":") for line in idx.text.strip().splitlines()]
        ranges = []
        for i, parts in enumerate(lines):
            if parts[3] != "EDPARM" or "above mean sea level" not in parts[4]:
                continue
            level_ft = round(float(parts[4].split()[0]) * FT_PER_M, -2)
            if not any(abs(level_ft - w) <= 300 for w in WANTED_FT):
                continue
            start = int(parts[1])
            end = int(lines[i + 1][1]) - 1 if i + 1 < len(lines) else ""
            ranges.append((start, end))
        tmp = path.with_suffix(".part")
        try:
            with tmp.open("wb") as out:
                for start, end in ranges:
                    out.write(_get(url, headers={"Range": f"bytes={start}-{end}"}).content)
        except BaseException:
            tmp.unlink(missing_ok=True)  # never leave half a file behind
            raise
        tmp.rename(path)
        log.info("gtg: cached %s f%03d (%d levels)", self.cycle.isoformat(), fhr, len(ranges))
        return path

    def _paths(self, fhr: int) -> tuple[Path, Path]:
        stem = f"{self.cycle:%Y%m%d%H}_f{fhr:03d}"
        return self.cache_dir / f"{stem}.levels.npy", self.cache_dir / f"{stem}.cells.npy"

    def is_cached(self, fhr: int) -> bool:
        return all(p.exists() for p in self._paths(fhr))

    def cache(self, fhr: int) -> bool:
        """Decode the hour to disk unless it's there already. Returns whether it decoded."""
        if self.is_cached(fhr):
            return False
        grib = self._download(fhr)
        levels, edr, lats, lons = decode(grib)
        lats_path, lons_path = _grid_paths(self.cache_dir)
        if not lats_path.exists() or not lons_path.exists():
            _save(lats_path, lats)
            _save(lons_path, lons)
        levels_path, cells_path = self._paths(fhr)
        _save(cells_path, np.ascontiguousarray(np.moveaxis(edr, 0, -1)))
        _save(levels_path, levels)  # last: its presence marks the hour complete
        grib.unlink(missing_ok=True)  # the decoded arrays replace it
        return True

    def _grid(self) -> Grid:
        global _grid
        if _grid is None:
            lats_path, lons_path = _grid_paths(self.cache_dir)
            if not lats_path.exists():
                self.cache(0)
            lats, lons = np.load(lats_path), np.load(lons_path)
            _grid = Grid(lats.ravel(), lons.ravel(), lats.shape)
        return _grid

    def _load(self, fhr: int) -> GtgField:
        if fhr not in self._fields:
            self.cache(fhr)
            levels_path, cells_path = self._paths(fhr)
            self._fields[fhr] = GtgField(np.load(levels_path), np.load(cells_path, mmap_mode="r"))
        return self._fields[fhr]

    def field(self, fhr: int) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        """Raw grid for the map: flat lats, flat lons (-180..180), levels_ft, edr[level, ny, nx]."""
        f = self._load(fhr)
        grid = self._grid()
        return grid.lats, grid.lons, f.levels_ft, np.moveaxis(f.cells, -1, 0)

    def release(self, fhr: int) -> None:
        self._fields.pop(fhr, None)

    def _nearest(self, lat: float, lon: float) -> tuple[float, int]:
        """Distance (radians) and flat index of the closest grid point. The tree is built on first use."""
        dist, flat = self._grid().tree.query(lonlat_to_xyz(np.array([lat]), np.array([lon])))
        return float(dist[0]), int(flat[0])

    def in_domain(self, lat: float, lon: float) -> bool:
        dist, _ = self._nearest(lat, lon)
        return dist < 5.0 / 6371.0  # within 5 km of a grid point

    def edr(self, lat: float, lon: float, altitude_ft: float, valid: datetime) -> float:
        fhr = round((valid - self.cycle).total_seconds() / 3600)
        field = self._load(fhr)
        _, flat = self._nearest(lat, lon)
        j, i = np.unravel_index(flat, self._grid().shape)
        n = NEIGHBOURHOOD
        window = field.cells[max(j - n, 0) : j + n + 1, max(i - n, 0) : i + n + 1].max(axis=(0, 1))
        return float(np.interp(altitude_ft, field.levels_ft, window.astype(np.float32)))


class GtgEnsemble:
    """The newest GTG run blended with the one before (a "lagged ensemble").

    Consecutive hourly runs disagree a little; blending them keeps a forecast from
    jumping around between updates. The newest run still decides when it calls
    severe, so averaging never hides it.
    """

    name = "gtg"
    horizon_h = MAX_FHR
    WEIGHTS = (0.65, 0.35)

    def __init__(self, members: list[GtgSource]):
        self.members = members
        self.newest = members[0]
        self.cycle = self.newest.cycle

    def covers(self, valid: datetime) -> bool:
        return self.newest.covers(valid)

    def covers_point(self, lat: float, lon: float) -> bool:
        return self.newest.covers_point(lat, lon)

    def in_domain(self, lat: float, lon: float) -> bool:
        return self.newest.in_domain(lat, lon)

    def edr(self, lat: float, lon: float, altitude_ft: float, valid: datetime) -> float:
        newest = self.newest.edr(lat, lon, altitude_ft, valid)
        if newest >= SEVERE_EDR:
            return newest
        total, weight = newest * self.WEIGHTS[0], self.WEIGHTS[0]
        for member, w in zip(self.members[1:], self.WEIGHTS[1:]):
            if member.covers(valid):
                total += member.edr(lat, lon, altitude_ft, valid) * w
                weight += w
        return total / weight
