# Add a flight from your booking (1.2 plan)

Why: people have a booking, not a flight number. Lanre asked whether they could add a flight by booking reference. **This is a plan only: no code has been written and nothing has been signed up for.** Pick an option at the end.

Builds on 1.1 (branch `claude/vibrant-taussig-985964`, not yet on `main`): the Find step in `AddFlightView` and the `flight-search` edge function. Design rules from `docs/design/DESIGN_SPEC.md` and `docs/design/flight-status-1.1-copy.md` still apply. Never name a data source. That includes "from your airline's email" or "read by …". Use no error colours, and show airport-local times.

## Why a booking reference can't be looked up

A booking reference (PNR, like `K7QX2M`) lives in the airline's or travel agency's booking system. Without the passenger's surname, nothing will look it up, and even with it the only route is an airline's own "manage booking" site. Those have no public API, and scraping them breaks their terms. Our flight data provider indexes flights by number, date and airport, never by booking. Some paid aggregators (TripIt, Sabre and Amadeus trip APIs) can read bookings, but only for bookings made through them or through partner agencies. That's not worth the cost or the data-sharing for us.

So every option below is an **indirect import**. It reads something the traveller already has and pulls out a **flight number and departure date**, plus airports when it can. It then hands those to the 1.1 search exactly as if they'd been typed.

## The shared seam (same for every option)

```
source (photo, pass, email, calendar)
  -> on-device or server parser
  -> [BookingCandidate { number: "B6 23", day: "2026-10-22", origin: "JFK"?, destination: "LAX"? }]
  -> flight-search { number, date } for each candidate (unchanged function)
  -> FindStep result UI (Found it / pick a leg / not found), pre-filled
  -> existing Check your flight -> save
```

- **`BookingCandidate`** is a new small model in `Models/FlightSearch.swift`. `number` goes through `FlightNumber.normalize`, so "B6023", "B6 0023" and "JBU23" all work. `day` is the **local departure date**, which is what `flight-search` already expects (`dateLocalRole: Departure`). Airports are optional hints. They're mapped with `AirportStore.airport(_:)`, which already indexes IATA codes.
- **FindStep changes:** it accepts an optional `prefill: BookingCandidate` and runs `find()` straight away. It also uses the airport hints the way it already uses `connection.from`. If the number flies several legs that day, it keeps only the leg that matches the hint. That removes most "pick the leg you're on" screens.
- **Several flights in one booking** (connections, return trips): show a list, "We found 3 flights in this booking", with every leg ticked. Then add each one through the existing search, check and save path. Connections already chain in 1.1 (`startConnection`). The list just drives that loop. If a leg returns `not_found` or `not_published`, it's listed with the existing 1.1 copy and can be saved as a pending number (`enterManually`). It never blocks the others.
- **The server stays the validator.** Parsers can be loose. A candidate only reaches the user if `flight-search` finds a real flight for it. This caps how wrong an import can be. Cap each import at **6 candidates**, so the search limit of 60 an hour (`SEARCHES_PER_HOUR`) is never at risk.
- **No server change** for the on-device options. `flight-search` gets the same `{ number, date }` it gets today.

## The options

### A. Photo or screenshot, read on device (boarding pass barcode + text)

The user taps **Add from a screenshot** and picks an image: a screenshot of the confirmation email, the airline app's trip page, or the Wallet boarding pass.

- **Picker:** `PhotosPicker` runs out of process, so it needs **no photo-library permission prompt**. We only ever see the one image the user picks.
- **Barcode first:** `VNDetectBarcodesRequest` with `.pdf417`, `.aztec` and `.qr` symbologies. A boarding-pass screenshot from Wallet or an airline app contains the IATA **BCBP** barcode (Resolution 792). We parse it on device:
  - Each leg has an operating carrier (3 chars), flight number (5 chars, zero-padded), from and to airports (IATA), and **date of flight as a day of the year** (`295`). The barcode has no year. Pick the year that puts the date closest to today, within −30 to +330 days.
  - Multi-leg passes list every leg, so connections come through in one go.
  - The barcode also holds the **passenger name and booking reference**. We read only the carrier, number, airports and date fields, and drop the rest in memory.
  - This is exact and needs no guessing, but it only exists **after check-in** (usually 24 h out). By then the forecast has mostly done its job. It's still useful for "I'm at the airport, add my flight".
