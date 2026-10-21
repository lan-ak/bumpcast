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
| `timeline_locked` | Pro features | Taps "See when the bumps are" | Yes |
| `updates_locked` | Pro features | Taps a locked "what changed" update | Yes |
| `live_activity_locked` | Pro features | Taps "We've taken off" (Live Activity and in-flight reminders) | Yes |
| `pilot_reports_locked` | Pro features | Turns on pilot reports on the map | Yes |
| `flight_limit_reached` | Pro features | Adds a 3rd upcoming flight (free limit is 2) | Yes |
| `upgrade_from_settings` | Pro features | "Get BumpCast Pro" in Settings | Yes |

**Gated placements never unlock Pro by themselves.** The app only opens Pro content when the user has the `pro` entitlement or a flight pass for that flight. A holdout, or a campaign with no paywall, simply shows nothing.

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

Onboarding answers (fear level, how often they fly, and so on) are set as attributes from inside the Superwall onboarding flow itself, so they don't need app code.

## Left to do in the dashboard

1. ~~Design the onboarding flow~~ Done: `superwall/paywalls/onboarding`, live at 100% on the Onboarding campaign. Edit it there and run `SUPERWALL_CHANNEL=next superwall publish`. While it loads, the app shows `LaunchLoadingView`; if it can't load in 8 s (or the campaign skips), `NativeOnboardingView` asks the same questions natively, without the paywall. Debug builds can force the native flow with `-nativeOnboarding`.
2. ~~Design the paywalls~~ Done, as code sharing `superwall/components/pro` (one look: the onboarding Plans page, as a modal sheet). The headline follows `params.event_name`; the flight pass is only offered when the placement passes `flight_id`.
   - **Forecast moments** → `forecast-moment` (paywall 281983) at 100%. Shows the user's route, hours to departure and `grade_title` on the sky. Leads with the flight pass (they need it for this flight); "More options" opens This flight / Yearly / Monthly as one choice. Without a flight, Pro leads.
   - **Pro features** → A/B test at 50/50: `pro-features` (281984, subscription is the button, pass is a link) vs `pro-features-pass-first` (281985, pass is the button, Pro trial is a link). Without a flight both show the subscription only.
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
   - the paywall must be closable (never lock the whole app);
   - cancelling is in Settings → "Manage or cancel subscription".

## Before launch: verify purchases on the server

Two things are currently trusted from the app, which is fine for TestFlight but not for launch:

- **Flight passes:** `flight_passes` rows are inserted by the app. Someone calling the Supabase API directly could unlock a flight without paying.
- **Pro status:** `profiles.is_pro` is reported by the app, and the worker uses it to decide who gets update pushes.

**Fix:** point Superwall's webhooks at a Supabase Edge Function that writes `is_pro` and flight passes with the service role. Then remove the client insert policy on `flight_passes`, and the client's ability to set `is_pro`. This needs the Superwall webhook signing secret.
