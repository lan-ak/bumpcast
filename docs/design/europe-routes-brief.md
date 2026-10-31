# US–Europe and within-Europe routes: design brief (draft for Lanre, Oct 31)

Requested by the "Free weather data sources" session. It builds on the approved **global-forecasts-copy.md (revision 2)**, which shipped in 1.0.2 as the opt-in **Global outlook (beta)**. Europe routes fit into that design; this brief covers only what changes or was missing.

## The short version

- **The shipped app already handles most of it**, as long as the worker sends `noaa_possible = false` on every route that leaves the US box. Without that flag, today's app shows a European flight as "Advance · confirms Tue", which is a promise it can never keep. This is the one hard rule for the worker.
- **Five things need an app update:**
  - the "Confirmed forecast" step when you add a flight,
  - the map on mixed and Europe routes,
  - "last part confirmed" wording for flights into the US,
  - the cap on the outlook glass,
  - the data credits.
- **It stays a beta,** opt-in, in Pro. The final backtest (3,901 pilot reports, Oct 27–31) found the outlook shows bumps on 61% of moderate-or-worse reports, and on 23% of reports pilots called smooth. Only 57 of the reports came from outside the US, so its accuracy there isn't proven. §7 sets out how it can graduate from beta.
- **Decisions for you:** marked **Decide** below.

---

## 1. A flight that will never be confirmed (within Europe, or LHR–CDG)

What the shipped app shows with the beta on, and what to change:

| Where | Today | Change |
|---|---|---|
| Badge | Global outlook · BETA | Keep |
| Status line | Updated every 6 hours until you fly | Keep |
| Outlook sheet body | "…this is our worldwide outlook. It's newer and less detailed than our forecasts for US routes, and it updates every 6 hours until you fly." | Add: **"It won't become a confirmed forecast, so check back before you fly."** (App update.) |
| Outlook sheet, How to read it | "Times are approximate and levels are ranges. It can miss bumps…" | Add the cap in plain words: **"On its own it shows light bumps at most. Moderate or strong only appear near an official warning or a pilot report."** |
| Add flight, "Saved" timeline | **Now → Advance forecast → Confirmed forecast (date) → You fly.** Wrong for these routes. | **Now → Global outlook (beta), from {date} ("Updated every 6 hours. Times are approximate.") → You fly.** No confirmed step. (App update, `AddFlightView` ~line 2051.) |

**What the outlook claims:** a grade without a score, approximate times, one-step ranges, and never "smooth".
**What it never claims:** exact minutes, "confirmed", or that no bumps means calm. "Light bumps are possible on any flight." stays.

**Rule change.** Rule 4 in global-forecasts-copy.md says the outlook alone is capped at **moderate**. The worker now caps it at **light**. Update the rule. `OutlookSegmentRow` caps the glass at `.moderate` when there's no warning; change it to `.light` so the app agrees even if the worker changes (app update). Ranges still read "Light to moderate possible", which is honest: the outlook misses moderate bumps.

## 2. Mixed routes (JFK → LHR, LHR → JFK)

The approved design already covers the timeline: exact minute bars on confirmed stretches with an accent strip under them, faded 30-minute outlook blocks, the legend "Confirmed, exact · Outlook, approximate", and "Beta outlook" tags on outlook rows. The summary uses the outlook headline for the whole flight. Keep all of that.

**Gaps:**

1. **Before anything is confirmed** (more than about 17 h out), a mixed route says only "Updated every 6 hours until you fly". It never mentions that the US part will be confirmed. Change the line to:
   - Leaving the US: **"The part over the US is confirmed from {Tue around 3 PM}. The rest stays a beta outlook."**
   - Arriving in the US: **"The landing over the US is confirmed from {Tue around 11 PM}…"**
   - Timing: a stretch can be confirmed 18 h before it is flown. A westbound flight's landing stretch is about 8 h after takeoff, so it's confirmed about 9 h before departure, not 17 h. Work it out from the stretch's own time. (App update.)
