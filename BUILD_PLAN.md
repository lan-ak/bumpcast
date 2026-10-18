# Turbulence app: build plan

Codename **Smooth** (rename before launch). iOS only, SwiftUI.

## What the research changed

- The free US model (NOAA GTG) only forecasts **0–18 hours** ahead, not 48. It covers the continental US from the surface to 45,000 ft and models clear-air and mountain-wave turbulence, not turbulence from storms.
- The global WAFS turbulence grids (36h now, up to 48h in the newer version) need an approved **WIFS account**.
- **Decision: hybrid forecast.**
  - **48h to 18h:** our own turbulence score, computed from free global models (GFS, plus ECMWF open data later). The inputs are wind shear and the Ellrod/TI-style indices.
  - **Inside 18h:** switch to the GTG eddy dissipation rate (EDR), the standard turbulence measure.
  - **Later:** add WAFS once approved.
  - This keeps the 48h → 24h → 6h → 2h notification rhythm. Each update can say "now using higher-resolution US data".
- **Pilot reports** come from the aviationweather.gov Data API (`/api/data/pirep`, about 100 requests/min). The backend fetches them once a minute and the app reads them from our backend.

## Architecture

- **iOS app** (SwiftUI, iOS 26+):
  - SwiftData for saved flights and cached forecasts, so the app works offline.
  - ActivityKit for the Live Activity and Dynamic Island.
  - Superwall SDK on top of StoreKit 2.
- **Supabase:**
  - Postgres tables: flights, forecasts, forecast_segments, landing_reports, waitlist.
  - Auth: anonymous, upgradeable to Sign in with Apple.
  - Edge function: the app's API.
- **Python worker** (Fly.io):
  - Fetches GFS and GTG data every hour (GRIB2, parsed with xarray and cfgrib).
  - Builds each flight's route: great-circle path, plus a standard climb, cruise and descent profile.
  - Samples turbulence along the route and produces a grade and timeline.
  - Sends APNs pushes for the 48h, 24h, 6h and 2h updates.

## Build order

1. **Core slice:** save a flight (airports, date and time) → route profile → grade and bump timeline, using real data, shown in the app.
2. Scheduled updates and "what changed" push notifications.
3. Offline download, plus the "We've taken off" Live Activity.
4. Paywall: Superwall with a flight pass and a subscription.
5. Turbulence map with pilot reports (landscape).
6. Calm tools: breathing timed to the bumps, plus explainers.
7. After-landing "How bumpy was it?" check, plus a waitlist for flights outside coverage.

## Local setup still needed

- Supabase CLI and Docker for local development (neither is installed yet).