- **Text fallback:** `VNRecognizeTextRequest` (accurate mode, on device). It runs only when no BCBP barcode is found. Then:
  - Find flight-number tokens with the same pattern as `FlightNumber.normalize`. Require a 2-char carrier with a letter, followed by 1–4 digits, and drop the obvious false hits ("Gate B6", "Seat 23A", "Terminal 4", confirmation codes). Give a higher score to tokens next to words like "Flight" or "Vol", or next to a time.
  - Find dates with `NSDataDetector` and airports with a 3-letter IATA lookup in `AirportStore`.
  - Pair each number with the nearest date (and airports) that comes *before* it in reading order. Confirmation layouts almost always put the date above or beside the flight.
  - Drop dates in the past. Booking and issue dates are usually in the past too, so this removes them.
- **Feeds** the shared seam. If nothing usable is found, the user sees "We couldn't find a flight in that picture", then **Type the flight number** or **Choose airports**.
- **Later, same parser:** a share extension ("Share to BumpCast" from Photos, Mail, Files or the airline app), live camera scanning of a paper pass with `DataScannerViewController` (needs a camera permission), and paste-from-clipboard with `PasteButton` (no prompt). Each one is only a new way into the same `BookingImporter`.

**Privacy:** the image never leaves the phone and isn't stored. The only things sent are the flight number and date, which typed search already sends. **No App Privacy label change.** Apple doesn't count data processed only on device as collected. Add one line to the privacy doc and `site/privacy.html`: "If you add a flight from a picture, the picture is read on your iPhone and isn't uploaded or kept."

**Effort:** about **4–5 days**.
- 1 day for the BCBP parser and tests (fixtures from real passes with names and references blanked).
- 1.5 days for the text heuristics and tests on 15–20 real confirmation screenshots (JetBlue, Delta, United, American, Southwest, Air Canada, WestJet, Alaska, Expedia, Google Flights).
- 1.5 days for the UI and the multi-flight list.
- Half a day for VoiceOver, Dynamic Type and the "nothing found" paths.

**Risks:** OCR accuracy varies across airline layouts. The server check stops wrong flights from being saved, but a miss still means falling back to typing. Wallet boarding passes can't be read straight from Wallet (see B), so the user has to take a screenshot first. Teach that in one line.

### B. Apple Wallet boarding pass, imported directly

**Not possible as a direct import.** `PKPassLibrary` only gives an app the passes signed with its own pass type IDs, and airline passes are signed by the airlines. Two indirect routes exist:

- **Share the `.pkpass` file:**
  - Register BumpCast as a handler for `com.apple.pkpass` (document type plus an import UTI), or accept the file in a share extension.
  - A `.pkpass` is a zip with `pass.json`. `pass.json` holds the `barcodes` message (the BCBP string) and usually `relevantDate`, so we parse it with the same BCBP parser as A.
  - In practice, the Share option in Wallet's pass menu depends on how the airline set up the pass, and many airline apps don't hand the file out at all. Hit rate is uncertain. Test on 5 airlines before promising it.
- **Screenshot the pass:** this is option A, and it works for every pass.

**Privacy:** same as A if the file is parsed on device and not kept. **Effort:** half a day to 1 day on top of A, since the parser is shared. **Verdict:** fold it into A as a later extra. Don't ship it as its own feature.

### C. Pick from a calendar event

Many people have flight events in their calendar: from Gmail (Google Calendar adds them), from Siri Suggestions "Found in Mail", or from TripIt. The user taps **Choose from your calendar** and sees upcoming events whose title, location or notes contain a flight-number token. They tap one, and it goes through the same parser as A's text step. Airports and dates come from the event's start date and time zone.

