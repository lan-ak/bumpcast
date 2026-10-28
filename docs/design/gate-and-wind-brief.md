# Gate changes and airport wind: design brief

**Approved Oct 27.** Boards: `gate-changes.html` and `airport-wind.html`. In each idea, an explorer and a skeptic argued until they agreed, checking the code, the database and public docs as they went. Two of the four ideas need screens:

| Idea | Outcome | Mockups |
|---|---|---|
| Gate changes | Build a reduced version: in the app only, no push | Yes, §1 |
| Takeoff and landing winds | Build a reduced version: mark existing stretches near the ground as gusty | Yes, §2 |
| Aircraft type | Backend only: record the aircraft model now; give turboprops their own climb profile later if the data supports it. Nothing on screen | No |
| Route history beyond 48 h | Dropped. Every real user who saved a flight early is flying outside coverage, so the gap is coverage, not history | No |

Rules for both (from DESIGN_SPEC.md):
- Never name a data source.
- No red and no warning symbols. Severity colours (amber, orange, plum) mean turbulence only; status uses ink and accent teal.
- Times are local to the airport.
- Every status shows how fresh it is.
- Follow the motion and haptics rules.

---

## 1. Gate changes

**Free, like the rest of live status.** It never appears on a paywall. Nothing here pushes.

### What it does

- **An honest changed-gate line.** "Gate B22, was B18", with the old gate struck through. It uses the TimePair style for moved times: new gate in accent teal, old gate struck through in secondary ink.
- **"Was" means this phone showed it.** "Was B18" appears only if this device showed B18 while the app was open. A gate that changed before the user looked is never struck through.
- **Gates stay current while the app is open.** From 3 h before departure until takeoff, the app re-reads status every 5 min while it's open and online. There's no spinner and no banner.
- **Schedule-only flights stop saying "On time".** They say "Scheduled times only". **This is a primary state, not an edge case:** at JFK, 110 of 230 departures had only the published schedule.
- **A gate that disappears isn't announced.** Nothing shows until 90 min out, then "Gate on airport screens".
- **The age shows only when it matters.** "updated 40 min ago" appears only before takeoff, and only when status is still more than 30 min old after the in-app refresh.

### Surfaces

- **Flight card status row** (`LiveStatusRow`): the Next flight card and the Upcoming rows.
- **Route header, departure side** (`FlightRouteHeader`): the gate line under the departure time, with the struck-through previous gate line beneath it in the same full or short form.
- **Route header status label:** "Scheduled times ›" and "updated N min ago".
- **Expanded status details** (`FlightStatusDetails`): the Gate row, plus "Changed from…", "Last shown in the app as…" and the schedule-only line.

**Not touched:** pushes, the Updates feed, Settings, the Live Activity, the Dynamic Island, widgets, the "Boarding soon" reminder, paywalls and onboarding.

### States to mock up

| State | Card | Header | Details |
|---|---|---|---|
| Gate known, unchanged | On time · Gate B22 · Terminal 5 | Gate B22 · Terminal 5 (short: Gate B22 · T5) | B22 · Terminal 5 |
| **Gate changed** (this phone showed B18) | On time · Gate B22, was ~~B18~~ | Gate B22 · Terminal 5, over ~~Gate B18 · Terminal 5~~ | B22 · Terminal 5. Changed from B18. |
| Gate changed, but this phone never showed the old one | Same as unchanged | Same as unchanged | Same as unchanged (the details still open once) |
| Terminal changed | On time · Gate B22 · Terminal 5, was ~~Terminal 4~~ (always the full form on the card, never "T4") | ~~Gate A3 · Terminal 4~~ under the new line | Changed from A3 · Terminal 4. |
| Terminal changed, no gate known | On time · Terminal 5, was ~~Terminal 4~~ | ~~Terminal 4~~ under the new line | Changed from Terminal 4. |
| Delayed and gate changed | Delayed 40 min · now 7:55 AM · Gate B22 (the whole row is already teal) | Struck time only. The old gate isn't stacked under it (version B, chosen Oct 27) | Changed from B18. |
| Gate gone, more than 90 min out | On time (or On time · Terminal 5), no gate words | No gate line | Last shown in the app as B22. |
| Gate gone, 90 min or less out | On time · Gate on airport screens | — | Last shown in the app as B22. Some flights only show their gate on the airport screens. |
| No gate or terminal, 90 min or less out | On time · Gate on airport screens | — | Some flights only show their gate on the airport screens. |
| **Schedule-only** | Scheduled times only (then · Terminal 5 and · Gate on airport screens as they apply) | Label: Scheduled times › (times without a struck-through pair; use this label only when neither side is live) | We only have the published schedule for this flight so far. Delays and the gate may only show on the airport screens. Then the freshness line. |
| Before takeoff, still old after the refresh | Unchanged | On time ›, with "updated 40 min ago" underneath | Freshness line unchanged |
| More than 48 h out, departed, cancelled, diverted, or added by airports | Unchanged from today | Unchanged | Unchanged |

