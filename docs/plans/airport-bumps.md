# Airport bumps: takeoff and landing turbulence from free model fields

Status: plan, Nov 5 2026. No code changed. Worker-only; no app update.

**Problem:** near the ground the forecast has no real low-level physics outside GTG. The outlook's lowest layer is 850–700 hPa (`sources/gfs.py:34`, `sources/ecmwf.py:31`), and `np.interp` clamps everything below that layer's mid (~7–10k ft) to its value (`gfs.py:273`, `ecmwf.py:255`). So worldwide (SMOOTH_GLOBAL=1), a gusty or convective climb-out and approach reads smooth unless a SIGMET or PIREP says otherwise. Inside the US, GTG has levels at 1,000, 4,000, 7,000 and 10,000 ft MSL (`gtg.py:33`), but they're coarse.

**Solution:** a per-airport "near the ground" EDR built from surface fields in the GFS and ECMWF files we already download. Apply it to climb and descent minutes below 10,000 ft AGL as `max(base, low)`, capped at light (0.20). Run it in shadow first, then switch it on with an env flag.

## 1. Data, verified Nov 5 2026

**GFS 0.25°** (inventory `gfs.t00z.pgrb2.0p25.f024.idx`, 20261104/00, 743 records; grib-filter request tested, returns GRIB):

| Field | Inventory name | Filter params | Global msg size |
|---|---|---|---|
| 10 m gust (instantaneous) | `GUST:surface` | `var_GUST` + `lev_surface` (already on) | 614 KB |
| 10 m wind | `UGRD/VGRD:10 m above ground` | `lev_10_m_above_ground` | 958 + 940 KB |
| CAPE, surface | `CAPE:surface` | `var_CAPE` | 529 KB |
| CAPE, most-unstable-ish | `CAPE:180-0 mb above ground` | `lev_180-0_mb_above_ground` | 502 KB |
| Lifted index | `LFTX:surface`, `4LFTX:surface` | `var_LFTX` | 542 KB |
| Convective precip rate | `CPRAT:surface` (instant and 6-h average both come back: keep `stepType=instant`) | `var_CPRAT` | 648 KB |
| PBL height | `HPBL:surface` (eccodes shortName `unknown`) | `var_HPBL` | 1.4 MB |
| 850 / 925 hPa wind | `UGRD/VGRD:850 mb` (already fetched), `925 mb` | `lev_925_mb` | ~0.93 MB each |

Measured cost: the extra fields for one 40°×30° tile came to **370 KB per forecast hour**, with the same request and no extra NOMADS calls. That's about +25% on a tile.

**ECMWF IFS 0.25 oper** (AWS `20261104/18z/ifs/0p25/oper/…-{0,24}h-oper-fc.index`, 194/191 records). The first request got S3 `SlowDown`; see Risks.

| Field | Index param (levtype sfc) | Size per step |
|---|---|---|
| 10 m gust, **max since the previous step (3 h)** | `10fg` | 647 KB (step 0 is a 224-byte empty message) |
| 10 m wind | `10u`, `10v` | 741 + 735 KB |
| Most-unstable CAPE | `mucape` (no plain `cape`) | 321 KB |
| Convective precip, **accumulated from step 0** | `cp` (step 0 empty) | 375 KB |
| Total precip / rate | `tp` (accumulated), `tprate` | 391 / 345 KB |
| 100 m wind, land-sea mask | `100u/100v`, `lsm` | 640 KB each, 188 KB |
| 925 / 1000 hPa wind | pl `u/v` 925, 1000 | ~0.6–0.7 MB each |

Not in the open data: lifted index and boundary-layer height. 850 hPa `u/v/gh` and the step-0 `z` are already fetched (`ecmwf.py:60-68`). Extra download for `10fg, 10u, 10v, mucape, cp` is **~2.8 MB per step** on top of ~17 MB.

