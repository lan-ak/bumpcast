# International route pages from a model climatology

Status: **built Nov 15, 2026 (Lanre chose option 2 plus an accuracy page): 12 season-only pages and
/learn/forecast-accuracy.html, not yet published.** See "Result of the check" at the end. Scripts and scores (`year.py`, `score.py`,
`score.json`) are kept in the side-session notes folder, `intl-check/`; the maintained version is
`scripts/model_data.py` (see site/README.md).

## Problem

The 277 route pages count a year of pilot reports (IEM). Outside North America those feeds carry almost
none (24 h on Nov 15: Europe 2 of 400, North Atlantic 0, Asia-Pacific 9, US 196), so JFK–LHR or SYD–SIN
can't be built the same way honestly.

## Source and method

- **Data:** ECMWF open-data analyses (step 0 of each run), 0.25°, on AWS (`ecmwf-forecasts`, eu-central-1).
  The archive goes back to at least Mar 2024 at 0.25°. CC BY 4.0: pages must carry "Contains ECMWF open data".
- **Method:** the worker's own code. `ecmwf.decode` + `ecmwf.global_edr` (= `gfs.blend_edr`, the app's
  diagnostics) on each analysis, then EDR along `route.build_profile` (still air) every 5 min, read the way
  `EcmwfSource.edr` reads it (3×3 neighbourhood, interpolated to the flight's height). Same 20 stretches
  as today's pages. Severity steps from `severity.py` (light ≥ 0.10).
- **Not capped at 0.20** for the statistics, but pages would only speak of "light or more" and compare
  stretches and months *within* a route. The app's outlook can't call moderate on its own, so the pages
  shouldn't either.
- **Optional:** add GFS analyses (NOAA's `noaa-gfs-bdp-pds` on AWS, also free) and average, as the app's
  outlook does. That doubles the run.

## Cost, size, time (measured)

| | One analysis | A year at 00/06/12/18Z (1,460) |
|---|---|---|
| Download (byte ranges of the 36 fields) | 23.7 MB | ~35 GB, not kept |
| Decode + diagnostics | 0.8 s, ~550 MB RAM | — |
| Wall time, 8 threads on this Mac | ~2 s each (S3 throttles with 503s; retries cope) | ~50 min |
| Output | — | a few MB of JSON |
| Money | $0 (AWS Open Data, no egress fee) | $0 |

Run it locally, like `route_data.py`. Not on the worker: the Fly machine's disk and CPU are for live
forecasts, and this is a monthly batch job.

## Sample: 96 analyses (00Z and 12Z on the 1st, 8th, 15th and 22nd of each month, Nov 2025–Oct 2026)

Share of cruise points at light or more (uncapped EDR ≥ 0.10):

| Route | Cruise light+ | Bumpiest stretches (model) | Bumpiest months (model) | Smoothest months |
|---|---|---|---|---|
| JFK–LHR | 43% | 5–10% and 25–45% of the way (off New England; mid-Atlantic) | Mar, Nov | Feb, Oct |
| LHR–DXB | 31% | 35–55% of the way (the middle third) | Jan, Apr | Sep, Nov |
| SYD–SIN | 27% | the first 15% (over south-east Australia) | Jul–Sep | Apr, Dec |

Checked against the pilot-report pages on two US routes (Spearman rank correlation, model vs reports):

| Route | Stretches | Months |
|---|---|---|
| JFK–LAX | −0.19 | 0.21 |
| DEN–PHX | −0.77 | −0.08 |

**This is the problem.** On US routes, where we can check, the model's "where" and "when" don't match
where and when pilots report bumps. Some of that is the reports' fault (reporting habits differ by control
center, which the current pages already warn about), and 8 analyses a month is too few to judge months.
But it's not enough to publish "the bumpiest stretch of JFK–LHR is off Newfoundland" as a fact. The model
also calls light-or-more on ~40% of cruise minutes and on almost every flight (90–98% of analyses have 15+
minutes of it), so on its own it doesn't separate smooth flights from bumpy ones.

## Recommendation

Don't build pages yet. First, one validation run (~1 h, $0):

1. Full year, 4 analyses a day, for ~15 US and Canadian routes that already have dense pilot reports,
   ECMWF and GFS averaged (the app's outlook).
2. Score it two ways: (a) stretch and month rankings against the existing pages, (b) point-by-point
   against every pilot report with an intensity (AUC, as in the Nov 5 ECMWF CAT test, which gave 0.74).
3. **Gate:** build international pages only if stretch rankings agree (median Spearman ≥ 0.5) and months
   agree on most routes. If not, the honest page is thinner (see below).

If it passes, build:

- **Data:** `scripts/route_model_data.py` → `scripts/data/routes_intl.json`, same shape as `routes.json`
  where it can be (`along`, `months`), with shares instead of report counts.
- **Pages:** the existing route template and components in `build_site.py` (grade card, stat tiles,
  stretch rows, timeline card, month chart), as `site/routes/jfk-lhr.html` etc. alongside the US ones, in
  the same hub and picker, marked "Model estimate".
- **Gusts at each end:** IEM also archives METARs outside the US (country networks like `GB__ASOS`); check
  coverage per airport before reusing the gusty-days section.
- **Routes (~40):** transatlantic JFK/EWR/BOS/IAD/ORD/YYZ/YUL–LHR, JFK–CDG, JFK–FRA, YYZ–FRA; transpacific
  LAX/SFO/SEA/YVR–NRT/HND/ICN/HKG; Gulf LHR/FRA/CDG–DXB/DOH, DXB–BOM/DEL; Asia SIN–HKG, SIN–SYD,
  HND–ICN, HKG–NRT, DEL–BOM; Europe LHR–MAD/BCN/FRA/CDG/AMS/IST, CDG–BCN, FRA–IST.

If it fails, the fallback is a route page without stretch or month claims: the flight (distance, time,
cruise height, what it crosses), how the jet stream and season usually affect it (from Learn, sourced),
and the app's forecast for the day. That's thin, and Google may treat 40 near-identical pages as doorway
pages, so I'd build ~10 at most, or none.

## Wording if built

- Badge "A year of weather-model analyses", not "A year of pilot reports". Title stays "Turbulence on
  JFK–LHR flights"; the description says "estimated from a year of ECMWF weather analyses".
- Every number reads as a model estimate: "In the model, light bumps or more on about 4 in 10 cruise
  minutes", never "pilots reported". No report counts, no "moderate" or "severe".
- "How we made this page": the method above, the ECMWF credit, and that weather models miss thunderstorm
  bumps and small-scale terrain, with a link to the Learn page.
- JSON-LD `Dataset.variableMeasured`: "Modelled clear-air turbulence (EDR) along the route", with ECMWF as
  the data source and `license` CC BY 4.0.
- Check every page at 320/375/800/1280 px before publishing, then `publish_site.sh` and `indexnow.py`
  only on Lanre's go-ahead.

## Result of the check (Nov 15, 2026)

Full year Nov 2025–Oct 2026: all 1,460 analyses (00/06/12/18Z), ECMWF and GFS each, the worker's
diagnostics uncapped, averaged as the app's outlook does. 52 routes (16 US/Canada check routes, 36
international), 441,183 airliner pilot reports. Took 27 min on this Mac, ~77 GB downloaded and discarded, $0.
(ECMWF's 06/18Z files are under `scda` until May 11, 2026 and `oper` after.)

**1. Report by report, the model has real skill.** AUC 0.69 for moderate-or-worse vs the rest (0.69 at
cruise), matching the Nov 5 test. Cruise reports by model value:

| Model EDR | Reports | Pilots said light+ | Pilots said moderate+ |
|---|---|---|---|
| under 0.05 | 13,953 | 40% | 6% |
| 0.05–0.10 | 122,645 | 66% | 17% |
| 0.10–0.15 | 81,500 | 81% | 30% |
| 0.15–0.20 | 47,408 | 86% | 39% |
| 0.20–0.30 | 46,832 | 90% | 47% |
| 0.30 and up | 28,937 | 93% | 56% |

**2. A year of it doesn't reproduce the route pages.** Median rank correlation over the 16 US routes:

| | Model, every analysis | Model read only at the reports |
|---|---|---|
| Stretches | **+0.07** (gate 0.5: fail) | +0.53 |
| Months | +0.43 (7 of 16 routes ≥ 0.5) | +0.51 |

Only ORD–MIA and LGA–ORD pass on stretches; DEN–PHX and SFO–IAD come out reversed. Read at the reports
themselves, the model agrees with pilots, so the gap is mostly *when and where reports get filed* (pilots
report more on bumpy days, and some centers rarely report smooth air), not the model being wrong. But that
cuts both ways: neither source tells us which stretch of JFK–LHR is really bumpiest across all flights, and
the US routes, the only place we can check, don't confirm the model's answer.

**3. ECMWF and GFS agree with each other** on almost every route (stretches typically +0.9, months
+0.95), so the model's picture is consistent, just not confirmed by pilots.

### Verdict

Don't build the 36 international pages with "bumpiest stretch" and "bumpiest month" claims: on the routes
we can check, those claims would be unconfirmed half the time. What the evidence does support is the daily
forecast (report-by-report skill), which is what the app already sells.

Options, in order of preference:

1. **Stop here.** Revisit when the worker's worldwide pilot-report archive (`archive.py`, since Oct 22) has a
   season or more of reports outside the US to validate against directly.
2. **About 10 "season" pages** for the busiest international routes: route facts, the month chart only
   (labelled as a model estimate, with the US check stated), no stretch rankings. Months only half pass,
   so I'd still not recommend it.
3. **Pages without climatology claims** (route facts, how jet streams and seasons affect it, the app's
   forecast): thin, and a doorway-page risk on Google.