2. **Flights into the US.** The add-flight explanation only handles flights that leave the US ("The first part, over the US, is confirmed."). Add **"The last part, over the US, is confirmed."** for arrivals, and the matching "Saved" timeline step: "Landing confirmed, {date}". (App update, `RouteStep.betaExplanation`.)
3. **The map is US-only, and the mixed-route card can mislead.** `RouteProfile` only reads points inside the US grid. On JFK → LHR it can say **"Smooth along your route at this height"** when it has only seen the first 40 minutes. Fix (app update):
   - The route card reads **"Over the US part of your route: Smooth at this height"**.
   - Add a second line: **"The map covers the US. Your forecast has the outlook for the rest."** with an **Open forecast ›** link.
   - Draw the route past the grid edge faded and dashed, so the map doesn't look like it has data there.
4. **Within-Europe routes on the map** say "No map data along your route at this height yet." The word "yet" promises something we can't deliver. Use the line from point 3 and the same link, and drop "yet". (App update.)
   - **Decide:** a European map layer from the outlook. I'd hold it: a coarse 6-hourly grid next to the hourly US map would invite the comparison we said never to make.

Verification: the previews only include JFK → LHR. Ask the worker session for a **LHR → JFK** sample (confirmed at the end) and an **LHR → FCO** sample (outlook only, with a pilot report) to check in the simulator.

## 3. Warnings: the only thing that raises the outlook above light

The approved warning treatment ships already: a banner above the chart in dark ink, the ⚑ flag, a chart capsule and band, a row line, a list label, and a sheet that includes "Your crew has this warning too." Keep it. Changes:

- **Region names must be places people know.** Oceanic warnings come from areas named things like "Shanwick" or "Gander Oceanic". The `region` the worker sends must read as **"over the North Atlantic"**, **"over the Bay of Biscay"** or **"over the Alps"**, never a code or a control area name. (Worker; no app change.)
- **No warnings doesn't mean all clear.** Over the ocean, the absence of pilot reports says nothing. That's why the cap line in §1 belongs in the sheet. Don't add a "No warnings on your route" line anywhere: it would read as reassurance we can't back up.
- **Strong is still only ever "possible"**, and only near an official warning or a pilot report (approved rule).
- **Pilot report age:** pilot reports are rare out there, so an old one gets shown. The sheet already gives its age ("Pilots reported bumps here, 2 h ago"). Hide reports older than 3 h on outlook routes. **Decide** the cut-off with the worker session.

## 4. Coverage, onboarding, paywall and marketing

**Add flight.** `Coverage.swift` is a US box. It decides when to ask about the beta, never what we can forecast. With the beta on, any route can be added, and if the worker can't do it, the flight shows "We can't forecast this route yet" with "Notify me when we can". That works in the shipped app. Keep the worker as the source of truth; no client region list.

**Onboarding (a gap that affects sales).** Someone whose first flight is LHR → JFK during onboarding hasn't answered the beta question, so `OnboardingFlight` returns `out_of_coverage` and the paywall treats the route as one we can't forecast.
- **Decided (Lanre, Oct 31): (b), turn the beta on automatically** for any onboarding flight outside the US. The flight gets the usual Global outlook BETA badge and sheet, and the Settings switch shows it on, so they can turn it off.
  - Options considered:
  - **(a):** ask the beta question inside onboarding, as one extra step for international flights. The wording is already approved: "Get the global outlook (beta) for this flight?" (App update.)
  - **(b)** Turn the beta on automatically for any onboarding flight outside the US. Cheaper, but they never opted in.
- Until then, the paywall's out-of-coverage wording can say "Turn on our global outlook (beta) in the app for this route" with no app update.

**Paywall.** It already shows both lines together: "Detailed, hourly forecasts for US flights" and "Global outlook (beta) for international flights: approximate, updated every 6 hours". Both stay true. No change.

**In the app,** "We have the strongest coverage in the US, and we're expanding rapidly." stays (approved).

**Marketing:**

| Where | Now | Change to |
|---|---|---|
| App Store description, Coverage | "forecasts flights within the continental United States and southern Canada" | "Detailed forecasts for flights within the continental US and southern Canada. A beta outlook for flights to, from and within Europe." (Goes with the next version.) |
| Promo text | "Flying in the US or southern Canada?" | Keep; it leads with the strong product |
| Site home and support | "Covers the continental United States and southern Canada" | Same as the App Store line |
| Meta and Apple Ads | US targeting | **Don't advertise Europe while it's in beta** (§7) |