**Semantics differ:** GFS gust is instantaneous, ECMWF `10fg` is a 3-hour max. ECMWF `cp` has to be differenced between steps and divided by 3 h. Calibrate each model's gust term separately.

## 2. Low-level EDR (first guess, capped at light)

Each model gives three terms, read at the **airport**: nearest cell, max over ±1 cell (~25 km). On ECMWF, use land cells only (`lsm` > 0.5) so coastal airports don't read sea gusts. A first guess to calibrate, like `gfs.py:47-60`.

| Term | Input | → EDR (piecewise linear) | Height weight (AGL) |
|---|---|---|---|
| **Gust (G)** | 10 m gust, kt | ≤15→0.04, 20→0.08, 25→0.12, 30→0.16, ≥35→0.20 | 1 to 2,000 ft, linear to 0 at 6,000 ft |
| **Shear (S)** | \|V850 − V10m\| / (z850 − elev), kt per 1,000 ft | ≤2→0.04, 4→0.09, 6→0.14, 8→0.18, ≥10→0.20 | 1 to 5,000 ft, linear to 0 at 8,000 ft |
| **Convective (C)** | MUCAPE (ECMWF) / CAPE 180-0 mb (GFS), J/kg | <250→0.03, 500→0.08, 1000→0.12, 2000→0.16, ≥3000→0.20; **capped at 0.06 unless convective precip ≥ 0.5 mm/h** within ±1 cell | 1 to 10,000 ft |

`low = min(max(G·wG, S·wS, C·wC), 0.20)`. GFS and ECMWF are averaged where both cover the minute, as `outlook.py:38-40` does. The cap equals `gfs.MAX_OUTLOOK_EDR` (`gfs.py:73`); it can reach light, never moderate. README line 44 still says the outlook is capped at "moderate", which is stale: the cap is 0.20.

Rules of thumb behind the curves (to check against the sources before shipping):
- 25 kt gusts → 0.12 lines up with today's TAF rule: "gusty" at ≥25 kt (`airfield.py:28`) and its shadow floor of 0.12 (`airfield.py:39`).
- AIRMET Tango (FAA AC 00-45H) is issued for sustained surface winds ≥30 kt. That's where officials start flagging low-level turbulence, so 30 kt sits near the top of our light band.
- Mechanical turbulence grows with wind speed over rough ground. Around 20 kt is the usual "you'll feel it" point (FAA AC 00-6B, turbulence chapter).
- Vertical shear of 6 kt per 1,000 ft counts as light–moderate (already used at `gfs.py:51`).
- CAPE 1,000–2,500 J/kg is moderate instability and >2,500 is strong (standard NWS/SPC usage). CAPE alone doesn't make bumps, so the term needs convective precip to go above smooth.
- Lifted index is left out: it repeats CAPE, and ECMWF doesn't have it.

## 3. Where it plugs in

1. **New `worker/src/smooth_worker/sources/lowlevel.py`:** the curves above, plus `LowLevel(gfs, ecmwf).edr(airport, agl_ft, valid) -> (edr, inputs)`.
   - It caches per (airport, valid hour), since every climb minute reads the same airport.
   - ECMWF steps are 3-hourly: use the step whose 3-hour gust window contains `valid`.
2. **`sources/gfs.py`:**
   - Add the vars/levels to `_download` params (`gfs.py:183-194`).
   - Rename the cache file (`gfs.py:180`, e.g. `_ll`) so old tiles are fetched again.
   - In `_decode` (`gfs.py:209-231`), keep `gust`, `10u/10v`, `cape`@180-0, `cpr` instant and the 850 `gh` per tile, alongside `_tiles`.
3. **`sources/ecmwf.py`:**
   - Extend `_ranges` (`ecmwf.py:60-75`) with sfc `10fg, 10u, 10v, mucape, cp`, plus `lsm` at step 0 (stored once next to `orog.npy`, `ecmwf.py:175`).
   - In `cache()` (`ecmwf.py:204-227`), save `{stem}.low.npy`: uint8 gust kt, uint8 shear (0.1 kt/1000 ft), uint8 MUCAPE/20, uint16 cp in 0.1 mm.
   - Make `is_cached` (`ecmwf.py:178`) require it, so a run decoded before the change is redone.
