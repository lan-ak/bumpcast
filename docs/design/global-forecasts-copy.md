# BumpCast: worldwide routes and mixed-source forecasts (copy and states, revision 2)

**Approved by Lanre (revision 2), with paywall option B.** Mockups are in `docs/design/global-forecasts.html`. After approval, the spec goes to the "Global data coverage options" session.

New forecast fields:
- `sources` [{start_min, end_min, source: gtg|gfs}]: which kind of forecast covers each stretch
- `noaa_possible` (bool): whether the whole route can ever be confirmed
- `warnings` [{start_min, end_min, kind: sigmet|pirep, severity, label}]: official warnings and pilot reports along the route
- `agreement` (optional, later)

**Why the outlook must read rougher than a confirmed forecast:** over the US, the global outlook missed about two-thirds of moderate pilot reports. The confirmed forecast missed about a third. For a nervous flyer, the worst failure is "calm" followed by a bumpy flight.

## 0. Rules

1. **Never name a data source.** No NOAA, GTG, GFS, SIGMET, "global model" or "the US forecast". "Official warning" and "Pilot report" are kinds of information, and we can name them.
2. **Trust rules for outlook stretches.** These apply to outlook-only routes (`noaa_possible = false`) and to the outlook parts of partly confirmed routes:
   1. **Label:** **Global outlook (beta)**. The first rollout is opt-in for waitlist users.
   2. **No numeric score.** Show the grade only.
   3. **Approximate times:** "about 3 h in, for around 40 min". Round to the nearest 10 min under 1 h and the nearest 30 min above. The chart draws outlook stretches as coarse 30-minute blocks at 42% opacity.
   4. **Ranges, not single levels:** "Light to moderate possible", "Moderate to strong possible near the warning". A range is one step: light to moderate, or moderate to strong.
   5. **Never "smooth".** A smooth or mostly smooth grade reads **No major bumps expected**, always followed by **Light bumps are possible on any flight.** In the list it's shortened to "No major bumps".
   6. **Official warnings are prominent.** They're the most credible signal outside the US (details in §4).
   7. **Always ask for a rating** after these flights land (details in §6).
3. **Confirmed stretches stay exact** (minute bars, exact times, a single level), even on a beta route.
4. **Strong turbulence is only ever "possible"**, and only when an official warning or a pilot report points to it. The outlook alone is capped at moderate.

## 1. Badges

| Condition | Badge | Colour |
|---|---|---|
| `noaa_possible = true`, nothing confirmed yet | Advance forecast | secondary ink |
| `noaa_possible = true`, some stretches confirmed | Partly confirmed | accent |
| `noaa_possible = true`, everything confirmed | Confirmed forecast | accent |
| `noaa_possible = false` | **Global outlook** + a mono **BETA** tag | secondary ink |
| International route, beta off | Not forecast yet | secondary ink |

## 2. Status line under the grade

| State | Line |
|---|---|
| Global outlook, nothing confirmed | Updated every 6 hours until you fly |
| Global outlook, some stretches confirmed | First 41 min confirmed. The rest is a beta outlook, updated every 6 hours. |
| Non-adjacent confirmed stretches | First 41 min and last 30 min confirmed. · Confirmed from 1 h 10 min to 2 h 05 min in. · 3 stretches confirmed, 2 h 15 min in total. |
| An official warning on the route | Official warning on your route (this replaces the line above) |

US states (Advance, Partly confirmed, Confirmed) keep their current lines.

## 3. Forecast screen

- **Headlines** on outlook routes:
  - Smooth or mostly smooth: "No major bumps expected."
  - Some bumps: "A few bumps possible."
  - Bumpy or rough: "Bumpy in places."
  - The summary always ends with "Light bumps are possible on any flight."
- **Chart:**
  - Confirmed stretches: exact minute bars, with a solid accent strip under the axis.
  - Outlook stretches: faded 30-minute blocks.
  - Legend: "Confirmed, exact" · "Outlook, approximate".
- **Stretch rows on the outlook:**
  - Title: "About 1 h 30 min in, for around 30 min"
  - Body: "{Range} possible {over the place}."
  - Small "Beta outlook" tag on partly confirmed routes.
- **No score anywhere** on outlook routes.

## 4. Official warnings (prominent)

- **Banner** above the chart, the first thing on the screen.
  - Dark ink with white text in light mode; light with dark text in dark mode. No red and no warning triangle. It uses a flag icon.
  - Wording: **OFFICIAL WARNING** (eyebrow), then **Thunderstorms over Recife, about 1 h 30 min in**, then a chevron.
