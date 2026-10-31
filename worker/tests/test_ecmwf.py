import json
from datetime import UTC, datetime, timedelta

import numpy as np

from smooth_worker.sources import ecmwf
from smooth_worker.sources.ecmwf import EDR_UNIT, FT_UNIT, EcmwfSource
from smooth_worker.sources.gfs import MAX_OUTLOOK_EDR
from smooth_worker.sources.outlook import Outlook

RUN = datetime(2026, 10, 31, 6, tzinfo=UTC)


def _index(*entries):
    return "\n".join(json.dumps(e) for e in entries)


def test_ranges_pick_our_fields_and_merge_neighbours():
    text = _index(
        {"levtype": "sfc", "param": "msl", "_offset": 0, "_length": 10},
        {"levtype": "pl", "param": "u", "levelist": "250", "_offset": 10, "_length": 5},
        {"levtype": "pl", "param": "v", "levelist": "250", "_offset": 15, "_length": 5},
        {"levtype": "pl", "param": "q", "levelist": "250", "_offset": 20, "_length": 5},
        {"levtype": "pl", "param": "t", "levelist": "1000", "_offset": 25, "_length": 5},  # level not used
        {"levtype": "pl", "param": "gh", "levelist": "300", "_offset": 30, "_length": 5},
        {"levtype": "sfc", "param": "z", "_offset": 35, "_length": 5},
    )
    assert ecmwf._ranges(text, 12) == [(10, 19), (30, 34)]
    assert ecmwf._ranges(text, 0) == [(10, 19), (30, 39)]  # terrain comes with step 0


def _fields(ny=21, nx=1440):
    """A jet with a sharp shear zone crossing 0 deg, on a 0.25 deg grid."""
    lats = np.linspace(55, 50, ny)
    lons = np.arange(nx) * 0.25
    fields = {("orog", 0): np.zeros((ny, nx), np.float32)}
    for k, mb in enumerate(ecmwf.LEVELS_MB):
        z = 1500 + 1300 * k
        jet = 10 + 3 * k
        u = np.full((ny, nx), jet, np.float32)
        u[ny // 2 :] += 2 * k  # more speed with height in the south: shear on the 0 deg line too
        fields[("u", mb)] = u
        fields[("v", mb)] = np.zeros((ny, nx), np.float32)
        fields[("gh", mb)] = np.full((ny, nx), z, np.float32)
        fields[("t", mb)] = np.full((ny, nx), 288 - 0.0065 * z, np.float32)
    return fields, lats, lons


def test_global_edr_is_continuous_across_greenwich():
    fields, lats, lons = _fields()
    mids, edr = ecmwf.global_edr(fields, lats, lons)
    assert mids.dtype == edr.dtype == np.uint8 and edr.shape == (len(ecmwf.LEVELS_MB) - 1, len(lats), len(lons))
    # The field is the same at every longitude, so 359.75 and 0 must agree: no seam at 0 deg.
    assert np.array_equal(edr[:, :, -1], edr[:, :, 0]) and np.array_equal(edr[:, :, 0], edr[:, :, 720])
    assert 20000 < int(mids.max()) * FT_UNIT < 50000


def _stored(tmp_path, edr_value):
    """A run with step 0 on disk: one layer at 30,000-40,000 ft, constant EDR everywhere."""
    source = EcmwfSource(RUN, tmp_path)
    lats, lons = np.array([52.0, 51.75, 51.5, 51.25, 51.0]), np.arange(1440) * 0.25
    mids_path, edr_path = source._paths(0)
    shape = (2, len(lats), len(lons))
    heights = np.broadcast_to(np.array([30000, 40000])[:, None, None] / FT_UNIT, shape)
    np.save(edr_path, np.full(shape, round(edr_value / EDR_UNIT), np.uint8))
    np.save(mids_path, heights.astype(np.uint8))
    lats_path, lons_path, orog_path = source._grid_paths()
    np.save(lats_path, lats), np.save(lons_path, lons), np.save(orog_path, np.zeros((5, 1440)))
    return source


def test_edr_reads_stored_steps_and_stays_light(tmp_path):
    calm = _stored(tmp_path / "calm", 0.1)
    assert abs(calm.edr(51.5, -0.1, 35000, RUN) - 0.1) < EDR_UNIT  # just west of 0 deg wraps to 359.9
    rough = _stored(tmp_path / "rough", 0.45)
    assert rough.edr(51.5, 0.0, 35000, RUN + timedelta(hours=1)) == MAX_OUTLOOK_EDR  # nearest step: 0


def test_ready_and_prune(tmp_path):
    source = EcmwfSource(RUN, tmp_path)
    for step in range(0, ecmwf.NEEDED_STEP + 1, ecmwf.STEP_H):
        for path in source._paths(step):
            path.write_bytes(b"x")
    older = EcmwfSource(RUN - timedelta(hours=12), tmp_path)
    for path in older._paths(0):
        path.write_bytes(b"x")
    newer = EcmwfSource(RUN + timedelta(hours=6), tmp_path)
    for path in newer._paths(0):
        path.write_bytes(b"x")
    assert ecmwf.ready_cycles(tmp_path) == [RUN]
    assert ecmwf.prune(tmp_path) == 2  # the newest (decoding) and the newest complete stay
    assert ecmwf.ready_cycles(tmp_path) == [RUN] and newer.is_cached(0) and not older.is_cached(0)


class Member:
    def __init__(self, name, value, hours=144):
        self.name, self.value, self.hours, self.cycle = name, value, hours, RUN

    def covers(self, valid):
        return 0 <= (valid - RUN).total_seconds() / 3600 <= self.hours

    def edr(self, lat, lon, altitude_ft, valid):
        return self.value

    def wind(self, lat, lon, altitude_ft, valid):
        return (50.0, 0.0)


def test_outlook_averages_the_models_it_has():
    outlook = Outlook(Member("gfs", 0.04, hours=120), Member("ecmwf", 0.12, hours=78))
    assert outlook.name == "gfs" and outlook.cycle == RUN
    assert abs(outlook.edr(50, -30, 35000, RUN + timedelta(hours=10)) - 0.08) < 1e-9
    assert outlook.edr(50, -30, 35000, RUN + timedelta(hours=100)) == 0.04  # beyond ECMWF's steps here
    assert outlook.runs == (("gfs", RUN), ("ecmwf", RUN))
    assert outlook.wind(50, -30, 35000, RUN) == (50.0, 0.0)
    ecmwf_only = Outlook(None, Member("ecmwf", 0.12))
    assert ecmwf_only.edr(50, -30, 35000, RUN) == 0.12 and ecmwf_only.wind(50, -30, 35000, RUN) is None
