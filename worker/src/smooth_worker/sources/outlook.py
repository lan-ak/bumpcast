"""The global outlook: our GFS and ECMWF turbulence diagnostics, combined.

Two independent models agreeing is worth more than either alone. Each minute takes the mean of
the two where both cover it, and whichever one does otherwise. Both are capped at light
(`gfs.MAX_OUTLOOK_EDR`); only GTG, an official warning or a pilot report goes higher.

It keeps the name "gfs", which the worker and the shipped app read as "outlook" (not GTG).
Its run is GFS's when there is one: refresh timing follows GFS's 6-hourly runs.
"""

from datetime import datetime

from .ecmwf import EcmwfSource
from .gfs import GfsSource


class Outlook:
    name = "gfs"

    def __init__(self, gfs: GfsSource | None, ecmwf: EcmwfSource | None):
        if gfs is None and ecmwf is None:
            raise ValueError("an outlook needs GFS or ECMWF")
        self.gfs, self.ecmwf = gfs, ecmwf
        self.members = [m for m in (gfs, ecmwf) if m is not None]
        self.cycle = self.members[0].cycle

    @property
    def runs(self) -> tuple:
        """Every member's run, so new inputs are loaded when either model has a new one."""
        return tuple((m.name, m.cycle) for m in self.members)

    def covers(self, valid: datetime) -> bool:
        return any(m.covers(valid) for m in self.members)

    def covers_point(self, lat: float, lon: float) -> bool:
        return True  # both global

    def edr(self, lat: float, lon: float, altitude_ft: float, valid: datetime) -> float:
        values = [m.edr(lat, lon, altitude_ft, valid) for m in self.members if m.covers(valid)]
        return sum(values) / len(values)

    def wind(self, lat: float, lon: float, altitude_ft: float, valid: datetime) -> tuple[float, float] | None:
        """GFS's winds for ground speeds (ECMWF's aren't kept)."""
        return self.gfs.wind(lat, lon, altitude_ft, valid) if self.gfs else None
