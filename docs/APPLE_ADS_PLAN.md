# BumpCast launch: Apple Ads plan (SKAG)

**Who we're buying:** people who are nervous about an upcoming flight. Flight tracking is a feature, not the pitch. We bid where someone is already worried about turbulence or about flying itself, and we stay out of the big generic flight-tracker auctions ("flight tracker", "flightradar"). Those are costly and full of people who want a free status app.

## 1. Fix these before spending a dollar

1. **The store says "continental United States" only.** The worker's coverage box (`worker/src/smooth_worker/forecast.py`, lat 22–52, lon −128 to −64) includes Toronto, Montreal, Ottawa, Vancouver, Calgary and Winnipeg. It leaves out Edmonton, Halifax, St. John's, Hawaii, Alaska, Mexico and the Caribbean (Cancún sits at 21°N, just outside). A Canadian who taps the ad and reads "United States" will leave. Change the description to "flights within the US and southern Canada", or switch on the global outlook (`SMOOTH_GLOBAL=1`) before launch if it's ready.
2. **Connect Apple Ads to BumpCast in Superwall.** Petscans and PickleGo are connected, but BumpCast (58179) is not. In the dashboard: BumpCast → Integrations → Apple Search Ads → Advanced. Without it we see taps and installs but not **revenue by keyword**, and revenue by keyword is the only number this plan is managed on.
3. **Two custom product pages** (one ad variant per theme):
   - *Turbulence:* screenshots lead with the grade and the minute-by-minute timeline. Headline: "See when the bumps will come."
   - *Nervous flyer:* screenshots lead with calm wording, breathing and the Live Activity countdown. Headline: "Know what your flight will feel like."
4. **Paywall for paid users.** A $3.99 pass nets about $3.39 after Apple's cut, and will not pay back a paid install on its own. Payback depends on the annual trial. Run a Superwall test on the forecast-moment paywall for users who came from Apple Ads: pass-first (today) against annual-first. No app update is needed.

## 2. US or Canada first?

| | Canada | US |
|---|---|---|
| Avg Apple Ads cost per tap, all categories | ~$0.96–1.17 USD | ~$1.47–1.91 USD |
| Avg cost per install | ~$1.58–2.24 USD | ~$2.51–3.70 USD (travel) |
| Share of searchers whose flight we can forecast | **Lower:** sun trips, Europe, Edmonton and the Maritimes fall outside coverage | **High:** nearly every domestic flight |
| Search volume for "turbulence" / "fear of flying" | Small. Many exact keywords will barely serve | About 10× Canada |
| Seasonal peak | December holidays, winter sun season (mostly out of coverage) | **Thanksgiving, Wed Nov 25 – Sun Nov 29, 2026**, then December |

**Recommendation: launch in Canada, open the US within about two weeks, and from then on split budget by cost per paying user, not cost per tap.**

Canada is about 40% cheaper per tap, which makes it the cheaper place to find broken keywords, a weak product page or a paywall that doesn't convert. Cheaper taps don't make cheaper customers, though. More Canadian searchers fly routes we can't forecast, and Canada's search volume is too small to learn quickly. The US is where most of the money is, and US Thanksgiving is the biggest nervous-flyer week of the year. Don't let a cautious Canada start push the US launch past about **Nov 16**. US travellers search two to seven days before they fly.

If the global outlook goes live before launch, coverage in Canada improves and Canada deserves a bigger share of the budget.

## 3. Account structure

One campaign per country per theme, so budgets and reports stay separate. Inside each campaign, high-volume keywords get a **single-keyword ad group (SKAG)** on exact match. Low-volume long-tail keywords share one exact-match ad group, because splitting keywords that get five impressions a week teaches us nothing.

```
CA – Brand            exact SKAGs
CA – Turbulence       exact SKAGs + 1 long-tail exact group     → Turbulence product page
CA – Nervous flyer    exact SKAGs + 1 long-tail exact group     → Nervous-flyer product page
CA – Competitors      exact SKAGs
CA – Discovery        broad match + Search Match, low bids; every exact keyword above added as an exact negative
(same five for US)
```

- Search Match is **off** in every group except Discovery.
- Each week, any search term in Discovery with 2 or more installs, or a purchase, gets its own SKAG and becomes an exact negative in Discovery.
- Audience: all users, ages 18+, iPhone only. The app has no iPad layout, so don't pay for iPad taps.
- Language: English only at launch. There's no fr-CA store listing yet, so French-Canadian keywords would land on an English page. US Spanish keywords can come later, since an es-MX listing already exists.

## 4. Keywords and starting bids

Bids are starting max cost per tap. Canada in CAD, US in USD. Adjust weekly by the rules in section 6.

### Brand (bid low; there's no competition until someone else bids on it)
| Keyword | CA | US |
|---|---|---|
| bumpcast | 0.50 | 0.50 |
| bump cast | 0.50 | 0.50 |

### Turbulence: the core keywords, with the highest intent
SKAGs:
| Keyword | CA | US |
|---|---|---|
| turbulence | 1.75 | 2.25 |
| turbulence forecast | 2.00 | 2.50 |
| turbulence app | 1.75 | 2.25 |
| turbulence map | 1.50 | 2.00 |
| turbulence tracker | 1.75 | 2.25 |
| flight turbulence | 1.75 | 2.25 |
| turbulence predictor | 1.50 | 2.00 |

