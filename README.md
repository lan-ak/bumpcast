# BumpCast

Turbulence forecasts for anxious and curious flyers. An iOS app plus a Python forecast worker on Supabase.

- [BUILD_PLAN.md](BUILD_PLAN.md): the product plan.
- [SUPERWALL.md](SUPERWALL.md): placements, attributes, products and the remaining dashboard work.

```
ios/        SwiftUI app + Live Activity widget (XcodeGen: ios/project.yml)
worker/     Python forecast engine, notifications, map data (Fly.io app "smooth-worker")
supabase/   Database schema (migrations) and config (project "smooth")
marketing/  The Sky Report: route pages and daily social cards (marketing/skyreport/README.md)
```

## What's built

- **Saved flights**, kept on the phone for offline use and refreshed in the background before boarding.
- **Forecast:**
  - a grade, a minute-by-minute timeline, and plain-language bumpy stretches;
  - labelled as an "Early outlook" (our score) or a "NOAA forecast" (GTG).
- **Notifications:**
  - "ready" at 48 h for everyone, plus delays, cancellations and diversions (live status is free);
  - updates at 24, 6 and 2 h, plus "confirmed by NOAA", for Pro or a flight pass;
  - each update says what changed and why, and they also form an in-app feed.
- **"We've taken off":**
  - a Live Activity and Dynamic Island countdown to each stretch, re-timed by push to the airline's wheels-up (or a tap), with an End button;
  - local reminders 2 minutes before each stretch;
  - both work offline.
- **Calm tools:** breathing paced to the next stretch, and six explainers.
- **Turbulence map:**
  - NOAA GTG by altitude for now, +3 h and +6 h;
  - pilot reports from aviationweather.gov (Pro).
- **After landing:**
  - "How bumpy was it?" is checked against the forecast in the database;
  - public accuracy stats appear in Settings;
  - the review prompt appears only after a flight where the forecast matched.
- **Outside coverage:** says so, and offers "Notify me when you cover {country}", which feeds a per-country waitlist.
- **Sky Report:**
  - grades for 50 popular routes, today and tomorrow, rebuilt hourly by the worker;
  - feeds a page per route and the daily social cards (`marketing/skyreport/README.md`).
- **Superwall:** paywalls and onboarding, gating, a single-flight pass, and subscriptions. See SUPERWALL.md.

## How a forecast is made

1. **Route:** great-circle path between the two airports, assuming a typical jet climb, cruise and descent and 15 minutes of taxi-out (`worker/src/smooth_worker/route.py`).
2. **Data source,** chosen for each minute of the flight (`forecast.py`):
   - **0–18 h before departure:** NOAA **GTG v4** eddy dissipation rate (EDR) on the 3 km HRRR grid, from NOMADS `dafs/prod`. The worker reads each file's `.idx` and downloads only the ~21 altitude levels it needs, about 21 MB per forecast hour (`sources/gtg.py`).
   - **18–48 h before departure:** our own outlook. It computes the **Ellrod TI1** clear-air turbulence index from GFS 0.25° winds (NOMADS grib filter, about 1 MB per hour) and maps it onto the EDR scale (`sources/gfs.py`). That mapping is a first guess; calibrate it with pilot reports and after-landing ratings. The index is averaged over neighbouring cells and capped at "moderate": a single global model 18+ hours out can't credibly call severe turbulence, so only GTG can.
   - **More than 48 h before departure:** the forecast is `too_early`.
   - **Route leaves the US domain:** the forecast is `out_of_coverage`.
3. **Output:** EDR is turned into severity (smooth < 0.10 ≤ light < 0.22 ≤ moderate < 0.34 ≤ severe). From that come the bumpy stretches, a grade and a 0–100 score.

## Worker

```bash
cd worker
uv sync
uv run pytest
uv run smooth-worker forecast JFK LAX 2026-10-19T14:00Z   # any airport pair, UTC departure
cp .env.example .env   # then fill in, and:
uv run --env-file .env smooth-worker run                  # keep forecasts in Supabase fresh
```

`run` polls every 5 minutes. It forecasts new or edited flights straight away, then refreshes them as their data updates: hourly while the flight is inside GTG range, and every 6 hours for GFS.

### Push notifications (APNs)

Without an APNs key, the worker still records every notification for the in-app feed, but sends no pushes. To send them:

1. In your Apple Developer account, go to Keys and create a key with Apple Push Notifications service. Download the `.p8` file.
2. Set the key on the worker:

   ```bash
   cd worker
   fly secrets set APNS_KEY_ID=<key id> APNS_TEAM_ID=<team id> APNS_KEY="$(cat AuthKey_XXXX.p8)"
   ```

Debug builds register as `sandbox` devices; release builds register as `production`.

### Deploy (Fly.io)

The worker runs as one always-on Fly machine (`smooth-worker`, region `iad`, shared-cpu-1x / 1 GB), with a 3 GB volume at `/data` for the GRIB cache. It has no HTTP service; it just polls Supabase every 5 minutes. Config is in `worker/fly.toml`.

```bash
curl -L https://fly.io/install.sh | sh      # installs to ~/.fly/bin
~/.fly/bin/flyctl auth login
cd worker
fly launch --no-deploy --copy-config --name smooth-worker --region iad
grep -E '^(SUPABASE_URL|SUPABASE_SERVICE_ROLE_KEY)=' .env | fly secrets import --stage
fly deploy --remote-only --ha=false          # builds on Fly's remote builder; no local Docker needed
fly logs                                     # expect "processed N flight(s)" every 5 minutes
```

To ship code changes, run `fly deploy --remote-only` again from `worker/`.

## Supabase

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase db push        # applies supabase/migrations
supabase config push    # turns on anonymous sign-ins
```

## iOS app

```bash
cd ios
xcodegen generate
open Smooth.xcodeproj
```

With no Supabase keys the app runs in **demo mode**, using a bundled real forecast (`Resources/sample_forecast.json`). To connect it to your project, copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and fill in the URL and anon key.

To refresh the airport list (OurAirports): `cd worker && uv run python scripts/build_airports.py`.
