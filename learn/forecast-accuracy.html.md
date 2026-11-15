# How accurate is the turbulence outlook?

> BumpCast's global turbulence outlook checked against 441,678 airline pilot reports, November 2025 to October 2026.

Pick a pilot report of moderate bumps and a calmer one at random: the outlook rated the bumpier one higher about 7 times in 10 (AUC 0.69; 0.5 is a coin toss, 1 is perfect).

## Higher readings, more bumps

Pilot reports at cruising height (20,000 ft and up), by the outlook's reading:

| Outlook reading | Reports | Light or more | Moderate or stronger | Severe |
|---|---|---|---|---|
| under 0.05 | 13,953 | 40% | 5.7% | 0.2% |
| 0.05–0.10 | 122,645 | 66% | 17% | 0.2% |
| 0.10–0.15 | 81,500 | 81% | 30% | 0.3% |
| 0.15–0.20 | 47,408 | 86% | 39% | 0.5% |
| 0.20–0.30 | 46,832 | 90% | 47% | 0.9% |
| 0.30+ | 28,937 | 93% | 56% | 2.1% |

## By height

| Height | Reports | AUC, moderate or stronger | AUC, any bumps |
|---|---|---|---|
| All heights | 441,678 | 0.69 | 0.71 |
| Cruise, 28,000 ft and up | 284,433 | 0.69 | 0.70 |
| 20,000 to 28,000 ft | 56,842 | 0.71 | 0.73 |
| Below 20,000 ft | 100,403 | 0.68 | 0.70 |

## What we tested, and what we didn't

- The global outlook: BumpCast's clear-air turbulence estimate from ECMWF and NOAA GFS, averaged. Used for international flights (Global outlooks, beta) and beyond the 18 hours of the US Graphical Turbulence Guidance (GTG), which isn't tested here.
- The best case: each model's analysis, matched to every report within 3 hours. Forecasts made a day or two ahead are less sharp.
- Over North America only: too few pilot reports elsewhere.
- Year-long patterns: the outlook's months matched pilot reports on 7 of 16 US routes, its bumpiest stretches on 2.

## Questions

### How accurate are turbulence forecasts?

Useful, not perfect. We checked BumpCast's global outlook against 441,678 airline pilot reports over a year. Pick a report of moderate bumps and a calmer one at random, and the outlook rated the bumpier one higher about 7 times in 10. Where it read highest, 56% of reports were moderate or stronger; where it read lowest, 5.7%.

### Does a smooth forecast mean no bumps at all?

No. Even where the outlook read lowest, pilots reported at least light bumps 40% of the time. Light chop is common and harmless, and pilots report bumpy air more readily than smooth. Keep your seat belt fastened while seated.

### Can turbulence be predicted?

Much of it, yes. Clear-air turbulence and mountain waves come from the wind and temperature patterns weather models forecast, so higher model readings do go with more bumps. Bumps in and around thunderstorms and over small hills are harder, which is why pilots also steer around storms and share reports on the day.

Contains ECMWF open data (CC BY 4.0). GFS data from NOAA. Pilot reports: https://mesonet.agron.iastate.edu/request/gis/pireps.php

Source: https://bumpcast.app/learn/forecast-accuracy.html (data November 2025 to October 2026). From BumpCast: https://apps.apple.com/app/id6824269447
