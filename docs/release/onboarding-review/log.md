# BumpCast onboarding + Pro paywalls: daily review log (read-only; changes need Lanre's OK)

## Day Wed Nov 4

First run. Data to 2026-11-04 16:51 UTC. Since change = from 2026-11-03 21:00 UTC (Pro paywalls from about 21:40, once devices picked up the new config). Excluded: 55 `$SuperwallAlias:` ids, 4 Apple review devices (iPhone99,*), and Lanre's phone. Not excluded: 22 real iPhones that report Darwin 25.6.0, because that is iOS 26.6, not the simulator. No simulator device models showed up.

**Health: OK.**
- Campaigns: 113534 has 193398 on, soft 100%, no hard variant; 199265 is off. 113535 has 199274 on, forecast-moment 100%; 193399 is off. 113536 has 199275 on (pass-first 50 / sub-leads 50), then 199276 on (pro-features 100); 193400 and 195604 are off.
- Paywall versions: soft v8, hard v24, forecast-moment v14, pro-features v13, pass-first v12.
- Pricing: every paywall_open after 21:40 had annual `bumpcast_pro_annual_4999_3d` with trial false, and pass `bumpcast_flight_pass_999` on the Pro paywalls. The old $39.99 trial product showed only on 8 opens before 21:40, on 2 devices that still had the old config cached. No trial since then.
- Onboarding paywall_open: 26 in 24h from 26 installs. No products-load failures, webview failures or timeouts.
- trigger_fire matches paywall_open on every Pro placement.
- 1 transaction_fail: 2EDBCD03 on Yearly $49.99 in soft onboarding at 05:05, "Unable to Complete Purchase". This is StoreKit's generic error. Another Yearly went through 2 hours earlier, so it is not a broken product.
- Watch: `paywallWebviewLoad_processTerminated` went from 1–6 a day (Oct 28–31) to 23–25 a day (Nov 1–4). These are mostly preloaded webviews that iOS kills in the background. No paywall failed to open, but the rate is going up.

**Onboarding funnel**

| | 24h | Since change | Baseline Oct 27–Nov 3 |
|---|---|---|---|
| Installs / onboarding opened | 26 / 26 | 22 / 23 | ~53/week |
| Reached source (end of questions) | 25 (96%) | 23 (100%) | 92% |
| Median feeling→source | 32 s | 32 s | 33 s |
| find → notifications | 25 → 23 | 23 → 21 | – |
| checking / flight page / plans | 15 / 14 / 10 | 13 / 12 / 9 | – |
| Saved a flight (any) | 20 (77%) | 18 (78%) | ~32% |
| Saved a flight in the onboarding flow | 15 | 13 (57%) | – |
| Notifications granted / not-now / denied | 14 / 8 / 1 | 12 / 8 / 1 | 30% granted |
| Paid in onboarding | 1 Yearly $49.99, 1 Monthly $6.99 | same: 2 of 23 (9%) | 1 Monthly |

- Flight state at the end of onboarding, since change: too_early 6, ready 5, pending 1, out_of_coverage 1.

**Purchases since change**
- 3A575EBF: Yearly $49.99, no trial, onboarding-soft, 2 min after install. 24h flier, calm, monthly-plus, App Store, notifications granted. Came back 10 h later and added 7 more flights.
- CB4B0474: Monthly $6.99, onboarding-soft, 2 min after install. Flying in 3d, very anxious, few-a-year, social, notifications granted. Came back the next day. This was 22:31, so served by the old soft variant 676301 before 689523 was created at 22:38. Same paywall and pricing.
- 59952292 (watched): the 3-day trial renewed to **Yearly $39.99** (proceeds shown as $28.00; $33.99 at 85%). It came in at 21:09 Nov 3. First trial to convert. Stop watching.
- 8EB2E0C0: trial on the old forecast-moment $39.99 at 21:10, 4 min after install, cancelled 3 min later. This was before the Pro change, so the last of the old trials.
- Old products, no user id: 2 `bumpcast_pro_annual` initial purchases at $0 "NORMAL" on Nov 2 (02:56 and 17:20). Probably offer-code redemptions; check against the Sideshift codes.
- Cancellations and refunds since change: none.

**Segments since change** (n=23; too small to call)
- next_flight_window:
  - 24h: 1 of 4 bought, 4 of 4 saved a flight
  - 3d: 1 of 1 bought
  - week: 0 of 5 bought, 4 of 5 saved a flight
  - later: 0 of 13 bought, 9 of 13 saved a flight
- Notifications: both buyers had granted. Granted 12 of 12 saved a flight, vs not-now 6 of 8.
- **Later fliers, the main bet of this change:** 9 of 13 (69%) saved a flight, up from about 32% overall before. 3 of them opened forecast-moment. One (2EDBCD03) tried Yearly and the payment failed. It's too early to see whether they come back on a later day, because the cohort is under 2 days old.

**Pro paywalls since 21:40 Nov 3**

| Paywall / placement | Users | Opens | Declines | Purchases |
|---|---|---|---|---|
| forecast-moment: first_grade_viewed 3, forecast_ready_opened 2, timeline_locked 2 | 5 | 7 | 5 | 0 |
| pro-features (sub-leads): live_activity_locked 1 (Has a flight), pilot_reports_locked 1 (No flight) | 2 | 2 | 2 | 0 |
| pro-features-pass-first | 0 | 0 | – | 0 |

- **Pass-first vs sub-leads:** 1 open vs 0, no purchases. Far too early to call.
- pilot_reports_locked lands in the No-flight audience even for users who have a flight. That placement probably doesn't send `flight_id`, which keeps traffic out of the test.
- Placements that never fired in the last 7 days: update_opened, flight_limit_reached, upgrade_from_settings, live_status_locked, email_import_locked. updates_locked fired once (Nov 1).
- 24h, including before the change: forecast-moment 12 opens / 6 users, 1 old $39.99 trial (8EB2E0C0). pro-features 4 opens / 4 users.