- **On the chart:** a solid capsule, "⚑ Official warning", above the stretch, plus a light shaded band over the stretch.
- **In the stretch row:** "⚑ Official warning · thunderstorms".
- **In the list:** "⚑ Official warning on route".
- **Sheet** (tap the banner or the marker):
  - Title: the banner text
  - Heading: What this means for your flight
  - Body: Aviation weather offices issue warnings where strong turbulence or storms are likely. This one covers about 30 min of your route, around 1 h 30 min after takeoff.
  - Crew card: **Your crew has this warning too.** Pilots fly around storms, often by many miles, and turn the seatbelt sign on early.
  - What you might feel: Moderate to strong bumps are possible near the storms. Keep your seatbelt fastened from about 1 h in.
  - Footer: Warnings are updated through the day. We'll tell you if this one changes or clears.
- **Pilot reports** keep the small flag and their sheet, as on the map ("Pilots reported bumps here").

## 5. Global outlook sheet (tap the badge)

- **Title:** Global outlook (beta)
- **Body:** Your route leaves the area we can forecast in full detail, so this is our worldwide outlook. It's newer and less detailed than our forecasts for US routes, and it updates every 6 hours until you fly.
- **Based on:** Worldwide weather forecasts, checked against official warnings and recent pilot reports. *(Approved: kept.)*
- **How to read it:** Times are approximate and levels are ranges. It can miss bumps, so treat it as a guide and keep your seatbelt fastened.
- **Help us improve it:** After you land, tell us how it felt. Every rating makes the outlook better.
- **Agreement slot (later):** Forecasts agree well / mostly agree / differ in places.

## 6. After landing: always ask

- **Notification** (sent for every beta flight; the notification-gaps branch already covers every flight with a forecast):
  - Title: Welcome to Lisbon
  - Body: How bumpy was it? You flew with our beta global outlook, and your two taps help us improve it.
- **In-app card**, which stays on the flight until it's answered or dismissed:
  - Title: How did it compare?
  - Options: Smoother than the outlook · About what it said · Bumpier than the outlook
  - Footer: Your answer helps us improve global outlooks.

## 7. Opt-in (beta)

- **Waitlist card** (routes the beta covers):
  - Title: Try the global outlook for this flight
  - Body: A newer, less detailed forecast for routes outside the US. Times are approximate and it can miss bumps.
  - Buttons: **Turn on the beta** · Not now
- **Settings switch:**
  - Label: Global outlooks BETA
  - Footer: Forecasts for flights outside the US. Less detailed than US forecasts, and updated every 6 hours. After each one, we'll ask how it felt.
- **Adding an international flight** (asked once; the answer becomes the Settings switch):
  - Question: Get the global outlook (beta) for this flight?
  - Explanation: The first part, over the US, is confirmed. The rest is our newer worldwide outlook. *(First sentence only on partly confirmed routes.)*
- **Beta off:** the flight shows "Not forecast yet" with the waitlist card, and the list shows "Beta available".
- **Polar or other routes the worker can't do:** "We can't forecast this route yet", with "Notify me when we can".
- **People already on the waitlist,** once their route is covered: push "A forecast for your flight is ready to try", then "BOS → LHR on Thu 22 Oct can use our beta global outlook. Tap to turn it on."

## 8. Paywall: option B approved

- **Option A (not chosen): free during the beta.**
  - Headline: "Global outlooks are free during the beta"
  - Body: Try our newer forecast for flights outside the US. It's less detailed than our US forecasts, and your ratings help it improve.
  - Pro line: Pro still adds the full timeline, updates and live status on every flight.
- **Option B (approved): in Pro, with plain copy.** The Pro list line reads: "Global outlook (beta) for international flights: approximate, updated every 6 hours." It sits next to "Detailed, hourly forecasts for US flights".
- **Either way,** never write "forecasts worldwide" without the beta qualifier, and never compare the outlook's quality to US forecasts favourably.

## 9. Other decisions

- **Step 1 coverage line (approved):** keep "We have the strongest coverage in the US, and we're expanding rapidly." during the opt-in beta.
- **Publisher credit:** none on these screens. Where a credit appears elsewhere, it's Akinyemi & Co Ltd.

## Changes

- **Revision 1 → first review:** advisory markers were removed as clutter.
- **Revision 2:** added the trust rules from the "Global data coverage options" session. Lanre then chose to make official warnings **more prominent, for trust**, so they're back as a banner, a chart marker, a row line, a list label and a sheet.
- **Approval:** Lanre approved revision 2 with paywall option B, the "Based on" line kept, and the step 1 coverage line unchanged.
