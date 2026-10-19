"""Our own clear-air turbulence outlook from the free global GFS model.

Used wherever GTG doesn't reach: beyond its 18-hour horizon, and anywhere
outside the US. Like GTG (on a much coarser grid), it blends several
turbulence diagnostics, each mapped onto the EDR scale so the app treats
every source the same way:

- Ellrod TI1: vertical wind shear x deformation.
- Ellrod TI2: vertical wind shear x (deformation + convergence).
- Vertical wind shear on its own.
- Richardson number (stability vs shear).
- Mountain waves: wind blowing across steep terrain near the ground.

The mappings are literature starting points to calibrate against pilot
reports and after-landing ratings.

GFS is fetched in tiles (40 deg lon x 30 deg lat, ~1 MB per forecast hour),
so a route only downloads the part of the world it flies over.
"""

import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path

import eccodes
import numpy as np

from ..http import client, get_with_retry

log = logging.getLogger(__name__)

FILTER = "https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl"
LISTING = "https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod"
LEVELS_MB = [850, 700, 600, 500, 400, 350, 300, 250, 200, 150]
NEEDED_FHR = 78  # 48 h lead + longest flights (~19 h) + cycle latency
EARTH_RADIUS_M = 6_371_000.0
FT_PER_M = 1 / 0.3048
G = 9.81

TILE_LON, TILE_LAT = 40, 30
TILE_MARGIN = 1.0  # deg; room for gradients and the neighbourhood at tile edges
MAX_TILES_IN_MEMORY = 200  # each is well under 1 MB

# Each diagnostic -> EDR, as piecewise-linear (index, EDR) points.
# Ellrod's own TI guidance (x1e-7 s^-2): ~4 light-moderate, ~8 moderate, ~12 moderate-severe.
TI_POINTS = [0.0, 4.0, 8.0, 12.0, 20.0]
EDR_POINTS = [0.03, 0.12, 0.22, 0.34, 0.50]
# Vertical shear (s^-1): 6 kt per 1,000 ft (~0.010) is the classic light-moderate rule of thumb.
VWS_POINTS = [0.0, 0.005, 0.010, 0.015, 0.020]
VWS_EDR = [0.03, 0.08, 0.15, 0.24, 0.34]
# Richardson number: below ~0.25 the layer overturns; a 0.25 deg grid smooths it, so be generous.
RI_POINTS = [0.25, 0.5, 1.0, 2.0, 5.0]
RI_EDR = [0.34, 0.24, 0.15, 0.08, 0.03]
# Terrain-forced vertical motion (m/s) from low-level wind across slopes. A 0.25 deg grid
# flattens mountains a lot, so even modest forced motion counts.
MW_POINTS = [0.0, 0.15, 0.3, 0.6, 1.0]
MW_EDR = [0.03, 0.10, 0.16, 0.22, 0.26]
MW_MAX_FT = 45000

# Each point takes the mean of its two strongest diagnostics. A plain mean of all four
# washed real bumps out (the measures rarely all fire at once on a coarse grid); the
# single strongest raised too many false alarms. Checked against GTG and pilot reports
# over the US on 2026-10-18; recheck once after-landing ratings come in.
BLEND_TOP = 2
NEIGHBOURHOOD = 1  # +/- cells (0.25 deg, ~25 km) averaged around each point
# One global model can't credibly call severe turbulence; only GTG (or an official
# warning) may. Cap just below the severe threshold.
MAX_OUTLOOK_EDR = 0.30


def latest_cycle(now: datetime | None = None) -> datetime | None:
    """Newest GFS cycle with output published far enough ahead."""
    now = now or datetime.now(UTC)
    start = now.replace(hour=now.hour - now.hour % 6, minute=0, second=0, microsecond=0)
    for k in range(6):
        cycle = start - timedelta(hours=6 * k)
        url = f"{LISTING}/gfs.{cycle:%Y%m%d}/{cycle:%H}/atmos/"
        listing = client().get(url)
        if listing.status_code == 200 and f"gfs.t{cycle:%H}z.pgrb2.0p25.f{NEEDED_FHR:03d}\"" in listing.text:
            return cycle
    return None


