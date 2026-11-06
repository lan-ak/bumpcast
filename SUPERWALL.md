# BumpCast × Superwall

Superwall is the only purchase provider. It runs all purchases, the onboarding flow, and every paywall. The app registers placements and keeps user attributes current; the dashboard decides what each placement shows.

- **Project:** BumpCast (43267)
- **iOS app:** 58179, bundle `ca.akinyemi.bumpcast`
- **Public key:** in `ios/Config/Secrets.xcconfig` as `SUPERWALL_API_KEY`

## Products and entitlement

| Product ID | Type | Price | Grants |
|---|---|---|---|
| `bumpcast_flight_pass` | Consumable | $3.99 | Unlocks Pro for **one flight** (recorded in Supabase `flight_passes`) |
| `bumpcast_flight_pass_999` | Consumable | $9.99 | Same as the $3.99 pass. Created 2026-11-01. Only app builds that include `Products.flightPasses` record it, so keep it off paywalls until that build is live |
| `bumpcast_pro_monthly` | Auto-renewing | $6.99 / month | `pro` |
| `bumpcast_pro_annual` | Auto-renewing | $39.99 / year, 7-day free trial | `pro` |
| `bumpcast_pro_annual_3999_3d` | Auto-renewing | $39.99 / year, 3-day free trial | `pro` |
| `bumpcast_pro_annual_4999_3d` | Auto-renewing | $49.99 / year, **no trial** (its 3-day trial was removed in all 175 territories on 2026-11-03; backup in `docs/release/backups/2026-11-03-annual-4999-3d-intro-offers.json`). The Yearly plan everywhere in onboarding (Plans and the flight paywall) since 2026-11-03 | `pro` |
| `bumpcast_pro_annual_5999_3d` | Auto-renewing | $59.99 / year, 3-day free trial | `pro` |

The three 3-day-trial plans were created on 2026-10-25 in the BumpCast Pro group. The app needs no change for another Pro plan: Superwall grants `pro`, and the app's expiry check reads any auto-renewing transaction.

For local testing, `ios/BumpCast/Products.storekit` mirrors the first three and is attached to the Run scheme.

**Flight passes:** when a purchase of any product in `Products.flightPasses` completes on a paywall opened from a flight, the app records the transaction against that flight. Every flight placement passes `flight_id`, so a paywall can sell the pass in context. The flight is taken when the paywall is presented (a register Superwall refuses because a paywall is already up leaves the one on screen in charge) and dropped when it closes. When a pass purchase starts, its flight is saved on the phone (`pass.pending`) until the purchase ends, so a pass approved later (Ask to Buy) or completed while the app was closed, which reaches the app only as a StoreKit `Transaction.updates` entry with no Superwall `transactionComplete`, is still recorded (1.0.4+). **Checked with Apple (from 1.0.4, once `verify-pass` is deployed):** the app sends each pass to the `verify-pass` function, which looks the transaction up with Apple and saves it; only verified passes unlock a flight off the phone that bought it, and in the worker's notifications. Test-store passes (UUID ids) count only while the function's `ALLOW_TEST_STORE_PASSES` is `1`. See `docs/release/1.0.4.md`, "Server: verified flight passes".

## Placements

