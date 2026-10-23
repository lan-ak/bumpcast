# Onboarding: "When is your next flight?"

**Goal:** people flying soon are the most motivated buyers. Ask when they fly next. If it's soon, have them add the flight during onboarding, show what we know about it, and end on a hard paywall. Everyone else keeps today's onboarding.

Status: built (2026-10-22). Worker deployed; app changes and the Superwall flow are uncommitted and unpublished, waiting on the app release.

**Measured:** on the live worker, a saved flight has its first forecast in **2.8–4 s** (5 h, 10 h and 30 h out). The app checks every second, so about 3–5 s in the app. Before the GTG cache below, it was 11.5 s for a 20 h flight and 12–30 s for flights under 18 h.

**How:** the worker decodes each hour of every new GTG run once, on its own thread, paced to stay inside NOAA's request limit (~10 minutes per run), and stores it on disk with each grid cell's altitudes together. Forecasts use the newest fully decoded run and read only the cells along the route: 0.05–2 s instead of 3–6 s per hour of flight. Output is identical to before (checked on the same run: same grade, score and stretches).

---

## 1. The flow

The new question goes after "How often do you fly?". The flow only splits at the end, so everyone else sees exactly today's pages.

```
Welcome → Feeling → Reassure → How → Help → Frequency → NEXT FLIGHT (new) → Source → Notifications
                                                                                    │
                     ┌──────────────────────────────────────────────────────────────┤
                     │ answered 24 h or 3 days                                       │ answered next week or later
                     ▼                                                               ▼
        Add your flight (native screen, opened by the page)                   Plans (unchanged, closable)
                     ▼
        Checking your flight (Superwall page; waits for the forecast)
                     ▼
        Your flight: hard paywall (Superwall page; content depends on the forecast)
```

**The new question.** "When is your next flight?" with four answers: in the next 24 hours / in the next 3 days / in the next week / further out. The answer is saved as the user attribute `next_flight_window` (`24h`, `3d`, `week`, `later`), like the other answers.

**Notifications come before the flight.** Soon flyers still see the notifications page first. Their forecast and updates arrive as push notifications, so this is where permission matters most.

**The actual flight decides the screen.** If someone answers "24 hours" but adds a flight 5 days away, they get the "we're tracking it" version, not a forecast.

## 2. Which screens are built where

Every screen is in the Superwall onboarding flow (`superwall/paywalls/onboarding`) except one: the add-flight screen stays native, as you chose.

| Screen | Built in | Notes |
|---|---|---|
| Next flight question | Superwall | New page, same style as Frequency |
| Add your flight | **Native** (`AddFlightView`) | Opened on top of the onboarding through a custom callback |
| Checking your flight | Superwall | Loading moment, e.g. "Checking the sky along YYZ → EWR…" |
| Your flight (hard paywall) | Superwall | Four versions, see §4 |
| Plans (everyone else) | Superwall | Unchanged |

## 3. How the page and the app talk: two custom callbacks

There's no new placement and nothing new to present, so nothing to wait for between screens. Both callbacks are "blocking": the page waits for the app's answer. Neither side has a timeout. I checked the installed iOS SDK and the web runtime.

**`add_flight`**
- **Page sends:** nothing.
- **App does:** opens `AddFlightView` on top of the onboarding, from the onboarding's own view controller. A normal SwiftUI sheet would open behind it. The app also links any flight pass bought on this paywall to the new flight, otherwise a $3.99 pass bought here wouldn't unlock anything. It remembers this flight, so if the user force-quits and onboarding starts again, the callback returns the same flight instead of asking twice.
- **App returns:** `flight_id`, `route`, `origin` / `destination` (IATA), `departure_at` (UTC), `hours_to_departure`. Returns a failure if the user closes the screen without saving.
- **If the user cancels:** they stay on the Notifications page and see an "I'll add it later" link, which continues to Plans. Nobody gets stuck.

**`flight_forecast`**
- **Page sends:** `flight_id`.
- **App does:** checks for the forecast every 1–2 seconds, for up to about 20 seconds.
- **App returns:** `state` (`ready`, `pending`, `too_early` or `out_of_coverage`), plus `grade`, `grade_title` and `confidence` when it's ready. It never returns `bumpy_minutes` or the timeline: when and how long is what they're buying, so the page never receives it.

The "Checking your flight" page is open while `flight_forecast` waits, so the wait looks like an intentional step.

## 4. The "Your flight" paywall

It has no close button. It keeps Restore, Terms and Privacy. It leads with the **$3.99 flight pass for this flight**, and "More options" shows the Pro plans, reusing `superwall/components/pro`. The flight pass gets added to the onboarding's product list (today it only has annual and monthly).

The paywall has four versions, depending on what the forecast check returns:

