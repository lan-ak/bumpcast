"""EDR (eddy dissipation rate, m^(2/3) s^-1) to plain-language severity.

Thresholds are the commonly used ones for a medium-size airliner; GTG and
WAFS both forecast EDR, and our GFS index is mapped onto the same scale.
"""

SMOOTH, LIGHT, MODERATE, SEVERE = "smooth", "light", "moderate", "severe"
ORDER = [SMOOTH, LIGHT, MODERATE, SEVERE]

LIGHT_EDR = 0.10
MODERATE_EDR = 0.22
SEVERE_EDR = 0.34


def classify(edr: float) -> str:
    if edr >= SEVERE_EDR:
        return SEVERE
    if edr >= MODERATE_EDR:
        return MODERATE
    if edr >= LIGHT_EDR:
        return LIGHT
    return SMOOTH


def worse(a: str, b: str) -> str:
    return a if ORDER.index(a) >= ORDER.index(b) else b
