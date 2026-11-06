# ECMWF clear-air turbulence (CAT) feed: request draft

Goal: worldwide EDR turbulence forecasts for BumpCast, from ECMWF's own `cat` field (what Windy shows),
in place of our Ellrod index from raw winds outside the US.

## Facts (checked 2026-11-05)

- Parameter: **`cat`, paramId 260290**, "Clear air turbulence (CAT)", units of EDR (m^2/3 s^-1),
  access "dissemination" ([parameter database](https://codes.ecmwf.int/parameter-database/api/v1/param/260290/)).
- Since Cy50r1 (May 2026): on 41 ICAO flight levels, FL50 to FL450 every 1,000 ft, recalibrated on
  aircraft data ([Forecast User Guide 8.1.14](https://confluence.ecmwf.int/spaces/FUG/pages/673550924/Section%2B8.1.14%2BClear%2BAir%2BTurbulence%2BCAT)).
- ECMWF classes: nil < 0.10, light 0.10–0.20, moderate 0.20–0.45, severe > 0.45. Ours are 0.10 / 0.22 / 0.34:
  decide the mapping before showing it (calibrate on the pilot-report archive).
- Not in the free 0.25° open-data files (checked today's index). Since 1 Oct 2025 the whole real-time
  catalogue is CC BY 4.0 with no information cost; direct delivery needs a Service Agreement (Real-time)
  and a service charge ([charges](https://confluence.ecmwf.int/display/DAC/Service+Charges%3A+From+01+July+2024)):
  €500/yr under 1 GiB/day, €1,500/yr for 1–10 GiB/day, €7,500/yr for 10–100 GiB/day.

## What to ask for

Estimates assume ~1.6 MB per global 0.25° field (12-bit GRIB2); ECMWF's test feed gives the real size.

| Option | Grid | Levels | Steps | Runs | ≈ GiB/day | €/yr |
|---|---|---|---|---|---|---|
| A, lean | 0.25° | 12: FL100, 180, 240, 280, 300, 320, 340, 360, 380, 400, 420, 450 | 0–72 h, 3-hourly | 00, 12Z | ~0.9 | 500 |
| **B, recommended** | 0.25° | 21: FL50, 70, 100, then FL120–440 every 2,000 ft, and FL450 | 0–48 h hourly, 51–90 h 3-hourly | 00, 06, 12, 18Z | ~7 | 1,500 |

B gives hourly global turbulence for the 0–48 h window our notifications cover (48 h "ready", 24/6/2 h updates).

Levels match what we take from GTG (`gtg.WANTED_FT`: 1,000, 4,000, 7,000, 10,000, then 12,000–44,000 ft
every 2,000), so climb, cruise (FL220–FL390 in `route.py`) and descent all read the same heights worldwide.
`cat` starts at FL50: below ~5,000 ft (takeoff and final approach) there is no CAT field, so those minutes
come from the airport plan (gusts, low-level shear, convection from the free GFS/ECMWF files,
docs/plans/airport-bumps.md). Flight levels are pressure altitude, so at high airports (Denver, Mexico City)
FL50–FL70 are at or below the ground and climb starts higher up the list.

## Draft email

To: ECMWF Data Services (support portal: https://support.ecmwf.int, "Real-time data" request)
Subject: Real-time Service Agreement enquiry: Clear air turbulence (paramId 260290), commercial app

> Hello,
>
> I run BumpCast, a turbulence-forecast app for airline passengers, published by Akinyemi & Co Ltd.
> We already use the ECMWF open data (0.25°, with CC BY 4.0 attribution in the app and on
> bumpcast.app) and would like to add your Clear Air Turbulence field (`cat`, paramId 260290)
> under a Service Agreement for the Provision of Open Data Products (Real-time).
>
> What we're looking for:
> - Parameter: `cat` on flight levels FL50, FL70, FL100, FL120–FL440 every 2,000 ft, and FL450 (21 levels),
>   so climb and descent are covered as well as cruise
> - Grid: global, 0.25° regular lat/lon
> - Steps: 0–48 h hourly, then 3-hourly to 90 h
> - Runs: 00, 06, 12 and 18 UTC
> - Delivery: pull (or push to a single endpoint), GRIB2
>
> Could you tell us:
> 1. The expected daily volume and the volume band and service pack this falls into (we expect Band 2, Basic).
> 2. Whether a smaller fallback (12 levels, 3-hourly to 72 h, 00/12 UTC only) would fit Band 1.
> 3. Whether CCSDS compression is available on the Basic pack.
> 4. Whether showing CAT-derived turbulence levels to members of the public in a paid consumer app,
>    with CC BY 4.0 attribution, raises any issue.
> 5. How to get a test feed to measure volume before signing, and the usual lead time to go live.
>
> Thank you,
> Lanre Akinyemi
> Akinyemi & Co Ltd, BumpCast
> support@akinyemi.ca

## After they reply

1. Test feed: measure GiB/day, check timing (when each step lands vs our 5-minute poll).
2. Worker: `sources/ecmwf_cat.py` reading flight levels directly (no Ellrod), cached like `ecmwf.py`;
   blend or replace the outlook outside GTG's domain; lift the 0.20 cap only once the backtest supports it.
3. Backtest against the worldwide pilot-report archive (`archive.save_reports`) before dropping the beta tag.

## Free trial: ECMWF CAT charts vs our outlook (2026-11-05)

Before paying, ECMWF's public CAT charts (charts.ecmwf.int `medium-cat`, global, CC BY 4.0, 8 flight
levels, 3-hourly) were read pixel by pixel and scored against 12,207 pilot reports with a turbulence
intensity (Oct 31 18Z to Nov 5, 934 outside the US), at the same lead (6–9 h, same ECMWF run) as our
ECMWF outlook. Scripts and data: session scratchpad `catscore/` (score.py, analyse.py, scored.csv).

| AUC, moderate+ vs the rest | ECMWF CAT (chart, 100 km radius) | Our ECMWF outlook |
|---|---|---|
| All | 0.69 | 0.74 (0.73 with the app's 0.20 cap) |
| Cruise, FL280+ | 0.69 | 0.73 |
| FL210–270 | 0.66 | 0.71 |
| FL80–200 | 0.62 | 0.67 |
| Cruise, outside the US | 0.68 | 0.72 |

Checks: map positions verified on six coastlines; the result holds at 40–360 km search radii;
squeezing our values into the chart's 12 colour steps costs us only 0.01, so the chart format doesn't
explain the gap.

Verdict: on this test, ECMWF's CAT does not beat what we already compute, so don't pay for the feed on
the strength of it. Caveats: 5 days; pilot reports cluster along jet streams, which suits a wind-shear
index like ours; the charts aren't the full-resolution field. Rescore with weeks of the worldwide
report archive, or ask ECMWF for a test batch of the real field, before deciding again.
