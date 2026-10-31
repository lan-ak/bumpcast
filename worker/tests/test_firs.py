import pytest

from smooth_worker.firs import place


@pytest.mark.parametrize(
    ("fir_name", "fir_id", "centre", "expected"),
    [
        ("EGGX SHANWICK OCEANIC", "EGGX", None, "the North Atlantic"),
        ("CZQX GANDER OCEANIC", "CZQX", None, "the North Atlantic"),
        ("CZQX GANDER DOMESTIC", "CZQX", None, "Newfoundland"),
        ("NEW YORK OCEANIC", "KZWY", None, "the western Atlantic"),
        ("LPPO SANTA MARIA OCEANIC", "LPPO", None, "the Atlantic near the Azores"),
        ("BIRD REYKJAVIK", "BIRD", None, "the North Atlantic"),
        ("LFFF PARIS", "LFFF", None, "France"),
        ("ENOR POLARIS", "ENOR", None, "Norway"),
        ("LGGG ATHINAI", "LGGG", None, "Greece"),
        ("GOOO DAKAR OCEANIC", "GOOO/O", None, "the Atlantic off West Africa"),
        ("GOOO DAKAR TERRESTRE", "GOOO", None, "Dakar"),
        ("SBAO ATLANTICO", "SBAO", None, "the South Atlantic"),
        ("MHCC CENTRAL AMERICAN", "MHTG", None, "Central America"),
        ("SBRE RECIFE", "SBRE", None, "Recife"),  # unlisted land FIR: its own name, tidied
        ("XXXX SOMEWHERE OCEANIC", "XXXX", (-20.0, 70.0), "the Indian Ocean"),  # unlisted oceanic
        (None, None, None, None),
    ],
)
def test_place(fir_name, fir_id, centre, expected):
    assert place(fir_name, fir_id, centre) == expected