- **Permission:** since iOS 17, *reading* events requires **full calendar access** (`requestFullAccessToEvents`, `NSCalendarsFullAccessUsageDescription`). There is no out-of-process event picker. That's a heavy prompt for a calm app: "BumpCast would like full access to your calendar". App Review checks that the reason is specific.
- **Coverage:** good for Gmail users and people who use Siri Suggestions. Close to useless for everyone else. Event titles vary ("Flight to Los Angeles (B6 23)", "B6 23 JFK-LAX", "✈︎ LAX").
- **Bonus:** with access granted, the app could *notice* new flight events and offer them, which is the closest thing to auto-import without email.

**Privacy:** events are read on device. Only the flight number and date are sent. **No App Privacy label change**, but the permission itself costs trust. **Effort:** about **2–3 days**, reusing A's text parser (picker, permission flow, matching, tests).

**Verdict:** worth doing after A, and only if people ask for it. Don't make it the first booking feature.

### D. Forward confirmation emails to an inbound address

The user forwards their airline confirmation to a personal address, like `k7qx2m@trips.bumpcast.app`. The flight shows up in the app, with a push: "B6 23 on Thu 22 Oct is ready to add".

- **Needs a domain.** BumpCast has none yet (`site/` is parked, and legal pages are Google Docs). We'd need a domain plus MX records.
- **Inbound pipeline.** An inbound-mail service (Postmark Inbound, SendGrid Inbound Parse, Amazon SES or Cloudflare Email Routing) posts each message to a new edge function, `booking-inbound`.
- **Who sent it.** Users are anonymous Supabase IDs with no email, so each user gets a **random per-user address token**, stored in a new `inbound_addresses` table. We don't match on sender address, because sender matching would require collecting and checking the user's email.
- **Parsing.**
  - First, **schema.org `FlightReservation`** JSON-LD or microdata. Most large US airlines and online travel agencies embed it for Gmail, and it's exact (`flightNumber`, `airline.iataCode`, `departureAirport.iataCode`, `departureTime`).
  - Otherwise, a text heuristic like A's.
  - Last resort, a small LLM extraction (Claude Haiku) that returns only `{ number, date, origin, destination }`. That adds a model processor to the privacy story.
- **Feeds** the shared seam on the server. The function calls the same search, then writes **pending import rows** (`booking_imports`: user_id, number, day, airports, status). The app shows those as a "Ready to add" list that uses the 1.1 check screen.
- **Abuse and safety:**
  - Accept mail only for active tokens, and rate-limit per token.
  - Drop attachments without opening them, and require SPF/DKIM to pass.
  - Never follow links in the mail.
  - Let the user reset their address from Settings.

**Privacy (biggest cost):**
- A confirmation email holds the passenger's **name, booking reference, sometimes address, loyalty number and partial card details**. The inbound service receives all of it, and so does our function.
- Rule: parse in memory and **store only the candidate fields**. Never store the raw message, set the inbound service's retention to the minimum, and log no bodies.
- App Privacy: Flights are already declared as Other User Content. Because the inbound service holds raw mail for a while, declare it conservatively: **Contact Info → Name** and **Email Address** (the forwarding sender), both Linked to You and used for App Functionality.
- That changes the label of an app whose pitch is calm and trustworthy, and it needs a privacy-doc section on forwarded email.

**Effort:** about **8–12 days**, plus ongoing upkeep.
- 1 day for the domain, DNS and inbound service.
- 2 days for the edge function, tables, tokens, row-level security and rate limits.
- 2–3 days for parsers and a fixture corpus.
- 2 days for the "Ready to add" UI and Settings address screen with copy and reset.
- 1 day for the privacy doc, label and App Review notes.
- Ongoing upkeep as airline templates change. There's also a monthly cost for the inbound service, small at our volume.

**Verdict:** this is the best experience in the long run. It works from the day you book, needs no app open, and catches multi-leg trips. It's also the most work and the only option that changes the privacy label. It's a strong **1.3** candidate once 1.2 shows how many users add flights from a booking.