**Recommendations (need Lanre's OK)**
1. **Hold on onboarding pricing and flow.** We need about 50–60 more onboarding users (about a week) before judging. Early signs: 2 paid from 23 users, with no trial; flight saving went from about 32% to 78%; notifications granted went from 30% to 52%.
2. **Send `flight_id` with `pilot_reports_locked`** (and the other Pro placements) when the user has a flight, so those users enter the Has-a-flight pass test. This is an app change in the iOS placement call, and needs an update. Expected effect: roughly double the traffic to the pass-first test.
3. **Look up the 2 `bumpcast_pro_annual` $0 purchases from Nov 2** in App Store Connect or Sideshift, to confirm they are offer codes and not a pricing leak.

Lanre, Nov 4: #2 (flight_id) on hold. #3: the $0 purchases were Trybe creator codes, so no action needed.
Lanre, Nov 4: hard paywall test declined for now. Keep soft 100% (193398) and leave 199265 paused.

## Day Thu Nov 5

Data to 2026-11-05 14:00 UTC. Since change = from 2026-11-03 21:00 UTC. Near-flier test = from 2026-11-04 23:50 UTC (about 14 h). Excluded: 23 `$SuperwallAlias:` ids. No Apple review devices (iPhone99,*), no simulators, and Lanre's phone didn't appear. iOS 26.6 devices kept, as yesterday.

**Health: config OK, one flow problem.**
- Campaigns as expected: 113534 has 199841 on (onboarding-near 289001 100%), 193398 and 199265 off. 113535 has 199842 (30-min skip) then 199843 (forecast-moment 100%) on, 199274 and 193399 off. 113536 has 199275 (pass-first 50 / sub-leads 50) then 199276 (pro-features 100) on, 193400 and 195604 off.
- Paywall versions unchanged: near v2, soft v8, hard v24, forecast-moment v14, pro-features v13, pass-first v12.
- Onboarding opened for 20 of 21 installs in 24h. The one miss is an iPad (2AA5B120, 11:53): `onboarding` returned no_rule_match twice, so the native questions ran instead. The near audience has no filter, so this is unexplained. Only 1 user.
- No webview or products-load failures, no timeouts, and 0 transaction_fail in 24h. `paywallWebviewLoad_processTerminated` was 21 in 24h, flat against 23–25 a day.
- Pricing: every open since 21:40 Nov 3 showed annual `bumpcast_pro_annual_4999_3d` with no trial, and Pro paywalls showed the $9.99 pass. No trial transaction. onboarding-near page views report `is_free_trial_available = true`, because its hard page carries the $39.99 trial product. That is expected. 4 older users had background preloads with cached old products (`bumpcast_pro_annual` / `_3999_3d`). None of those were opened.
- **PROBLEM: near-flier relaunch collided with Forecast moment.** 230F2DA0 is the only user to see the hard trial page. They were flying ROC→BWI at 10:50 and added the flight at 00:39. They saw the trial page and left without tapping. At 11:15, 25 min after departure, a boarding notification brought them back. `first_grade_viewed` opened forecast-moment at the same moment as the onboarding relaunch. Onboarding errored (`onboarding_fell_back` reason=error) and dropped to the native questions. They closed the app 8 s later. So the relaunch-to-trial path has never actually worked.

**Onboarding funnel**

| | 24h | Since change (2 days) | Near test 289001 (14 h) | Soft 193398 (Nov 3 21:00–Nov 4 23:50) |
|---|---|---|---|---|
| Installs / onboarding opened | 21 / 20 | 40 / 40 | 9 / 8 | – / 31 |
| Reached source (end of questions) | 20 (100%) | 40 (100%) | 8 | 31 |
| Median feeling→source | 26 s | 30 s | 26 s | 32 s |
| find → notifications | 20 → 20 | 40 → 38 | 8 → 8 | 31 → 29 |
| checking / flight page / plans | 10 / 10 / 11 | 22 / 21 / 18 | 3 / 3 / 6 | 19 / 18 / 11 |
| Saved a flight (any) | 15 (75%) | 32 (80%) | 6 | 25 (81%) |
| Notif granted / not-now / denied | 12 / 6 / 2 | 23 / 13 / 2 | 7 / 1 / 0 | 15 / 12 / 2 |
| Paid in onboarding | 0 | 2 (Monthly, Yearly; both soft) | 0 | 2 |
| Paid anywhere | 2 (Pro, from Settings) | 4 | 2 | 2 |

- Compared with yesterday, the questions are still near-perfect and notifications granted rose to 58% (23 of 40). Flight saving is steady at about 80%.

**Near-flier test (289001), 8 users**
- Hard trial page seen: 1 (230F2DA0). Trial starts on `bumpcast_pro_annual_3999_3d`: 0. Cancellations, conversions and lapses: none yet. Relaunched and got the trial again: 0, because the one relaunch failed (see Health).
- Timeline soft page: 2 (467E53A4 later, 8954E777 3d). Both declined.
- 5 of 8 skipped adding a flight in the flow. That includes **2 of the 3 people flying within 24h** (095E482E, 96972F16), so the trial never reached them. Both declined Plans, and both bought later that day from **Settings → Upgrade** (pro-features): Yearly $49.99 and Monthly $6.99.
- Against soft (2 paid from 31): the near cohort has 2 paid from 8, but none of those purchases came through the near-flier page itself.

**Purchases since change**
- CB4B0474: Monthly $6.99, onboarding-soft, Nov 3 22:31 (reported yesterday).
- 3A575EBF: Yearly $49.99, onboarding-soft, Nov 4 03:10 (reported yesterday). Not cancelled.
- **095E482E: Yearly $49.99, pro-features via upgrade_from_settings, Nov 5 10:12, 6.5 h after install. They turned off auto-renew 3 s later** (opened Manage subscription). They keep the year, but it won't renew. Answers: 24h, very anxious, monthly-plus, social, notifications granted. Skipped adding a flight in onboarding, opened Settings → Upgrade 13 s after closing Plans, tried Restore, then bought. Added their flight right after.
- **96972F16: Monthly $6.99, pro-features via upgrade_from_settings, Nov 5 11:49, 10 h after install.** Before that they started and abandoned a $9.99 pass on forecast-moment (first_grade_viewed) at 11:45, then abandoned Monthly once and bought on the second try. Answers: 24h, calm, monthly-plus, social, granted.
- Renewal: 59952292 renewed to Yearly $39.99 on Nov 3 (reported yesterday; no longer watching).
- Expirations, Nov 4: trials A75671E6 (hard $39.99) and 33886513 (old `bumpcast_pro_annual`) lapsed unpaid. Both were already cancelled.
- No refunds.
- By product since change: 2 Yearly $49.99, 2 Monthly $6.99, 0 passes. All 4 buyers said they fly within 24h or 3d (24h ×3, 3d ×1). All 4 had granted notifications.

**Segments since change** (n=40; small)
- By next_flight_window: 24h 3 of 9 bought, 3d 1 of 5, week 0 of 6, later 0 of 20.
- By notifications: granted 4 of 23, not-now 0 of 13.
- By source: social 3 of 20, app-store 1 of 9.
- **Later fliers:** 15 of 20 saved a flight. 2 came back on a second day, 2 opened a forecast-ready alert, and 4 saw forecast-moment. 0 bought. Only 16 users are over 30 h old, so return rates are still too early to call.

**Pro paywalls**

| Paywall / placement | Since change: opens (users) | Purchases | 24h: opens |
|---|---|---|---|
| forecast-moment / first_grade_viewed | 10 (10) | 0; 1 pass $9.99 started and abandoned | 9 |
| forecast-moment / forecast_ready_opened | 5 (4) | 0 | 2 |
| forecast-moment / timeline_locked | 8 (6) | 1 old $39.99 trial (8EB2E0C0, Nov 3, cancelled) | 3 |
| pro-features / upgrade_from_settings | 3 (2) | **Yearly $49.99 + Monthly $6.99** | 3 |
| pro-features / pilot_reports_locked | 3 (3) | 0 | 1 |
| pro-features / live_activity_locked | 2 (2) | 0 | 0 |
| pro-features / flight_limit_reached | 1 (1) | 0 | 1 |
| pro-features-pass-first | 0 | – | 0 |

- The 30-minute cap (199842) skipped 1 trigger: 3016CB4F's forecast_ready_opened, 3 min after their first_grade_viewed paywall.
- **Pass-first vs sub-leads:** 0 opens vs 1 open in 2 days. There is no test running in practice. Pro placements don't send `flight_id`, so users with flights (e.g. 96972F16 on pilot_reports_locked) land in No-flight. Lanre has put this on hold.
- Placements that never fired since the change: update_opened, updates_locked, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Stop Forecast moment from taking over a near-flier relaunch.**
   - Evidence: the only hard-trial viewer came back from a notification and got forecast-moment plus the native questions instead of the trial.
   - Stopgap in the dashboard: add a top holdout audience to Forecast moments 113535, "[05/11] Claude v1 Review - Near-flier hard page (skip)", with rule `size(device.activeEntitlements) == 0 && user.onboarding_near_offer == "trial"`. The cost is that these few users would miss forecast-moment later.
   - Proper fix, in the app: don't register Pro placements while onboarding is unfinished (Onboarding.swift `phase != .done`). This needs an update.
2. **Hold the near-flier test.** Only 1 user has seen the trial in 14 h. Most 24h fliers skip adding the flight and then buy from Settings anyway. That suggests intent is high but the hard page rarely triggers. About 10 more hard-trial viewers are needed before calling it, which is about a week at this rate. Re-check after fix #1.
3. **Watch, no action:** the Settings → Upgrade path produced both of today's purchases. If it keeps converting, consider pointing the Plans page's close at Upgrade for 24h fliers. That is a design question for Lanre, so nothing proposed yet.

Lanre, Nov 5: chose to keep the trial page hard and fix the collision in Superwall. Done ~15:00 UTC:
- onboarding-near 289001 → v3: the trial page sets user attribute `onboarding_hard_open = true`; the flow's first page clears it when there's no trial left to resume (`components/near.ts`, `trial.tsx`, `app/index.tsx`).
- Forecast moments 113535: new top audience 200113 "[05/11] Claude v1 Review - Near-flier trial still open (skip)", holdout 100% when no entitlements AND event is first_grade_viewed / forecast_ready_opened / update_opened AND `user.onboarding_hard_open == true`.
- Not yet seen on a real device: check the next hard-trial relaunch.

### Update, Thu Nov 5 17:10 UTC (second run; changes since the 14:00 entry)

Excluded: 24 `$SuperwallAlias:` ids. No review devices, simulators or Lanre's phone.

**Health: OK.**
- Campaigns match the 15:00 setup. 113535 now has 200113 (near-flier trial still open, skip) first, then 199842, then 199843 (forecast-moment 100%). 113534 and 113536 haven't changed.
- Versions: near v3 (Lanre's fix), soft v8, hard v24, forecast-moment v14, pro-features v13, pass-first v12.
- 24h: 18 of 19 installs opened onboarding. The one miss is the iPad 2AA5B120 (no_rule_match), already reported. 0 webview or products-load failures, 0 timeouts, 0 transaction_fail. processTerminated was 17 in 24h, down from 21.
- Pricing: every open since 14:00 showed $49.99 with no trial and the $9.99 pass. No trial transaction.
- New fallback: 77DB1563 (iPhone16,2, app 1.0.4) logged `onboarding_fell_back` reason=timeout at 11:55. No install or paywall events came with it, so it looks like an existing user relaunching. 1 user, watch.
- **200113 is unproven.** Nobody has seen the hard trial page since v3. No user currently has `onboarding_hard_open`, and 200113 has skipped nothing yet. The relaunch-to-trial path is still not seen on a real device.

**Since 14:00:** 1 new onboarding user. E6AD481B is a "later" flier, very anxious, from social. They granted notifications, skipped adding a flight, reached Plans and closed the app.

**Updated totals**
- 24h onboarding: 18 users, all reached source. 14 tapped Add flight, 9 reached the flight page, 10 reached Plans. Notifications: 12 granted, 5 not-now, 1 denied.
- Near test (289001, about 17 h): 9 users. Hard trial seen by 1, trial starts 0, timeline page 2 (both declined). 3 of the 9 fly within 24h, and 2 of those 3 skipped adding the flight.
- Since change: 41 onboarding users. Still 2 paid in onboarding (both soft).

**New purchase**
- **2771390E: Monthly $6.99, pro-features via pilot_reports_locked, Nov 5 16:11.** This is an older user: installed Oct 29 and saw the hard variant. Answers: very anxious, few a year, week, app store, granted. They had a flight, but they landed in "No flight" (experiment 199433). That's the same `flight_id` gap that already has pass-first on hold. They bought 6 s after the paywall opened and haven't cancelled.

**Purchases since change:** 2 Yearly $49.99 (3A575EBF; 095E482E, auto-renew off). 3 Monthly $6.99 (CB4B0474, 96972F16, 2771390E). 0 passes. **3 of today's 3 came through pro-features** (Settings ×2, pilot reports ×1). No refunds.

**Recommendations (need Lanre's OK)**
1. Hold the near-flier test. 200113 needs its first real hard-trial relaunch before it can be judged. That's about 10 more hard-trial viewers, which at today's rate is about a week.
2. Watch, no change: pro-features is now the main converter today (3 buys from about 6 opens). Pass-first remains unrun because placements don't send `flight_id`. That still needs Lanre's app-side decision.

## Nov 5: pass-first test ended, campaign audit

**Change (Lanre's yes):** Pro features 113536 now has 200212 "[05/11] Claude v1 Review - Has a flight: subscription leads only" on (`pro-features` 100%), ranked above 199276. 199275 is paused at its 50/50 for comparison. Backup of the campaign before the change: `docs/release/backups/2026-11-05-campaign-113536-before.json`.

**Audit of every live audience and paywall input against what the app sends:**
- Onboarding 113534: one live audience (199841, near 100%). The flow gets its flight from the `add_flight` callback and reads only attributes it sets itself (`onboarding_hard_flight`, `onboarding_hard_open`). No gap.
- Forecast moments 113535: all four placements (`first_grade_viewed`, `forecast_ready_opened`, `update_opened`, `timeline_locked`) always send a flight, so the pass always leads there. The app skips the moments for Pro and pass holders. Skip audiences 200113 and 199842 read `user.onboarding_hard_open` and `device.minutesSinceLastPaywallView`, both set. No gap.
- Pro features 113536: the flight-only pass link was the only gap, and it's now closed by ending the test. Two leftovers, both harmless: `live_status_locked` is still on the campaign, but no shipped build fires it (it was made free on Oct 20, before 1.0); and `flight_added` / `turn_on_notifications` have no campaign on purpose, so the app falls back to native.
- Headlines: every placement the app fires has its own `pro.title.*`; anything else gets the fallback.

## Day Fri Nov 6

Run at 17:11 UTC. 24h = Nov 5 17:11 → Nov 6 17:11. Excluded: 33 `$SuperwallAlias:` ids. No review devices, simulators or Lanre's phone.
- **Exclusion rule fix:** "Darwin 25.6.0" is the iOS 26.x user agent, not just the Mac simulator. Applied literally, it would drop 23 real iPhones, including buyer 2771390E. This run excludes simulators by device model only. Earlier entries' counts already included these users.

**Health: OK.** One device-level issue.
- Campaigns match the setup:
  - 113534: only 199841 (near 289001 at 100%) is live.
  - 113535: 200113 skip, then 199842 skip, then 199843 forecast-moment 100%. Old audiences are paused.
  - 113536: 200212, then 199276, both pro-features 100%. 199275, 193400 and 195604 are paused.
- Versions are unchanged: near v3, soft v8, hard v24, forecast-moment v14, pro-features v13, pass-first v12.
- 24h: 11 installs, 13 onboarding users. One install missed onboarding: **5B9259F5** (iPhone14,7, app 1.0.4, 16:11 today). All three paywall webviews failed with "The URL was blocked by a content filter", so onboarding fell back to native (`onboarding_fell_back` reason=page_failed). The cause is a content filter or ad blocker on that device, not Superwall. Watch for a repeat.
- 0 products-load failures, 0 timeouts, 0 transaction_fail.
- processTerminated was 39, up from 17. Almost all are background preloads on existing subscribers' devices (59952292 ×11, 095E482E ×9…). Harmless.
- Pricing: every shown onboarding and Pro paywall had $49.99 with no trial and the $9.99 pass on 1.0.4. A few preload page views showed the dashboard default `bumpcast_pro_annual` / $3.99 pass. They were programmatic and never opened, so no user saw them. No trial transaction.
- **200113 is still unproven.** 0 skips, and nobody has seen the hard trial page since v3. 199842 (30-min cap) skipped 0 in 24h and 1 since it went live.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 11 | 52 |
| Onboarding users | 13 (all near) | 54 (31 soft, 22 near, 1 hard) |
| Reached source | 12 | 53 |
| Notifications page | 10 | 49 |
| Tapped Add flight / added in flow | 6 / 1 | 40 / 19 |
| Flight page / Plans page | 1 / 9 | 22 / 28 |
| Notifications granted | 4 | 28 |
| Median feeling→source | 28 s | 30 s |
| Onboarding purchases | 0 | 2 (both soft, Nov 3–4) |

- 24h add-flight is weak: 6 tapped Add, only 1 completed in the flow, and 9 of 13 ended on Plans. Yesterday it was 14 tapped and 9 reached the flight page. The sample is small, so this is not yet a trend.

**Near-flier test (289001, ~41 h, 22 users)**
- Saw the hard trial (`onboarding_near_offer = trial`): **1 user ever**, 230F2DA0 (Nov 5 00:40, ROC→BWI). They relaunched at 11:15 and got the trial again. That was before v3, and they didn't start the trial.
- Trial starts on `bumpcast_pro_annual_3999_3d`: 0. Cancellations, conversions and lapses: none to report.
- Timeline soft page: 3 users. DDEB5651 (today 15:05), 467E53A4 and 8954E777 (relaunched 6× and kept getting the timeline). 0 Yearly or Monthly bought on it.
- Near users who paid: **3 of 22**, all *outside* onboarding:
  - 095E482E: Yearly $49.99 via Settings, auto-renew off
  - 96972F16: Monthly via Settings
  - 8954E777: $9.99 pass via forecast-moment
- Soft baseline (193398): 2 paid of ~40, both inside onboarding.
- Near fliers mostly don't add the flight in onboarding. The hard page has fired once in 41 h.

**Purchases**
- **New: 8954E777 bought a $9.99 Flight Pass on forecast-moment / timeline_locked**, Nov 5 20:03 UTC, 16 h after install. This is the first pass sold since the price change.
  - Their answers: very anxious, few a year, 3d, social, notifications granted, near-trial variant.
  - In onboarding they added a flight leaving in more than 24 h and saw the timeline page (Yearly $49.99 + Monthly). They declined, relaunched several times, and bought the pass when the timeline locked.
- Lapsed today, all already cancelled, $0: 3 old trials (`bumpcast_pro_annual` ×1, `bumpcast_pro_annual_3999_3d` ×2).
- No new cancellations, refunds or renewals.
- Since change, paid: 2 Yearly $49.99 (3A575EBF; 095E482E with auto-renew off), 3 Monthly $6.99 (CB4B0474, 96972F16, 2771390E), 1 pass $9.99 (8954E777).
  - Gross $93.92 / proceeds about $79.83 (at 85%).
  - Every buyer flies within a week. 0 "later" fliers bought.

**Segments since change** (n=54; small)
- By next_flight_window: 24h 3 of 12, 3d 2 of 5, week 0 of 10, later 0 of 26.
- By notifications: granted 5 of 28, not-now 0 of 19, denied 0 of 2.
- By source: social 4 of 23, app store 1 of 15, other/friend 0 of 15.
- By feeling: very anxious 3 of 15, calm 2 of 21, nervous/uneasy 0 of 18.
- **Later fliers (26):** 18 saved a flight. 4 came back on a second day, 2 opened a forecast-ready alert, 4 saw forecast-moment, 0 bought.
- Across all 54, 12 of the 40 users older than 30 h came back on a second day.

**Pro paywalls** (opens = users)

| Paywall / placement | 24h opens | Since Nov 3 21:30 opens | Purchases since |
|---|---|---|---|
| forecast-moment / first_grade_viewed | 2 | 12 | 0 (1 pass started and abandoned) |
| forecast-moment / forecast_ready_opened | 0 | 4 | 0 |
| forecast-moment / timeline_locked | 1 | 7 | **1 pass $9.99** |
| pro-features / upgrade_from_settings | 1 | 3 | Yearly $49.99 + Monthly |
| pro-features / pilot_reports_locked | 0 | 4 | Monthly |
| pro-features / live_activity_locked | 0 | 1 | 0 |
| pro-features / flight_limit_reached | 0 | 1 | 0 |
| pro-features-pass-first | 0 | 0 | – |

- Never fired since the change: update_opened, updates_locked, live_status_locked, email_import_locked.
- Every trigger_fire for a free user presented a paywall. No silent misses.

**Recommendations (need Lanre's OK)**
1. **Hold the near-flier test.** 1 hard-trial viewer in 41 h, and 0 trial starts. About 10 viewers are needed to judge it, more than a week at this rate. The near cohort is still converting (3 of 22) through Pro paywalls, so nothing is broken.
2. **Watch, no change:** the timeline page → forecast-moment pass path produced today's sale. If a second "declined timeline → bought pass later" case shows up, consider adding the $9.99 pass to the timeline page (onboarding-near `flight` page for flights more than 24 h out). That would need a design review first.

## Nov 7: hard offer ends at departure (onboarding-near v6)

**Why:** 0BDB7267 (Meta "02 countdown · turbulence", iPhone19,3, DFW→MIA 12:05 UTC) quit on the hard offer. Tapping the boarding notification (11:05) and then the landing notification (15:22) brought the hard offer back over the flight each time, and both times they closed the app in about 2 s. In both relaunches the `flight_forecast` check failed in under 3 s (no result logged), so the offer showed without the pass. That's probably the app answering before it has loaded the flight on a cold launch from a notification, and it needs an app update. It was the first real-device run of 200113, which correctly held back first_grade_viewed.

**Change (Lanre's yes):** review page `after-departure.html`.
- onboarding-near 289001 → **v6**: `savedHardFlight` resumes the hard offer only until scheduled departure. A relaunch after departure goes straight to the closable Plans (`leftHardOffer`, `app/index.tsx`) instead of the questions. The ≤24 h hard offer in the first run is unchanged.
- Onboarding 113534: new top audience **200805** "[07/11] Claude v1 Review - near-flier, offer ends at departure" (no entitlements, 289001 100%), enabled at ~15:52 UTC. **199841 paused** for comparison. Backup: `docs/release/backups/2026-11-07-campaign-113534-before.json`.
- The daily review task now expects 200805 and checks after-departure relaunches.

**Same day, v7: the forecast-check failure was in the paywall, not the app.** On both relaunches Superwall preloaded the onboarding page at launch. The page's index resumed straight to `checking`, which asked `flight_forecast` about 1 s *before* the app registered the `onboarding` placement, whose handler answers custom callbacks (11:05:39.39 vs 11:05:40.36; 15:22:06.67 vs 15:22:07.54). With no handler, it failed at once. v7 (`app/index.tsx`) resumes only once `paywall_open` has arrived (`snapshot.paywall`), and shows an empty sky until then instead of a flash of the welcome. No app update needed. (The pass is never offered on a resume, by design, because `add_flight` is skipped.) It's in the same audience, 200805, as a bug fix to v6 from 30 minutes earlier.

## Day Sat Nov 7

Run at 17:03 UTC. 24h = Nov 6 17:03 → Nov 7 17:03. Excluded: 50 `$SuperwallAlias:` ids. No review devices, simulators or Lanre's phone.

**Health: OK.**
- Campaigns match the setup:
  - 113534: 200805 (289001 100%) live, 199841 paused. 200805 has had 2 onboarding opens since ~15:52 (experiment 200962).
  - 113535: 200113 skip → 199842 skip → 199843 forecast-moment 100%.
  - 113536: 200212 → 199276, both pro-features 100%. The old paused audiences are no longer listed (deleted Nov 6, per SUPERWALL.md).
- Versions: near v7, soft v8, hard v24, pass-first v12. Forecast-moment is **v15** and pro-features **v14** (were v14/v13). That's explained: Lanre locked them on Nov 6 (commit f75f779).
- 24h: 17 installs, all 17 got onboarding (19 onboarding users). 0 webview, product-load or transaction failures.
- 3 `onboarding_fell_back` reason=timeout on 2 *existing* devices (6771A75A ×2, variant "hard"; 77DB1563, also timed out Nov 5). No new install was affected. Watch only.
- Pricing: every onboarding and Pro paywall open showed $49.99 Yearly. Pro opens had no trial and the $9.99 pass. The trial flag shows only on onboarding-near, which still carries `bumpcast_pro_annual_3999_3d`.
- The only trial transaction was 8F6712DF on `bumpcast_pro_annual_3999_3d` via onboarding-near. That's the test's intended trial, not a problem.
- **No after-departure relaunches yet since v6/v7, and no forecast-check failures since v7** (16:20 UTC). The one earlier case, 341EA8C9, was at 02:39 UTC, before the fix: it relaunched before departure and went index → checking → plans in 2 s with no flight result.
- **Task context is stale:** since v4 (Nov 6 ~22:00), new near users see the hard page as Yearly $49.99 or $9.99 pass, not the $39.99 trial. They're tagged `onboarding_near_offer = annual_or_pass` and variant `near-offer`.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 17 | 69 |
| Onboarding users | 19 (all near) | 73 (41 near, 19 soft, 12 both, 1 hard) |
| Reached source / find | 19 / 19 | 72 / 72 |
| Notifications page | 18 | 67 |
| Tapped Add flight | 17 | 58 |
| Saved a flight in the flow | 14 | 38 |
| Flight page / Plans page | 13 / 7 | 35 / 35 |
| Notifications granted / not-now / denied | **14** / 3 / 1 | 42 / 22 / 3 |
| Median feeling→source | 25 s | 29 s |
| Onboarding purchases | 1 trial (cancelled) | 2 paid + 1 trial |

- **Best day yet for add-flight and notifications.** 14 of 19 saved a flight (yesterday 1 of 13), and 14 of 19 granted notifications. The baseline was about 30%.
- next_flight_window (24h): 24h 8, later 7, week 4.

**Near-flier test (289001, since Nov 4 23:50)**
- Hard page viewers: **7 ever**, 6 of them in the last 24h.
  - Trial version ($39.99, 3-day trial), 4 viewers: 230F2DA0, 8F6712DF, C06FCE91, 2B70C9E1.
  - annual_or_pass version (v4+), 3 viewers: 8FE0A5A4, 341EA8C9, 3D094D33.
- Trial starts: **1, 8F6712DF.**
  - Installed Nov 6 18:49 and saw the trial page at 18:50. They left the app, came back about an hour later, and started the trial at 19:51.
  - They **cancelled at 19:52, 1 minute later**. The trial will lapse on Nov 9 19:51 at $0.
  - Their answers: calm, monthly-plus, social, 24h (EWR→DCA), notifications granted.
- annual_or_pass: 0 Yearly or passes bought from 3 viewers. 3D094D33's flight (DRO→DEN) leaves Nov 8 00:55, so it's still open.
- Relaunches that got the hard page again: 8F6712DF, where it converted to the trial. 341EA8C9 hit the pre-v7 bug and got Plans.
- Timeline soft page: 9 users ever, 6 in 24h. 0 Yearly or Monthly bought there.
- Near cohort paid: still 3, all outside onboarding (095E482E Yearly, 96972F16 Monthly, 8954E777 pass), plus 1 trial cancelled. The soft baseline (193398) was 2 paid of ~40, both in onboarding.
- 30-min cap (199842): skipped 2 in 24h (DFDE3659 ×2, forecast_ready_opened) and 3 ever. 200113: 1 skip ever (0BDB7267, Nov 7 11:05), 0 new.

**Purchases**
- 24h: 8F6712DF trial start and a cancellation within 1 minute. No paid purchase, refund or renewal.
- Since change, paid is unchanged: 2 Yearly $49.99 (3A575EBF; 095E482E with auto-renew off), 3 Monthly $6.99, 1 pass $9.99. Gross $93.92 / proceeds about $79.83 at 85%.
- 0 of 33 "later" fliers have bought.

**Pro paywalls (24h opens = users)**
- forecast-moment: first_grade_viewed 3, timeline_locked 3. pro-features: flight_limit_reached 1, live_activity_locked 1. 0 transactions.
- Since Nov 3 21:30: forecast-moment 15 / 4 / 11 (first_grade_viewed / forecast_ready_opened / timeline_locked). pro-features: upgrade 3, pilot reports 4, live activity 3, flight limit 2. Purchases unchanged: 1 pass, 1 Yearly, 2 Monthly.
- Every trigger_fire for a free user presented a paywall or a holdout. No silent misses.
- Still never fired: update_opened, updates_locked, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Hold the near test.** annual_or_pass has 3 viewers and 0 buys. About 10 viewers are needed to judge it, roughly 3–4 more days at today's rate of ~6 hard-page viewers a day. The trial arm's one start cancelled in 1 minute, the same pattern as the 6 of 7 cancelled trials in the baseline.
2. **Update this task's context:** near hard page = Yearly $49.99 or $9.99 pass (`annual_or_pass`, v4+). Count Yearly and pass buys on it, and stop expecting trial starts. Only the scheduled-task file changes.

## Day Sun Nov 8

Run at 17:12 UTC. 24h = Nov 7 17:12 → Nov 8 17:12. Excluded: 11 `$SuperwallAlias:` ids in 24h (58 since the change). No review devices, simulators or Lanre's phone.

**Health: OK.**
- Campaigns match the setup:
  - 113534: 200805 (289001 100%) live, 199841 paused. All 19 onboarding triggers in 24h went to 200805 and presented.
  - 113535: 200113 skip → 199842 skip → 199843 forecast-moment 100%.
  - 113536: 200212 → 199276, both pro-features 100%.
- Versions: near v7, soft v8, hard v24, forecast-moment v15, pro-features v14, pass-first v12. All explained (Nov 6–7 changes). 281985 is archived, as SUPERWALL.md says.
- 24h: 15 installs, all got onboarding (19 onboarding users). 0 webview, product-load or transaction failures. 25 triggers presented and 3 held out, none silently missed.
- `onboarding_fell_back`: 1 timeout on 77DB1563, the same existing device as Nov 5 and Nov 7. Watch only.
- processTerminated was 16, background preloads on existing devices (6771A75A, 6692D835…). Harmless.
- Pricing: every onboarding and Pro paywall open showed $49.99 Yearly, no trial and the $9.99 pass. No trial transaction in 24h.
- **v7 resume works.** 3D094D33 relaunched from a notification at Nov 7 17:26, before departure: index → checking → hard page in 3 s, with a flight result. 0 forecast-check failures across 30 near users since v7. This was also the 200113 skip working (first_grade_viewed and forecast_ready_opened both held back).
- After-departure relaunches: **0 so far**, so index → plans is still unmeasured.
- 2AA5B120 (iPad17,2, Nov 5) is the second install that never got onboarding: `no_rule_match`, then `skipped`. One case, not repeated. Not a problem.
- **Correction:** the "Gross $93.92 / proceeds about $79.83" in the Nov 6 and Nov 7 entries was wrong. Those 6 purchases add up to $130.94 gross.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 15 | 84 |
| Onboarding users | 19 (all near) | 90 (58 near, 31 soft, 1 hard) |
| Reached source / find | 17 / 17 | 88 / 88 |
| Notifications page | 15 | 81 |
| Tapped Add flight | 12 | 70 |
| Saved a flight in the flow | 7 | 45 |
| Flight page / Plans page | 8 / 8 | 41 / 42 |
| Notifications granted / not-now / denied | 11 / 4 / 1 | 52 / 26 / 3 |
| Median feeling→source | 30 s | 29 s |
| Onboarding purchases | **2 paid** | 4 paid + 1 trial |

- Add-flight fell back to 7 of 19 (yesterday 14 of 19, the day before 1 of 13). Noisy day to day. Notifications held up at 11 of 19.
- next_flight_window (24h): 24h 8, 3d 6, later 4, unanswered 1.

**Near-flier test (289001, since Nov 4 23:50, 58 users)**
- Hard page viewers: **10 ever**, 2 new in 24h (981BC733, FC6BF9BA) plus the 3D094D33 relaunch.
  - Trial version ($39.99, 3-day trial), 4 viewers: 1 trial start (8F6712DF, cancelled after 1 minute, lapses Nov 9 19:51 at $0). No conversions.
  - annual_or_pass (v4+), 6 viewers: **0 Yearly or passes bought.** Two are still open: 981BC733 (TPA→LAX 20:55 UTC today) and FC6BF9BA (DEN→BOS 21:00 UTC today).
  - 981BC733 saw the timeline page on Nov 7, when the flight was 29 h out. They re-ran the questions today and got the hard page 8 h before departure.
- Timeline soft page: 13 users ever, 5 in 24h. **First sale on it:** 6692D835, Monthly $6.99, 2 minutes after install.
- Cap 199842: 1 skip in 24h (CBBB36A4), 4 ever. 200113: 2 skips in 24h, 3 ever.
- Cohort paid: near **6 of 58** (10%), soft **3 of 31** (10%). The soft cohort has had longer to buy. The near page itself has not sold: of the 6 near buyers, 1 bought on the timeline page, 1 on Plans, 4 on Pro paywalls.

**Purchases**
- 24h, 4 paid, all new:
  - **6771A75A: Yearly $49.99 on onboarding-near Plans**, Nov 7 18:18. An existing user (installed before Nov 3). Nervous, few a year, app store, notifications granted, "later": the **first "later" flier to buy**. They saved a flight that had left 5 h earlier right after buying.
  - **6692D835: Monthly $6.99 on the timeline page**, Nov 7 22:28, 2 minutes after install. A little uneasy, monthly-plus, 3d, social, granted.
  - **065B30BE: Monthly $7.31 on forecast-moment / timeline_locked**, Nov 7 21:51, 3 minutes after install. **Turned off auto-renew 12 minutes later.** Calm, monthly-plus, 3d, other, denied. Declined Plans, saved a flight about to leave, hit timeline_locked and bought.
  - **86C919AE: Flight Pass $9.99 on forecast-moment / timeline_locked**, Nov 8 11:58, 4.3 days after install. Very anxious, yearly or less, week, app store, granted. Soft cohort. Declined the flight page on Nov 4. Later declined the paywall for a second flight, since the pass covers one.
- Since change, paid: 3 Yearly $49.99, 5 Monthly, 2 passes $9.99. **Gross $205.22 / proceeds about $174.44 at 85%**, from 10 users. Excludes the 59952292 $39.99 renewal.
- 9 of 10 buyers fly within a week. No refunds.

**Segments since change** (n=90; small)
- By next_flight_window: 3d 4 of 11, 24h 3 of 26, week 1 of 14, later 1 of 37.
- By notifications: granted 8 of 52, not-now 0 of 26, denied 1 of 3.
- By source: social 5 of 38, app store 3 of 29, other 1 of 16, friend 0 of 5.
- By feeling: very anxious 4 of 18, calm 3 of 43, uneasy 1 of 15, nervous 1 of 13.
- **Later fliers (37):** 24 saved a flight, 6 came back on a second day, 2 opened a forecast-ready alert, 4 saw forecast-moment, 1 bought.
- 21 of the 67 users older than 30 h came back on a second day.

**Pro paywalls** (opens = users)

| Paywall / placement | 24h opens | Since Nov 3 21:30 opens | Purchases since |
|---|---|---|---|
| forecast-moment / first_grade_viewed | 1 | 16 | 0 |
| forecast-moment / forecast_ready_opened | 0 | 4 | 0 |
| forecast-moment / timeline_locked | 2 | 12 | **2 passes $9.99, 1 Monthly** |
| pro-features / upgrade_from_settings | 2 | 5 | Yearly $49.99 + Monthly |
| pro-features / pilot_reports_locked | 0 | 4 | Monthly |
| pro-features / live_activity_locked | 0 | 2 | 0 |
| pro-features / flight_limit_reached | 0 | 2 | 0 |

- **timeline_locked is the Pro paywall that sells:** 3 of 12 openers bought, against 0 of 20 on first_grade_viewed and forecast_ready_opened (1 pass started and abandoned on first_grade_viewed, Nov 5).
- Has a flight (200212): 1 trigger since Nov 5, 0 pass purchases from the link.
- Still never fired: update_opened, updates_locked, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Hold the near test.** annual_or_pass has 6 viewers and 0 buys, with 2 still open today. About 4 more viewers reach the 10 needed, roughly 2 days at today's rate. If it's still 0 of 10, the next proposal is to make that page closable, since hard-page viewers have produced 0 paid so far (10 viewers, trial arm included).
2. **Design review: add the $9.99 pass to the timeline page** (`superwall/paywalls/onboarding-near/components/soft.tsx`, Yearly and Monthly today). Yesterday's trigger is met: two users declined a flight page, then bought a pass later (8954E777, 86C919AE). It might bring those sales forward by days, or trade some Yearly sales for passes. Show the design first, new audience if approved.
3. **Update this task's context** (still open from Nov 7): near hard page = Yearly $49.99 or $9.99 pass (`annual_or_pass`, v4+); versions now 7, 8, 24, 15, 14, 12.

## Day Mon Nov 9

Run at 17:11 UTC. 24h = Nov 8 17:11 → Nov 9 17:11. Excluded: no review devices, simulators or Lanre's phone; 0 `$SuperwallAlias:` ids in 24h and 3 since the change, counted on funnel events only (config and attribute events weren't pulled this run, so this isn't comparable with the 58 in the Nov 8 entry).

**Health: OK, one small bug below.**
- Campaigns match the setup:
  - 113534: 200805 (289001 100%) live, 199841 paused. All 14 onboarding triggers in 24h went to 200805 and presented.
  - 113535: 200113 skip → 199842 skip → 199843 forecast-moment 100%.
  - 113536: 200212 → 199276, both pro-features 100%.
- Versions unchanged: near v7, soft v8, hard v24, forecast-moment v15, pro-features v14, pass-first v12.
- 24h: 14 installs, all 14 got onboarding. 30 triggers presented = 30 paywall opens, 1 held out, none silently missed. 0 webview, product-load or transaction failures, 0 `onboarding_fell_back`.
- processTerminated was 10, harmless as before.
- Pricing: every onboarding and Pro paywall open in 24h showed $49.99 Yearly, no trial and the $9.99 pass. No trial transaction in 24h.
- Forecast-check failures before departure since v7: **0**. The one checking → plans under 4 s (18E2CB32, Nov 8) had a flight result, out of coverage, and wasn't a relaunch.
- After-departure relaunches: **still 0**, so index → plans is unmeasured. Of 12 hard-offer users, 10DF3876 (paid) reopened after departure and got no onboarding, which is correct; the rest haven't come back since v6.
- **Small bug: `onboarding_hard_open` can stay true for good.** `offer.tsx` sets it when the hard page opens; only the flow's index clears it, and a user who finishes the flow never gets that page again. So 200113 would skip that user's first_grade_viewed and forecast_ready_opened on every later flight. 13539E94 is the live case today. 8F6712DF joins once their trial lapses (they have it set and finished the flow). 0 wrong skips so far.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 14 | 98 |
| Onboarding users | 14 (all near) | 104 (72 near, 31 soft, 1 hard) |
| Reached source / find | 14 / 14 | 102 / 102 |
| Notifications page | 13 | 94 |
| Tapped Add flight | 9 | 79 |
| Saved a flight in the flow | 7 | 52 |
| Flight page / Plans page | 7 / 7 | 48 / 50 |
| Notifications granted / not-now / denied | 10 / 3 / 0 | 62 / 29 / 3 |
| Median feeling→source | 31 s | 30 s |
| Onboarding purchases | **1 paid** | 5 paid + 1 trial |

- Add-flight: 7 of 14 (yesterday 7 of 19). Notifications: 10 of 14 granted (yesterday 11 of 19), against the ~30% baseline.
- next_flight_window (24h): later 6, 3d 4, 24h 3, week 1.

**Near-flier test (289001, since Nov 4 23:50, 72 users)**
- Hard offer tagged: **12 ever**, 2 new in 24h (10DF3876, 13539E94).
  - Trial version, 4 viewers: 1 trial start (8F6712DF, cancelled after 1 minute, lapses Nov 9 19:51 UTC at $0, after this run). No conversions.
  - annual_or_pass, 8 tagged, **7 really saw it**. 13539E94 added a flight that had left 20 minutes earlier: flight page → Plans in the same second, then declined.
  - **First sale on the hard page: 10DF3876, Yearly $49.99, Nov 8 17:57.** 1 of 7 (small). Installed 2 minutes earlier, EWR→PHX leaving 4.5 h later. Nervous, few a year, social, granted. No cancellation so far; took off and opened flight alerts.
- Relaunches that got the hard page again: 0 new in 24h.
- Timeline soft page: 18 users ever, 5 in 24h, 0 bought in 24h. 1 sale ever (6692D835).
- Cap 199842: 1 skip in 24h (892724CF), 5 ever. 200113: 0 in 24h, 3 ever.
- Cohort paid: near **7 of 72** (10%), soft **3 of 31** (10%). Of the 7 near buyers, 1 hard page, 1 timeline, 1 Plans, 4 on Pro paywalls.

**Purchases**
- 24h: 1 paid, 10DF3876 Yearly $49.99. No cancellations, refunds or renewals.
- Since change, paid: **4 Yearly $49.99, 5 Monthly, 2 passes $9.99**. Gross $255.21 / proceeds about $216.93 at 85%, from 11 users. Excludes the 59952292 $39.99 renewal.
- 10 of 11 buyers fly within a week. No refunds.

**Segments since change** (n=104; small)
- By next_flight_window: 3d 4 of 15, 24h 4 of 29, week 1 of 15, later 1 of 43.
- By notifications: granted 9 of 62, not-now 0 of 29, denied 1 of 3.
- By source: social 6 of 44, app store 3 of 32, other 1 of 20, friend 0 of 6.
- By feeling: very anxious 4 of 24, nervous 2 of 14, calm 3 of 50, uneasy 1 of 15.
- By frequency: monthly-plus 5 of 43, few a year 4 of 42, yearly or less 1 of 17.
- **Later fliers (43):** 26 saved a flight, 7 came back on a second day, 2 opened a forecast-ready alert, 5 saw forecast-moment, 1 bought.
- 25 of the 85 users older than 30 h came back on a second day.

**Pro paywalls** (opens = users)

| Paywall / placement | 24h opens | Since Nov 3 21:30 opens | Purchases since |
|---|---|---|---|
| forecast-moment / first_grade_viewed | 4 | 20 | 0 |
| forecast-moment / forecast_ready_opened | 0 | 4 | 0 |
| forecast-moment / timeline_locked | 4 | 15 | **2 passes $9.99, 1 Monthly** |
| pro-features / upgrade_from_settings | 0 | 5 | Yearly $49.99 + Monthly |
| pro-features / pilot_reports_locked | 0 | 4 | Monthly |
| pro-features / live_activity_locked | 1 | 3 | 0 |
| pro-features / flight_limit_reached | 2 | 4 | 0 |

- 0 transactions on Pro paywalls in 24h. timeline_locked is still the one that sells: 3 of 15 openers bought, against 0 of 24 on first_grade_viewed and forecast_ready_opened.
- Has a flight (200212): 2 triggers in 24h, 3 since Nov 5, 0 pass purchases from the link.
- Still never fired: update_opened, updates_locked, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Hold the near test.** annual_or_pass is now 1 of 7, the first hard-page sale. About 3 more viewers reach 10, roughly 2–3 days at today's rate. The Nov 8 idea of making the page closable no longer has its trigger.
2. **Fix `onboarding_hard_open` staying true after a free finish.** Clear it when the flow finishes without a purchase, or don't set it for a flight that's already left (`superwall/paywalls/onboarding-near/components/offer.tsx`). Effect: those users see Forecast moments again on later flights. 1 user is affected today, 2 after tonight. Needs a push and a new audience.
3. **Design review: add the $9.99 pass to the timeline page** (open from Nov 8, `superwall/paywalls/onboarding-near/components/soft.tsx`). No new evidence today: 5 more timeline viewers, 0 bought.

Task context is still stale (near hard page = Yearly $49.99 or $9.99 pass; versions 7, 8, 24, 15, 14, 12). Only the scheduled-task file needs changing.

## Nov 9: hard-open flag fix (onboarding-near v8)

**Why:** `onboarding_hard_open` could stay true after the flow finished, and 200113 would then skip that user's first_grade_viewed and forecast_ready_opened on later flights (13539E94, today).

**Change (Lanre's yes), live ~17:56 UTC:**
- onboarding-near 289001 → **v8**, published alone (`--id onboarding-near`). Nothing else under `superwall/` had changed since v7. `components/offer.tsx`: the flag is no longer set for a flight that has already left, and buying or restoring clears it.
- Onboarding 113534: new audience **201414** "[09/11] Claude v1 Review - near-flier, hard-open flag fix" (no entitlements, 289001 100%), enabled. **200805 paused.** Backup: `docs/release/backups/2026-11-09-campaign-113534-before.json`.
- Not fixed by this: 13539E94 and 8F6712DF keep the flag, because their flow won't run again.
- Not tested on a device. Check in the data: a free user finishing on a departed flight should have the flag false or unset, and a buyer on the hard page should have it false.
- Unchanged: a flight that has already left still goes flight page → Plans in the same second, though SUPERWALL.md describes a hard page. Probably `app/index.tsx`'s `leftHardOffer` reacting to the attribute the page just set (not confirmed).

## Day Tue Nov 10

Run at 17:12 UTC. 24h = Nov 9 17:12 → Nov 10 17:12. Excluded: 5 `$SuperwallAlias:` ids in 24h (75 since the change, raw events). No review devices, simulators or Lanre's phone.

**Health: OK.**
- Campaigns match the setup:
  - 113534: 201414 (289001 100%) live; 200805 and 199841 paused. All 8 onboarding triggers in 24h went to 201414 and presented.
  - 113535: 200113 skip → 199842 skip → 199843 forecast-moment 100%.
  - 113536: 200212 → 199276, both pro-features 100%.
- Versions: near v8, soft v8, hard v24, forecast-moment v15, pro-features v14, pass-first v12 (archived). All as expected.
- 24h: 31 triggers, 30 presented = 30 paywall opens, 1 held out (200113), none silently missed. 0 webview, product-load or transaction failures. processTerminated 15 (6 devices), harmless as before.
- Pricing: every onboarding and Pro open in 24h showed $49.99 Yearly, no trial and the $9.99 pass. No trial transaction.
- `onboarding_fell_back` 2, both timeouts on existing devices: 77DB1563 (4th time, watch only) and F2B43881 (installed Nov 4, first time).
- 1 of 7 installs never got onboarding: A1A8ABE3 (iPhone16,2, Nov 9 18:35) closed the app 2 s after install, before any trigger. Third such case (230F2DA0, 2AA5B120). Not repeated in a pattern; not a problem.
- **v8 hard-open fix: PASS.** Since 17:56 Nov 9: 3E11602F bought on the hard page and has the flag false. E3416FFA didn't buy and their flight hadn't left, so true is correct. No departed flights added since. 13539E94 and 8F6712DF are the known leftovers.
- Forecast-check failures before departure: **0** (still 0 since v7). E3416FFA relaunched twice before departure (21:43 and 00:15, 1 h before LAX→CDG): checking → hard page in 2–3 s with a flight result each time.
- After-departure relaunches: **still 0**, so index → plans is unmeasured. E3416FFA hasn't opened since departure.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 7 | 105 |
| Onboarding users | 6 (all near) | 110 (78 near, 31 soft, 1 hard) |
| Reached source / find | 5 / 5 | 107 / 107 |
| Notifications page | 5 | 99 |
| Tapped Add flight | 5 | 84 |
| Saved a flight in the flow | 4 | 56 |
| Flight page / Plans page | 4 / 1 | 52 / 51 |
| Notifications granted / not-now / denied | 4 / 1 / 0 | 66 / 30 / 3 |
| Median feeling→source | 26 s | 30 s |
| Onboarding purchases | **1 paid** | 6 paid + 1 trial |

- Installs halved (7 vs 14). Likely the Apple Ads stop (Nov 9 evening) and the end of the Meta weekend run.
- Small day, but the flow did its job: 4 of 6 saved a flight, 4 of 6 granted notifications.
- next_flight_window (24h): 24h 2, week 2, later 1, unanswered 1.

**Near-flier test (289001, since Nov 4 23:50, 78 users)**
- Hard offer tagged annual_or_pass: 10 ever, **9 really saw it** (13539E94's flight had already left). 2 new in 24h:
  - **3E11602F: Yearly $49.99 on the hard page**, Nov 10 14:58, 2 minutes after install. DFW→SLC leaving 2 h later. Very anxious, monthly-plus, other, granted. One abandoned attempt first, then bought 10 s later. Opened the flight 5 times since.
  - E3416FFA (LAX→CDG, 3.5 h out): restore failed, then 2 relaunches back to the hard page. A Yearly purchase started at 21:44 (after tapping a forecast-ready notification) with no complete or abandon recorded. No revenue. Calm, monthly-plus, social.
- **annual_or_pass: 2 Yearly from 9 viewers, 0 passes** (yesterday 1 of 7). Trial arm (4 viewers): no change, closed.
- Relaunches that got the hard offer again: 2 in 24h (both E3416FFA), 3 ever.
- Timeline soft page: 20 users ever, 2 in 24h, 0 bought in 24h. 1 sale ever (6692D835).
- Cap 199842: 0 skips in 24h, 5 ever. 200113: 1 skip in 24h (E3416FFA first_grade_viewed, offer still open: correct), 4 ever.
- Cohort paid: near **8 of 78** (10%), soft **3 of 31** (10%). Soft baseline window was 2 of ~40. Of the 8 near buyers: 2 hard page, 1 timeline, 1 Plans, 4 Pro paywalls.

**Purchases**
- 24h: 1 paid, 3E11602F Yearly $49.99 (onboarding-near hard page). No cancellations, refunds or renewals.
- Since change, paid: **5 Yearly $49.99, 5 Monthly, 2 passes $9.99** from 12 users. Gross $305.20 / proceeds about $259.42 at 85%. Excludes the 59952292 $39.99 renewal.
- Cancellations stay at 2 (095E482E Yearly within 18 s, 065B30BE Monthly within 12 min), both still paid. No refunds.
- 11 of 12 buyers fly within a week; 5 of 12 within 24 h.

**Segments since change** (n=110; small)
- By next_flight_window: 3d 4 of 15, 24h 5 of 31, week 1 of 17, later 1 of 44.
- By notifications: granted 10 of 66, not-now 0 of 30, denied 1 of 3.
- By source: social 6 of 48, app store 3 of 32, other 2 of 21, friend 0 of 6.
- By feeling: very anxious 5 of 26, nervous 2 of 16, calm 3 of 51, uneasy 1 of 15.
- By frequency: monthly-plus 6 of 45, few a year 4 of 45, yearly or less 1 of 17.
- **Later fliers (44):** 27 saved a flight, 9 came back on a second day, 3 opened a forecast-ready alert, 6 saw forecast-moment, 1 bought.
- 34 of the 103 users older than 30 h came back on a second day.

**Pro paywalls** (opens = users)

| Paywall / placement | 24h opens | Since Nov 3 21:30 opens | Purchases since |
|---|---|---|---|
| forecast-moment / first_grade_viewed | 3 | 23 | 0 |
| forecast-moment / forecast_ready_opened | 0 | 4 | 0 |
| forecast-moment / timeline_locked | 5 | 18 | **2 passes $9.99, 1 Monthly** |
| pro-features / upgrade_from_settings | 0 | 5 | Yearly $49.99 + Monthly |
| pro-features / pilot_reports_locked | 0 | 4 | Monthly |
| pro-features / live_activity_locked | 2 | 5 | 0 |
| pro-features / flight_limit_reached | 0 | 4 | 0 |
| pro-features / updates_locked | **1 (first ever)** | 1 | 0 |

- 0 transactions on Pro paywalls in 24h (2nd day running). timeline_locked: 3 of 18 openers bought, against 0 of 27 on first_grade_viewed and forecast_ready_opened.
- timeline_locked fired 15 times for 5 users in 24h: 24078B42 hit it 6 times overnight (plus live_activity_locked twice), 467E53A4 4 times in one minute. Neither bought.
- **updates_locked fired for the first time** (892724CF, 3d flier, via Has a flight 200212, pass shown as third product). Declined. Has a flight: 4 triggers in 24h, 7 since Nov 5, 0 passes from the link.
- Still never fired: update_opened, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Hold the near test one more viewer.** annual_or_pass is 2 Yearly from 9 viewers (22%), against 10% for the soft flow's onboarding users. At 10 viewers, decide whether to keep the hard page as the default for near fliers. No change needed now.
2. **Design review: add the $9.99 pass to the timeline page** (open from Nov 8, `superwall/paywalls/onboarding-near/components/soft.tsx`). No new evidence today: 2 timeline viewers, 0 bought.
3. Hold on Pro paywalls: 2 days with no Pro sale, but only 11 openers in 24h. Needs ~20 more timeline_locked openers before judging a change.

Task context is current (versions 8, 8, 24, 15, 14, 12; audience 201414).

## Day Wed Nov 11

Run at 17:11 UTC. 24h = Nov 10 17:11 → Nov 11 17:11. Excluded: 3 `$SuperwallAlias:` ids (7-day pull). No review devices, simulators or Lanre's phone. "Since change" totals = yesterday's plus today's 24h, because Nov 3 21:00 is now past the 7-day query cap.

**Health: OK. Watch: installs down to 1.**
- Campaigns match the setup:
  - 113534: 201414 (289001 100%) live; 200805 and 199841 paused.
  - 113535: 200113 skip → 199842 skip → 199843 forecast-moment 100%.
  - 113536: 200212 → 199276, both pro-features 100%.
- Versions: near v8, soft v8, hard v24, forecast-moment v15, pro-features v14, pass-first v12 (archived). All as expected.
- 24h: 10 triggers, 10 presented = 10 paywall opens (1 onboarding, 9 Pro), 0 held out, none missed. 0 webview, product-load or transaction failures, 0 `onboarding_fell_back`, 0 restore failures. processTerminated 19 (5 devices), harmless as before.
- Pricing: every open in 24h showed $49.99 Yearly, no trial, $9.99 pass. No trial transaction.
- **Installs: 1 in 24h** (yesterday 7, Nov 9 14). By day: Nov 7 20, Nov 8 16, Nov 9 10, Nov 10 3, Nov 11 1 so far. The one install got onboarding, so the flow isn't broken; traffic dried up. The Apple Ads "(Nov 10)" restart should be delivering, so worth a look in the ads review.
- Forecast-check failures before departure: 0 (no hard-offer relaunches). After-departure relaunches: still 0, index → plans still unmeasured.
- v8 hard-open fix: no new hard-page buyers, restorers or departed flights in 24h, nothing to check. Flag still true for 12 users (10DF3876 paid; E3416FFA's offer ran to its Nov 10 departure; the rest from before v8). 0 skips by 200113 in 24h.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 1 | 106 |
| Onboarding users | 1 (near) | 111 (79 near, 31 soft, 1 hard) |
| Reached source / find | 1 / 1 | 108 / 108 |
| Notifications page | 0 | 99 |
| Tapped Add flight | 0 | 84 |
| Saved a flight in the flow | 0 | 56 |
| Flight page / Plans page | 0 / 0 | 52 / 51 |
| Notifications granted / not-now / denied | 0 / 0 / 0 | 66 / 30 / 3 |
| Median feeling→source | 85 s (n=1) | ~30 s |
| Onboarding purchases | 0 | 6 paid + 1 trial |

- The one user, B56D18A1 (app 1.0.3, iPhone17,1, nervous, monthly-plus, **24h flier**, social), went back and forth through feeling/reassure/how/help several times, reached Find at 11:39 and left the app 45 s later without adding a flight. Not seen since.

**Near-flier test (289001, since Nov 4 23:50, 79 users)**
- No new hard-offer viewers in 24h. annual_or_pass stays **2 Yearly from 9 viewers, 0 passes**. Trial arm: no change, closed.
- Relaunches that got the hard offer again: 0 in 24h, 3 ever.
- Timeline soft page: 0 new viewers, 0 sales in 24h; 1 sale ever (6692D835).
- Cap 199842: 0 skips in 24h, 5 ever. 200113: 0 in 24h, 4 ever.
- Cohort paid: near 8 of 79 (10%), soft 3 of 31 (10%).

**Purchases**
- 24h: none. No cancellations, refunds or renewals.
- Since change, paid: 5 Yearly $49.99, 5 Monthly, 2 passes $9.99 from 12 users. Gross $305.20 / proceeds about $259.42 at 85%. Unchanged.

**Segments since change** (n=111; small; only change is the one new 24h flier)
- By next_flight_window: 3d 4 of 15, 24h 5 of 32, week 1 of 17, later 1 of 44.
- Later fliers: not recomputed (no new later fliers).

**Pro paywalls** (24h; 7-day columns are Nov 4 17:00 → now)

| Paywall / placement | 24h opens (users) | 7d opens | 7d purchases |
|---|---|---|---|
| forecast-moment / first_grade_viewed | 1 | 21 | 0 (1 pass abandoned) |
| forecast-moment / forecast_ready_opened | 2 | 3 | 0 |
| forecast-moment / timeline_locked | 1 | 16 | 2 passes $9.99, 1 Monthly |
| pro-features / live_activity_locked | 2 | 5 | 0 |
| pro-features / pilot_reports_locked | 1 | 3 | 1 Monthly |
| pro-features / flight_limit_reached | 1 (AB054BCB, twice) | 4 | 0 |
| pro-features / upgrade_from_settings | 0 | 5 | Yearly + Monthly |
| pro-features / updates_locked | 0 | 1 | 0 |

- 5 users, 9 opens, 0 transactions (3rd day without a Pro sale). All existing users from Nov 8–9 installs, plus AB054BCB (the Nov 2 pass refund).
- Still never fired: update_opened, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Hold everything.** 1 new user in 24h gives no signal on onboarding, the near test (needs 1 more hard-offer viewer to reach 10) or Pro paywalls (~20 more timeline_locked openers).
2. **Check why installs fell to 1/day** (ads review, not a paywall change): Apple Ads "(Nov 10)" restart should be running; with no traffic, none of these tests move.
3. Design review: $9.99 pass on the timeline page (open since Nov 8, `superwall/paywalls/onboarding-near/components/soft.tsx`). No new evidence.

Task context is current (versions 8, 8, 24, 15, 14, 12; audience 201414).

## Day Thu Nov 12

Run at 17:12 UTC. 24h = Nov 11 17:00 → Nov 12 17:12. Excluded: 4 `$SuperwallAlias:` ids. No review devices, simulators or Lanre's phone. "Since change" = yesterday's totals + today's 24h (Nov 3 21:00 is past the 7-day cap). Pro 7-day columns = Nov 5 17:00 → now.

**Health: OK.**
- Campaigns match the setup:
  - 113534: 201414 (289001 100%) live; 200805 and 199841 paused.
  - 113535: 200113 skip → 199842 skip → 199843 forecast-moment 100%.
  - 113536: 200212 → 199276, both pro-features 100%.
- Versions: near v8, soft v8, hard v24, forecast-moment v15, pro-features v14, pass-first v12 (archived). All as expected.
- 24h: 18 triggers = 16 presented (7 onboarding, 9 Pro) + 2 `no_rule_match` for C25B9E04, 0 held out. 0 webview, product-load, transaction or restore failures. processTerminated 27 (5 devices), harmless as before.
- `onboarding_fell_back` 1: C25B9E04 (iPad8,12, new install) already had an active `pro` entitlement (bumpcast_pro_annual since Oct 28, so a Trybe comp, family share or reinstall). The no-entitlement rule correctly skipped the paywall; they answered the native questions and added DFW→HND. Not a problem.
- Pricing: every open in 24h showed $49.99 Yearly, no trial, $9.99 pass. All 4 purchases periodType NORMAL. No trial transaction.
- Installs back up: **6 in 24h** (yesterday 1).
- Forecast-check failures before departure: **0**. E68187E4 relaunched 30 s after their first hard view (JFK→LAX, leaves today 22:59 UTC): index → checking → flight with a flight result. Still 0 since v7.
- After-departure relaunches: still 0 (E3416FFA no opens). E68187E4 is the next chance after 22:59 UTC tonight.
- v8 hard-open fix: no hard-page buyers, restorers or departed flights in 24h. E68187E4 true is correct (offer open). Today's two onboarding buyers bought on Plans and have no flag. 0 skips by 200113.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 6 | 112 |
| Onboarding users (paywall) | 6 (5 new + 8D8CCC4B restarting, all near) | 116 (84 near, 31 soft, 1 hard) |
| Reached source / find | 4 / 4 | 112 / 112 |
| Notifications page | 4 | 103 |
| Tapped Add flight in the flow | 1 | 85 |
| Saved a flight in the flow | 1 | 57 |
| Flight page / Plans page | 1 / 3 | 53 / 54 |
| Notifications granted / not-now / denied | 3 / 1 / 0 | 69 / 31 / 3 |
| Median feeling→source | 35 s (n=4) | ~30 s |
| Onboarding purchases | **2 paid** | 8 paid + 1 trial |

- BAB17CF0 (new) and 8D8CCC4B (Nov 5 install) both quit after the feeling page, 2 minutes apart.
- 3 of 4 who reached Find skipped adding a flight and went to Plans; 2 of those 3 bought there.

**Near-flier test (289001, since Nov 4 23:50, 84 users)**
- **Hard offer reached 10 real viewers.** New: E68187E4 (calm, monthly-plus, 24h, app store, granted; JFK→LAX ~19 h out). Started Yearly, abandoned after 4 s, no buy yet; offer open until 22:59 UTC.
- annual_or_pass: **2 Yearly from 10 viewers (20%), 0 passes.** Trial arm: no change.
- Relaunches that got the hard offer again: 1 in 24h (E68187E4), 4 ever.
- Timeline soft page: 0 new viewers in 24h. 1 timeline sale ever (6692D835). But 8954E777, a timeline-page viewer from Nov 5, bought a $9.99 pass on forecast-moment today.
- Cap 199842: 0 skips in 24h, 5 ever. 200113: 0 in 24h, 4 ever.
- Cohort paid: near **11 of 84** (13%), soft 3 of 31 (10%).

**Purchases**

| User | Product | Price | Where | From install | Answers |
|---|---|---|---|---|---|
| 8D9BE4F6 (GB) | Monthly | £ (= $9.28) | onboarding-near **Plans**, no flight | 1.5 min | uneasy, monthly-plus, week, social, not-now; added MAN→JFK right after |
| 762FE51C | **Yearly $49.99** | $49.99 | onboarding-near **Plans**, no flight | 53 s | very anxious, monthly-plus, **later**, social, granted |
| 8954E777 | **Pass $9.99** | $9.99 | forecast-moment / timeline_locked | 7 days | very anxious, few-a-year, 3d, social, granted; added LAX→SLC 2 min before |
| AB054BCB | Monthly | $6.99 | forecast-moment / timeline_locked (4th open in an hour) | 14 days | very anxious, yearly-or-less, 3d, app store, not-now; Nov 2 pass refunder; declined updates_locked too |

- No cancellations, refunds or renewals in 24h.
- Since change, paid: **6 Yearly, 7 Monthly, 3 passes from 16 users.** Gross ~$381.45 / proceeds ~$324 at 85%.
- Best Superwall day so far: 4 buyers.

**Segments since change** (n=116; small; yesterday's counts + today)
- By next_flight_window: 3d 5 of 15, 24h 5 of 33, week 2 of 18, **later 2 of 46** (762FE51C is the 2nd later-flier buyer, on Plans without a flight).
- By notifications: granted 12 of 69, not-now **1 of 31** (first not-now buyer), denied 1 of 3.
- By feeling: very anxious 7 of 27, uneasy 2 of 16, nervous 2 of 17, calm 3 of 52.
- By source: social 9 of 51, app store 3 of 33, other 2 of 21, friend 0 of 6.
- Later fliers: not recomputed beyond the 2 new (762FE51C bought, 91996DF1 declined Plans).

**Pro paywalls**

| Paywall / placement | 24h opens (users) | 7d openers | 7d buyers |
|---|---|---|---|
| forecast-moment / first_grade_viewed | 1 (1) | 15 | **0** |
| forecast-moment / forecast_ready_opened | 0 (fired once, already presented) | 2 | 0 |
| forecast-moment / timeline_locked | 7 (3) | 13 | **4** (2 passes, 2 Monthly) |
| pro-features / updates_locked | 1 (AB054BCB) | 2 | 0 |
| pro-features / live_activity_locked | 0 | 5 | 0 |
| pro-features / flight_limit_reached | 0 | 3 | 0 |
| pro-features / upgrade_from_settings | 0 | 3 | 0 |
| pro-features / pilot_reports_locked | 0 | 1 | 0 |

- Pro sales back after 3 days: 2 in 24h, both on timeline_locked.
- 7 days: timeline_locked 4 of 13 openers bought (31%); first_grade_viewed 0 of 15.
- Has a flight (200212): 1 trigger (AB054BCB updates_locked), declined, 0 passes from the link.
- Still never fired: update_opened, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Near test decision (10 viewers reached): keep the hard page for near fliers.** 2 Yearly from 10 hard viewers (20%) vs 10% for soft-flow onboarding users. No setting changes; rename 201414 to drop "test" if you want it to read as the default. Recheck after E68187E4's departure tonight.
2. **Test a 50% holdout on first_grade_viewed** (campaign 113535, new "[12/11] Claude v1 Review - first grade holdout" audience above 199843). 0 of 15 bought there in 7 days (0 of ~23 since Nov 3) while timeline_locked converts 4 of 13. Expected: fewer early dismissals before people hit the timeline, without lost sales. Check timeline_locked conversion by arm after ~30 users.
3. Design review: $9.99 pass on the timeline onboarding page (`superwall/paywalls/onboarding-near/components/soft.tsx`). New weak evidence: a timeline-page viewer bought a pass a week later.

Task context is current (versions 8, 8, 24, 15, 14, 12; audience 201414).

## Day Fri Nov 13

Run at 18:11 UTC. 24h = Nov 12 18:11 → Nov 13 18:11. Excluded: 5 `$SuperwallAlias:` ids in 24h (49 in the 7-day pull). No review devices, simulators or Lanre's phone. "Since change" = yesterday's totals + today's 24h (Nov 3 21:00 is past the 7-day cap). Pro 7-day columns = Nov 6 18:00 → now.

**Health: OK.**
- Campaigns match the setup:
  - 113534: 201414 (289001 100%) live; 200805 and 199841 paused.
  - 113535: 200113 skip → 199842 skip → 199843 forecast-moment 100%.
  - 113536: 200212 → 199276, both pro-features 100%.
- Versions: near v8, soft v8, hard v24, forecast-moment v15, pro-features v14, pass-first v12 (archived). All as expected.
- 24h: 11 triggers, 11 presented (5 onboarding, 6 Pro), 0 held out, none missed. 0 webview, product-load, transaction or restore failures. processTerminated 11 (5 devices), harmless as before. 4 `paywallProductsLoad_retry` were background preloads for 8D9BE4F6 (a subscriber, no paywall shown).
- Pricing: every open in 24h showed $49.99 Yearly, no trial, $9.99 pass. Both purchases periodType NORMAL. No trial transaction.
- `onboarding_fell_back` 1: AEECADCC (bought Monthly yesterday) got the onboarding again today, fell back with reason `offline` and finished the native flow. They're a subscriber, so no paywall was due. Not a problem; noted because a paying user re-entering onboarding is odd.
- Forecast-check failures before departure: **0**. F28DF23E relaunched 1.5 min after their first hard view: index → checking → flight in 3 s with a flight result. Still 0 since v7.
- After-departure relaunches: **still 0.** E68187E4 (left Nov 12 22:59) and F28DF23E (left Nov 13 16:55) haven't opened since. index → plans still unmeasured.
- v8 hard-open fix: no hard-page buyers, restorers or departed flights in 24h. E68187E4 and F28DF23E still true (offer expired, but the flag clears only when the flow restarts, and they haven't relaunched). Expected, not a v8 failure. 0 skips by 200113.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 4 | 116 |
| Onboarding users (paywall) | 4 (all near) | 120 (88 near, 31 soft, 1 hard) |
| Reached source / find | 4 / 4 | 116 / 116 |
| Notifications page | 4 | 107 |
| Saved a flight in the flow | 3 | 60 |
| Flight page / Plans page | 3 / 1 | 56 / 55 |
| Notifications granted / not-now / denied | **0 / 4 / 0** | 69 / 35 / 3 |
| Median feeling→source | 22 s (n=4) | ~30 s |
| Onboarding purchases | **1 paid** | 9 paid + 1 trial |

- Good flow day: 4 of 4 reached Find, 3 of 4 saved a flight.
- All 4 picked "not now" on notifications (usual rate ~30%). n=4, likely noise; AEECADCC granted later from Add flight. Watch tomorrow.
- next_flight_window: 24h 3, week 1.

**Near-flier test (289001, since Nov 4 23:50, 88 users)**
- **Hard offer: 11 real viewers.** New: F28DF23E (nervous, yearly-or-less, 24h, social, not-now; ISP→RSW ~14 h out). Saw it twice (relaunch), no purchase attempt. E68187E4 (yesterday) left without buying.
- annual_or_pass: **2 Yearly from 11 viewers (18%), 0 passes.** Last 3 viewers: 0 buys. Trial arm: no change.
- Relaunches that got the hard offer again: 1 in 24h (F28DF23E), 5 ever.
- Timeline soft page: 2 new viewers (67D4544A YYC→OGG 29 h out; 06A899D3 week flier, forecast too early), 0 bought on the page. But **6913763D, a timeline-page viewer from Nov 8, bought Monthly on forecast-moment today**: the 2nd timeline-page viewer to buy later on Pro (8954E777 yesterday).
- Cap 199842: 0 skips in 24h, 5 ever. 200113: 0 in 24h, 4 ever.
- Cohort paid: near **13 of 88** (15%), soft 3 of 31 (10%).

**Purchases**

| User | Product | Price | Where | From install | Answers |
|---|---|---|---|---|---|
| AEECADCC | Monthly | $6.99 | onboarding-near **Plans**, no flight | 40 s | uneasy, few-a-year, 24h, app store, not-now (in-flow answers); then added 9+ flights in 3 h (crew-like use) |
| 6913763D | Monthly | $6.99 | forecast-moment / timeline_locked (2nd open, 10 s after the 1st) | 4.8 days | very anxious, yearly-or-less, 3d, social, granted; saw timeline page Nov 8 |

- No cancellations, refunds or renewals in 24h.
- Since change, paid: **6 Yearly, 9 Monthly, 3 passes from 18 users.** Gross ~$395.43 / proceeds ~$336 at 85%.
- 3rd Plans-page buyer in 2 days (8D9BE4F6, 762FE51C, AEECADCC): all skipped adding a flight and bought within 2 min of install.

**Segments since change** (n=120; small; carried forward + today)
- By next_flight_window: 3d 6 of 15, 24h 6 of 36, week 2 of 19, later 2 of 46.
- By notifications: granted 13 of 69, not-now 2 of 35, denied 1 of 3.
- By feeling: very anxious 8 of 27, uneasy 3 of 17, nervous 2 of 20, calm 3 of 52.
- By source: social 10 of 52, app store 4 of 34, other 2 of 23, friend 0 of 6.
- Later fliers: no new later fliers; still 2 of 46.

**Pro paywalls**

| Paywall / placement | 24h opens (users) | 7d openers | 7d buyers |
|---|---|---|---|
| forecast-moment / timeline_locked | 4 (2) | 14 | **5** (2 passes, 3 Monthly) |
| forecast-moment / first_grade_viewed | 0 (didn't fire) | 13 | **0** |
| forecast-moment / forecast_ready_opened | 2 (2) | 4 | 0 |
| pro-features / live_activity_locked | 0 | 5 | 0 |
| pro-features / flight_limit_reached | 0 | 3 | 0 |
| pro-features / upgrade_from_settings | 0 | 2 | 0 |
| pro-features / updates_locked | 0 | 2 | 0 |
| pro-features / pilot_reports_locked | 0 | 1 | 0 |

- 7 days: timeline_locked **5 of 14 openers bought (36%)**; first_grade_viewed 0 of 13; every other placement 0 of 17.
- 24h declines: 67D4544A (timeline_locked, 3 min after onboarding), D0B7BB36 and 3BDAC7E9 (forecast_ready_opened, 3 s and 36 s).
- Has a flight (200212): 0 triggers in 24h. Still never fired: update_opened, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Still open from yesterday: 50% holdout on first_grade_viewed** (campaign 113535, new "[13/11] Claude v1 Review - first grade holdout" audience above 199843, event first_grade_viewed, holdout 50 / forecast-moment 50). Evidence stronger: 0 of 13 there vs 5 of 14 on timeline_locked in 7 days. Expected: no lost sales, fewer early dismissals. Read timeline_locked conversion by arm after ~30 users.
2. **Near test: keep the hard page, but stop calling it a win.** 2 of 11 (18%) with the last 3 viewers at 0. Soft-flow onboarding users are 10%; the near cohort overall is 15% (much of it from Plans and Pro). No change; recheck at 15 viewers.
3. **Hold the timeline-page pass idea** (`superwall/paywalls/onboarding-near/components/soft.tsx`): timeline viewers are buying later on timeline_locked (2 in 2 days), so the page may be doing its job by leading into the app. No change.

Task context is current (versions 8, 8, 24, 15, 14, 12; audience 201414).

## Day Sat Nov 14

Run at 17:11 UTC. 24h = Nov 13 17:00 → Nov 14 17:11. Excluded: 1 `$SuperwallAlias:` id and EA298607 (Lanre's own account, opened onboarding-soft preload only). No review devices, simulators or Lanre's phone. "Since change" = yesterday's totals + today's 24h. Pro 7-day columns = Nov 7 17:00 → now.

**Health: OK.**
- Campaigns match the setup:
  - 113534: 201414 (289001 100%) live; 200805 and 199841 paused.
  - 113535: 200113 skip → 199842 skip → 199843 forecast-moment 100%.
  - 113536: 200212 → 199276, both pro-features 100%.
- Versions: near v8, soft v8, hard v24, forecast-moment v15, pro-features v14, pass-first v12 (archived). All as expected.
- 24h: 7 triggers, 7 presented (3 onboarding, 4 Pro), 0 held out, none missed. 0 webview, product-load or transaction failures. 1 `restore_fail` (EAF16DB3, Settings restore with nothing to restore; then opened upgrade_from_settings and left). processTerminated 26 (8 devices), harmless as before.
- Pricing: every open in 24h showed $49.99 Yearly, no trial, $9.99 pass. No transactions at all, so no trial.
- Forecast-check failures before departure: **0** (no before-departure relaunches today). Still 0 since v7.
- After-departure relaunches: **still 0 measured.** E68187E4, F28DF23E and AAF78A05 haven't reopened since their flights left.
- v8 hard-open fix: no hard-page buyers, restorers or departed flights in 24h. AAF78A05 true (flight left 13:20 today, no relaunch yet), expected. 3E11602F (Nov 10 hard buyer) still false. 0 skips by 200113.
- **Watch: 2nd paying user re-entering onboarding.** 3E11602F (Yearly since Nov 10, uses the app daily) logged `onboarding_fell_back` reason `offline` at 00:56 today, same as AEECADCC yesterday (Monthly buyer). Both bought inside the onboarding paywall. Looks like an in-flow purchase may not mark onboarding as done in the app, so a later launch starts the onboarding loader again (`ios/BumpCast/Services/Onboarding.swift` fallBack path). Harmless when online (no-entitlement rule skips the paywall), but worth a code check. Not verified.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 3 | 119 |
| Onboarding users (paywall) | 3 (all near, all new) | 123 (91 near, 31 soft, 1 hard) |
| Reached source / find | 3 / 3 | 119 / 119 |
| Notifications page | 2 | 109 |
| Saved a flight in the flow | 1 | 61 |
| Flight page / Plans page | 1 / 1 | 57 / 56 |
| Notifications granted / not-now / denied | 2 / 0 / 0 | 71 / 35 / 3 |
| Median feeling→source | 33 s (n=3) | ~30 s |
| Onboarding purchases | **0** | 9 paid + 1 trial |

- 3C605CAA (later flier) tapped Add flight on Find and stopped there (no flight saved, no further events).
- D0875B68 (later flier) skipped adding, declined Plans in 6 s, then tapped Add flight in the app.
- Notifications back to normal: 2 of 2 granted (yesterday 0 of 4).

**Near-flier test (289001, since Nov 4 23:50, 91 users)**
- **Hard offer: 12 real viewers.** New: AAF78A05 (calm, few-a-year, 24h, social, granted; EWR→POP, ~18 h out). Saw the flight page, no purchase attempt, didn't reopen before departure.
- annual_or_pass: **2 Yearly from 12 viewers (17%), 0 passes.** Last 4 viewers: 0 buys, 0 transaction starts. Trial arm: no change.
- Relaunches that got the hard offer again: 0 in 24h, 5 ever.
- Timeline soft page: 0 new viewers. 58A51583 (timeline viewer, week flier) hit first_grade_viewed (declined 19 s) and timeline_locked today, no buy.
- Cap 199842: 0 skips in 24h, 5 ever. 200113: 0 in 24h, 4 ever.
- Cohort paid: near **13 of 91** (14%), soft 3 of 31 (10%).

**Purchases**
- **0 purchases in 24h** (first zero day since Nov 10).
- **Cancellation: AEECADCC turned off renewal on Monthly $6.99** at 01:33 today, ~30 h after buying on Plans (reason UNSUBSCRIBE). Uneasy, few-a-year, 24h, app store, not-now. They added 9+ flights in 3 h on day one (crew-like use). Pro stays active to the end of the month.
- Since change, paid: 6 Yearly, 9 Monthly (1 now cancelling), 3 passes from 18 users. Gross ~$395.43 / proceeds ~$336 at 85%.

**Segments since change** (n=123; small; carried forward + today)
- By next_flight_window: 3d 6 of 15, 24h 6 of 37, week 2 of 19, later **2 of 48**.
- By notifications: granted 13 of 71, not-now 2 of 35, denied 1 of 3.
- By feeling: very anxious 8 of 28, uneasy 3 of 18, nervous 2 of 20, calm 3 of 53.
- By source: social 10 of 53, app store 4 of 36, other 2 of 23, friend 0 of 6.
- Later fliers: 2 new, 0 flights saved in the flow, 0 bought.

**Pro paywalls**

| Paywall / placement | 24h opens (users) | 7d openers | 7d buyers |
|---|---|---|---|
| forecast-moment / timeline_locked | 2 (2) | 13 | **5** |
| forecast-moment / first_grade_viewed | 1 (1) | 11 | **0** |
| forecast-moment / forecast_ready_opened | 0 | 4 | 0 |
| pro-features / live_activity_locked | 0 | 5 | 0 |
| pro-features / upgrade_from_settings | 1 (EAF16DB3) | 3 | 0 |
| pro-features / updates_locked | 0 | 2 | 0 |
| pro-features / flight_limit_reached | 0 | 2 | 0 |
| pro-features / pilot_reports_locked | 0 | 1 | 0 |

- 24h: 4 opens, 0 transaction starts. C3A8C2FA declined timeline_locked in 4 s; 58A51583 declined first_grade_viewed in 19 s.
- 7 days: timeline_locked 5 of 13 openers bought (38%); first_grade_viewed 0 of 11; all other placements 0 of 17.
- Has a flight (200212): 0 triggers. Still never fired: update_opened, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Still open: 50% holdout on first_grade_viewed** (campaign 113535, new "[14/11] Claude v1 Review - first grade holdout" audience above 199843, event first_grade_viewed, holdout 50 / forecast-moment 50). Evidence unchanged in direction: 0 of 11 vs timeline_locked 5 of 13 in 7 days. Read timeline_locked conversion by arm after ~30 users.
2. **Check whether an in-onboarding purchase marks onboarding done** (`ios/BumpCast/Services/Onboarding.swift`): 2 paying users (3E11602F, AEECADCC) re-entered the onboarding loader on later launches. Read-only check in your session; app update only if confirmed.
3. **Near test: hold.** 2 of 12 (17%), 0 of the last 4. No change; recheck at 15 viewers.

Task context is current (versions 8, 8, 24, 15, 14, 12; audience 201414).

## Day Sun Nov 15

Run at 17:12 UTC. 24h = Nov 14 17:00 → Nov 15 17:12. Excluded: 2 `$SuperwallAlias:` ids. No review devices, simulators or Lanre's phone. "Since change" = yesterday's totals + today's 24h. Pro 7-day columns = Nov 8 17:00 → now (so Nov 7–8 buyers dropped out of the window).

**Health: OK.**
- Campaigns match the setup:
  - 113534: 201414 (289001 100%) live; 200805 and 199841 paused.
  - 113535: 200113 skip → 199842 skip → 199843 forecast-moment 100%.
  - 113536: 200212 → 199276, both pro-features 100%.
- Versions: near v8, soft v8, hard v24, forecast-moment v15, pro-features v14, pass-first v12 (archived). All as expected.
- 24h: 7 triggers, 7 presented (2 onboarding, 5 Pro), 0 held out, none missed. 0 webview, product-load, transaction or restore failures. processTerminated 14 (4 devices), harmless as before.
- 2 `paywallProductsLoad_missingProducts` for 59952292 (a subscriber) right after a `sync_failed offline=true`: background preload with no network, no paywall shown. Not a problem. 6 `paywallProductsLoad_retry` were background preloads for 3E11602F (subscriber), as on Nov 13.
- Pricing: every open in 24h showed $49.99 Yearly, no trial, $9.99 pass. No transactions at all, so no trial.
- **Installs: 1 in 24h** (0E05BFF9, Apple Search Ads). Lowest since Nov 11. Onboarding opened for them, so not BROKEN; traffic is the constraint.
- Forecast-check failures before departure: **0**. 0E05BFF9 relaunched 10 h after their first hard view: index → checking → flight in 3 s with a `ready` flight result. Still 0 since v7.
- After-departure relaunches: **still 0 measured.** E68187E4, F28DF23E, AAF78A05 and now 0E05BFF9 (left 12:30 UTC today) haven't reopened since departure.
- v8 hard-open fix: no hard-page buyers, restorers or departed flights in 24h. 0E05BFF9 true (offer was open; flight left today, no relaunch yet), expected. 0 skips by 200113.
- Onboarding re-entry by payers (yesterday's watch): **0 `onboarding_fell_back` in 24h.** No new case.

**Onboarding funnel**

| | 24h | Since change (Nov 3 21:00) |
|---|---|---|
| Installs | 1 | 120 |
| Onboarding users (paywall) | 1 (near, new) | 124 (92 near, 31 soft, 1 hard) |
| Reached source / find | 1 / 1 | 120 / 120 |
| Notifications page | 1 | 110 |
| Saved a flight in the flow | 1 | 62 |
| Flight page / Plans page | 1 / 0 | 58 / 56 |
| Notifications granted / not-now / denied | 1 / 0 / 0 | 72 / 35 / 3 |
| Median feeling→source | 30 s (n=1) | ~30 s |
| Onboarding purchases | **0** | 9 paid + 1 trial |

- 0E05BFF9 (nervous, few-a-year, 24h, social, granted) went through every page in 46 s to Find, added JNB→BFN (16 h out), saw the hard page. No purchase attempt.

**Near-flier test (289001, since Nov 4 23:50, 92 users)**
- **Hard offer: 13 real viewers.** New: 0E05BFF9. Saw it at 20:03 and again on relaunch at 06:22 (before departure). 0 transaction starts.
- annual_or_pass: **2 Yearly from 13 viewers (15%), 0 passes.** Last 5 viewers: 0 buys, 0 transaction starts. Trial arm: no change (96972F16, a trial-arm viewer, re-synced Pro status today; it's their Monthly from Nov 5, still active, no new transaction).
- Relaunches that got the hard offer again: 1 in 24h (0E05BFF9), 6 ever.
- Timeline soft page: 0 new viewers.
- Cap 199842: 0 skips in 24h, 5 ever. 200113: 0 in 24h, 4 ever.
- Cohort paid: near **13 of 92** (14%), soft 3 of 31 (10%).

**Purchases**
- **0 purchases in 24h** (2nd zero day in a row). No cancellations, refunds or renewals. Next renewals due: 81AACD37 Monthly ~Nov 30, 600E3E84 ~Dec 3.
- Since change, paid: 6 Yearly, 9 Monthly (1 cancelling, AEECADCC), 3 passes from 18 users. Gross ~$395.43 / proceeds ~$336 at 85%.

**Segments since change** (n=124; small; carried forward + today)
- By next_flight_window: 3d 6 of 15, 24h 6 of 38, week 2 of 19, later 2 of 48.
- By notifications: granted 13 of 72, not-now 2 of 35, denied 1 of 3.
- By feeling: very anxious 8 of 28, uneasy 3 of 18, nervous 2 of 21, calm 3 of 53.
- By source: social 10 of 54, app store 4 of 36, other 2 of 23, friend 0 of 6.
- Later fliers: 0 new. Two earlier later fliers came back today (CC471AAF first_grade_viewed, 3BDAC7E9 live_activity_locked ×2), both declined. Still 2 of 48 bought.

**Pro paywalls**

| Paywall / placement | 24h opens (users) | 7d openers | 7d buyers |
|---|---|---|---|
| forecast-moment / timeline_locked | 1 (1) | 12 | **3** (1 pass, 2 Monthly) |
| forecast-moment / first_grade_viewed | 1 (1) | 11 | **0** |
| forecast-moment / forecast_ready_opened | 0 | 4 | 0 |
| pro-features / live_activity_locked | 3 (2) | 7 | 0 |
| pro-features / updates_locked | 0 | 2 | 0 |
| pro-features / flight_limit_reached | 0 | 2 | 0 |
| pro-features / upgrade_from_settings | 0 | 1 | 0 |
| pro-features / pilot_reports_locked | 0 | 1 | 0 |

- 24h: 5 opens, 0 transaction starts. 86C919AE (very anxious, week, soft) declined live_activity_locked in 3 s, then timeline_locked in 7 s. 3BDAC7E9 declined live_activity_locked twice (6 s, 4 s). CC471AAF declined first_grade_viewed in 25 s.
- 7 days: timeline_locked 3 of 12 openers bought (25%); first_grade_viewed 0 of 11; all other placements 0 of 17.
- **Correction:** Has a flight (200212) is experiment 200369 in events. It did get traffic: 3 live_activity_locked opens in 24h (12 opens on 200369 in 7 days: live_activity_locked 10, updates_locked 2), 0 pass buys. Earlier entries said "0 triggers" there; that was wrong for live_activity_locked.
- Still never fired: update_opened, live_status_locked, email_import_locked.

**Recommendations (need Lanre's OK)**
1. **Still open: 50% holdout on first_grade_viewed** (campaign 113535, new "[15/11] Claude v1 Review - first grade holdout" audience above 199843, event first_grade_viewed, holdout 50 / forecast-moment 50). 0 of 11 there vs timeline_locked 3 of 12 in 7 days. Read timeline_locked conversion by arm after ~30 users.
2. **Still open: check whether an in-onboarding purchase marks onboarding done** (`ios/BumpCast/Services/Onboarding.swift`). No new case today; 2 known (3E11602F, AEECADCC).
3. **Near test: hold.** 2 of 13 (15%), 0 of the last 5. Traffic (1 install today) is now the limit, not the paywall; recheck at 15 viewers.

Task context is current (versions 8, 8, 24, 15, 14, 12; audience 201414).
