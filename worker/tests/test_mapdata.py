import numpy as np

from smooth_worker import mapdata


def test_pirep_intensity_and_dedupe():
    report = {"obsTime": 1792334640, "lat": 40.0, "lon": -80.0, "fltLvl": 350, "tbInt1": "LGT-MOD", "rawOb": "X"}
    rows = mapdata.pirep_rows([report, report, {**report, "tbInt1": "", "rawOb": "Y"}])
    assert len(rows) == 1
    assert rows[0]["intensity"] == "moderate" and rows[0]["altitude_ft"] == 35000


def test_grid_binning_takes_max_and_marks_no_data():
    lats = np.array([54.99, 54.98, 30.0])
    lons = np.array([-129.99, -129.98, -100.0])
    edr = np.array([0.05, 0.25, 0.12])
    cells = mapdata.encode(mapdata.bin_edr(lats, lons, edr))
    ny, nx = mapdata.grid_shape()
    assert len(cells) == ny * nx
    assert cells[0] == "2"  # north-west corner: max of 0.05 and 0.25
    j, i = round((mapdata.NORTH - 30) / mapdata.STEP), round((-100 - mapdata.WEST) / mapdata.STEP)
    assert cells[j * nx + i] == "1"
    assert cells[1] == mapdata.NO_DATA
