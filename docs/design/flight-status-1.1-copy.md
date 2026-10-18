# BumpCast 1.1: flight-number search and live status (copy)

For review before anything is built. Mockups: `docs/design/flight-status-1.1.html`.

**Ground rules (from DESIGN_SPEC.md):**
- **No data sources, ever.** Never name the data provider or any data source, in the UI or in push copy. Don't write "airline data", "from the airport" or "via …" either. Status is simply what we show.
- **No red, no warning symbols.** Status never borrows the severity colours. Amber, orange and plum mean turbulence only. Status uses ink and the accent teal, and the words carry the meaning.
- **Times are always local to the airport** they belong to, with the zone abbreviation the first time it appears on a screen.
- **Honest freshness.** Every status shows when it was last updated. We never imply live tracking: there is no in-air position and no "Landed".

---

## 1. Add a flight: search by flight number (free)

Step 1 of the add-flight sheet gets a new first screen. The airport route stays available, one tap away.

| Element | Copy |
|---|---|
| Title | Find your flight |
| Field label | Flight number |
| Field placeholder | e.g. B6 23 |
| Day picker label | Day |
| Primary button | Find flight |
| Secondary link | Choose airports instead |
| Helper, under the field | Airline code and number, from your booking. |

**Searching**

| Element | Copy |
|---|---|
| Inline status | Looking for B6 23 on Thu 22 Oct… |
| VoiceOver | Searching for flight B6 23 |

**One match** (the form is filled and the user confirms)

| Element | Copy |
|---|---|
| Eyebrow | Found it |
| Card | B6 23 · JFK → LAX · Departs 7:15 AM EDT · Arrives 10:41 AM PDT |
| Question | Is this your flight? |
| Primary | Yes, use this flight → goes to **Check your flight** |
| Secondary | Not this one |

**Several legs on that number and day**

| Element | Copy |
|---|---|
| Title | B6 23 flies 2 legs that day |
| Body | Pick the one you're on. |
| Row | BOS → JFK · 5:30 AM → 6:45 AM |
| Row | JFK → LAX · 7:15 AM → 10:41 AM |

**No match** (fall back to airports, with no error colour)

| Element | Copy |
|---|---|
| Title | We couldn't find B6 23 on Thu 22 Oct |
| Body | Check the number and the day, or add it by choosing your airports. |
| Primary | Choose airports |
| Secondary | Try again |

**Offline or lookup error**

| Element | Copy |
|---|---|
| Title | Flight search isn't available right now |
| Body | You can still add your flight by choosing your airports. We'll forecast it the same way. |
| Primary | Choose airports |
| Secondary | Try again |

**Check your flight** (after a match): the route card gains a mono eyebrow, `B6 23 · JetBlue`, and a line "Arrives 10:41 AM PDT". The rest of the step is unchanged.

---

## 1a. Number search: schedule not out yet

We set no search horizon. Search goes as far ahead as airlines have published schedules, usually 9–11 months. A number on a date past that is not a dead end.

**On the number search**

| Element | Copy |
|---|---|
| Title | UA 456's schedule for Thu 9 Sep 2027 isn't out yet |
| Body | Airlines publish their schedules in stages, and this one hasn't been released. Add your airports and departure time from your booking. We'll fill in the rest when it's published. |
| Primary | Enter airports and time → the usual Route → When → Check steps |
| Secondary | Change number or day |
| Pinned context on the manual steps | UA 456 · Thu 9 Sep 2027, with "Times fill in when the airline publishes them" below |

The flight saves with its number. Until the schedule is published, the flight uses the entered times.

**While waiting** (the line appears on the flight card and in the detail header)
- We'll fill in the details when the airline publishes this flight.

**When the schedule is published** (a one-time in-app note on the card and the detail view, cleared once seen)

| Case | Note |
|---|---|
| Times differ | Schedule published. UA 456 leaves at 8:05 AM, not 8:00 AM. Your forecast will use 8:05 AM. |
| Arrival added, departure matches | Schedule published. It matches what you entered. Arrives 11:31 AM PDT. |
| An airport differs | Schedule published. UA 456 flies from EWR, not JFK. Your forecast will use EWR. |

The forecast always uses the airline's times once they're published.