| Placement | Campaign | When it fires | Gated? |
|---|---|---|---|
| `onboarding` | Onboarding | First launch, once. The flow and its Pro paywall are code in `superwall/paywalls/onboarding` (paywall 281980). | No |
| `first_grade_viewed` | Forecast moments | First time a free user sees a forecast grade (soft paywall) | No |
| `forecast_ready_opened` | Forecast moments | Free user opens the app from the "Your forecast is ready" push (**the main paywall moment**) | No |
| `update_opened` | Forecast moments | Free user opens the app from an update or "confirmed by NOAA" push | No |
| `timeline_locked` | Forecast moments | Taps "See when the bumps are" (shows the forecast-moment paywall, pass first) | Yes |
| `updates_locked` | Pro features | Taps a locked "what changed" update | Yes |
| `live_activity_locked` | Pro features | Taps "We've taken off" (Live Activity and in-flight reminders) | Yes |
| `pilot_reports_locked` | Pro features | Turns on pilot reports on the map | Yes |
| `flight_limit_reached` | Pro features | Adds a 3rd upcoming flight (free limit is 2) | Yes |
| `upgrade_from_settings` | Pro features | "Get BumpCast Pro" in Settings | Yes |
| `email_import_locked` | Pro features | Taps "Add from your email" or Connect Gmail (Settings), or resumes it after Pro lapsed. A subscription feature: a flight pass never unlocks it, and no flight is sent, so the "No flight" audience shows `pro-features` with the email headline and benefit (1.1+) | Yes |
| `flight_added` | none yet | A flight added in Add flight, once the sheet has closed (1.0.2+). See [Moments](#moments-notifications-and-ratings). | No |
| `turn_on_notifications` | none yet | "Turn on notifications" on a flight's screen, while notifications haven't been answered (1.0.2+) | No |

**Gated placements never unlock Pro by themselves.** The app only opens Pro content when the user has the `pro` entitlement or a flight pass for that flight.

### Pro, and what a lock does (`Paywalls.unlock`)

The app's Pro is Superwall's subscription status (`Superwall.shared.subscriptionStatus.isActive`), never stricter. Superwall merges App Store, web, promo-code and test-store entitlements, and every campaign audience checks the same thing, so a lock always ends in the content or a paywall. Pro is re-read when the status or `customerInfo` changes, after a restore, on every lock tap, and when the app comes forward (`verifyEntitlements`). StoreKit's cache on the phone is never used to take Pro away: it can lag a renewal (in the air), and web, promo and test-store Pro have no App Store transaction. The one exception: when StoreKit plainly shows the latest Pro subscription ended (refunded, or expired and not renewing) while Superwall still says Pro, `verifyEntitlements` calls `refreshConfiguration()` so Superwall re-reads purchases, at most once every 6 hours per transaction and only online with the config loaded; Pro then follows what Superwall says.

Every tap ends in one of these:

- **Already Pro or has the flight's pass:** the feature opens with no Superwall call.
- **Offline**, or on wifi that isn't reaching the internet (`Connectivity.isOnline`): a short note ("You're offline. Connect to wifi to unlock this."), or the call site's inline note when it passes `whenOffline`. No paywall, since the purchase couldn't go through.
- **Config still loading:** "Connecting to the App Store…" while the register waits. Repeat taps don't queue more requests (`isOpening`, reset after 30 s).
- **Paywall shown:** purchased or restored opens the feature (polled for up to 3 s while the status lands).
- **Skipped because Superwall already counts the user as Pro:** Pro refreshes and the feature opens.
- **Skipped for a holdout or a placement with no campaign:** "BumpCast Pro isn't available right now."
- **Error:** config gave up (104) says to reopen the app once connected; a paywall already on screen (102) is ignored; anything else says "Couldn't open BumpCast Pro."

Soft placements (`first_grade_viewed`, `forecast_ready_opened`, `update_opened`) aren't registered offline; `first_grade_viewed` waits for the next grade seen online. It also waits for the next launch when the onboarding paywall was on screen this session, so finishing onboarding (which opens the flight) doesn't lead straight into a second paywall (1.0.4+).

**Restore purchases** (Settings): SuperwallKit has no public restore without its own alert, which it shows whenever the restore leaves no active entitlement. The app configures that alert's words (`restoreFailed`: "Nothing to restore"; this also applies to restore buttons on paywalls) and says "Purchases restored." only when Pro is active afterwards, so there's never a second, contradictory alert (1.0.4+).

### How Superwall behaves for this app (found on the 10-22 flight)

- **Every audience carries `size(device.activeEntitlements) == 0`.** Superwall adds it automatically, and the v2 campaign API shows these audiences as `expression: null`, so it isn't visible there (only in the static config's `expression_cel`). Anyone Superwall counts as Pro gets `no_rule_match` on every placement. If the app's Pro ever disagrees with Superwall's, a lock gets neither content nor paywall; that's why Pro follows Superwall.
- **Test-store users are matched by user ID** (`test_mode_user_ids` in the config). A new anonymous user ID is no longer a test-store user, so its paywalls try real sandbox purchases. Test-store users' config is never cached (`keepingForNextLaunch` is false for them), so every launch needs the network, and the test-mode entitlement modal blocks every paywall until it's closed.
- **`enable_config_refresh_v2` is off for app 58179,** so config is never cached for anyone: each launch fetches it, retrying for about 1.5 minutes offline, and then gives up for the whole session. A launch without network leaves paywalls unavailable until the next launch (locks say so). On slow plane wifi the fetch took about 2 minutes, and lock taps queue until it lands. `configurationStatus` stays `.pending` through the retries and never becomes `.failed` when they run out, so the app can't detect this up front; first-launch onboarding goes native after the logo when there's no network path.

