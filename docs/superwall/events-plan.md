# In-app events to send to Superwall (plan, Nov 1 2026)

Superwall is the app's only analytics. Today it only sees the 15 placements the app registers. Those are paywall moments, and most of them fire only for free users or only online, so they can't count what people do. Apart from `review_requested`, nothing else a user does is logged. This plan lists the events worth adding, from an audit of every screen and service in `ios/BumpCast`.

**Built for 1.0.4 (Nov 1), all tiers, uncommitted on `main`.** Every event also goes to Mixpanel (Lanre, Nov 1), with Superwall's own paywall and purchase events and the user attributes as the profile; see SUPERWALL.md, "Events". Where the build differs from the plan below:
- `flight_deleted` has no `where` param: it's logged once, in `FlightStore.delete`, with `flown` and `cancelled`. The email source isn't known there.
- Flights added automatically from email have no `flight_saved`. `email_scan_finished` counts them (`added`).
- `forecast_confirmed_seen` sends `grade` only, not `changed_grade`.
- `breathing_finished` sends `done` (left with Done) where the plan says `completed`.
- `landing_rated` sends `where` as `app` or `live_activity`. The in-app cards share one control, so they aren't told apart.
- `explainer_opened` `where` is `learn`, `related`, `forecast`, `calm` or `live_activity`. The Flights Learn card only switches tabs, so it shows up as `tab_viewed`.
- The `countdowns_used` user attribute isn't there. `countdown_started` counts countdowns instead.
- `global_outlook_set` defaults its `where` to `other`, so the Duo test files that call it still compile.

## How they're sent

- **One helper, `Analytics.log(_ event: Event, _ params: [String: Any])`** in `Services/Analytics.swift`. It calls `Superwall.shared.register(placement:params:)` with no handler, only when Superwall is configured. Unlike `show()`/`take()` it doesn't skip offline or for Pro: the SDK queues events. `ReviewPrompt.ask` moves onto it.
- **Events are separate from placements.** The paywall placements stay exactly as they are, since campaigns depend on them. A log event is a placement only because Superwall has no other way to send one, so **no log event ever gets a campaign.** SUPERWALL.md gets an "Events (log only)" table next to the placements table.
- **Names:** snake_case, object then past-tense verb (`flight_saved`). Params are snake_case with a fixed set of values. No free text, emails or account ids. Flight numbers and airports are fine.
- **Automatic context isn't repeated:** Superwall already attaches app version, device, locale and the user's attributes to every event.
- **Each event has one call site where it can't double-fire.** Where a placement already fires (e.g. `flight_added`), the event fires next to it, for everyone, online or not.

## Tier 1: the core loop (does the app work for people?)

| Event | Fires when | Params | Call site |
|---|---|---|---|
| `flight_add_started` | Add flight sheet opens | `source`: list, empty_state, cancelled_card, onboarding_native, email_needs_you, email_ready | `AddFlightView.swift:139` |
| `flight_searched` | A flight-number search returns | `result`: found, not_found, not_published, unavailable, offline; `matches`; `connection` | `AddFlightView.swift:832` |
| `flight_saved` | A new flight is saved | `method`: search, route, manual_time, schedule_pending, onboarding, email_auto; `covered`; `in_air`; `saved_offline`; `leg` (1, 2…); `hours_to_departure` | `AddFlightView.swift:408`, `OnboardingFlight.swift:56`, `EmailImport.swift:425` |
| `flight_save_failed` | Save shows "That didn't go through" | `method` | `AddFlightView.swift:446` |
| `flight_edited` | An edit is saved | `forecast_reset` | `FlightStore.swift:751` |
| `flight_deleted` | A flight is removed | `where`: list, detail, cancelled_card, email; `flown`; `cancelled`; `from_email` | `FlightsListView.swift:822`, `FlightDetailView.swift:113`, `FlightStatusViews.swift:662`, `EmailImport.swift:565` |
| `flight_opened` | A flight's screen opens | `source`: list, card, notification, live_activity, deeplink, onboarding, toast; `forecast_state`; `grade`; `confidence`; `full_access`; `hours_to_departure`; `in_air` | `FlightDetailView.swift:68` (source passed in by `Router.openFlight` and the list) |
| `forecast_confirmed_seen` | Someone first sees a forecast that firmed up from early to confirmed | `grade`; `changed_grade` | `ForecastView.swift:52` |
| `notification_opened` | Any notification tapped | `kind`: ready, update, confirmed, stretch, boarding, landing; `full_access` | `PushNotifications.swift:71` |
| `notification_prompt_answered` | The system notification prompt is answered | `where`: add_flight, flight_card, settings, onboarding_native, surface; `granted` | `PushNotifications.swift:26` |
| `countdown_started` | The countdown or Live Activity is set up | `how`: tapped, auto_24h; `starts`: now, scheduled; `live_activities_allowed` | `InFlight.swift:170`, `:203`, `:727` |
| `took_off` / `landed` | "We've taken off" / "We've landed" | `basis` (tapped, reported) | `InFlight.swift:284`, `:298` |
| `seatbelt_tapped` | The seatbelt sign is tapped in flight | `minute` | `InFlight.swift:313` |
| `landing_rated` | "How did it feel?" answered | `rating`; `matched`; `beta`; `where`: just_landed_card, detail, rate_sheet, live_activity; `saved_offline`; `forecast_grade` | `FlightStore.swift:943`, `BumpCastApp.swift:21` |
| `review_requested` | The app asks Apple for a rating | `moment` | `ReviewPrompt.swift` (built) |

