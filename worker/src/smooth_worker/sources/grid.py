import numpy as np


def lonlat_to_xyz(lats: np.ndarray, lons: np.ndarray) -> np.ndarray:
    """Unit-sphere coordinates, so KD-tree distances work across any projection."""
    lat, lon = np.radians(lats), np.radians(lons)
    return np.column_stack((np.cos(lat) * np.cos(lon), np.cos(lat) * np.sin(lon), np.sin(lat)))
