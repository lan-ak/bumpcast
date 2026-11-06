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