**Ordering:** a known gate always comes before its terminal. With no gate, today's "Terminal 5 · Gate …" order stays.

**VoiceOver:**
- Card: "On time, gate B22, changed from B18".
- Schedule-only: "Scheduled times only, no live updates for this flight so far".

**Decided (Oct 27):**
- **Delayed and gate changed: version B.** The old gate shows in the details only; the header keeps only the struck time.
- **"Last shown in the app as B22."**
- **"Scheduled times only" and "Scheduled times ›"** as written. The wording doesn't promise that updates will come.

---

## 2. Airport wind

**What it does.** When the airport's own forecast expects gusts of 25 kt or more within an hour of takeoff or landing, a light climb or descent stretch that the forecast already shows, and that peaks near the ground, is marked as gusty: a pale teal band on the timeline and a short label on the stretch row. (Changed Oct 27 from a sentence on the row to this visual indicator: option A of the visual exploration, with option B's short label.)

**What doesn't change:**
- calm days;
- free users;
- the grade and the stretch count;
- every push.

**How common it is.** About 1 in 5 flights between windy hubs, and 1 in 4 to 1 in 3 from November to March. **Design it as a normal state, not an alert.**

### Tiers

- **Pro or a flight pass:** the timeline band, the stretch-row label, the link to the new explainer, and the cause sentence in the in-flight reminder.
- **Free:** the "Gusty at the airport" explainer in Learn, like the other cause pages.
- **Never:** wind as paywall bait, a blurred wind line, or a teaser.

### Surfaces

1. **Forecast › "Bumps along the way" timeline.**
   - A pale teal band (accent at about 10% opacity) with two soft teal curls over the gusty end, takeoff or landing.
   - The axis label at that end reads "Gusty · {city}" in place of "Takeoff" or "Landing".
   - Teal only, never a severity colour. Nothing changes on calm days.
   - Build note: smooth bars are also a teal (`#3A9A8F`), so check the band can't read as "smooth" over a light-chop bar.
2. **Forecast › What to expect, stretch row.**
   - A short secondary label under the existing "feels like" line, led by a new gust mark: two easy curves over a ground line, in teal, decorative.
   - Don't use the `wind` SF Symbol; "Practice breathing" already uses it.
   - No clock time and no chip.
3. **The "Why it's bumpy here" link on the main stretch.** A light stretch with the cause links to "Gusty at the airport". Every other stretch keeps today's link.
4. **Learn › Why it gets bumpy: a new "Gusty at the airport" page,** in the existing template:
   - diagram;
   - What's happening, What the crew is doing, What you'll feel;
   - a Good to know card;
   - related chips.

   **Diagram:** simple teal lines over muted ground, a small level plane, soft curved wind lines, no jagged lines. **No** "What will light chop feel like?" haptic on this page.
5. **The in-flight 2-minute reminder** (a local notification). The title is unchanged and sets the level; the body carries the cause.

**Not surfaces:** a banner, warning card or badge; a map layer; an airport weather card; a wind push; crosswind; knots; clock times.

### States to mock up

