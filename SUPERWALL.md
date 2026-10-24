# BumpCast × Superwall

Superwall is the only purchase provider. It runs all purchases, the onboarding flow, and every paywall. The app registers placements and keeps user attributes current; the dashboard decides what each placement shows.

- **Project:** BumpCast (43267)
- **iOS app:** 58179, bundle `ca.akinyemi.bumpcast`
- **Public key:** in `ios/Config/Secrets.xcconfig` as `SUPERWALL_API_KEY`

## Products and entitlement

| Product ID | Type | Price | Grants |
|---|---|---|---|
| `bumpcast_flight_pass` | Consumable | $3.99 | Unlocks Pro for **one flight** (recorded in Supabase `flight_passes`) |
| `bumpcast_pro_monthly` | Auto-renewing | $6.99 / month | `pro` |
| `bumpcast_pro_annual` | Auto-renewing | $39.99 / year, 7-day free trial | `pro` |

For local testing, `ios/BumpCast/Products.storekit` mirrors these and is attached to the Run scheme. The products still need creating in App Store Connect with the same IDs.

**Flight passes:** when a `bumpcast_flight_pass` purchase completes on a paywall opened from a flight, the app records the transaction against that flight. Every flight placement passes `flight_id`, so a paywall can sell the pass in context.

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

**Gated placements never unlock Pro by themselves.** The app only opens Pro content when the user has the `pro` entitlement or a flight pass for that flight.

### Pro, and what a lock does (`Paywalls.unlock`)

The app's Pro is Superwall's subscription status (`Superwall.shared.subscriptionStatus.isActive`), never stricter. Superwall merges App Store, web, promo-code and test-store entitlements, and every campaign audience checks the same thing, so a lock always ends in the content or a paywall. Pro is re-read when the status or `customerInfo` changes, after a restore, on every lock tap, and when the app comes forward (`verifyEntitlements`). StoreKit's cache on the phone is never used to take Pro away: it can lag a renewal (in the air), and web, promo and test-store Pro have no App Store transaction. The app never calls `refreshConfiguration()`.

Every tap ends in one of these:

- **Already Pro or has the flight's pass:** the feature opens with no Superwall call.
- **Offline**, or on wifi that isn't reaching the internet (`Connectivity.isOnline`): a short note ("You're offline. Connect to wifi to unlock this."), or the call site's inline note when it passes `whenOffline`. No paywall, since the purchase couldn't go through.
- **Config still loading:** "Connecting to the App Store…" while the register waits. Repeat taps don't queue more requests (`isOpening`, reset after 30 s).
- **Paywall shown:** purchased or restored opens the feature (polled for up to 3 s while the status lands).
- **Skipped because Superwall already counts the user as Pro:** Pro refreshes and the feature opens.
- **Skipped for a holdout or a placement with no campaign:** "BumpCast Pro isn't available right now."
- **Error:** config gave up (104) says to reopen the app once connected; a paywall already on screen (102) is ignored; anything else says "Couldn't open BumpCast Pro."

Soft placements (`first_grade_viewed`, `forecast_ready_opened`, `update_opened`) aren't registered offline; `first_grade_viewed` waits for the next grade seen online.

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

Onboarding answers (fear level, how often they fly, and so on) are set as attributes from inside the Superwall onboarding flow itself, so they don't need app code. `next_flight_window` is `24h`, `3d`, `week` or `later`.

### Onboarding callbacks (flying in the next 3 days)

People who answer `24h` or `3d` add their flight inside the flow and end on a hard paywall for it (no close button; the flight pass leads). The flow asks the app through two custom callbacks, handled in `ios/BumpCast/Services/OnboardingFlight.swift`:

| Callback | App does | Returns |
|---|---|---|
| `add_flight` | Opens Add flight over the flow | `flight_id`, `route`, `origin`, `destination`, `departure_at`, `origin_utc_offset_minutes`, `hours_to_departure`, `forecast_unlocks_at`, `flight_number`; or failure with `reason` `cancelled` / `unavailable` |
| `flight_forecast` (`flight_id`) | Waits up to 20 s for the first forecast | `state` (`ready`, `pending`, `too_early`, `out_of_coverage`), plus `grade`, `grade_title`, `confidence` when ready. Never when or how long. |

Flights outside coverage, flights saved offline, and app versions without the callbacks go to the closable Plans page instead. **App builds before this change have no handlers**, so point the Onboarding campaign at the new app version before publishing the flow.

## Left to do in the dashboard

1. ~~Design the onboarding flow~~ Done: `superwall/paywalls/onboarding`, live at 100% on the Onboarding campaign. Edit it there and run `SUPERWALL_CHANNEL=next superwall publish`. While it loads, the app shows `LaunchLoadingView`; if it can't load in 8 s (or the campaign skips), `NativeOnboardingView` asks the same questions natively, without the paywall. Debug builds can force the native flow with `-nativeOnboarding`.
2. ~~Design the paywalls~~ Done, as code sharing `superwall/components/pro` (one look: the onboarding Plans page, as a modal sheet). The headline follows `params.event_name`; the flight pass is only offered when the placement passes `flight_id`.
   - **Forecast moments** → `forecast-moment` (paywall 281983) at 100%. Shows the user's route, hours to departure and `grade_title` on the sky. Leads with the flight pass (they need it for this flight); "More options" opens This flight / Yearly / Monthly as one choice. Without a flight, Pro leads.
   - **Pro features** → two audiences, top to bottom:
     1. **Has a flight** (193400, `params.flight_id != null`): A/B test at 50/50, `pro-features` (281984, subscription is the button, pass is a link) vs `pro-features-pass-first` (281985, pass is the button, Pro trial is a link).
     2. **No flight** (195604, everyone else): `pro-features` at 100%. A pass needs a flight, so the test only runs where one can be sold. Today `pilot_reports_locked`, `flight_limit_reached` and `upgrade_from_settings` send no flight.
   - Edit them under `superwall/paywalls/`, then `SUPERWALL_CHANNEL=next superwall publish`.
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

**Onboarding: hard vs soft flight paywall** (Onboarding campaign 113534, 50/50, started 2026-10-23). The two paywalls are the same flow:
- `onboarding` (281980) is **hard**: the flight paywall and the pass offer have no close button.
- `onboarding-soft` (284375) is **soft**: both have one.

`onboarding-soft` re-exports every page of `onboarding` and only sets `variant.soft` in its layout, so edit `onboarding` and publish both. Its name must stay "Onboarding": the app waits for that paywall name before it presents the flow.

Only people flying in the next 3 days who add their flight (app 1.0.1+) reach the flight paywall; everyone else sees the closable Plans page in both. Each flow sets `onboarding_paywall_variant` (`hard` / `soft`) when it opens. Superwall's experiment view on the campaign shows onboarding conversion per variant; `docs/superwall/onboarding-hard-vs-soft.sql` also counts flight passes bought later in the app, split by that attribute.

## Before launch: verify purchases on the server

Two things are currently trusted from the app, which is fine for TestFlight but not for launch:

- **Flight passes:** `flight_passes` rows are inserted by the app. Someone calling the Supabase API directly could unlock a flight without paying.
- **Pro status:** `profiles.is_pro` is reported by the app, and the worker uses it to decide who gets update pushes.

**Fix:** point Superwall's webhooks at a Supabase Edge Function that writes `is_pro` and flight passes with the service role. Then remove the client insert policy on `flight_passes`, and the client's ability to set `is_pro`. This needs the Superwall webhook signing secret.
