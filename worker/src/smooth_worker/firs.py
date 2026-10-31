"""Plain place names for the areas official warnings (SIGMETs) are issued for.

SIGMETs are issued per flight information region (FIR), a control area with names like
"EGGX SHANWICK OCEANIC" or "ENOR POLARIS" that mean nothing to a passenger. The app shows a
warning's region after "over" ("Thunderstorms over the North Atlantic"), so each one becomes a
place people know: a country, a sea or an ocean.

Europe, the North Atlantic and North America are listed in full (the routes we cover or are
adding); anywhere else the FIR's own name is tidied up, and an unlisted oceanic area is named
after its ocean.
"""

# ICAO FIR code -> place, for the whole FIR (or its land part, when it also has an oceanic one).
PLACES = {
    # North Atlantic oceanic areas
    "EGGX": "the North Atlantic",  # Shanwick
    "CZQX": "the North Atlantic",  # Gander Oceanic (Gander Domestic is below, by name)
    "BIRD": "the North Atlantic",  # Reykjavik, Iceland to Greenland
    "BGGL": "Greenland",  # Sondrestrom
    "LPPO": "the Atlantic near the Azores",  # Santa Maria
    "KZWY": "the western Atlantic",  # New York Oceanic
    "KZMA": "the western Atlantic",  # Miami Oceanic
    "TTZP": "the Caribbean",  # Piarco
    "TJZS": "the Caribbean",  # San Juan
    "GCCC": "the Canary Islands",
    "SBAO": "the South Atlantic",  # Atlantico
    "ENOB": "the Norwegian Sea",  # Bodo Oceanic
    "KZHU": "the Gulf of Mexico",  # Houston Oceanic
    # UK, Ireland and western Europe
    "EGTT": "the UK", "EGPX": "the UK", "EGGN": "the UK",
    "EISN": "Ireland",
    "LFFF": "France", "LFEE": "France", "LFRR": "France", "LFMM": "France", "LFBB": "France",
    "EHAA": "the Netherlands", "EBBU": "Belgium", "EBUR": "Belgium", "ELLX": "Luxembourg",
    "EDGG": "Germany", "EDWW": "Germany", "EDMM": "Germany", "EDUU": "Germany", "EDYY": "Germany", "EDVV": "Germany",
    "LSAS": "Switzerland", "LOVV": "Austria",
    "LIMM": "Italy", "LIRR": "Italy", "LIBB": "Italy",
    "LECM": "Spain", "LECB": "Spain",
    "LPPC": "Portugal",
    "LMMM": "Malta",
    # Northern Europe
    "EKDK": "Denmark", "ENOR": "Norway", "ESAA": "Sweden", "EFIN": "Finland",
    "EETT": "Estonia", "EVRR": "Latvia", "EYVL": "Lithuania",
    # Central and eastern Europe
    "EPWW": "Poland", "LKAA": "Czechia", "LZBB": "Slovakia", "LHCC": "Hungary",
    "LJLA": "Slovenia", "LDZO": "Croatia", "LQSB": "Bosnia and Herzegovina", "LYBA": "Serbia",
    "LWSS": "North Macedonia", "LAAA": "Albania", "LRBB": "Romania", "LBSR": "Bulgaria",
    "LUUU": "Moldova", "UKBV": "Ukraine", "UKDV": "Ukraine", "UKLV": "Ukraine", "UKOV": "Ukraine",
    "UMMV": "Belarus",
    # Eastern Mediterranean and North Africa
    "LGGG": "Greece", "LCCC": "Cyprus", "LTAA": "Turkey", "LTBB": "Turkey", "LLLL": "Israel",
    "OLBB": "Lebanon", "OJAC": "Jordan", "HECC": "Egypt",
    "GMMM": "Morocco", "DAAA": "Algeria", "DTTC": "Tunisia", "HLLL": "Libya",
    # North America
    "CZQM": "Atlantic Canada", "CZUL": "Quebec", "CZYZ": "Ontario", "CZWG": "central Canada",
    "CZEG": "western Canada", "CZVR": "British Columbia",
    "MMFR": "Mexico", "MMFO": "Mexico", "KZAK": "the Pacific", "PAZA": "Alaska",
}

# FIRs with land and oceanic parts under one code: the oceanic part's place.
OCEANIC = {
    "CZQX": "the North Atlantic",
    "GOOO": "the Atlantic off West Africa",  # Dakar Oceanic
    "FAJO": "the Indian Ocean",  # Johannesburg Oceanic
    "NZZO": "the South Pacific",  # Auckland Oceanic
    "PAZA": "the North Pacific",  # Anchorage Oceanic
    "KZAK": "the Pacific",  # Oakland Oceanic
}

# By name, where the code alone isn't enough.
NAMED = {
    "GANDER DOMESTIC": "Newfoundland",
}

# FIR names that aren't places, wherever they turn up (tidied names on the right).
TIDY = {
    "Atlantico": "the South Atlantic",
    "Amazonica": "the Amazon",
    "Central American": "Central America",
    "Libyan": "Libya",
    "Athinai": "Greece",
    "Lisboa": "Portugal",
    "Alger": "Algeria",
    "Polaris": "Norway",
    "Ujung Pandang": "Indonesia",
    "Seychelles": "the Seychelles",
    "Rostov-na-donu": "Rostov-on-Don",
}
DROP_WORDS = {"FIR", "UIR", "CTA", "TERRESTRE", "OCEANIC", "OCEANICA", "DOMESTIC"}


def _ocean(lat: float, lon: float) -> str:
    """The ocean a point is in, roughly, for oceanic areas not listed above."""
    if -70 <= lon <= 20:
        return "the North Atlantic" if lat >= 0 else "the South Atlantic"
    if 20 < lon < 120 and lat < 30:
        return "the Indian Ocean"
    return "the North Pacific" if lat >= 0 else "the South Pacific"


def place(fir_name: str | None, fir_id: str | None = None, centre: tuple[float, float] | None = None) -> str | None:
    """'EGGX SHANWICK OCEANIC' -> 'the North Atlantic'; 'LFFF PARIS' -> 'France'.
    `centre` (lat, lon) names an unlisted oceanic area after its ocean."""
    if not fir_name and not fir_id:
        return None
    name = (fir_name or "").upper()
    words = name.split()
    code = (fir_id or "")[:4].upper()
    if len(words) > 1 and len(words[0]) == 4 and words[0].isalpha():
        code = code or words[0]
        words = words[1:]
    oceanic = "OCEANIC" in words or "OCEANICA" in words or (fir_id or "").upper().endswith("/O")
    rest = " ".join(words)
    if rest in NAMED:
        return NAMED[rest]
    if oceanic and code in OCEANIC:
        return OCEANIC[code]
    if code in PLACES:
        return PLACES[code]
    if oceanic and centre:
        return _ocean(*centre)
    tidy = " ".join(w.capitalize() for w in words if w not in DROP_WORDS)
    return TIDY.get(tidy, tidy) or None
