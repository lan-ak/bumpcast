# Flight data provider for live tracking (1.1)

Why: the 1.0 subtitle says "Live tracker & forecast alerts", but the app has no flight-number lookup or live status yet. 1.1 adds both. This doc picks the paid data source. **Nothing has been signed up for and no keys have been added.** The choice is yours.

Reminder: whichever provider we pick, the app and notifications never name it (DESIGN_SPEC rule on data sources).

## What we need

- Look up a flight by number and date ("B6 23", Oct 20), returning origin and destination airports and scheduled out/in times.
- Live status from about a day before departure until landing: scheduled, estimated and actual times; delay minutes; gate and terminal; cancelled and diverted.
- Strong US coverage, because most users fly in the US.
- Terms that allow a paid consumer iOS app to show the data and store it for the life of a trip.

## How many calls we'd make

There's one lookup when a flight is added, then the worker polls it: every 2 h from T‑24h to T‑4h, every 15 min from T‑4h to departure, and every 20 min in the air. That's about **30 calls per tracked flight** (fewer if we use push alerts, see AeroAPI below).

| Tracked flights / month | API calls / month |
|---|---|
| 1,000 | ~30,000 |
| 10,000 | ~300,000 |

If "1k–10k lookups" means raw API calls instead, every provider below falls into its cheapest paid tier.

## Comparison

| | FlightAware AeroAPI | AeroDataBox | aviationstack | Cirium (Sky / FlightStats) |
|---|---|---|---|---|
| US coverage | Best of the four. FAA feed, airline data and its own ADS-B network | Good at airports it tracks live. Elsewhere it has schedule only, with no live times (check per airport via `/health/services/feeds`) | Broad, but often reported as lagging for real-time data | Best for global airline data. It's the source behind Google Flights status |
| Live status fields | `scheduled_out` / `estimated_out` / `actual_out` (plus `_off`, `_on`, `_in`), `departure_delay` / `arrival_delay` (in seconds), `status`, `cancelled`, `diverted` | `scheduledTime` / `revisedTime` / `runwayTime`, `status` (including Canceled and Diverted), plus a `quality` marker that says whether a record is live or schedule-only | `scheduled` / `estimated` / `actual`, `delay` in minutes, `flight_status` | Full set, including delay reasons |
| Gate / terminal | Yes: `gate_origin`/`_destination`, `terminal_origin`/`_destination` | Yes: `gate`, `terminal`, plus check-in desk and baggage belt | Yes | Yes |
| Push on change | Yes. Alerts (webhooks) are included in Standard | Flight Alert API (extra) | No | Yes (Alerts API) |
| Pricing model | Pay per call: $0.005 per `/flights/{ident}`, with a **$100/month minimum** on Standard | Flat plans in "units". Flight status is Tier 2, which costs 2 units | Flat plans counted in requests | Contract or quote only. Its self-serve commercial plan prices by volume, but prices are behind a login |
| Cost at 1k flights (~30k calls) | ~$150/mo | $99/mo direct Growth (400k units), or $40/mo on RapidAPI Ultra (50k units, which is too tight at 60k needed) | $149.99/mo Professional (50k req) | Likely $$$$ |
| Cost at 10k flights (~300k calls) | ~$1,500/mo (cut a lot with alerts in place of polling) | $499/mo direct Scale, or ~$240/mo RapidAPI Mega (500k units + overage) | Exceeds Business (250k for $499.99), so it needs Enterprise | Likely $$$$ |
| Consumer app terms | **Standard tier explicitly covers business‑to‑consumer use.** Personal tier forbids it | Commercial use is OK on every paid plan (they cite mobile apps as an example). **No permanent copies.** Caching is 7 days by default and "extended" on Growth/Scale. No redistribution or raw republishing | Commercial use is OK on paid plans | Negotiated per contract |
| Sign-up friction | Self-serve, credit card | Self-serve, credit card | Self-serve, credit card | Sales call |

Sources: [AeroAPI pricing and tiers](https://www.flightaware.com/commercial/aeroapi/), [AeroAPI OpenAPI spec v4.30](https://static.flightaware.com/rsrc/aeroapi/aeroapi-openapi.yml), [AeroDataBox pricing and terms](https://aerodatabox.com/pricing/), [AeroDataBox data coverage](https://www.aerodatabox.com/data-coverage), [aviationstack pricing](https://aviationstack.com/pricing), [Cirium developer getting started](https://developer.flightstats.com/getting-started/).

## Recommendation: FlightAware AeroAPI, Standard tier

1. **It's accurate enough to back the "Live tracker" claim.** US coverage is the strongest of the self-serve options, and every field we need comes back as a typed field in one call (`/flights/{ident}`). That includes `cancelled` and `diverted` booleans and delay values ready to use.
2. **Its terms are clear for a consumer app.** Standard is the tier licensed for business-to-consumer use, so there's no grey area about caching or derived work.
3. **Alerts keep the cost down as we grow.** We'd register an alert when a flight is added, so the worker gets departure changes, cancellations and diversions pushed to it. Polling then drops to a few safety-net calls per flight, which brings the per-flight cost toward ~$0.03–0.05 and the 10k-flight bill well under the polling estimate above.
4. **What it costs:** the $100/month minimum from day one, even with few users.

**Budget alternative: AeroDataBox (direct Growth, $99/mo flat).** It's about 5× cheaper at scale and returns gates and terminals. Downsides: live times exist only at airports it tracks live, so some US regional airports would show schedule-only data and we'd have to handle that case in the UI. Its "no permanent copies" rule also means we'd purge stored status after the flight. Pick this if cost matters more than coverage before 1.1 has paying users.

**Not recommended:**
- **aviationstack:** It's often reported as lagging for real-time status, which is risky for a "live" claim, and it gets expensive past 250k requests.
- **Cirium:** Its data quality is excellent, but it needs a sales contract and is priced for enterprises. Overkill for 1.1.

## Before signing up (whichever you pick)

- Run a free or personal-tier trial against 20–30 real upcoming US flights (JetBlue, Southwest, a regional carrier, a cancelled flight). Check how often gate and estimated times show up and how fresh they are.
- Confirm the attribution requirements in the provider's terms. Our design rule forbids naming sources in the UI, so a provider that requires on-screen credit is a blocker.
- Add the key as a Fly.io secret on the worker only. The iOS app calls our backend for lookups and never holds the key.

## Decision

- [ ] FlightAware AeroAPI Standard (recommended)
- [ ] AeroDataBox direct Growth
- [ ] Other
