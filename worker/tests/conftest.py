import pytest

from smooth_worker import airfield


@pytest.fixture(autouse=True)
def no_airport_forecasts(monkeypatch):
    """Tests never fetch airport wind forecasts: every airport has none unless a test says so."""
    airfield.reset()
    monkeypatch.setattr(airfield, "_fetch", lambda icaos: {})
    yield
    airfield.reset()
