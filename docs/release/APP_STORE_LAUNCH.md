# BumpCast 1.0: App Store launch

App Store Connect app `6824269447`, version 1.0 (`0d3b581b-1aab-4737-93b8-065ad6d18c93`). Listing copy lives in `metadata/` (`asc metadata push`). Support and privacy pages are Google Docs owned by lanre@akinyemi.ca ([privacy](https://docs.google.com/document/d/1wgxMmBIa1OiTJesX83nBVIJl1c2EAz-TxvpMndDK7T0/edit), [support](https://docs.google.com/document/d/1k6sr1RYokvIx8a09Gw5Wv2tZPhEGh4t39c6o9NEDmRM/edit)); the listing links their `/preview` URLs, the same setup as Cribbage Nights. `site/` keeps the HTML source in case BumpCast gets its own domain.

Modelled on Flighty, byAir, Flightradar24 and the turbulence apps (Turbli+, Turby, Flight+, Flying Calmly, Sky Guru), read on Oct 18, 2026. House rule from `docs/design/DESIGN_SPEC.md` still applies: **never name data sources** (no NOAA, GTG, "global models") in the listing or screenshots. Pilot reports are a feature, so they can be named.

## Listing

Rebuilt on Oct 18, 2026 from the Appfigures ASO report. Its key finding: Apple already shows turbulence apps in flight-tracker searches, but only when "Flight" and "tracker" appear in the listing. FlyBud ("FlyBud – Flight & Turbulence" / "Live tracker, Forecast, Alerts") is two weeks old with 9 ratings, and it already ranks #20–31 for "flighty", "flightradar24", "flightaware" and "flight tracker".

| Field | en-US | es-MX (second keyword field for the US store) | Status |
|---|---|---|---|
| Name | BumpCast Flight: Turbulence (27) | BumpCast Vuelo: Turbulencia (27) | pushed |
| Subtitle | Live tracker & forecast alerts (30) | Rastreador y alertas en vivo (28) | pushed |
| Keywords | radar,plane,airplane,status,delay,nervous,flyer,fear,flying,anxiety,map,weather,pilot,airline,bumpy (99) | avion,radar,miedo,volar,ansiedad,pronostico,clima,piloto,aviation,aircraft,airport,smooth,calm (94) | pushed |
| Promotional text | "Flying soon? Add your flight…" | "¿Vuelas pronto? Agrega tu vuelo…" | pushed |
| Description | `metadata/version/1.0/en-US.json` | `metadata/version/1.0/es-MX.json` | pushed |
| Support, privacy URLs | Google Docs `/preview` links; contact support@akinyemi.ca | same (English docs) | pushed; both docs public |
| Categories | Travel (primary), Weather (secondary) | | set |
| Age rating | 4+ (all none; health or wellness topics = yes) | | set |
| Content rights | uses third-party content (public weather data, pilot reports) | | set |
| Copyright | 2026 Lanre Akinyemi | | set |
| Release | Manual release, with phased release on | | set |

Why these choices:
- **Name and subtitle together** match "flight tracker" (59), "live flight tracker", "flight forecast" and "turbulence forecast". "Flight" is in the name and "tracker" is in the subtitle; Apple combines words across name, subtitle and keywords.
- **Keywords:**
  - "radar" pairs with "Flight" for "flight radar" (54);
  - "plane" covers "plane tracker" (46);
  - "fear" and "flying" moved here from the old subtitle;
  - no word repeats the name or subtitle.
- **es-MX** is widely reported to be indexed in the US store. Its keyword field holds Spanish equivalents plus English overflow (aviation, aircraft, airport, smooth, calm). Its screenshots fall back to en-US.
- **No competitor names anywhere** in the metadata, screenshots or ad text. Those searches are reached through relevance and Search Ads.
- **Description:** Flighty/byAir format. It opens "BumpCast is a flight tracker for the ride itself". The "We've taken off" section describes what is tracked: the flight's progress, minute by minute, along the route against the forecast. It doesn't claim live flight status or delays.
- **Categories:** flight trackers live in Travel, and that's where Apple judges relevance. Weather is secondary.

### Update: 1.0 will include flight search (decided Oct 18, 2026)

Build 2 won't be submitted. 1.0 ships on a later build that includes flight-number search and live status from the `add-flight-number-lookup` work. Once that's in, "Live tracker" and the "status" and "delay" keywords describe real features, and the risk below goes away. Update the App Review notes to say how to search by flight number.

### Known risk: "tracker" without flight tracking (decided Oct 18, 2026)

1.0 ships with "Live tracker" in the subtitle and "status" and "delay" in the keywords. The app has no flight-number lookup and no live flight status.
- **App Review:** reviewers can reject this under guideline 2.3 (misleading metadata) or 2.3.7 (irrelevant keywords).
- **Users:** people arriving from Flighty and Flightradar24 searches expect status and delays. That risks early uninstalls and 1-star "not a tracker" reviews while ratings are still few.

Fallback, if review flags it:
- resubmit with the subtitle "Live forecast & bump alerts";
- swap "status,delay" for "storm,smooth".

Real fix: add flight-number lookup and live status from a paid flight-data feed, ideally in 1.1, before the Search Ads push on competitor terms.

## Screenshots (6.9" iPhone, 1320 × 2868; 10 frames)

The dominant style across Flighty, byAir, Flight+ and Turby:
- full-bleed dark sky background (the Cabin Dawn **night** gradient `#1B2A45 → #0B1322`);
- a floating device frame;
- a small eyebrow label in IBM Plex Mono caps;
- a 2–5 word headline in Familjen Grotesk, white with one accent word in `#6FBCCC`.

Each frame sells one benefit. Use a real-looking demo flight (e.g. `JFK → LAX · Thu 7:40 AM`) in light mode so the UI pops against the dark frame.

| # | Eyebrow | Headline | Screen |
|---|---|---|---|
| 1 | FOR NERVOUS FLYERS | Know every bump before you board. | Forecast hero: "A few bumps, mostly calm." with the wave timeline |
| 2 | MINUTE BY MINUTE | See exactly when it gets bumpy. | Full timeline with two bumpy stretches labelled |
| 3 | WE'VE TAKEN OFF | A countdown to every bump. | Lock Screen Live Activity plus Dynamic Island "Light chop in 12 min" |
| 4 | GETS SHARPER | From 48 hours out to confirmed. | Update feed: "Updated: smoother over Colorado" plus a Confirmed badge |
| 5 | WHY IT'S BUMPY | Plain words. No scary charts. | "Why it's bumpy here" card (mountain waves) |
| 6 | CALM, ON CUE | Breathe through it, right on time. | Calm breathing paced to the next stretch |
| 7 | TURBULENCE MAP | Feel what pilots are feeling. | Map with pilot reports on |
| 8 | AFTER YOU LAND | See how right we were. | "How did it feel?" plus the accuracy stat. No competitor shows this |
| 9 | FIND YOUR FLIGHT | Type a flight number. Done. | Find step with flight-number results |
| 10 | ALL THIS AND MORE | — | Icon grid: Live Activity, offline, breathing, explainers, map, pilot reports, accuracy, Flight Pass, no ads, no account |

- **Frame 1 is the hero.** Six of the eight competitors put social proof there (awards, press, "300K travelers"). We don't have any yet, so lead with the emotion. Add a laurel ("Rated 4.9 by nervous flyers", "10,000 flights forecast") as soon as the numbers are real.
- **The app needs a screenshot mode before frames can be captured.** No current flight sits inside the 48-hour window with bumps, so a launch argument has to seed a demo flight, forecast, Live Activity and accuracy stats. Frames are then composed with `asc screenshots frame` and uploaded with `asc screenshots upload`.

## Search Ads and ranking plan (from the Appfigures report)

US search popularity (Appfigures scale), and where turbulence apps rank today:

| Search | Popularity | FlyBud | Turbli+ |
|---|---|---|---|
| flightradar24 | 65 | #20–31 | #15 |
| flight tracker | 59 | #20–31 | #26 |
| flighty | 58 | #20–31 | |
| flight / flight radar | 54 | | |
| plane tracker | 46 | | |
| flightaware | 44 | #20–31 | |
| plane finder | 40 | | |

"Turbulence Forecast" shows up only around #40–52, because its name lacks "tracker".

**Apple Search Ads.** No turbulence app bids on the flight-tracker searches, so BumpCast would be the only one in those auctions.

| Campaign | Keywords (exact match) | Product page |
|---|---|---|
| Competitor | flighty, flightradar24, flightaware, plane finder | Companion custom page: "You know where your plane is. Now know how smooth the ride will be." |
| Generic | flight tracker, flight radar, plane tracker | Frequent-flyer custom page |
| Brand / defend | turbulence, turbulence forecast, fear of flying, bumpcast | Nervous-flyer custom page |

- **Never name competitors** in ad text or screenshots. Bidding on their names as keywords is allowed.
- **Start budgets small** and let the competitor campaign prove itself before scaling. Track tap-through rate and trial starts per campaign in Superwall.

**Custom product pages.** Make two; each needs its own set of 3+ screenshots.
- **Frequent flyers:** lead with the tracker and forecast. Use frames 3 (countdown), 2 (timeline), 4 (updates) and 7 (map). Hero: "You know where your plane is. Now know how smooth the ride will be."
- **Nervous flyers:** lead with calm. Use frames 1, 6 (breathing), 5 (why it's bumpy) and 8 (accuracy). Hero: "Fear of flying? Know every bump before you board."

**Ratings velocity** matters most; FlyBud ranks with 9 ratings.
- The review prompt already fires only after a landed flight where the forecast matched. Keep it that way.
- Launch push: TestFlight testers, friends and family, plus a "rate us after your next flight" note in the first What's New.

**In-app events** show up in search results. Plan one per travel peak:
- Thanksgiving: Nov 20–30, 2026;
- winter holidays: Dec 18 – Jan 4;
- spring break: March 2027.
Submit each one about two weeks ahead.

**Rank watch.** Check weekly in Appfigures:
- searches: "flight tracker", "flighty", "flightradar24", "flight radar", "turbulence forecast";
- goal: top 10 within 90 days of launch, ahead of FlyBud and Turbli+.

## Things no competitor does yet (cheap wins)

- **App preview video (15 s):** add a flight → grade appears → timeline scrubs → Live Activity counts down → "Smooth landing." None of the eight listings has one.
- **In-app event:** a "Thanksgiving travel turbulence outlook" from Nov 20 to 30, 2026. It can be submitted alongside or after 1.0, and none of the competitors uses events.
- **Subscription promotional images:** ASC flags them as missing on both subscriptions. They're needed for win-back and promo offers, so add them now.

## What's New voice (from 1.1 on; Apple doesn't show it for 1.0)

Write it Flighty-style: warm, specific and bulleted, never "bug fixes and performance improvements". Example:

> • Forecasts now say *which* stretch got smoother, not just that it did.
> • New explainer: why the bumps are worse at the back of the plane.
> • Thanks for every "How did it feel?" rating. They make tomorrow's forecasts better.

## Remaining blockers (from `asc validate`)

1. ~~Make both Google Docs public.~~ Done; both load logged out.
2. ~~Push the description and URLs.~~ Done.
3. **New build.** Build 0.1.0 (1) can't be attached to version 1.0. `project.yml` is now 1.0 (2). Archive, upload, then attach it.
4. **Screenshots:** see above.
5. **App Review details:**
   - contact name, email and phone;
   - notes. Suggested: "No login. Add any US domestic flight departing in the next 48 hours (e.g. JFK→LAX) to see a forecast. Flights further out show 'Your forecast unlocks…'. Pro can be tested with the sandbox subscription."
6. **Availability:** create it (`asc web apps availability create`, or set it in ASC Pricing and Availability). Start with the US only, since coverage is continental US.
7. **In-app purchases on first review:**
   - attach the Flight Pass and both subscriptions to version 1.0 (ASC → version page → In-App Purchases and Subscriptions);
   - add the subscription promotional images.
8. **App Privacy questionnaire.** It must match the privacy Google Doc and `site/privacy.html`. Declare everything below as **Linked to You**:
   - Every item is tied to the anonymous Supabase user ID, which the app also passes to Superwall with `identify`.
   - Apple counts data as linked when it's tied to an account or device ID, even without a name or email.
   - **Not used for tracking** for every item. No ATT prompt, no IDFA, no ad networks or data brokers. Superwall reads the IDFA only once ATT is granted, and the app never asks.

   | Data type | Collected by | Purposes |
   |---|---|---|
   | Identifiers → User ID | Supabase (anonymous ID), Superwall | App Functionality, Analytics |
   | Identifiers → Device ID | APNs push token (Supabase), Superwall vendor ID (IDFV) | App Functionality, Analytics |
   | Purchases → Purchase History | Superwall, Supabase (`flight_passes`) | App Functionality, Analytics |
   | Usage Data → Product Interaction | Superwall (paywall and onboarding events, flight counts, notification status) | Analytics, Developer's Advertising or Marketing (choosing which in-app offer to show) |
   | User Content → Other User Content | Flights, after-landing ratings and waitlist country (Supabase); next-flight route, grade and onboarding answers (Superwall attributes) | App Functionality, Analytics, Developer's Advertising or Marketing |

   - **Not collected:** precise or coarse location, contact info, health data, diagnostics.
   - **Device details:** Superwall reads the locale, region setting and time zone from device settings, not from location services. They fall under the Device ID and Product Interaction rows, not Location.
   - **Superwall's privacy manifest** declares only Purchase History, as not linked. The rows above are wider because of what *this app* sends: `identify` with the user ID, plus the user attributes in `Paywalls.swift` and `Onboarding.swift`. If new attributes are added, update both this table and the privacy doc.
   - **Fear level:** the onboarding answer about turbulence is borderline under Health & Fitness. It's a comfort preference, not a medical or health record, so it's declared as Other User Content. If App Review pushes back, move it to Health.

## Launch day (manual release)

1. Once approved, hold the build in "Pending Developer Release". Pick a Tuesday or Wednesday morning ET.
2. Release. Phased release covers automatic updates only; new downloads get 1.0 immediately.
3. Post the launch the way Flighty did: a short screen recording of the Live Activity, which is the most shareable moment.
4. Watch `asc status --app 6824269447`, crash reports and Superwall conversion for the first 48 hours.