| State | What shows |
|---|---|
| Calm at both ends (most flights) | Nothing new |
| Advance forecast (18–48 h out), or the airport forecast doesn't reach takeoff yet | Nothing new |
| Gusty at departure, light climb stretch near the ground | Band and "Gusty · {city}" at the takeoff end, and the label on the climb row. If it's the main stretch, the link opens "Gusty at the airport" |
| Gusty at arrival, light descent stretch near the ground | Band and "Gusty · {city}" at the landing end, and the label on the descent row |
| Gusty at both ends | A band at each end and two labelled rows. The grade is unchanged |
| Moderate or stronger near the ground, and gusty | The severity and "feels like" lines are unchanged, plus the "May also be gusty" label. The link stays "Near the ground" |
| Gusty, but the stretch peaks above about 4,000 ft, or there's no stretch near the ground | Nothing new |
| Wind eases on an update | The band and label cross-fade out in place (no animation with Reduce Motion). No push |
| In the air or offline | The band and label are part of the saved forecast, and the reminder uses forecast tense. Freshness comes from the existing footer |
| Free user | No band and no label, and no blurred version or teaser. Only the free Learn page |

### Copy

**Timeline axis, gusty end:** Gusty · Toronto

**Descent row (light):**
- 52 min into the flight
- Light chop for about 3 min while descending
- {existing feels-like line}
- {gust mark} Gusty in Newark around your landing

**Climb row (light):**
- Right after takeoff
- Light chop for about 3 min while climbing
- {existing feels-like line}
- {gust mark} Gusty in Toronto around your takeoff

**Moderate row:**
- Moderate for about 4 min while descending
- {existing feels-like line}
- {gust mark} May also be gusty in Denver around your landing

**In-flight reminder, descent:**
- Title: Light chop in about 2 minutes
- Body: Gusty wind was expected in Newark for your landing, so the descent may be bumpy for about 3 min. Routine for the crew. Tap for a slow breathing exercise.

**In-flight reminder, climb:**
- Title: Light chop in about 2 minutes
- Body: Gusty wind was expected in Toronto for your takeoff, so the climb may be bumpy for about 3 min. It eases as you climb higher. Tap for a slow breathing exercise.

**Explainer:**
- **Title:** Gusty at the airport
- **Subtitle:** Windy days near the ground
- **What's happening:** On a windy day, the wind near the ground speeds up and slows down as it flows over buildings and land, a bit like a river over stones. You feel it for a few minutes as you climb out and on the way down.
- **What the crew is doing:** Pilots plan every takeoff and landing around the wind. In gusty air they fly the approach a little faster for extra control, and keep the seatbelt sign on until the air settles.
- **What you'll feel:** Bumps and some side-to-side sway, now and then a firmer one, that ease as you climb or once you touch down.
- **Good to know:** Gusty takeoffs and landings happen every day at busy airports. Some airports don't have a wind forecast, or not until a few hours before. Your forecast still covers the climb and descent either way.

**VoiceOver:**
- Each row reads in order: time, severity, the "feels like" line, then the full sentence in place of the label: "Gusty wind expected in Newark around your landing. Normal on a windy day, and the crew plans for it." (Climb: "Gusty wind expected in Toronto around your takeoff. The bumps ease as you climb.")
- The gust mark is hidden from VoiceOver.
- The timeline band reads "Gusty wind expected in {city} around your takeoff" (or "landing").

**Place names:** always "in {city}", from the airport's city. Never the airport's full name, its code or a clock time.

**Decided (Oct 27):**
- **Threshold: 25 kt** (about 1 in 5 flights at windy hubs).
- **Go-arounds:** not mentioned in the explainer.

---

## Deliverables

- `docs/design/gate-changes.html` and `docs/design/airport-wind.html`: review boards in the same format as `flight-status-1.1.html`. Each section names a screen, states the rule, and shows phones in light and dark.
- The copy goes on the boards. If you change any wording, list the changes in a short "Copy changes" note at the top of the board.
- Don't edit app code, and don't commit.