These answer: how many installs add a flight, where adding fails, whether people come back to the forecast before flying, which notifications bring them back, whether they use the app in the air, and whether the forecast matched.

## Tier 2: what people use

| Event | Fires when | Params | Call site |
|---|---|---|---|
| `tab_viewed` | Tab switch | `tab`: flights, map, learn, calm | `BumpCastApp.swift:112` |
| `breathing_started` | A breathing session starts | `where`: calm, forecast, notification, live_activity | `CalmView.swift:233` |
| `breathing_finished` | It ends | `seconds`; `completed` (Done vs left) | `CalmView.swift:273`, `:240` |
| `explainer_opened` | A Learn or "why it's bumpy" explainer opens | `id`; `where`: learn, forecast, calm, flights_card, live_activity | `LearnView.swift:82`, `ForecastView.swift:994`, `CalmView.swift:134`, `Router.swift:86` |
| `map_opened` | The Map tab opens with content | `has_route` | `TurbulenceMapView.swift:91` |
| `pilot_reports_toggled` | Pilot reports on/off | `on`; `pro` (the free teaser counts as off) | `TurbulenceMapView.swift:453` |
| `pilot_report_tapped` | A report on the map is tapped | `severity` | `TurbulenceMapView.swift:116` |
| `global_outlook_set` | The beta outlook is turned on/off | `on`; `where`: settings, flight_invite, add_flight, onboarding | `GlobalBeta.swift:26` (the one place every change goes) |
| `waitlist_joined` | Joined a coverage waitlist | `country` | `FlightStore.swift:985` |
| `haptics_set` | Haptics toggled | `on`; `where`: settings, calm | `SettingsView.swift:80`, `CalmView.swift:267` |
| `restore_finished` | Restore purchases finishes | `result`: restored, nothing, offline, unavailable | `SettingsView.swift:33` |
| `manage_subscription_opened` | "Manage or cancel" tapped | — | `SettingsView.swift:23` |
| `onboarding_fell_back` | The Superwall flow didn't show, so native ran | `reason`: timeout, skipped, error, offline, no_key | `Onboarding.swift:224` |
| `onboarding_finished` | Either flow finishes | `flow`: superwall, native; `added_flight` | `Onboarding.swift:229` |
| `onboarding_flight_result` | The flow's add-flight step ends | `state`: saved, pending, cancelled, unavailable; `forecast`: ready, pending, too_early, out_of_coverage | `OnboardingFlight.swift:56`, `:148` |

## Tier 3: when it goes wrong

Throttled to once per session per kind, so a bad connection doesn't flood.

| Event | Fires when | Params | Call site |
|---|---|---|---|
| `sync_failed` | The flights sync fails (offline banner) | `offline` | `FlightStore.swift:452` |
| `map_load_failed` | Map tiles or reports fail | `what`: levels, reports | `TurbulenceMapView.swift:573`, `:624` |
| `lock_unavailable` | A Pro lock can't open a paywall | `reason`: offline, connecting, not_loaded, unavailable, failed; `placement` | `Paywalls.swift:296` |
| `flight_link_missing` | A link or notification opens a deleted flight | `from` | `FlightDetailView.swift:43` |
| `pass_late_recorded` / `pass_rejected` | A flight pass arrives outside a paywall (Ask to Buy, app closed), or the server rejects one | `product_id` | `Paywalls.swift:627`, `FlightStore.swift:930` |
| `push_registration_failed` | APNs registration fails | — | `BumpCastApp.swift:39` |

## Email import (when `EmailImport.isReady` is on in Release)

`email_connect_finished` (`result`: connected, cancelled, failed), `email_scan_finished` (`result`, `added`, `ready`, `needs_you`, `first_scan`), `email_flight_dismissed` (`reason`), `email_disconnected`. Call sites are in `EmailImport.swift:250–368` and `EmailImportViews.swift`. Leave them out until Google's review is done, since Release builds can't reach them yet.

## User attributes (state, not events)

Keep these current after each sync (alongside the ones in SUPERWALL.md), so every event and audience can be split by them: `flights_upcoming`, `flights_flown`, `landing_reports`, `global_outlook_on`, `haptics_on`, `countdowns_used`.

## Not worth logging

Every scroll, chip and ladder tap on the map, pull to refresh, expanding status details, the Upcoming/Flown switch and Licenses. They're low signal and high volume. Add any of them later if a question needs it.

## Known gaps in the placements today (left as they are)

- `flight_added` doesn't fire for flights added from email ("Needs you" → Add), from the onboarding flow, or offline. `flight_saved` covers all of them.
- `forecast_ready_opened` / `update_opened` only fire for users without access, and `first_grade_viewed` once, for free users. `notification_opened` and `flight_opened` cover everyone.
- Locks (`*_locked`) only fire for free users. Pro usage of those features shows up as `countdown_started`, `pilot_reports_toggled` and so on.

## Shipping

The events need an app update. Tier 1 is about 15 call sites plus the helper and fits in 1.0.4. Tiers 2 and 3 can ship with it or in 1.0.5. Before release: a unit test that every `Event` name is unique and none matches a campaign placement, and a debug run checking each Tier 1 event lands in `sw.events_rep` with its params.
