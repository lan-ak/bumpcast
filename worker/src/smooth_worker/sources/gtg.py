"""NOAA Graphical Turbulence Guidance v4 (DAFS) on the 3 km HRRR grid.

Hourly cycles, forecasts f000-f018, EDR at 51 heights (surface to FL500).
Each file is ~155 MB, so we read the .idx inventory and byte-range only the
EDPARM (all-turbulence EDR) messages at the heights we need, ~1 MB each.
"""

import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

import eccodes
import numpy as np
from scipy.spatial import cKDTree

from ..http import client
from .grid import lonlat_to_xyz

log = logging.getLogger(__name__)

BASE = "https://nomads.ncep.noaa.gov/pub/data/nccf/com/dafs/prod"
MAX_FHR = 18
FT_PER_M = 1 / 0.3048
# Coarser below 10,000 ft (few minutes spent there), every 2,000 ft above.
WANTED_FT = [1000, 4000, 7000, 10000] + list(range(12000, 46000, 2000))
NEIGHBOURHOOD = 1  # +/- cells (3 km each) when taking the local max


def _file(cycle: datetime, fhr: int) -> str:
    return f"{BASE}/dafs.{cycle:%Y%m%d}/dafs.t{cycle:%H}z.gtg.3km.conus.f{fhr:03d}.grib2"


def latest_cycle(now: datetime | None = None) -> datetime | None:
    """Newest cycle whose f018 file is published."""
    now = now or datetime.now(UTC)
    for days_back in (0, 1):
        day = (now - timedelta(days=days_back)).date()
        listing = client().get(f"{BASE}/dafs.{day:%Y%m%d}/")
        if listing.status_code != 200:
            continue
        cycles = sorted(
            {
                int(name.split(".t")[1][:2])
                for name in listing.text.split('"')
                if name.startswith("dafs.t") and name.endswith(f".gtg.3km.conus.f{MAX_FHR:03d}.grib2")
            }
        )
        if cycles:
            return datetime(day.year, day.month, day.day, cycles[-1], tzinfo=UTC)
    return None


@dataclass
class GtgField:
    """EDR for one valid hour: levels_ft (L,), edr (L, ny, nx)."""

    levels_ft: np.ndarray
    edr: np.ndarray


class GtgSource:
    name = "gtg"

    def __init__(self, cycle: datetime, cache_dir: Path):
        self.cycle = cycle
        self.cache_dir = cache_dir / "gtg"
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._fields: dict[int, GtgField] = {}
        self._tree: cKDTree | None = None
        self._shape: tuple[int, int] | None = None

    def covers(self, valid: datetime) -> bool:
        fhr = round((valid - self.cycle).total_seconds() / 3600)
        return 0 <= fhr <= MAX_FHR

    def _download(self, fhr: int) -> Path:
        path = self.cache_dir / f"{self.cycle:%Y%m%d%H}_f{fhr:03d}.grib2"
        if path.exists():
            return path
        url = _file(self.cycle, fhr)
        idx = client().get(url + ".idx")
        idx.raise_for_status()
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
        with tmp.open("wb") as out:
            for start, end in ranges:
                r = client().get(url, headers={"Range": f"bytes={start}-{end}"})
                r.raise_for_status()
                out.write(r.content)
        tmp.rename(path)
        log.info("gtg: cached %s f%03d (%d levels)", self.cycle.isoformat(), fhr, len(ranges))
        return path

    def _load(self, fhr: int) -> GtgField:
        if fhr in self._fields:
            return self._fields[fhr]
        levels, grids = [], []
        with self._download(fhr).open("rb") as f:
            while (gid := eccodes.codes_grib_new_from_file(f)) is not None:
                try:
                    ny, nx = eccodes.codes_get(gid, "Ny"), eccodes.codes_get(gid, "Nx")
                    if self._tree is None:
                        lats = eccodes.codes_get_array(gid, "latitudes")
                        lons = eccodes.codes_get_array(gid, "longitudes")
                        self._tree = cKDTree(lonlat_to_xyz(lats, lons))
                        self._shape = (ny, nx)
                    values = eccodes.codes_get_values(gid).reshape(ny, nx)
                    missing = eccodes.codes_get(gid, "missingValue")
                    values = np.where(values == missing, 0.0, values)
                    levels.append(eccodes.codes_get(gid, "level") * FT_PER_M)
                    grids.append(values.astype(np.float32))
                finally:
                    eccodes.codes_release(gid)
        order = np.argsort(levels)
        field = GtgField(np.array(levels)[order], np.stack(grids)[order])
        self._fields[fhr] = field
        return field

    def in_domain(self, lat: float, lon: float) -> bool:
        if self._tree is None:
            self._load(0)
        dist, _ = self._tree.query(lonlat_to_xyz(np.array([lat]), np.array([lon])))
        return bool(dist[0] < 5.0 / 6371.0)  # within 5 km of a grid point

    def edr(self, lat: float, lon: float, altitude_ft: float, valid: datetime) -> float:
        fhr = round((valid - self.cycle).total_seconds() / 3600)
        field = self._load(fhr)
        _, flat = self._tree.query(lonlat_to_xyz(np.array([lat]), np.array([lon])))
        j, i = np.unravel_index(flat[0], self._shape)
        n = NEIGHBOURHOOD
        window = field.edr[:, max(j - n, 0) : j + n + 1, max(i - n, 0) : i + n + 1].max(axis=(1, 2))
        return float(np.interp(altitude_ft, field.levels_ft, window))