Long-tail exact group (CA 1.25, US 1.75): turbulence forecast app, turbulence radar, turbulence today, turbulence prediction, turbulence report, turbulence alert, flight turbulence forecast, turbulence checker, will my flight be bumpy, bumpy flight, airplane turbulence, plane turbulence.

### Nervous flyer: the audience
SKAGs:
| Keyword | CA | US |
|---|---|---|
| fear of flying | 1.50 | 2.00 |
| flight anxiety | 1.50 | 2.00 |
| nervous flyer | 1.50 | 2.00 |
| flying anxiety | 1.25 | 1.75 |
| afraid of flying | 1.25 | 1.75 |

Long-tail exact group (CA 1.00, US 1.50): fear of flying app, scared of flying, anxiety flying, aviophobia, nervous flying, flight anxiety app, calm flying, plane anxiety, flying phobia, airplane anxiety.

These searchers convert to installs at a lower rate than turbulence searchers, but they may make better subscribers. Judge them on revenue, not installs.

### Competitors (exact only; the ad shows our product page, never their name)
CA 1.00, US 1.40 each: turbli, soar fear of flying, skyguru, flycalm, valk, turbulence forecast flight+, bumpline.

"Turbulence Forecast" is both a competitor's app name (PJM Media) and a generic search. It already sits in the Turbulence campaign.

### Held back (phase 3 test only, CA first, bid ≤ CA$0.60)
flight tracker, flight status, flight delay, plane tracker. These have big volume and low intent. Only try them once we know what a paying install is worth.

### Negatives (campaign level, every campaign)
game, games, simulator, flight simulator, pilot training, flight school, ticket, tickets, cheap flights, booking, hotel, drone, movie, film, ps5, xbox, rc, model, wind turbine, turbulence physics, fluid dynamics.

## 5. Budget and phases

| Phase | Dates (adjust to launch day) | Markets | Daily budget | Goal |
|---|---|---|---|---|
| 0. Setup | Before launch | Both | 0 | Section 1 done. Campaigns built and paused. |
| 1. Learn | Launch → day 14 | CA | CA$40 (Brand 3, Turbulence 18, Nervous 10, Competitors 4, Discovery 5) | Real tap-through rate, install rate and first purchases per keyword |
| 2. US for Thanksgiving | ~Nov 9 → Nov 29 | CA + US | CA$40 + US$75, US$120 Nov 20–26 | Catch the peak; first read on US cost per payer |
| 3. Scale | December onward | Budget follows cost per payer | Raise any campaign beating target by 20%/week | Holiday travel; test the held-back tracker keywords |

That's about US$2,500–3,500 over the first six weeks. Small enough to cut losses fast, big enough to get a read on the main keywords.

## 6. What we manage to, and the weekly rules

**Numbers that matter**, from Superwall once the integration is connected:
- Cost per install, used only for early triage.
- **Cost per paying user**: spend ÷ users with a pass, trial start or subscription.
- 30-day revenue per install, by keyword.

**Starting targets** (assumptions; replace with real data after phase 1):
- Install rate from tap ≥ 40% on the turbulence keywords, ≥ 30% on the nervous-flyer keywords.
- Cost per paying user ≤ **US$15** while we learn. Long term, it has to sit under 30-day net revenue per payer, which is mostly annual plans.

**Every Monday:**
1. A keyword with 30 or more taps and no installs: halve the bid. If it's still at zero a week later, pause it.
2. A keyword with installs but nobody paying after 15 or more installs: lower the bid 25%.
3. A keyword under the cost-per-payer target and losing impression share: raise the bid 15–20%.
4. Discovery: promote winning search terms (see section 3) and add junk terms as negatives.
5. Check for "turbulence" news. A widely shared turbulence incident sends searches up 5–10× for a few days. Raise the daily budgets, not the bids, so we don't overpay per tap during the spike.

## 7. Risks

- **Coverage mismatch** (section 1.1). It's the largest risk to Canada results, and it hits hardest in winter, when Canadians fly south.
- **Thin volume.** Canadian exact-match keywords may serve almost nothing. That's why the US needs to open before Thanksgiving and not after Canada "proves out".
- **The pass doesn't pay back.** If most paid users buy a single $3.99 pass, paid acquisition loses money until the annual-first paywall test wins.
- **Benchmarks are averages** across categories and vary a lot between sources. This niche could cost more or less than these figures. Phase 1 exists to replace them with real numbers.

## Sources

- [AppTweak: Apple Ads benchmarks 2026](https://www.apptweak.com/en/aso-blog/apple-ads-benchmarks) (US travel CPT $1.58, CPI $3.70; Canada CPT $1.17)
- [Adapty: Apple Ads benchmarks 2026, 90 countries](https://adapty.io/blog/apple-ads-benchmarks-2026/) (US CPT $1.58 / CPA $2.51; Canada CPT $0.96 / CPA $1.58)
- [Rocketship HQ country benchmarks](https://www.rocketshiphq.com/?p=5321) (US CPT $1.47; Canada $0.98)
- [Intentplus: four benchmark datasets compared](https://intentplus.io/blog/apple-ads-benchmarks-2026)
- [SplitMetrics: benchmarks by market](https://splitmetrics.com/apple-ads-search-results-benchmarks-2026/benchmarks-by-markets)
- Competitors from the App Store via the Apple Ads app search: Turbulence Forecast (PJM Media), Turbulence Forecast – Flight+, Turbulence Forecast: Bumpline, Flight Anxiety – FlyCalm.me, plus [Turbli](https://apps.apple.com/us/app/turbli/id6762553623) and SOAR.