### Placement params (on flight placements)

| Param | Example |
|---|---|
| `flight_id` | UUID |
| `route` | `YYZ → EWR` |
| `hours_to_departure` | `26` |
| `grade` / `grade_title` | `some_bumps` / `A few bumps` |
| `confidence` | `early`, `partly_confirmed`, `confirmed` |
| `bumpy_minutes` | `12` |

### Moments: notifications and ratings

From 1.0.2, `flight_added` and `turn_on_notifications` let a Superwall surface decide how the app asks for notifications and App Store ratings, so it can change without a release (`Paywalls.take`):

- **A campaign shows a surface:** it asks for notifications with the **Request Permission** tap behavior (Notification), and for a rating with a **Custom Callback** named `request_review`, which the app answers with Apple's own rating prompt (the system decides whether it shows). When the surface closes, the app re-reads the notification permission and tells the worker and Superwall.
- **No campaign, or no audience match:** the app does what it did before. After `flight_added`: the system notification prompt if Add flight's "Tell me when it's ready" was on and notifications haven't been answered. From 1.0.3 the app's own rating prompt comes on the first forecast someone opens instead (advance or confirmed, free or Pro, once; after any paywall on screen closes). After `turn_on_notifications`: the system prompt.
- **Holdout:** nothing.

Besides the flight's params, both send `notifications` (`enabled`, `denied`, `not_determined`), `notify` (the flight's "Tell me when it's ready") and `forecast_state` (`early`, `partly_confirmed`, `confirmed` or `global_outlook` once there's a forecast; otherwise `too_early`, `building`, `beta_available` or `not_covered`).

Apple only allows its own rating prompt (guideline 5.6.1): a surface can lead up to `request_review`, but mustn't ask for stars itself or send only happy users to it.

The onboarding flow doesn't use these placements: it asks in its own pages, with Request Permission and the same `request_review` callback (see below).

## Events (log only, 1.0.4+)

What people do in the app, from `Analytics.log` (`ios/BumpCast/Services/Analytics.swift`). Each is registered as a placement because Superwall has no other way to take an event, so they land in `sw.events_rep` under their own names. **Never give one a campaign:** a paywall would show in the middle of what the user was doing. A unit test (`AnalyticsTests`) keeps their names apart from the placements above and from Superwall's own events. Unlike the placements, they fire for everyone (Pro or free, online or not), and errors are sent once a launch.

The same events, with the same params, go to **Mixpanel**, plus Superwall's own paywall, purchase, restore and permission events (their `$` params lose the `$`), Mixpanel's automatic first-open and session events, and the user attributes below as the profile (`pro` on every event). Both use the Supabase account id. The token is `MIXPANEL_TOKEN` in `ios/Config/Secrets.xcconfig`; empty sends nothing to Mixpanel.

The full list with params and where each fires: `docs/superwall/events-plan.md`. In short:

- **Adding and keeping flights:** `flight_add_started` (`source`), `flight_searched` (`result`, `matches`), `flight_saved` (`method`, `covered`, `in_air`, `saved_offline`, `leg`), `flight_save_failed`, `flight_edited` (`forecast_reset`), `flight_deleted`, `flight_opened` (`source`, forecast state, grade, `full_access`), `forecast_confirmed_seen`.
- **Notifications:** `notification_opened` (`kind`), `notification_prompt_answered` (`where`, `granted`).
- **In the air:** `countdown_started` (`how`), `took_off`, `landed`, `seatbelt_tapped`, `landing_rated` (`rating`, `matched`, `where`), `review_requested` (`moment`: `first_forecast`, `forecast_matched`, or the surface's placement).
- **What people use:** `tab_viewed`, `breathing_started` / `breathing_finished`, `explainer_opened`, `map_opened`, `pilot_reports_toggled`, `pilot_report_tapped`, `global_outlook_set`, `waitlist_joined`, `haptics_set`, `restore_finished`, `manage_subscription_opened`, `onboarding_fell_back` (`reason`), `onboarding_finished` (`flow`), `onboarding_flight_result`.
- **When it goes wrong:** `sync_failed`, `map_load_failed`, `lock_unavailable`, `flight_link_missing`, `pass_late_recorded`, `pass_rejected`, `push_registration_failed`.
- **Email import** (once it's on in Release): `email_connect_finished`, `email_scan_finished`, `email_flight_dismissed`, `email_disconnected`.

## User attributes

These are kept current after every sync, for audiences and paywall text.

| Attribute | Meaning |
|---|---|
| `flights_saved`, `upcoming_flights`, `flights_flown` | Counts |
| `free_flight_limit` | `2` |
| `next_flight_route`, `next_flight_hours`, `next_flight_grade`, `next_flight_confidence`, `next_flight_covered` | The next upcoming flight |
| `has_flight_pass` | Has bought at least one pass |
| `notifications_enabled` | Push permission granted |
| `in_flight` | Currently in a tapped "We've taken off" flight |
| `landing_reports`, `landing_reports_matched` | After-landing ratings given / where the forecast matched |
| `waitlist_countries` | Comma-separated ISO codes from the coverage waitlist |
| `global_outlook_on`, `haptics_on` | The global outlook (beta) and haptics settings (1.0.4+) |

Onboarding answers (fear level, how often they fly, and so on) are set as attributes from inside the Superwall onboarding flow itself, so they don't need app code. `next_flight_window` is `24h`, `3d`, `week` or `later`.

### Onboarding callbacks (flying in the next 3 days)

Since 2026-11-03 everyone (app 1.0.1+) is asked to add their next flight right after the questions, whenever they fly; the notifications ask comes after it and names the route. With a flight added, the flow checks it and ends on the flight paywall; without one ("I'll add it later"), on Plans. On the flight paywall and Plans, everyone sees Yearly at $49.99 with no trial (`bumpcast_pro_annual_4999_3d`, badged "Save N%" against twelve months of Monthly) and Monthly at $6.99: 3-day trials covered the very flight people came for and were cancelled within minutes. The "Need more time?" 7-day trial offer was removed on 2026-11-03 (nobody converted on it); onboarding has no trial anywhere. The flight pass is never sold in onboarding. The flow asks the app through two custom callbacks, handled in `ios/BumpCast/Services/OnboardingFlight.swift`:

| Callback | App does | Returns |
|---|---|---|
| `add_flight` | Opens Add flight over the flow | `flight_id`, `route`, `origin`, `destination`, `departure_at`, `origin_utc_offset_minutes`, `hours_to_departure`, `forecast_unlocks_at`, `flight_number`; or failure with `reason` `cancelled` / `unavailable` |
| `flight_forecast` (`flight_id`) | Waits up to 20 s for the first forecast | `state` (`ready`, `pending`, `too_early`, `out_of_coverage`), plus `grade`, `grade_title`, `confidence` when ready. Never when or how long. |
| `request_review` (1.0.2+) | Shows Apple's rating prompt | Success. Earlier builds answer failure: carry on as if it showed. |

Flights outside coverage, flights saved offline, and app versions without the callbacks go to the closable Plans page instead. **App builds before this change have no handlers**, so point the Onboarding campaign at the new app version before publishing the flow.

## Left to do in the dashboard

1. ~~Design the onboarding flow~~ Done: `superwall/paywalls/onboarding`, live at 100% on the Onboarding campaign. Edit it there and run `SUPERWALL_CHANNEL=next superwall publish`. While it loads, the app shows `LaunchLoadingView`; if it can't load in 20 s (right after the logo with no network path), or the campaign skips, `NativeOnboardingView` asks the same questions natively, without the paywall. From 1.0.2 (build 9) the app asks the `onboarding` placement which paywall it shows only after Superwall's first preload has finished: asking builds the paywall's screen without loading its page, and build 8 asked first, so the preload reused the unloaded screen and the flow timed out to native. If the placement's paywall isn't loading by then (another campaign preloaded first, say), the app presents it anyway and Superwall shows its loading screen until the page is in. Debug builds can force the native flow with `-nativeOnboarding`.
2. ~~Design the paywalls~~ Done, as code sharing `superwall/components/pro` (one look: the onboarding Plans page, as a modal sheet). The headline follows `params.event_name`; the flight pass is only offered when the placement passes `flight_id`.
   - **Forecast moments** → `forecast-moment` (paywall 281983) at 100%. Shows the user's route, hours to departure and `grade_title` on the sky. Leads with the flight pass (they need it for this flight); "More options" opens This flight / Yearly / Monthly as one choice. Without a flight, Pro leads.
   - **Pro features** → two audiences, top to bottom:
     1. **Has a flight** (193400, `params.flight_id != null`): A/B test at 50/50, `pro-features` (281984, subscription is the button, pass is a link) vs `pro-features-pass-first` (281985, pass is the button, Pro trial is a link).
     2. **No flight** (195604, everyone else): `pro-features` at 100%. A pass needs a flight, so the test only runs where one can be sold. Today `pilot_reports_locked`, `flight_limit_reached`, `upgrade_from_settings` and `email_import_locked` send no flight.
   - Edit them under `superwall/paywalls/`, then `SUPERWALL_CHANNEL=next superwall publish`.
   - **Since 2026-11-03** both campaigns run on duplicated audiences named "[03/11] Claude v1 Review - …" (Forecast moments 199274; Pro features 199275 has a flight, 199276 no flight), with the originals (193399, 193400, 195604) paused for comparison, as in Onboarding (193398 live, 199265 paused). On all three Pro paywalls Yearly is `bumpcast_pro_annual_4999_3d` ($49.99, no trial) with a "Save N%" badge against Monthly; passes unchanged.
   - **Since 2026-11-05** the pass-first test is over (Lanre's call): it never got traffic because only `live_activity_locked` and `updates_locked` send a flight. Has a flight is now 200212 "[05/11] Claude v1 Review - Has a flight: subscription leads only", `pro-features` at 100%; 199275 is paused at its 50/50. Users on those two placements still see the pass as a link under the subscription button. The pass never shows in the dashboard preview, which sends no `flight_id`.
3. **Replace the 100% holdout audiences** that Superwall creates with real audiences, for example:
   - `user.notifications_enabled == true`;
   - `params.hours_to_departure < 48`.
4. **Set up experiments** per the plan:
   - flight pass vs subscription as the lead offer;
   - trial length;
   - paywall timing.
5. **Keep the house rules:**
   - no fake discounts;
   - cancelling is in Settings → "Manage or cancel subscription".
6. **Ask Superwall to turn on `enable_config_refresh_v2`** for app 58179, so a launch without network falls back to the cached config instead of losing paywalls for the session (doesn't help test-store users).
7. **Test store:** after a re-sign-in, add the new anonymous user ID to the test store users (only `5DD2668A…` is listed), and before release, check no real user is listed there.

## Running experiments

**Onboarding: near-flier trial** (Onboarding campaign 113534, live 2026-11-04 ~23:50 UTC). Audience 199841 "[04/11] Claude v1 Review - All Users: near-flier trial" shows `onboarding-near` (paywall 289001) to everyone. 193398 (soft 100%) is paused, as the baseline. It's the soft flow, page for page, except the flight paywall, which is picked from the flight's real departure, not the "When is your next flight?" answer (4 of 7 people flying within 24 h on Nov 4 answered "Further out"):
- **Leaves within 24 h (or departed less than 12 h ago):** a hard page, with no close button and Restore only. One plan: Yearly `bumpcast_pro_annual_3999_3d`, $39.99 with a 3-day free trial, the biggest price on the page (guideline 3.1.2). It's laid out as a timeline: Today / Until you land / the day the trial ends and its price. The page saves the flight in the user attribute `onboarding_hard_flight`, so quitting the app doesn't get past it: the app marks onboarding done only on dismiss, so the flow runs again, and its index skips the questions and goes straight back to the trial, until 12 h after departure. Gaps that need an app update: an offline launch falls back to the native questions, and so does deleting the flight. It also sets `onboarding_near_offer = "trial"`. A relaunch whose forecast check fails still shows the trial (onboarding-near's Plans route). A failed purchase, or one "abandoned" in under 1.5 s (the phone blocking purchases), shows a "check Screen Time" note, but there is still no way past the page (Lanre's call, Nov 4: keep it hard).
- **Any later flight:** a closable timeline page (sets `onboarding_near_offer = "timeline"`) (Now or Today / first forecast / Pro steps) with Yearly $49.99 (no trial) and Monthly.
- **No flight, out of coverage, or the check failed:** Plans, closable, unchanged.

**Forecast moments: one paywall per session** (campaign 113535, 2026-11-04). The top audience 199842 is a 100% holdout when `params.event_name` is forecast_ready_opened or update_opened AND `device.minutesSinceLastPaywallView < 30`. Next is 199843 "[04/11] Claude v1 Review - All Users" (forecast-moment 100%); 199274 is paused. `first_grade_viewed` isn't capped: it fires once ever (the app sets `firstGrade.registered` before asking), so a skip would lose it, and the app already holds it back right after onboarding. The gated `timeline_locked` isn't capped: a lock with no paywall says "BumpCast Pro isn't available right now".

**Onboarding: hard vs soft flight paywall** (Onboarding campaign 113534, 50/50, started 2026-10-23). **Ended 2026-11-03: soft at 100%, hard at 0%.** Too few people reached the flight paywall to read it (12 in a week), and the split was uneven (hard got far more people flying within 3 days). Soft had buyers too: 4 trials in onboarding (all cancelled) plus a Monthly and a pass bought later. The two paywalls are the same flow:
- `onboarding` (281980) is **hard**: the flight paywall has no close button.
- `onboarding-soft` (284375) is **soft**: it has one.

`onboarding-soft` re-exports every page of `onboarding` and only sets `variant.soft` in its layout, so edit `onboarding` and publish both. They're named "Onboarding · hard" and "Onboarding · soft". From 1.0.2 the app asks the `onboarding` placement which paywall it shows, so names and identifiers can be anything (1.0 and 1.0.1 waited for one named "Onboarding", but only on a first launch, and new installs have been on 1.0.2 or later since Oct 25).

Only people flying in the next 3 days who add their flight (app 1.0.1+) reach the flight paywall; everyone else sees the closable Plans page in both. Each flow sets `onboarding_paywall_variant` (`hard` / `soft`) when it opens. Superwall's experiment view on the campaign shows onboarding conversion per variant; `docs/superwall/onboarding-hard-vs-soft.sql` also counts flight passes bought later in the app, split by that attribute.

## Before launch: verify purchases on the server

Two things are currently trusted from the app, which is fine for TestFlight but not for launch:

- **Flight passes:** `flight_passes` rows are inserted by the app. Someone calling the Supabase API directly could unlock a flight without paying.
- **Pro status:** `profiles.is_pro` is reported by the app, and the worker uses it to decide who gets update pushes.

**Fix:** point Superwall's webhooks at a Supabase Edge Function that writes `is_pro` and flight passes with the service role. Then remove the client insert policy on `flight_passes`, and the client's ability to set `is_pro`. This needs the Superwall webhook signing secret.