| Forecast | Who | What the paywall says (draft) | Hard? |
|---|---|---|---|
| `ready` | Flights within 48 h (detailed forecast within 18 h, early grade 18–48 h) | The grade is free, e.g. "YYZ → EWR, tomorrow 8:15 am: a few bumps". The offer: **see exactly when the bumps happen and how long they last**, and **get an update if the weather changes before you leave**. The timeline and updates are behind the paywall | Yes |
| `pending` | The forecast took longer than ~20 s | "Your forecast is on its way. We'll send it the moment it's ready." | Yes |
| `too_early` | Flights 48–72 h away (and anyone whose flight is later than they said) | "We can't forecast this with enough confidence yet, but we're already tracking it. Your forecast unlocks Tuesday at 9:40 am, and we'll keep you updated until you board." | Yes |
| `out_of_coverage` | Flights outside the US and southern Canada (worldwide forecasts are off) | No paywall here. Continue to the normal, closable Plans page | **No** |

The unlock time is the departure time minus 48 hours, worked out on the page from `departure_at`.

**Flights we can't forecast.** I strongly recommend never hard-locking someone into buying a flight we can't forecast. It invites refunds and 1-star reviews. If worldwide forecasts get switched on (`SMOOTH_GLOBAL=1`), most of these flights move into the other rows.

## 5. Getting a forecast within seconds (worker)

**Today.** The worker on Fly runs one loop: every flight, then notifications, schedules, pilot reports and map layers, then a 5-minute wait. A new flight waits for the next round, so 0 to over 6 minutes.

**Change.**
- A small, separate loop in the same worker looks for flights with no forecast every ~5 s and forecasts them straight away.
- The 5-minute round stays as it is.
- The weather data is already cached on the worker's disk, so a single forecast should take seconds.

**Target:** about 5–15 s from saving a flight to having a forecast. I'll time it on the worker before building anything else, so this becomes a measured number.

The worker change can be deployed on its own, before the app ships. It also speeds up the first forecast for every existing user.

## 6. Cost

- **Fly.io: +$0.75/month.** The worker's volume grew from 3 GB to 8 GB for the decoded weather (two runs, ~1.5 GB each).
- **Fly.io machine: no change.** The worker is already one machine running all the time (shared-cpu-1x, 2 GB), and you pay for that whether it's busy or idle. The new loop is one small database query every 5 seconds, which is mostly idle time. There are no new weather downloads, because the forecast uses data the worker already caches.
- **The one thing to watch is memory.** If a fast forecast happens while the 5-minute round is loading weather data, memory use rises. I'll check the machine's memory after deploying. If it gets close to 2 GB, the fix is to make the two take turns (no cost). Moving to 4 GB would roughly double the machine cost and is unlikely to be needed.
- **Supabase: no meaningful change.** About 500k tiny queries a month, which return almost nothing. Supabase doesn't bill per request.
- **Flight search:** no change. Adding a flight in onboarding is the same search as adding one later.

## 7. App changes (one release)

1. **Callbacks.** Handle `add_flight` and `flight_forecast` on the onboarding's presentation handler (`Onboarding.swift`).
2. **Add-flight screen.** Present `AddFlightView` on top of the onboarding in an "onboarding mode" and pass in `FlightStore`, `PushNotifications` and `Router`.
3. **Flight passes.** Link a pass bought on this paywall to the onboarding flight (`Paywalls.swift`).
4. **Force-quit.** Remember the onboarding flight so a relaunch doesn't ask again.
5. **Backup onboarding.** The native fallback (`NativeOnboardingView`), used when Superwall can't load, asks the same question. Soon flyers go to add-flight afterwards. There's no paywall there, because the native fallback can't sell.

After this release, every screen, the copy, the cut-offs, the offer and any tests change from Superwall without another release.

## 8. Superwall changes

1. Add the new question page and the branch at the end.
2. Add the "Checking your flight" and "Your flight" pages, with the four versions.
3. Add the flight pass to the onboarding's products.
4. **Fully hard from launch.** No closable version and no A/B test. Watch conversion, refunds and reviews after launch. If they go wrong, a closable version can be added from Superwall without an app release.
5. Publish with `SUPERWALL_CHANNEL=next superwall publish`, after the app release is live. Older app versions can't answer the callbacks, so they need to keep the current onboarding. The campaign can target the new app version with an audience filter.

## 9. Order of work

1. Time a forecast on the worker. *(measure first)*
2. Worker: the fast path for new flights. Deploy it and check memory.
3. App: callbacks, the add-flight screen, pass linking, force-quit handling, the native fallback.
4. Superwall: the question, the checking page, the four paywall versions, the products.
5. Test in the simulator with Superwall's test store. Test purchases are simulated, so real-purchase behaviour needs a check before release. Cover:
   - each answer;
   - each forecast state;
   - closing add-flight without saving;
   - force-quitting on the paywall;
   - buying a pass, then confirming the flight unlocks.
6. Release the app, then point the Onboarding campaign at the new version.

## 10. Decided / open

- ✅ **Decided:** hard paywall exception, for soon flyers only.
- ✅ **Decided:** native add-flight screen, opened through custom callbacks.
- ✅ **Decided:** for 48–72 h flights, "can't predict with enough confidence yet, but we're tracking it".
- ✅ **Decided:** the "ready" version shows the grade. What they pay for: exactly when and for how long, plus updates if the weather changes before they leave.
- ✅ **Decided:** flights outside coverage go to the normal, closable Plans page.
- ✅ **Decided:** fully hard from launch, with no A/B test.
- ✅ **Decided:** make it fast. The GTG disk cache is live; first forecasts take 3–5 s.
