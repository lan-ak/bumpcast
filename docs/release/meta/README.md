# BumpCast on Meta: daily review

The plan Lanre approves: https://claude.ai/artifact/JqUXBSzb479APPPp4pkpiQ. This folder is how it runs.

| File | What it is |
|---|---|
| `config.json` | IDs, budgets, the rules' thresholds, every creative's copy and approval, each page's launch order, and every Meta ad built so far |
| `log.md` | One entry per daily review: numbers per ad and every pause, launch and budget change |
| `../../../scripts/meta_ads.py` | `build`, `status` and `daily` (see its docstring) |
| `../../../scripts/test_meta_ads.py` | The rules on made-up numbers |
| `../creative/meta-ads.html` | The ads. `render_meta_ads.py` renders them to `../creative/meta-ads/` |

## How it measures

- **Meta** (Marketing API, `.meta/token`): spend, times shown, taps, frequency.
- **Superwall** (`superwall query`): installs, trial starts, paying users and proceeds per ad. Every ad's link is a Superwall ad link (Integrations → Performance marketing → Meta) for its App Store page, so Superwall tags each install with `acquisition_ad_id` and sends `sw_` events to the BumpCast dataset (2299041164252027). The ad sets optimise for `sw_paywall_open`. 82% of new users open a paywall (Oct 23–27), so it stands in for "installed and opened the app". Purchases are too rare to optimise for at this budget.
- **Pages:** each ad set opens one page. Turbulence and Tracker are the custom product pages; Standard is the default listing. Ad 01 runs on all three pages, so it compares the pages with the creative held constant.

## The daily rules (thresholds in `config.json`)

An ad is paused when any of these is true:

1. People have seen it more than 3.5 times on average.
2. No installs after $7.
3. Tap rate under 0.5% after $5.
4. After $10, it costs over 1.5× its page's average per install (once the page has 3 installs).
5. After 4 days live, Meta has shown it fewer than 250 times. Meta has already picked another ad.

Rules 4 and 5 skip ad 01 until Thanksgiving, and skip any ad with 3+ installs at 0.7× its page's cost or better. At most 2 pauses per page per day. A page is never left with nothing running.

Each page keeps 3 ads live. Empty slots are filled from the page's queue in order, using approved ads only. From Nov 16 the holiday ad (03 or 06) goes first.

Budgets: $3/day per page Nov 2–18. On Nov 19 the $12/day Thanksgiving budget is split once, by the test's cost per install: a page that's 25% cheaper than the others takes all of it, and pages within 25% of the best share it. The split is then kept. The $15 news reserve adds $7.50/day to the Turbulence page on up to two days when a turbulence incident is in major US news. When $300 is spent, or after Nov 29, everything is paused. The ad account bills in CAD, so every plan amount is US dollars converted at `usd_to_account` (1.40): CA$4.20/day per page in the test, CA$16.80/day at Thanksgiving, and a CA$420 account spending limit as the hard stop.

## What the daily review never does

- Launch an ad that breaks the creative rules below. Drafted ads are approved automatically (`"auto_approve_drafts": true`, Lanre, Oct 27), so the rules are the only check before Meta's own review.
- Change targeting, the objective, the optimisation event, or an approved ad's copy or image.
- Raise budgets beyond the plan, or delete anything. It only pauses.
- Touch Apple Ads, Superwall paywalls or campaigns, or the app.

When a page has fewer than 2 approved ads left to launch, it drafts 3 new ones for that page in `meta-ads.html`: real app captures, claims the App Store pages already make, and copy that describes the product, never the viewer. It renders and checks them, adds them to `config.json` as approved, runs `build` (paused), and the same review launches them into open slots.

Each report names the winners and losers (cheapest and dearest per install among ads that have spent $3 or more), and every pause and launch with its reason.

## Oct 28: link clicks until the dataset has 50 paywall opens