4. **`sources/outlook.py`:** expose `low_level(...)` over its members. `Outlook` is in every pass's source list, also inside the GTG window, so the low-level signal never depends on GTG.
5. **`forecast.py` `compute`:**
   - After the handoff blend (`forecast.py:155-157`) and before hazards (`158-160`), for samples with `phase == "climb"` and `altitude_ft − origin.elev_ft ≤ 10,000`, apply `edr = max(edr, low(origin, …))`. Do the same for `descent` with the destination.
   - This applies whatever source covers the minute, GTG included. Sample phases come from `route.py:80, 349-360`.
   - Gate it with `SMOOTH_LOW_LEVEL` (`0` off, `shadow`, `1` on), like `GLOBAL_COVERAGE` (`forecast.py:20`).
6. **Shadow data, no schema change:** add a `low_level` object to each end's row in `airport_wind`, an existing JSON column (`forecast.py:63, 78`). It holds the inputs per model, `edr`, the minutes it would raise, and the would-be grade (like `floor_grade`, `airfield.py:251-258`).
   - `airport_wind()` returns early for outlook forecasts (`__init__.py:407`), so the low-level rows must be written before that return.
7. **Stretches and explanations: already handled.**
   - Raised minutes form normal segments with `phase` climb or descent (`forecast.py:237-273`).
   - The app labels them "while climbing / descending" and links the "Near the ground" explainer by phase (`ios/BumpCast/Views/LearnView.swift:289-291, 319-326`).
   - The TAF gust label still applies on top (`airfield.py:213-247`). Unknown segment keys or causes are ignored (`ios/BumpCast/Models/Forecast.swift:25-48`).
   - **No app update.**
8. **Notifications:**
   - Worker text already uses the phase: "New: light chop … while climbing" (`changes.py:26, 114`). Live Activity stretches carry the phase (`notify.py:638-652`).
   - In-flight reminders are local in the app and phase-based, so nothing changes there.
   - **Rollout guard:** keep a `low_level_version` in `airport_wind`. When it differs between the previous and new forecast, `changes.describe` says "We now include bumps near the airports during takeoff and landing" instead of listing every new climb or descent stretch as a weather change. This mirrors the profile check (`changes.py:101-106`).

## 4. Disk, cadence, tests

- **Disk (checked on the machine):** `/data` is **7.8 GB, 3.1 GB used** (gtg 2.0 GB, ecmwf 622 MB, gfs 421 MB). README:78 and `fly.toml` `initial_size='3gb'` are stale.
  - GFS: ~+100 MB of grib (pruned after a day, `__init__.py:504-507`).
  - ECMWF: ~5.2 MB per step × 27 steps (0–78 h) ≈ 140 MB per run, ×`KEEP_CYCLES=2` ≈ **+280 MB**.
  - Total ≈ +0.4 GB, well within the 4.5 GB free.
- **Cadence:** unchanged.
  - GFS takes no extra requests (same filter call). ECMWF adds byte ranges to the same thread (`ECMWF_PACE_SECONDS`, `__init__.py:38-40`).
  - Forecasts refresh hourly in GTG range and 6-hourly otherwise (`__init__.py:45-46`). The low-level signal itself changes only with the 6-hourly global runs.
