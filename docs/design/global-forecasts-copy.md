# BumpCast: worldwide routes and mixed-source forecasts (copy and states)

Draft for Lanre's approval. **No app code changes until approved.** Mockups: `docs/design/global-forecasts.html`.

New forecast fields:
- `sources` [{start_min, end_min, source: gtg|gfs}]
- `noaa_possible` (bool)
- `warnings` [{start_min, end_min, kind: sigmet|pirep, severity, label}]
- `agreement` (optional, later)

## 0. Two rules this design keeps

1. **Never name a data source.** No NOAA, GTG, GFS, SIGMET, "global model" or "the US forecast". We describe *what kind* of forecast it is and how often it updates. "Pilot report" names a kind of information, the same way the map already does.
   > **Decision needed:** the explanation sheet says the global outlook is "based on worldwide weather forecasts". It names no model, but it describes the basis, which the brief asks for and the earlier no-sources pass avoided. The alternative is to drop that sentence and keep only "less detailed than our forecasts for US routes".
2. **The outlook never implies certainty about strong turbulence.** It's capped at moderate. Only an advisory or a pilot report can raise a stretch to strong, and then the wording is "strong bumps possible", never "strong turbulence expected".

## 1. Which badge a forecast gets

The badge follows `noaa_possible` first, then time.

| Condition | Badge | Icon | Colour |
|---|---|---|---|
| `noaa_possible = true`, nothing confirmed yet | **Advance forecast** | binoculars | secondary ink |
| `noaa_possible = true`, some stretches confirmed | **Partly confirmed** | checkmark.seal | accent |
| `noaa_possible = true`, all confirmed | **Confirmed forecast** | checkmark.seal.fill | accent |
| `noaa_possible = false` (any time) | **Global outlook** | globe | secondary ink |

A Global outlook never promises a confirm time, because it never becomes "Confirmed". It can still contain confirmed stretches (for example, the part over the US), and the status line says so.

## 2. Status line under the grade

| State | Status line |
|---|---|
| Advance | Confirmed Wed around 3:40 PM *(unchanged)* |
| Partly confirmed | see the stretch rules below, then "Fully confirmed within the hour" |
| Confirmed | Updated hourly until you fly *(unchanged)* |
| Global outlook, no confirmed stretches | Updated every 6 hours until you fly |
| Global outlook, with confirmed stretches | {stretches} confirmed. The rest updates every 6 hours. |

**Describing confirmed stretches** (works when they're not next to each other):
- One stretch at the start: **First 41 min confirmed**
- One stretch at the end: **Last 30 min confirmed**
- Start and end: **First 41 min and last 30 min confirmed**
- One stretch in the middle: **Confirmed from 1 h 10 min to 2 h 05 min in**
- Three or more: **3 stretches confirmed, 2 h 15 min in total**

## 3. Flights list short status

| State | Short status |
|---|---|
| Advance | Advance · confirms Wed *(unchanged)* |
| Partly confirmed | Partly confirmed *(unchanged)* |
| Confirmed | Confirmed *(unchanged)* |
| Global outlook | Global outlook |
| A recent pilot report on the route | adds "· pilot report", e.g. "Global outlook · pilot report" |
| Unsupported route | Can't forecast yet |

## 4. Chart and wave timeline

- **Fade by stretch, not by cut-off.** Outlook stretches draw at 40% opacity and confirmed stretches at full, wherever they fall. The mini wave on flight cards follows the same rule.
- **Coverage strip:** a 4 pt strip under the x-axis. Confirmed stretches are solid accent; outlook stretches are a light dotted line. Tapping the strip opens the explanation sheet. VoiceOver reads "First 41 minutes confirmed, then outlook."
- **Official advisories raise a stretch with no marker of their own** (Lanre: it adds clutter). The stretch simply shows its level, and its "What to expect" row reads like any other.
- **Pilot reports** get a small flag capsule above the chart spanning the stretch, labelled **Pilot report**, as on the map. Tapping it opens its sheet.
- **Legend line:** Solid = confirmed · Faded = outlook · Flag = pilot report (only shown when there is one)

## 5. Explanation sheets (tap the badge, the strip, or a pilot-report flag)

**Global outlook**
- Title: Global outlook
- Body: Your route leaves the area we can forecast in full detail, so this is our worldwide outlook. It's less detailed than our forecasts for US routes, and it updates every 6 hours until you fly.
- Based on: Worldwide weather forecasts, checked against official turbulence advisories and recent pilot reports. *(See Decision 0.1.)* This sheet is the only place advisories are mentioned.
- What it can't do: It won't call strong turbulence on its own. Strong bumps only show when an official advisory or a pilot report points to them.
- If part of the route is confirmed: The first 41 min, over the US, uses our detailed forecast and updates hourly.
- Agreement slot (only when `agreement` exists): **How sure we are:** Forecasts agree well along your route. / Forecasts mostly agree. / Forecasts differ in places, so treat this as a rough guide.

**Partly confirmed**
- Body: {stretches} of your flight is confirmed with our detailed forecast. The rest is still an advance forecast (faded in the chart) and will be confirmed closer to departure, usually within the hour.

**Advance** and **Confirmed**: unchanged from today's copy.

**Pilot report** (tap the flag)
- Title: Pilots reported bumps here
- Body: A crew flying near {Denver} in the last few hours reported {light chop}. We've raised that stretch to match.
- Crew line: Pilots share reports like this so the planes behind them can find smoother air.

## 6. Adding a flight and the waitlist

- International routes now get a forecast. The add-flight sheet no longer blocks or warns them.
- **Check your flight** shows one calm line for routes where `noaa_possible = false`: **Global outlook for this route, updated every 6 hours from 48 hours before you fly.**
- **Step 1 coverage note** (replacing "We have the strongest coverage in the US, and we're expanding rapidly."): **Forecasts for flights worldwide, most detailed in the US.** *(Lanre wrote the current line; changing it is his call.)*
- **What's left of the waitlist:** only routes the worker still can't forecast, such as polar or very long routes. It's driven by the worker's `out_of_coverage` status, not by the US box in `Coverage.swift`.
  - Card title: We can't forecast this route yet
  - Body: Routes over the far north are next on our list. We'll still save your flight.
  - Button: Notify me when we can
  - Joined: We'll let you know when we cover this route.
- **People already on the waitlist** get one push when their route becomes forecastable:
  - Title: Your flight now has a forecast
  - Body: BOS → LHR on Thu 22 Oct now has a global outlook. Tap to see it.
- Flight detail (`FlightDetailView` ~179) shows the forecast in place of the WaitlistCard for these flights. FlightStore's `.outOfCoverage` (~257) comes only from the worker's status, never from `Coverage.covers`.

## 7. Publisher credit

None of these screens shows a publisher credit. Where one appears elsewhere (Settings › About, legal pages), it credits **Akinyemi & Co Ltd**.

## 8. Changes after Lanre's first review

- **Official advisory markers are removed:** the chart flag, the advisory sheet, the "Raised by an official advisory" row line, and "· advisory" in the list. Advisories still raise stretches in the forecast. They're only mentioned in the Global outlook sheet's "Based on" line. Pilot reports keep their small flag.