The Sales ad sets optimised for `sw_paywall_open`, but the BumpCast dataset had no real ones yet (only Superwall's test events), so Meta barely delivered: 2 impressions overnight. Meta won't change an ad set's goal or attribution in place, and link-click optimisation isn't allowed in a Sales campaign. So the three ad sets now live in a Traffic campaign, **BumpCast · US · clicks**, with the same audience, budgets, ads and Superwall links (`optimise --goal LINK_CLICKS`). The Sales campaign and its ad sets are paused and kept.

Each review counts real paywall opens in Superwall since the move (`optimization.since`). At 50, it moves the ad sets back into the Sales campaign optimising for `sw_paywall_open` (`optimise --goal OFFSITE_CONVERSIONS`). Each ad keeps its key across moves, and old ad IDs (`retired_ads`) still count toward its numbers.

The review also flags **NOT DELIVERING** when Meta showed the ads fewer than 100 times the day before. Lanre gets a notification every morning, not only when something changes.

## Taps to installs, and the Nov 2 spend call

Every report has a "Taps to installs" line, per page and overall, for the whole campaign. From Nov 2 the review gives a one-time **spend call**:
**raise** if 10% or more of taps install, **hold** at 5–10%, **fix** under 5%. With fewer than 100 taps it says hold and asks again the next day.
It's advice for Lanre: the review never changes a budget on it. Thresholds are in `config.json` (`spend_call`); once made, `made` and `verdict` are recorded.

## Oct 30: boosted test budget, total raised to $400

Lanre asked for faster results. Each page runs at **$14/day** (CA$19.60; it was $7 earlier the same day) until the spend call is made (from Nov 2, once there are 100+ taps). After that, the review spreads what's left of the $153 test budget evenly over the days to Nov 18, at no less than $1/day per page (`total`, `boost_per_set`, `min_per_set` in the Test period). Lanre raised the total from $300 to **$400** (CA$560) so Thanksgiving keeps its $132; the test budget is $253. Meta's account limit has to be raised to CA$560 by hand (the system user can't touch billing). Until it is, every report flags ACCOUNT LIMIT.

## Oct 31: no Reels

Through Oct 30, link-click optimisation put 88% of taps and about 90% of spend into Instagram Reels, and only 1.9% of taps installed. Lanre dropped Reels, so the ad sets run on Facebook and Instagram feeds and Stories only. `targeting()` in the script matches this, so a rebuild or goal switch keeps Reels out. The story-size image is still used in Stories.

## Oct 31: back to paywall opens

Lanre asked to switch back before the 50 mark. By then Meta's dataset had 23 real paywall opens (the first try stalled with none), so `optimise --goal OFFSITE_CONVERSIONS` moved the ad sets into the Sales campaign as "· paywall opens", copying the Reels-free targeting, $14/day budgets and the 9 live ads. The click campaign and its ad sets are paused. If delivery stalls again, the morning report flags NOT DELIVERING.

## Setup (once, done Oct 27; live from 10:20pm ET)

1. Superwall → Integrations → Performance marketing → Meta: dataset, Conversions API token (Lanre), all six events, test events, three ad links (Default, Turbulence, Tracker). In Events Manager, confirm the `sw_` events and allow `install.link`.
2. Lanre: in Meta Business Settings, create a system user with access to the ad account, generate a token with `ads_management` and `ads_read`, copy it, and run `mkdir -p .meta && pbpaste > .meta/token && chmod 600 .meta/token`.
3. Fill `ad_account`, `page_id`, `instagram_user_id` and the three `ad_sets.*.link` in `config.json`.
4. `python3 scripts/meta_ads.py build --dry-run`, then `build`. Everything is created paused. Check one ad's preview in Ads Manager, set the inventory filter to Limited, and turn off Advantage+ creative enhancements if Meta turned any on.
5. `python3 scripts/meta_ads.py publish` turns on the campaign, the ad sets and the first day's 9 ads now, so Meta reviews them early. Delivery waits for the ad sets' Nov 2 start. It sets `"status": "live"`, and the daily review takes over from the next morning.

IDs (Oct 27): business A & Co Apps 1655980428996697, ad account act_2805776443152912 (CAD, Eastern), Page BumpCast 1467303836456537 (no Instagram account connected, so Instagram placements show the Page), dataset 2299041164252027 (`sw_` events confirmed, `install.link` the only allowed domain).

## Nov 2: Tracker page off

The Tracker page turned 0 of 62 taps into installs across six ads, so Lanre paused it. `off_pages` in `config.json` lists it: the review skips that page entirely, and the test's leftover budget and the Thanksgiving split go to the pages still running. To bring it back, delete it from `off_pages` and turn its ad set back on.

## Nov 2: capped at $300, ends Nov 5

Lanre capped the campaign at **$300** (CA$420, the account limit as it already is) and chose to spend the rest now. The Test period ends Nov 5 with `total` 300, so the review spreads what's left over Nov 3–5 and pauses everything from Nov 6. Thanksgiving is removed from `periods` (kept as `dropped_thanksgiving` for reference) and the news reserve is 0. The tests still check the rules against the $400 plan with Thanksgiving.

## Nov 3: ends Nov 4

Lanre asked to spend faster at the same $300 total. The Test period now ends Nov 4 (`to` in config.json), so what's left goes out over Nov 3–4 (about $26.57/day per page) and the review pauses everything from Nov 5.

## Nov 5: weekend rerun, $150 on the Turbulence page

The test ended Nov 4 at $299.85. Ad 02 was the only ad that paid for itself (4 paying users from 20 installs, $96.87 proceeds at 85% on $93.61, 1.03×). Lanre approved a weekend rerun on top: the total is now **$450** (CA$630).

- **Weekend** period, Nov 6–8: only the Turbulence page, only ads 02 and 10 (`lineup`), at **$50/day** (CA$70). Standard joins Tracker in `off_pages` (its ad set is paused). Friday's 8am review turns the two ads back on, sets the budget and records the page's numbers as the `baseline` that the check below counts from. Nothing else in the queue launches, and no ads are drafted.
- **Go-on check** (`stop`), each morning: once the run has spent $20, it pauses the page if installs cost more than $6 each. From Sunday's review, it also pauses if nobody has paid during the run. An ad paused during the run stays off. The usual rules still apply to 02 and 10 on their lifetime numbers.
- The Turbulence ad set ends **Sunday Nov 8 at 11:59pm ET** (`end_time` in Meta), and Monday's review pauses the ads. A fixed daily budget is never set above what's left of the total.
- Meta's spending limit is CA$630 (Lanre raised it Nov 5; the system user can't touch billing).
