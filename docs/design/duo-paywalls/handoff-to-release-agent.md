# iPhone Duo paywalls: hand-off to the 1.0.4 release agent

iPhone Duo paywalls (and the onboarding flight pass removal): the paywall side is LIVE in Superwall since Nov 1, published ahead of 1.0.4 at Lanre's request. The app side is in 1.0.4, uncommitted on main. Please add this to the 1.0.4 ledger. It replaces my earlier note.

LIVE IN SUPERWALL (Nov 1, Lanre's yes)
- onboarding v21, onboarding-soft v5, pro-features v11, pro-features-pass-first v10, forecast-moment v12.
- Safe for 1.0.3 and earlier: the Duo rules only match the open Duo (min-width 800 and min-height 560, which no iPhone reaches), and the side insets only take effect when the app sends them.

WHAT CHANGED
- Onboarding no longer sells the flight pass. Closing the App Store sheet on Yearly offers the 7-day trial ("Need more time?"); declining it, or closing on Monthly, does nothing more. The pass-offer page is deleted, along with its messages and the `pass` product slot on both onboarding paywalls. SUPERWALL.md and docs/superwall/onboarding-hard-vs-soft.sql are reworded to match.
- Open Duo (and partly open, which has the same 951 × 669 geometry): two columns either side of the 40 pt fold (455.5–495.5). Question pages put the sunrise on the left and the page on the right. Plans, the flight paywall and the three Pro paywalls put the headline (and ticket) in the sky on the left, with a solid white panel from the fold to the screen edge on the right. Nothing sits on the fold or under the status column.
- Duo insets, measured on the simulator: top 0, right 84, bottom 34, left 0, both open and closed (the status bar sits in an 84 pt right column). The fold is measured in vw, from the screen edge. Two CSS switches that are 0 on every iPhone: `--top-gap` (24 pt of room at the top, only with no top and no left inset) and `--duo-column` (the right inset, only with no left inset). Plans, the flight paywall, the Pro paywalls and "Need more time?" run under the column with their content clear of it.
- App (1.0.4): Paywalls.swift `shareSafeArea()` sends safe_area_top/right/bottom/left as user attributes, only when they change, at onboarding start and before every paywall. New shared hook superwall/components/safe-area.ts (onboarding uses all four edges; Pro paywalls only left/right). In `willPresentPaywall`, on the open Duo (regular × regular), the app sets `traitOverrides.horizontalSizeClass = .compact` on Superwall's own presenting window. It's created per presentation, so the app behind keeps its layout, and the modal paywall becomes a full-width sheet instead of a 650 pt card over the fold. (`register()` can't override the presentation, and `prefersPageSizing` set after present didn't apply; both were tried.) Onboarding.swift calls `shareSafeArea()`. Paywalls.swift also has the $9.99 pass session's edits, untouched.

FILES (uncommitted on main)
superwall/components/pro/{paywall.tsx, theme.css}, superwall/components/safe-area.ts (new), superwall/paywalls/forecast-moment/app/ticket.css, superwall/paywalls/onboarding/{app/flight.tsx, app/layout.tsx, app/theme.css, components/flight.ts, components/variant.ts, config.ts, messages/en.ts}, onboarding/app/pass-offer.tsx and onboarding-soft/app/pass-offer.tsx (deleted), superwall/paywalls/onboarding-soft/{app/layout.tsx, config.ts}, superwall/superwall.d.ts and superwall.lock (generated), SUPERWALL.md, docs/superwall/onboarding-hard-vs-soft.sql, ios/BumpCast/Services/{Paywalls.swift, Onboarding.swift}. Mockups and this note: docs/design/duo-paywalls/ (untracked).

CHECKED
- Default iPhone look unchanged, proven against the committed paywalls: a second studio ran `git archive HEAD superwall`, and every visible element's position and size was compared, with animations off, at 375×667 (top 20), 393×852 (59/34), 440×956 (62/34) and 852×393 sideways (0/59/21/59). That covered all 10 onboarding pages, the 3-day path (flight search, check, flight paywall), and all three Pro paywalls including "More options" expanded. All identical. The only differences seen were timing artifacts (a hidden sunrise mid-animation, and the brand font not yet loaded in one run).
- Duo audits in the studio with the real insets, closed (466×678) and open (951×669): every onboarding page, the 3-day path, all three Pro paywalls (collapsed and expanded) and "Need more time?". Checked: nothing on the fold, nothing under the column, nothing within 16 pt of the top, the back button clear of the question, no scrolling. All pass, except Pro features closed scrolls about 97 pt, which is in line with today's iPhone SE (74 pt).
- On the Duo simulator 6AD769BC… (open), with a fresh install: the onboarding from welcome through Plans, and Pro features from Settings opening as a full-width sheet. App tests: 133/133 pass. Debug build succeeds.

NOT CHECKED
- The closed Duo in the app itself (folding needs Lanre in Device Hub); it was checked in the studio with the real insets.
- In the app on the Duo: the flight paywall, the forecast moment and "Need more time?" (checked in the studio with stubbed flight data).

STILL TO DO FOR 1.0.4
1. On a 1.0.4 build: the open Duo's Pro paywalls and forecast moment open full width; closed, everything clears the camera column.
2. Commit the files above with the release.

NOTICED, NOT PAYWALLS (for the Duo app work)
- The app's own Settings sheet is still a centred card across the fold on the open Duo.
- The native onboarding fallback ("Know what your flight will feel like.") spans the fold on the open Duo.
- On a reinstall the keychain keeps the old account, so a forecast moment can open before the onboarding, which then falls back to the native one.

Also: the onboarding rename to "· hard" / "· soft" on your ledger is done (Nov 1, commit 2bcf5db).