def tile_of(lat: float, lon: float) -> tuple[int, int]:
    lon360 = lon % 360
    return min(int(lon360 // TILE_LON), 360 // TILE_LON - 1), min(int((lat + 90) // TILE_LAT), 180 // TILE_LAT - 1)


def tile_box(tile: tuple[int, int]) -> dict[str, float]:
    i, j = tile
    return {
        "leftlon": max(0.0, i * TILE_LON - TILE_MARGIN),
        "rightlon": min(359.75, (i + 1) * TILE_LON + TILE_MARGIN),
        "bottomlat": max(-90.0, j * TILE_LAT - 90 - TILE_MARGIN),
        "toplat": min(90.0, (j + 1) * TILE_LAT - 90 + TILE_MARGIN),
    }


def blend_edr(fields: dict, lats: np.ndarray, lons: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(layer_mid_ft[L, ny, nx], edr[L, ny, nx]) from GFS winds, heights and temperatures.

    `fields` maps (shortName, level_mb) -> 2D array, plus ("orog", 0) for terrain height.
    `lats` runs along axis 0, `lons` (deg, any range) along axis 1.
    """
    lat_rad = np.radians(lats)[:, None]
    cos_lat = np.maximum(np.cos(lat_rad), 0.05)  # gradients blow up at the poles
    y_m = EARTH_RADIUS_M * np.radians(lats)
    lon_rad = np.radians(lons)

    def gradients(field: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        d_dy = np.gradient(field, y_m, axis=0)
        d_dx = np.gradient(field, lon_rad, axis=1) / (EARTH_RADIUS_M * cos_lat)
        return d_dx, d_dy

    levels = [mb for mb in LEVELS_MB if ("u", mb) in fields]
    mids, edrs = [], []
    for lower, upper in zip(levels, levels[1:]):
        u1, v1, z1, t1 = (fields[(k, lower)] for k in ("u", "v", "gh", "t"))
        u2, v2, z2, t2 = (fields[(k, upper)] for k in ("u", "v", "gh", "t"))
        dz = np.maximum(z2 - z1, 1.0)
        vws = np.hypot(u2 - u1, v2 - v1) / dz
        u, v = (u1 + u2) / 2, (v1 + v2) / 2
        du_dx, du_dy = gradients(u)
        dv_dx, dv_dy = gradients(v)
        deformation = np.hypot(du_dx - dv_dy, dv_dx + du_dy)
        convergence = -(du_dx + dv_dy)
        ti1 = vws * deformation * 1e7
        ti2 = vws * np.maximum(deformation + convergence, 0.0) * 1e7

        theta1 = t1 * (1000 / lower) ** 0.286
        theta2 = t2 * (1000 / upper) ** 0.286
        n2 = np.maximum(G / ((theta1 + theta2) / 2) * (theta2 - theta1) / dz, 1e-6)
        ri = n2 / np.maximum(vws**2, 1e-10)

        diagnostics = np.stack(
            [
                np.interp(ti1, TI_POINTS, EDR_POINTS),
                np.interp(ti2, TI_POINTS, EDR_POINTS),
                np.interp(vws, VWS_POINTS, VWS_EDR),
                np.interp(ri, RI_POINTS, RI_EDR),
            ]
        )
        edrs.append(np.sort(diagnostics, axis=0)[-BLEND_TOP:].mean(axis=0))
        mids.append((z1 + z2) / 2 * FT_PER_M)
    mids, edrs = np.stack(mids), np.stack(edrs)

    if ("orog", 0) in fields and ("u", 700) in fields:
        dh_dx, dh_dy = gradients(fields[("orog", 0)])
        forced_w = np.abs(fields[("u", 700)] * dh_dx + fields[("v", 700)] * dh_dy)
        mountain = np.interp(forced_w, MW_POINTS, MW_EDR)
        edrs = np.where(mids <= MW_MAX_FT, np.maximum(edrs, mountain[None]), edrs)
    return mids, edrs


class GfsSource:
    name = "gfs"

    def __init__(self, cycle: datetime, cache_dir: Path):
        self.cycle = cycle
        self.cache_dir = cache_dir / "gfs"
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        # (fhr, tile) -> (lats, lons, layer_mid_ft, edr)
        self._tiles: dict[tuple[int, tuple[int, int]], tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]] = {}

    def covers(self, valid: datetime) -> bool:
        fhr = (valid - self.cycle).total_seconds() / 3600
        return 0 <= fhr <= 120

    def covers_point(self, lat: float, lon: float) -> bool:
        return True  # global

    def _download(self, fhr: int, tile: tuple[int, int]) -> Path:
        path = self.cache_dir / f"{self.cycle:%Y%m%d%H}_f{fhr:03d}_t{tile[0]}_{tile[1]}.grib2"
        if path.exists():
            return path
        params = {
            "dir": f"/gfs.{self.cycle:%Y%m%d}/{self.cycle:%H}/atmos",
            "file": f"gfs.t{self.cycle:%H}z.pgrb2.0p25.f{fhr:03d}",
            "var_UGRD": "on",
            "var_VGRD": "on",
            "var_HGT": "on",
            "var_TMP": "on",
            "lev_surface": "on",
            "subregion": "",
            **{k: str(v) for k, v in tile_box(tile).items()},
            **{f"lev_{mb}_mb": "on" for mb in LEVELS_MB},
        }
        r = get_with_retry(FILTER, params=params)
        r.raise_for_status()
        if not r.content.startswith(b"GRIB"):
            raise RuntimeError(f"GFS filter returned no GRIB for f{fhr:03d} tile {tile}: {r.text[:200]}")
        path.write_bytes(r.content)
        log.info("gfs: cached %s f%03d tile %s", self.cycle.isoformat(), fhr, tile)
        return path

    def _load(self, fhr: int, tile: tuple[int, int]):
        key = (fhr, tile)
        if key in self._tiles:
            return self._tiles[key]
        while len(self._tiles) >= MAX_TILES_IN_MEMORY:
            self._tiles.pop(next(iter(self._tiles)))
        fields: dict[tuple[str, int], np.ndarray] = {}
        lats = lons = None
        with self._download(fhr, tile).open("rb") as f:
            while (gid := eccodes.codes_grib_new_from_file(f)) is not None:
                try:
                    ny, nx = eccodes.codes_get(gid, "Nj"), eccodes.codes_get(gid, "Ni")
                    if lats is None:
                        lats = eccodes.codes_get_array(gid, "latitudes").reshape(ny, nx)[:, 0]
                        lons = eccodes.codes_get_array(gid, "longitudes").reshape(ny, nx)[0, :]
                    level_type = eccodes.codes_get(gid, "typeOfLevel")
                    short = eccodes.codes_get(gid, "shortName")
                    values = eccodes.codes_get_values(gid).reshape(ny, nx)
                    if level_type == "isobaricInhPa":
                        fields[(short, eccodes.codes_get(gid, "level"))] = values
                    elif level_type == "surface" and short in ("orog", "gh", "h"):
                        fields[("orog", 0)] = values
                finally:
                    eccodes.codes_release(gid)
        mids, edr = blend_edr(fields, lats, lons)
        loaded = (lats, lons % 360, mids, edr)
        self._tiles[key] = loaded
        return loaded

    def edr(self, lat: float, lon: float, altitude_ft: float, valid: datetime) -> float:
        fhr = round((valid - self.cycle).total_seconds() / 3600)
        if fhr > 120:
            fhr = round(fhr / 3) * 3  # 3-hourly beyond f120
        lats, lons, mids, edr = self._load(fhr, tile_of(lat, lon))
        j = int(np.abs(lats - lat).argmin())
        i = int(np.abs(lons - (lon % 360)).argmin())
        # Average over neighbouring cells: single-point jet-core spikes are noise at this resolution.
        n = NEIGHBOURHOOD
        window = (slice(None), slice(max(j - n, 0), j + n + 1), slice(max(i - n, 0), i + n + 1))
        profile = edr[window].mean(axis=(1, 2))
        value = float(np.interp(altitude_ft, mids[:, j, i], profile))
        return min(value, MAX_OUTLOOK_EDR)