**Push** (free, because it's part of search; quiet hours apply)
- Send only if departure differs by **15 min or more** (the same threshold as delays) or an airport differs.
- A matching schedule, or a difference under 15 min, stays in the app.

| Case | Title | Body |
|---|---|---|
| Time differs ≥ 15 min | UA 456 times confirmed | Your flight on Sep 9 leaves at 9:40 AM, not 8:00 AM. We'll forecast for the new time. |
| Airport differs | UA 456 details confirmed | Your flight on Sep 9 leaves from EWR, not JFK. We'll forecast for the right route. |

This replaces the route-list "aren't out yet" state only when a flight number was entered. Route searches keep the §1b version.

---

## 1b. Add by airports: flights on this route (free)

This is the When step behind "Choose airports instead":
- Once From, To and the day are set, it lists that day's nonstop flights.
- Only the operating carrier is shown; codeshares are hidden. Rows are sorted by departure.
- Tapping a row goes to **Check your flight**, the same as a number match, so the flight gets live status on Pro.
- On busy routes, rows are grouped into Morning (before 12 PM), Afternoon (12–5 PM) and Evening (after 5 PM). Jump chips show each group's count.

| Element | Copy |
|---|---|
| Eyebrow | JFK → LAX · Thu 22 Oct |
| Title | Which flight are you on? |
| Count and time-zone line | 23 nonstop flights. Times are local: JFK EDT, LAX PDT. |
| Jump chips | Morning 9 · Afternoon 8 · Evening 6 |
| Group headers | Morning · Afternoon · Evening |
| Row | B6 23 · JetBlue, then on the next line 7:00 AM → 10:32 AM |
| Row, VoiceOver | JetBlue 23, departs 7:00 AM, arrives 10:32 AM |
| Fallback link (every state) | Enter the time myself → today's time wheel |

**Loading**
- Finding nonstop flights on Thu 22 Oct…
- The day tiles stay usable while it loads.

**No flights found**
- Title: No nonstop flights found that day
- Body: If you're connecting, add your first flight, then tap **Add a connecting flight** on the last step. Or enter your departure time and we'll forecast it the same way.
- Buttons: **Enter the time myself** · Pick another day

**No schedule for this airport**
- Title: We can't list flights from Eagle County yet
- Body: Enter your departure time and we'll forecast it the same way.
- Button: **Enter the time myself**

**Beyond published schedules** (route searches only; usually more than 9–11 months ahead)
- Title: Flight lists for Thu 3 Dec aren't out yet
- Body: They appear closer to the day. For now, enter your departure time, or look up your flight number.
- Buttons: **Enter the time myself** · Look up flight number

**Offline or error**
- Title: Can't load flights right now
- Body: Enter your departure time instead. We'll forecast it the same way.
- Buttons: **Enter the time myself** · Try again

**Large text:** the times move under the flight name and the chevron is dropped; the whole row stays tappable. Don't say where the list comes from. No "departures board", no "from the airport".

---

## 1c. Add a connecting flight (free)

**Where:** on **Check your flight**, next to the primary save. It's the same whether the flight came from a number search, the route list or manual entry.

| Element | Copy |
|---|---|
| Primary button | Add flight |
| Secondary button | Add a connecting flight |

**What it does:**
- Saves the current flight, then reopens the add sheet for the next leg.
- The search starts from the arrival airport.
- The day defaults to the arrival date, which matters for overnight arrivals.
- Flight lists start after the arrival time.
- Each flight still saves and forecasts on its own. There's no trip grouping, linked cards or connection-risk alerts; those are planned for 1.2.

**Reopened sheet:**

| Element | Copy |
|---|---|
| Context line (top, accent icon) | Connecting from DEN · arrives 9:12 AM |
| Context line, overnight | Connecting from JFK · arrives Fri 6:40 AM |
| Title (number search) | Find your next flight |
| Number placeholder | e.g. UA 573 |
| Overnight day note | Friday, because your overnight flight lands then. |
| Top-left button | Done (the first flight is already saved, so not "Cancel") |
| Route list note | Showing flights after your 9:12 AM arrival. |
| Earlier flights link | Show 6 earlier flights |
| Airports route | From is pre-filled with the arrival airport, and can be changed |

**Back on Flights:**
- Toast: 2 flights added. Forecasts for each arrive Tue.
- If the forecasts arrive on different days: 2 flights added. First forecasts arrive Tue and Wed.
- One soft haptic for the whole trip, not one per flight.

---

## 2. Flight card (Flights list and Next flight)

- Show the flight number before the route: `B6 23 · JFK → LAX`. Flights added by airport have no number and show just the route.
- **Pro, or a flight pass for this flight:** a compact status row under the date.

| State | Status row |
|---|---|
| On time | On time · Gate B22 · Terminal 5 |
| On time, no gate yet | On time · Gate not set yet |
| Delayed | Delayed 40 min · now 7:55 AM |
| Delayed, with gate | Delayed 40 min · now 7:55 AM · Gate B22 |
| Departed | Departed 7:58 AM |
| Cancelled | Cancelled |
| Diverted | Diverted to DEN |
| Not yet tracked (more than 48 h out) | Live status starts Tue |

- **Free:** a locked row that opens the `live_status_locked` placement:
  - Row: **Live status** · Delays and gate changes, with a small "Pro" tag.
  - Never show a blurred or fake status behind it.

---

## 3. Flight detail: Status section

| Element | Copy |
|---|---|
| Section title | Flight status |
| Big status | On time / Delayed 40 min / Departed / Cancelled / Diverted |
| Table headers | Scheduled · Expected · Actual |
| Row labels | Departs (JFK) · Arrives (LAX) |
| Gate | Gate B22 · Terminal 5 |
| No gate | Gate not set yet |
| Freshness | Updated 3:12 PM · next update around 4:10 PM |
| Freshness, stopped | Updated 8:45 AM · status updates have finished for this flight |
| Forecast shifted | Forecast updated for the new 7:55 AM departure. The bumps moved with it. |
| Forecast shifted, no change | Forecast checked for the new 7:55 AM departure. Still mostly smooth. |

"Expected" replaces "Estimated" because it's warmer and just as clear. An empty cell shows an en dash.

**Cancelled**
- Title: This flight is cancelled
- Body: Your airline will be in touch about other options. When you have a new flight, add it and we'll forecast it.
- Buttons: **Add a new flight** · Remove this flight
- The forecast section is hidden and replaced by this card.

**Diverted**
- Title: Diverted to Denver (DEN)
- Body: Diversions are planned for and routine for the crew. Your airline will share what happens next.
- The forecast stays visible but faded, with the caption "This forecast was for the original route to LAX."

**More than 48 h out (Pro)**
- Live status starts Tue around 7:15 AM, two days before you fly.

---

## 4. Push notifications

Same rules as forecast updates:
- **Quiet hours:** nothing between 22:00 and 07:00 local time, unless the flight leaves within 4 h. Held messages go out at 07:00.
- **Combine:** a delay and the forecast change it causes are one message, never two.
- **Small changes stay in the app.** Departure moves under 15 min don't push.
- **Gate and terminal changes never push.** Gates refresh at most hourly, so a push could arrive late; the gate is always on the card instead.
- No exclamation marks, no "Alert" or "Warning", and no red emoji.

| Event | Title | Body |
|---|---|---|
| Delayed ≥ 15 min, forecast changed | Delayed 40 min, forecast updated | B6 23 now leaves at 7:55 AM. Still mostly smooth, with light chop over the Rockies. |
| Delayed ≥ 15 min, forecast unchanged | Delayed 40 min | B6 23 now leaves at 7:55 AM. We checked: your forecast hasn't changed. |
| Delay shortened ≥ 15 min | Leaving earlier than expected | B6 23 now leaves at 7:30 AM. Forecast updated. |
| Cancelled | B6 23 is cancelled | Your airline will be in touch about other options. Add your new flight for a fresh forecast. |
| Diverted | B6 23 is diverting to Denver | Diversions are routine for the crew. Your airline will share what happens next. |

---

## 5. Live-status paywall moment (`live_status_locked`)

- **Headline:** Know about delays before the airport does the announcing
- **Supporting line:** Delays, gate changes and cancellations, and a fresh turbulence forecast whenever your departure time moves.
- **Shorter alternative for small surfaces:** Live status, with your forecast kept up to date.
- **Flight pass mention:** Just this trip? A flight pass covers live status for one flight.

---

## 6. Decisions (confirmed by Lanre)

1. **Airline name:** shown next to the number: `B6 23 · JetBlue`.
2. **Gate-change pushes:** none. The gate shows on the flight card and in the detail view.
3. **Delay push threshold:** 15 minutes or more, in either direction.
4. **What's free and what's paid:** search stays free for everyone, by number and by route list. Live status and delay pushes are Pro or a flight pass. Schedule-published notes and pushes (§1a) are free, because they're part of search.
5. **Search horizon:** none of our own. Search reaches as far ahead as airlines have published schedules, usually 9–11 months.