### E. Connect your inbox and auto-import future flights (Lanre's pick, Oct 18)

The user taps **Connect Gmail** or **Connect Outlook** once. BumpCast then finds upcoming flights in their mail and adds them by itself, including new bookings later on. Nothing is forwarded.

**Providers**
- **Gmail:** Google sign-in with `gmail.readonly`. That's a Google **restricted scope**, and there's no narrower scope that can read message bodies (`gmail.metadata` is restricted too and can't see the flight details). Before more than 100 test users can connect, Google requires:
  - **App verification.** The home page and privacy policy must sit on a **domain we own and verify**, so the Google Docs links won't do. That means BumpCast needs its domain anyway, and `site/` can go live there. Verification also needs a demo video of the consent flow and a justification for the scope.
  - **A yearly CASA security assessment** by a Google-approved lab, *for apps that store or transmit restricted data on servers*. Google's exceptions don't name on-device apps explicitly, so E1 asks Google to confirm it's out of scope (see `EMAIL_IMPORT_SETUP.md`). Cost and turnaround vary by lab and tier. Expect weeks, not days, for the first round.
- **Outlook / Hotmail / Microsoft 365:** Microsoft Graph with `Mail.Read` (delegated). Personal accounts can consent themselves. Work accounts may need their admin, and Microsoft wants **publisher verification** (a Partner Network ID tied to the same verified domain). No paid assessment.
- **iCloud Mail, Yahoo and others:** no read API, only IMAP with app-specific passwords. Asking for and storing those isn't acceptable for a calm, trustworthy app. Not offered. Those users keep the screenshot import (A).

**Where the scanning runs: the key decision**

| | E1. On the phone | E2. On our server |
|---|---|---|
| How it works | The app holds the token in the Keychain. It scans when opened and in `BGAppRefreshTask` | Refresh tokens are encrypted in Supabase. The worker scans on Gmail push (`users.watch` → Pub/Sub) and Graph change notifications, or polls every few hours |
| "Auto" in practice | New flights appear the next time the app opens or iOS grants a background refresh (hours, not guaranteed) | Within minutes of the email arriving, with a push: "B6 23 on Thu 22 Oct added" |
| Mail leaving the phone | Never. Only the flight number and date, as today | Matching messages pass through our worker. Store only the flight fields, never bodies |
| Google CASA assessment | Likely not needed (no server storage; Google to confirm) | Needed, every year |
| App Privacy label | No change beyond Flights | Add **User Content → Emails or Text Messages** (Linked, App Functionality). Possibly also Name and Email Address |
| Effort | ~8–10 days | ~14–18 days, plus CASA prep, plus upkeep |

**Recommendation: E1 first.** It gets most of the "it just shows up" feeling without mail ever reaching us. That keeps the privacy promise simple ("Your email is read on your iPhone") and avoids the yearly assessment. Move to E2 only if people want the instant push badly enough to pay for it.

**Finding flights in the mail (both versions)**
1. **Search narrowly.** Ask for only likely messages, never the whole mailbox.
   - Gmail: `newer_than:330d (subject:(confirmation OR itinerary OR "e-ticket" OR "boarding pass" OR "trip") OR from:(…airline and agency senders…))`.
   - Graph: a matching `$search`.
   - Keep a list of about 60 airline and online-agency sender domains in a remote config file, so it can grow without a release.
2. **Read schema.org `FlightReservation` first.** Most big airlines and agencies embed it for Gmail. It's exact: flight number, carrier IATA code, airports and local departure time, often for every leg. Fall back to A's text parser on the plain-text part.
3. **Validate with `flight-search`,** as in the shared seam. Only real flights get through. Each scan sends at most 6 new candidates, and candidates already seen are cached (by message ID), so the search limit holds.
4. **Watch for changes:** a newer email for the same booking reference replaces the old legs. "Cancelled" or "refund" wording, or `reservationStatus: Cancelled`, removes an auto-added flight and tells the user. The booking reference is used only *in memory* to group messages; at most a salted hash is kept to link later emails.
5. **Only the traveller's own trips.** Skip messages where the passenger name in the schema doesn't match the name on the account owner's earlier bookings, and keep a "Not my flight" action. Mail often carries a partner's or colleague's itinerary.

**Auto-add, safely**
- Flights found by scanning are **added straight away, not left waiting for approval**. That's what "auto import" means. Each card shows a small eyebrow, `Added from your email`, plus **Undo** for 24 h and **Not my flight** at any time.
  - Note: this names the user's *own inbox*, not a data source, so it fits the design rule. Still check the exact wording against DESIGN_SPEC before building.
- Past flights and flights more than 330 days out are skipped. A future flight past the airline's published schedule is saved as a pending number (1.1 behaviour).
- Free limits apply as today. If the free plan caps tracked flights, imports beyond the cap land in a "Ready to add" list that leads to the existing paywall placement. They are never silently dropped.

**Settings → Email**
- Shows the connected account, when it was last checked and how many flights it found.
- **Disconnect** revokes the token with Google or Microsoft and deletes the token. Flights that were already added stay.
- One switch: **Add flights automatically** (on). Off means found flights go to "Ready to add" instead.

**Onboarding and Find step**
- Onboarding gets an optional card: "Add trips from your email automatically", with **Connect Gmail**, **Connect Outlook** and **Not now**.
- The Find step gets a row: **Find flights in your email**.
- The consent screen before Google's own: "BumpCast looks only for flight bookings. Your email is read on your iPhone and never stored." (E1 wording.)

**Build outline (E1)**
1. Register the domain, publish `site/` there with the privacy page, and verify it with Google Search Console. Apply for Google app verification (restricted scope) and Microsoft publisher verification. **Start this first: Google's review is the long pole.**
2. Sign-in: `ASWebAuthenticationSession` with PKCE for both providers, so there's no Google SDK. Tokens go in the Keychain. Requested scopes: `gmail.readonly` or `Mail.Read offline_access`.
3. `Services/MailScanner.swift`: the provider clients (search and fetch message), the schema.org extractor and the text fallback (A's parser), deduped by message ID.
4. `Services/AutoImport.swift`: validate with `flight-search`, then add, update or cancel through `FlightStore` with the existing save path. Record `import_source = 'email'` on the flight. That's a small migration, so Undo and the eyebrow survive reinstall.
5. `BGAppRefreshTask` registration, plus a scan on foreground at most every 30 minutes.
6. UI: onboarding card, Find row, Settings → Email, card eyebrow with Undo and Not my flight, "Ready to add" list.
7. Tests: a corpus of about 30 real confirmation emails with names, references and addresses blanked (schema and non-schema, multi-leg, changes, cancellations).
8. Privacy doc and `site/privacy.html` section on connected email. App Review notes with a demo account. Google's verification video.

**Effort (E1):** about 8–10 days of build. Google verification and domain setup run alongside and may take several weeks. Ship Outlook first if Google is slow.

## Side by side

| | A. Photo or screenshot | B. Wallet pass file | C. Calendar | D. Email forwarding |
|---|---|---|---|---|
| Works when | Any time there's a confirmation or pass to screenshot | After check-in, only if the airline lets the pass be shared | If the trip is already in the calendar | From the moment of booking |
| Accuracy | Exact from the barcode. Good from text, with the server check | Exact (barcode) | Fair (free-form titles) | Exact with schema.org, good otherwise |
| New permission prompt | None | None | Full calendar access | None |
| Data leaving the phone | Number and date only (as today) | Number and date only | Number and date only | Whole email, to the inbound service and our function |
| App Privacy label change | No | No | No | Yes (Name, Email Address) |
| New infrastructure | None | Document type or share extension | None | Domain, inbound mail, function, 2 tables |
| Effort | 4–5 days | +0.5–1 day on A | 2–3 days (after A) | 8–12 days, plus upkeep |
| 1.2 fit | **Yes** | Later, on A's parser | Later, on demand | 1.3 |

## Decision (Oct 18)

Lanre wants **E: connect the inbox, scan for future flights and auto-import them.** Plan: build **E1 (on the phone)**, Gmail and Outlook, with auto-add plus Undo. Start the domain and Google verification now, because that's the long pole. Keep A (screenshot) in mind as the fallback for iCloud and other mail. It reuses the same text parser, so it costs little once E1 exists. The original recommendation is kept below for the record.

## Earlier recommendation for 1.2 (before the decision)

Ship **A: Add from a screenshot**, with the barcode reader and text fallback behind one button. Build it as one `BookingImporter` so B (pass file and share extension), C (calendar) and paste can come later without new parsing. It needs no permission, has no privacy-label change, needs no server work and takes about a week. It also covers the boarding pass case without a separate Wallet feature.

Revisit **D** for 1.3 if analytics show heavy use of the screenshot import. Add a Superwall attribute or event such as `flight_added_via: typed | route | screenshot`, and update the Product Interaction row if it's new. If D goes ahead, register the domain early, because DNS and mail reputation take a while to settle.

## Design sketch for A (copy for review)

The 1.1 Find step gets one more way in, under the flight-number field. Typing stays the first choice.

| Element | Copy |
|---|---|
| Secondary button (photo icon) | Add from a screenshot |
| Helper under it | A confirmation, trip page or boarding pass. It's read on your iPhone. |
| Reading | Reading your screenshot… |
| One flight found | Same as 1.1: **Found it** · card · **Is this your flight?** |
| Several flights | **We found 3 flights in this booking** · Body: Untick any you don't want to add. · Rows: `B6 23 · Thu 22 Oct · JFK → LAX` · Primary: **Add 3 flights** |
| Leg not out yet | Row note: Times fill in when the airline publishes them *(1.1 pending copy)* |
| Nothing found | **We couldn't find a flight in that picture** · Body: Try a screenshot that shows the flight number and date, or type them in. · Primary: **Type the flight number** · Secondary: **Choose airports** |
| Search unavailable | 1.1 copy: **Flight search isn't available right now** … |
| First-use tip (once) | Tip: screenshot your boarding pass or confirmation, then add it here. |

- No mention of email, airline systems or any source. The helper says *where* reading happens ("on your iPhone"), which is a trust line, not a source.
- The candidate list uses the 1.1 route-row style: IATA in Plex Mono and local times, with no status colours.
- VoiceOver: the reading state announces "Reading screenshot". Each candidate row reads "Flight B6 23, Thursday 22 October, New York JFK to Los Angeles".

## Build outline for A (when chosen)

1. `Services/BookingImporter.swift`: `func candidates(from image: CGImage) async -> [BookingCandidate]`. It tries the barcode, then text, and dedupes by number and day.
2. `Models/BCBP.swift`: a pure parser for the mandatory BCBP fields and multi-leg passes, with year inference. Unit tests with blanked real passes in `BumpCastTests`.
3. `Models/BookingText.swift`: the token, date and airport pairing heuristics. Unit tests on OCR text dumps (stored as text, never as images of real bookings).
4. `AddFlightView`:
   - `PhotosPicker` on FindStep.
   - FindStep `prefill` and airport-hint filtering.
   - A new `ImportedFlightsList` step for several candidates, which loops the existing search, check and save path.
5. Copy in `Models/Copy.swift`, a line in the privacy doc and `site/privacy.html`, and a `flight_added_via` attribute.
6. No migration and no edge-function change.

## Your choice

Pick one for 1.2:

1. **A only** (recommended): Add from a screenshot, on device.
2. **A + B**: also open shared `.pkpass` files and add a share extension (about 1–2 more days).
3. **A + C**: also offer calendar picking behind the full-access prompt (about 2–3 more days).
4. **D**: email forwarding instead, accepting the domain, infrastructure and privacy-label change.