**Decide:** whether to say "Europe" at all in public copy before the ratings come in. My view: yes in the description, with "beta", but not in ads.

## 5. Data credits (NOAA and ECMWF)

ECMWF's licence (CC BY 4.0) requires visible attribution and a note that the data was changed. That conflicts with our rule "never name a data source". Proposal: **one exception, and only on a credits screen.** Forecast screens stay as they are.

- **Settings › Licenses** (the existing row) gains a **Weather data** section above Fonts:
  - "Contains modified ECMWF open data, licensed under CC BY 4.0." The licence name links to the licence.
  - "Uses forecasts, warnings and pilot reports from the US National Weather Service (NOAA)." NOAA's data is public domain, so this credit is a courtesy. Don't imply endorsement.
- **Website** support page: the same two lines under "Weather data". Also add them to the App Store description footer, so the credit is visible before the app update ships.
- **Before release:** check ECMWF's current wording for attribution. They may ask for exact text.
- **Before the worker change is deployed:** a credit must be visible somewhere, because the shipped app has no credits screen. The quickest homes, needing no app update:
  - the website support page ("Weather data"), published first;
  - the end of the App Store description. That only goes live with the next version, so the website is the real home until then.
  The app's Settings › Licenses section follows in the next update.
- **Decide (legal):** is the website alone enough for the weeks before the app update? I think it's reasonable under CC BY ("any reasonable manner"), but it's your call.

## 6. Shipped app vs. update

| Works in 1.0.2 with no update (if the worker sends `noaa_possible = false` and `sources`) | Needs an app update |
|---|---|
| Global outlook badge, beta opt-in, "Beta available" | Add-flight "Saved" timeline: no "Confirmed forecast" for outlook routes |
| Approximate times, ranges, no "smooth", no score | Mixed routes: "confirmed from {date}" before anything is confirmed |
| Confirmed US stretches drawn exactly on mixed routes | Arrivals: "The last part, over the US, is confirmed." |
| Warning banner, chart marker, rows and sheet | Map route card on mixed and Europe routes |
| "We can't forecast this route yet" with notify | Outlook glass capped at light without a warning |
| Rating ask after landing | Outlook sheet lines: "won't become confirmed" and the cap |
| Paywall coverage lines (Superwall) | Credits in Settings › Licenses |
| ECMWF data sent under source "gfs" (anything not "gtg" is outlook) | Onboarding beta question (if you choose a) |

**Shipped-app risk to fix on the worker:**
- Any forecast for a route outside the box **must** carry `noaa_possible = false`.
- Region names must be plain.
- If `SMOOTH_GLOBAL` is off, return `out_of_coverage`, never a bare "gfs" forecast.

## 7. How the outlook graduates from beta

**Lanre's bar:** several weeks of data, about 200 or more moderate-or-worse pilot reports outside the US, and after-landing ratings that agree with the forecast. Until all three are met, the beta label, the trust rules and the light cap all stay.

**Showing the ratings in the app (later, behind a flag).** The approved sheet already has an "Agreement slot (later)". Use it for travellers' ratings, as one line in the Global outlook sheet:
- Title: **What travellers said**
- Line: "On {412} beta flights, {78%} said the bumps were about what the outlook said, or smoother."
- Only for one region at a time ("Within Europe", "Across the Atlantic"), and only once that region has 100 or more ratings. Below 100, the slot stays hidden; don't show "Not enough ratings yet".
- If "Bumpier than the outlook" goes above 25% for a region, hide the line and flag it to us. Never show a number that would reassure people wrongly.
- No stars, percentages on the forecast screen, or comparisons with US accuracy.

**When it graduates** (a separate decision, later): drop the BETA tag and "(beta)" for that region only. The approximate times, ranges, "never smooth" and the light cap stay until the forecast itself changes.

## Not changing
- The ban on naming sources everywhere except the credits screen.
- Beta opt-in, in Pro (paywall option B).
- Updates every 6 hours, and the rating ask after every beta flight.
