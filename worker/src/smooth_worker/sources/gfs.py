"""Our own clear-air turbulence outlook from the free global GFS model.

Used beyond GTG's 18-hour horizon (out to 48 h before departure). We compute
the Ellrod TI1 index (vertical wind shear x deformation) for each layer
between pressure levels, then map it onto the EDR scale so the app treats
every source the same way. The mapping is a starting point to calibrate
against pilot reports and after-landing ratings.

Only covers clear-air turbulence at cruise heights; convective and low-level
mechanical turbulence come from GTG once the flight is inside 18 hours.
"""

import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path

import eccodes
import numpy as np

from ..http import client

log = logging.getLogger(__name__)

FILTER = "https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl"
LISTING = "https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod"
LEVELS_MB = [700, 600, 500, 400, 350, 300, 250, 200, 150]
# Covers the US forecast domain plus margin; the subset keeps downloads ~1 MB.
BOX = {"leftlon": 225, "rightlon": 300, "toplat": 56, "bottomlat": 18}
NEEDED_FHR = 66  # 48 h lead + longest US flight + cycle latency
EARTH_RADIUS_M = 6_371_000.0
FT_PER_M = 1 / 0.3048

# Ellrod TI1 (x1e-7 s^-2) -> EDR. Ellrod's own guidance: ~4 light-moderate,
# ~8 moderate, ~12 moderate-severe.
TI_POINTS = [0.0, 4.0, 8.0, 12.0, 20.0]
EDR_POINTS = [0.03, 0.12, 0.22, 0.34, 0.50]
NEIGHBOURHOOD = 1  # +/- cells (0.25 deg, ~25 km) averaged around each point
# A 18-48 h outlook from one global model can't credibly call severe turbulence;
# only GTG (inside 18 h) may. Cap just below the severe threshold.
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


class GfsSource:
    name = "gfs"

    def __init__(self, cycle: datetime, cache_dir: Path):
        self.cycle = cycle
        self.cache_dir = cache_dir / "gfs"
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._layers: dict[int, tuple[np.ndarray, np.ndarray]] = {}
        self._lats: np.ndarray | None = None
        self._lons: np.ndarray | None = None

    def covers(self, valid: datetime) -> bool:
        fhr = (valid - self.cycle).total_seconds() / 3600
        return 0 <= fhr <= 120

    def _download(self, fhr: int) -> Path:
        path = self.cache_dir / f"{self.cycle:%Y%m%d%H}_f{fhr:03d}.grib2"
        if path.exists():
            return path
        params = {
            "dir": f"/gfs.{self.cycle:%Y%m%d}/{self.cycle:%H}/atmos",
            "file": f"gfs.t{self.cycle:%H}z.pgrb2.0p25.f{fhr:03d}",
            "var_UGRD": "on",
            "var_VGRD": "on",
            "var_HGT": "on",
            "subregion": "",
            **{k: str(v) for k, v in BOX.items()},
            **{f"lev_{mb}_mb": "on" for mb in LEVELS_MB},
        }
        r = client().get(FILTER, params=params)
        r.raise_for_status()
        if not r.content.startswith(b"GRIB"):
            raise RuntimeError(f"GFS filter returned no GRIB for f{fhr:03d}: {r.text[:200]}")
        path.write_bytes(r.content)
        log.info("gfs: cached %s f%03d", self.cycle.isoformat(), fhr)
        return path

    def _load(self, fhr: int) -> tuple[np.ndarray, np.ndarray]:
        """Returns (layer_mid_ft[L, ny, nx], ti1[L, ny, nx]) for one forecast hour."""
        if fhr in self._layers:
            return self._layers[fhr]
        fields: dict[tuple[str, int], np.ndarray] = {}
        with self._download(fhr).open("rb") as f:
            while (gid := eccodes.codes_grib_new_from_file(f)) is not None:
                try:
                    ny, nx = eccodes.codes_get(gid, "Nj"), eccodes.codes_get(gid, "Ni")
                    if self._lats is None:
                        self._lats = eccodes.codes_get_array(gid, "latitudes").reshape(ny, nx)[:, 0]
                        self._lons = eccodes.codes_get_array(gid, "longitudes").reshape(ny, nx)[0, :]
                    key = (eccodes.codes_get(gid, "shortName"), eccodes.codes_get(gid, "level"))
                    fields[key] = eccodes.codes_get_values(gid).reshape(ny, nx)
                finally:
                    eccodes.codes_release(gid)

        lat_rad = np.radians(self._lats)[:, None]
        y_m = EARTH_RADIUS_M * np.radians(self._lats)
        lon_rad = np.radians(self._lons)

        def gradients(field: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
            d_dy = np.gradient(field, y_m, axis=0)
            d_dx = np.gradient(field, lon_rad, axis=1) / (EARTH_RADIUS_M * np.cos(lat_rad))
            return d_dx, d_dy

        mids, tis = [], []
        for lower, upper in zip(LEVELS_MB, LEVELS_MB[1:]):
            u1, v1, z1 = fields[("u", lower)], fields[("v", lower)], fields[("gh", lower)]
            u2, v2, z2 = fields[("u", upper)], fields[("v", upper)], fields[("gh", upper)]
            vws = np.hypot(u2 - u1, v2 - v1) / np.maximum(z2 - z1, 1.0)
            u, v = (u1 + u2) / 2, (v1 + v2) / 2
            du_dx, du_dy = gradients(u)
            dv_dx, dv_dy = gradients(v)
            deformation = np.hypot(du_dx - dv_dy, dv_dx + du_dy)
            tis.append(vws * deformation * 1e7)
            mids.append((z1 + z2) / 2 * FT_PER_M)
        layers = (np.stack(mids), np.stack(tis))
        self._layers[fhr] = layers
        return layers

    def edr(self, lat: float, lon: float, altitude_ft: float, valid: datetime) -> float:
        fhr = round((valid - self.cycle).total_seconds() / 3600)
        if fhr > 120:
            fhr = round(fhr / 3) * 3  # 3-hourly beyond f120
        mids, tis = self._load(fhr)
        j = int(np.abs(self._lats - lat).argmin())
        i = int(np.abs(self._lons - (lon % 360)).argmin())
        # Average the index over neighbouring cells: single-point jet-core spikes
        # (TI 30+) are noise at this lead time, not a forecast of severe bumps.
        n = NEIGHBOURHOOD
        window = (slice(None), slice(max(j - n, 0), j + n + 1), slice(max(i - n, 0), i + n + 1))
        ti_profile = tis[window].mean(axis=(1, 2))
        ti = float(np.interp(altitude_ft, mids[:, j, i], ti_profile))
        return min(float(np.interp(ti, TI_POINTS, EDR_POINTS)), MAX_OUTLOOK_EDR)