- **Tests** (`cd worker && uv run pytest`), new `tests/test_lowlevel.py` plus additions:
  1. Curves: each term's knots, the 0.20 cap, height weights at 0, 2k, 6k and 10k ft AGL.
  2. The convective term stays ≤0.06 without convective precip.
  3. GFS and ECMWF are averaged when both are present, and each is used alone otherwise.
  4. ECMWF `_ranges` picks `10fg/10u/10v/mucape/cp` (+`lsm` at step 0), extending `test_ecmwf.py:18`. Step 0's empty `10fg/cp` are handled. `cp` is differenced across steps.
  5. GFS `_decode` keeps instant `cpr` and drops the average one. HPBL `unknown` is ignored.
  6. `compute` raises only climb minutes ≤10k ft AGL at the origin and descent minutes at the destination; cruise is untouched. Use a high-elevation airport (DEN) for AGL.
  7. `max` never lowers GTG or hazard values. Off/shadow/on modes behave as described; shadow leaves `samples`, `segments`, `grade` and `score` unchanged.
  8. `changes.describe` with a version change gives the single rollout line.
  9. A worldwide route (e.g. LHR–FRA under the outlook only) gets low-level stretches with no GTG present.
  10. The existing `test_no_regression.py` passes with the flag off.

## 5. Validation, worldwide from day one

1. **Shadow for two weeks**, on every flight in every region. Compare the would-be grade to after-landing ratings (`landing_reports.felt_relative`, `supabase/migrations/20261018170000_relative_landing_rating.sql`).
   - Ratings already split by `forecast_noaa_possible` and outlook share (`20261019000000_global_coverage.sql:18-24`), so non-US routes are measured on their own.
   - Ratings are per flight, not per phase. Test whether flights where shadow raised the ends rate "bumpier" more often than calm-end flights.
2. **Inputs against METARs worldwide:** aviationweather.gov METARs give observed gusts at takeoff and landing for any ICAO airport. Score the model gust (GFS instant vs ECMWF 3-h max) against them, per region.
3. **Over the US:** compare the signal to GTG's 1,000–10,000 ft EDR at the same airports and hours, the same way the outlook was checked on Oct 18 (`gfs.py:63-66`).
4. **PIREPs/AIREPs** (already loaded, `hazards.py:24, 191-220`): low-level PIREPs are mostly US. AIREPs elsewhere are almost all at cruise, so they'll validate little outside the US; count matches but don't rely on them.
5. Switch on (`SMOOTH_LOW_LEVEL=1`) only if shadow doesn't worsen "bumpier/smoother" agreement in any region. Revisit a moderate cap (≤0.26) only with that evidence.

## 6. Risks and open questions

- **Grades on short hops:** 6–10 light minutes at both ends of a 60-minute flight cross the "light ≥20% of flight" line → `some_bumps` (`forecast.py:290`). Should near-ground minutes count fully in the grade? **Decision needed.**
- **Reverses an Oct 27 decision:** the airport-wind brief said numbers never change and the floor stays shadow only (`airfield.py:5-7, 36-39`; `docs/design/gate-and-wind-brief.md` §2). This plan changes numbers, after shadow. **Needs a yes.**
- **TAF tagging worldwide:** `airport_wind` skips outlook forecasts (`__init__.py:407`, `airfield.py:191-199`). Allow the TAF gust label on model-raised low-level stretches outside GTG? aviationweather.gov serves international TAFs (to confirm in the shadow data). This would be worker-only.
- **GTG + max:** inside the US this can only raise GTG's low levels, by ≤0.20. Alternatively keep GTG alone where it covers. **Decision needed.**
- **0.25° grid vs airports:** coastal and mountain airports. The land mask helps on ECMWF only (GFS `LAND` field not checked). The ±1-cell max can over-call.
- **Thunderstorms:** a convective signal at an airport means crews hold or divert. We cap at light and never imply hazard; copy stays calm.
- **ECMWF S3 throttling:** we hit `SlowDown` once on a plain index GET. More ranges per step means more requests: merge neighbouring ranges (already done) and keep the pace.
- **Mass "new stretch" pushes on rollout:** handled by the version line (§3.8). Check it before switching on.
- **Calibration data is thin:** ratings are whole-flight, and there are few users outside the US. Expect weeks before switching on per region.
