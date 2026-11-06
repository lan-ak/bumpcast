"""BumpCast's Meta campaign: build it, then review it daily (pause losers, launch the next approved ad).

The plan: https://claude.ai/artifact/JqUXBSzb479APPPp4pkpiQ
Everything the rules need lives in docs/release/meta/config.json; every change is logged to
docs/release/meta/log.md. Spend, impressions and taps come from Meta's Marketing API. Installs,
trials and paying users per ad come from Superwall, which attributes Meta installs through its ad
links (Integrations → Performance marketing → Meta) and tags each user with acquisition_ad_id.

    python3 scripts/meta_ads.py build --dry-run        # print what it would create
    python3 scripts/meta_ads.py build                  # create approved ads that aren't in Meta yet, all PAUSED
    python3 scripts/meta_ads.py publish                # turn on the first day's ads and budgets; delivery starts on day one
    python3 scripts/meta_ads.py optimise --goal LINK_CLICKS   # move the ad sets to another performance goal
    python3 scripts/meta_ads.py status                 # every ad, with spend, taps, installs and trials
    python3 scripts/meta_ads.py daily                  # what today's review would do (changes nothing)
    python3 scripts/meta_ads.py daily --apply          # do it, and append to the log
    python3 scripts/meta_ads.py daily --apply --news   # same, and spend the news reserve today

Token: .meta/token (gitignored), a Meta system user token with ads_management and ads_read on the
ad account. Superwall: the logged-in `superwall` CLI.

Money: the plan and the rules are in plan_currency (USD). If the ad account bills in another currency,
"usd_to_account" in config.json converts: budgets are multiplied by it on the way to Meta, and spend
is divided by it on the way back, so the rules always compare US dollars.
"""

import argparse
import datetime as dt
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "docs/release/meta/config.json"
LOG = ROOT / "docs/release/meta/log.md"
TOKEN = ROOT / ".meta/token"
IMAGES = ROOT / "docs/release/creative/meta-ads"
PAGES = ("turbulence", "tracker", "standard")
RATE_LIMIT_CODES = {4, 17, 32, 613, 80000, 80004}

PER_AD_SQL = """
WITH attributed AS (
  SELECT appUserId,
         anyIf(value, key = 'acquisition_ad_id') AS ad_id,
         anyIf(value, key = 'acquisition_source') AS source
  FROM sw.user_attributes_rep FINAL
  WHERE applicationId = {app} AND isSandbox = 0 AND isDeleted = 0
    AND key IN ('acquisition_ad_id', 'acquisition_source')
  GROUP BY appUserId
  HAVING source = 'meta'
),
purchases AS (
  SELECT appUserId,
         countIf(name = 'initial_purchase' AND lower(periodType) = 'trial') AS trials,
         countIf(name != 'transaction_complete' AND price > 0) AS paid,
         sumIf(proceeds, name != 'transaction_complete') AS proceeds
  FROM open_revenue.attributed_events_by_ts_rep
  WHERE applicationId = {app} AND environment = 'PRODUCTION'
    AND appUserId IN (SELECT appUserId FROM attributed)
  GROUP BY appUserId
)
SELECT ad_id, count() AS installs, countIf(trials > 0) AS trials,
       countIf(paid > 0) AS paid, round(sum(proceeds), 2) AS proceeds
FROM attributed LEFT JOIN purchases USING (appUserId)
GROUP BY ad_id
"""


# ---------------------------------------------------------------------------------------------
# The rules. Pure: config, today's date and the numbers in, a list of changes out.
# ---------------------------------------------------------------------------------------------

def period_for(cfg, today):
    for p in cfg["budget"]["periods"]:
        if dt.date.fromisoformat(p["from"]) <= today <= dt.date.fromisoformat(p["to"]):
            return p
    return None


def live_pages(cfg):
    """The pages still running. A page in "off_pages" (Lanre's call) is paused in Meta and skipped."""
    return [p for p in PAGES if p not in cfg.get("off_pages", {})]


def test_daily(cfg, period, today, spent):
    """Daily budget per page in the test. While "boost_per_set" is set and the spend call isn't made,
    that boosted amount; after it, what's left of the test's "total" spread evenly over the days left."""
    if period.get("boost_per_set") and not cfg.get("spend_call", {}).get("made"):
        return period["boost_per_set"]
    if period.get("total"):
        days_left = (dt.date.fromisoformat(period["to"]) - today).days + 1
        return max(period.get("min_per_set", 1.0), round((period["total"] - spent) / days_left / len(live_pages(cfg)), 2))
    # A fixed daily budget never runs past the campaign's total.
    return min(period["daily_per_set"], round(max(0.0, cfg["budget"]["total"] - spent) / len(live_pages(cfg)), 2))


def since_baseline(period, page, rows):
    """A page's spend, installs and paying users since the period's baseline (recorded on its first day)."""
    base = period.get("baseline", {}).get(page, {})
    return {k: sum(r[k] for r in rows if r["page"] == page) - base.get(k, 0) for k in ("spend", "installs", "paid")}


def stop_reason(period, today, page, rows):
    """A rerun's go-on check ("stop" in the period): why the page stops today, or None."""
    stop = period.get("stop")
    if not stop or page not in period.get("baseline", {}):
        return None
    s = since_baseline(period, page, rows)
    if s["spend"] >= stop["min_spend"]:
        cpi = s["spend"] / s["installs"] if s["installs"] else None
        if cpi is None or cpi > stop["max_cost_per_install"]:
            got = f"${cpi:.2f} per install" if cpi else "no installs"
            return f"{period['name'].lower()} run: {got} from ${s['spend']:.2f} (the limit is ${stop['max_cost_per_install']:.2f})"
    if today >= dt.date.fromisoformat(stop["paid_by"]) and s["paid"] <= 0:
        return f"{period['name'].lower()} run: no paying users from ${s['spend']:.2f}"
    return None


def cost_per_install(spend, installs):
    return spend / installs if installs else None


def page_split(cfg, ads):
    """Thanksgiving budget per page from the test's cost per install. Pages not listed get nothing."""
    rule = cfg["page_rule"]
    cpi = {}
    for page in live_pages(cfg):
        rows = [a for a in ads if a["page"] == page]
        spend, installs = sum(a["spend"] for a in rows), sum(a["installs"] for a in rows)
        if installs >= rule["min_installs"]:
            cpi[page] = spend / installs
    if not cpi:
        return {page: 1 / len(live_pages(cfg)) for page in live_pages(cfg)}, "no page reached {} installs, so the budget is split evenly".format(rule["min_installs"])
    best = min(cpi.values())
    close = [p for p, c in cpi.items() if c <= best * (1 + rule["margin"])]
    note = ", ".join(f"{p} ${c:.2f}" for p, c in sorted(cpi.items(), key=lambda kv: kv[1]))
    return {p: 1 / len(close) for p in close}, f"cost per install in the test: {note}"


def decide(cfg, today, ads, spent_total, news=False, paywall_opens=None, shown_yesterday=None):
    """Return (changes, notes). Each change is a dict with "do" in pause, launch, budget, pause_set,
    record_split or optimise. paywall_opens: real paywall opens since the ad sets moved to link clicks.
    shown_yesterday: impressions across the campaign yesterday."""
    rules, anchor = cfg["rules"], cfg["anchor"]
    period = period_for(cfg, today)
    changes, notes = [], []
    opt = cfg.get("optimization", {})
    if opt.get("current") == "LINK_CLICKS" and paywall_opens is not None:
        target = opt.get("switch_back_at", 50)
        if paywall_opens >= target:
            changes.append({"do": "optimise", "goal": "OFFSITE_CONVERSIONS",
                            "why": f"Meta's dataset now has {paywall_opens} paywall opens (the switch-back mark is {target})"})
        else:
            notes.append(f"Optimising for link clicks until the dataset has {target} paywall opens (now {paywall_opens}).")
    call = spend_call(cfg, today, ads)
    if call:
        verdict_, reason, final = call
        notes.append(f"SPEND CALL: {verdict_.upper()}. {reason}.")
        if final:
            changes.append({"do": "record_spend_call", "verdict": verdict_, "why": reason})
    live = [a for a in ads if a["status"] == "ACTIVE"]
    if shown_yesterday is not None and live and shown_yesterday < rules.get("min_daily_impressions", 100):
        notes.append(f"NOT DELIVERING: Meta showed the ads {shown_yesterday} times yesterday "
                     f"(expected at least {rules.get('min_daily_impressions', 100)}).")
    first_day = dt.date.fromisoformat(cfg["budget"]["periods"][0]["from"])
    last_day = dt.date.fromisoformat(cfg["budget"]["periods"][-1]["to"])

    if spent_total >= cfg["budget"]["total"] or today > last_day:
        why = "the $%d budget is spent" % cfg["budget"]["total"] if today <= last_day else "the campaign has ended"
        for a in ads:
            if a["status"] == "ACTIVE":
                changes.append({"do": "pause", "ad": a["key"], "why": why})
        return changes, notes
    if period is None or today < first_day:
        notes.append("Nothing runs today.")
        return changes, notes

    lineup = period.get("lineup")
    if lineup and "baseline" not in period:
        # The rerun's first day: remember where each page stood, so the go-on check counts only the rerun.
        base = {page: {k: round(sum(a[k] for a in ads if a["page"] == page), 2) for k in ("spend", "installs", "paid")}
                for page in lineup}
        changes.append({"do": "record_baseline", "period": period["name"], "baseline": base,
                        "why": f"{period['name']} starts"})
    thanksgiving = period["name"] == "Thanksgiving"
    holiday_ok = today >= dt.date.fromisoformat(rules["holiday_from"])
    split = None
    if thanksgiving:
        # Decided once, on the first Thanksgiving day, from the test's numbers; kept after that.
        split = cfg["page_rule"].get("split")
        if split is None:
            split, why = page_split(cfg, [a for a in ads if not a.get("holiday")])
            changes.append({"do": "record_split", "split": split, "why": why})
            notes.append("Thanksgiving split: " + why + ".")

    for page in live_pages(cfg):
        rows = [a for a in ads if a["page"] == page]
        live = [a for a in rows if a["status"] == "ACTIVE"]
        set_spend = sum(a["spend"] for a in rows)
        set_installs = sum(a["installs"] for a in rows)
        set_cpi = cost_per_install(set_spend, set_installs)

        if split is not None and page not in split:
            changes.append({"do": "pause_set", "set": page, "why": "another page installs for at least {:.0%} less".format(cfg["page_rule"]["margin"])})
            continue

        if lineup and page in period.get("baseline", {}):
            run = since_baseline(period, page, ads)
            cpi = f", ${run['spend'] / run['installs']:.2f} each" if run["installs"] else ""
            notes.append(f"{period['name']} run on {page} so far: ${run['spend']:.2f}, {run['installs']} installs{cpi}, "
                         f"{run['paid']} paid.")
        stop = lineup and stop_reason(period, today, page, ads)
        if stop:
            for a in live:
                changes.append({"do": "pause", "ad": a["key"], "why": stop})
            continue

        pauses = []
        for a in live:
            ctr = a["clicks"] / a["impressions"] if a["impressions"] else 0
            cpi = cost_per_install(a["spend"], a["installs"])
            protected = a["n"] == anchor and not thanksgiving
            keeper = (set_cpi is not None and a["installs"] >= rules["keeper_installs"]
                      and cpi <= rules["keeper_cost_per_install"] * set_cpi)
            why = None
            if a["frequency"] > rules["max_frequency"]:
                why = "people have seen it {:.1f} times on average".format(a["frequency"])
            elif a["installs"] == 0 and a["spend"] >= rules["no_installs_after"]:
                why = "no installs after ${:.2f}".format(a["spend"])
            elif a["spend"] >= rules["tap_rate_after"] and ctr < rules["min_tap_rate"]:
                why = "tap rate {:.2%} after ${:.2f}".format(ctr, a["spend"])
            elif not (protected or keeper):
                if (a["spend"] >= rules["relative_after"] and set_installs >= rules["relative_min_set_installs"]
                        and cpi is not None and cpi > rules["relative_cost_per_install"] * set_cpi):
                    why = "${:.2f} per install against ${:.2f} for its page".format(cpi, set_cpi)
                elif a["days_live"] >= rules["starved_days"] and a["impressions"] < rules["starved_impressions"]:
                    why = "Meta showed it only {} times in {} days".format(a["impressions"], a["days_live"])
            if why:
                pauses.append((a, why))

        pauses.sort(key=lambda p: -p[0]["spend"])
        pauses = pauses[:rules["max_pauses_per_set_per_day"]]

        # The next ads in this page's queue: the holiday ad first once it's allowed, then in order.
        queue = list(cfg["queue"][page])
        hol = cfg["holiday"].get(page)
        if hol and holiday_ok:
            queue.insert(0, hol)
        by_n = {a["n"]: a for a in rows}
        ready = [by_n[n] for n in queue if n in by_n and by_n[n]["approved"] and by_n[n]["status"] != "ACTIVE"
                 and not by_n[n]["launched"]]
        unbuilt = [n for n in queue if cfg["creatives"][n]["approved"] and n not in by_n]
        if lineup:
            # A rerun turns its chosen ads back on, and only those; one a rule pauses during the rerun stays off.
            queue = lineup.get(page, [])
            ready = [by_n[n] for n in queue if n in by_n and by_n[n]["status"] != "ACTIVE"
                     and not (by_n[n].get("paused") and by_n[n]["paused"] >= period["from"])]
            unbuilt = []

        staying = len(live) - len(pauses)
        launches = ready[:max(0, period["live_per_set"] - staying)]
        if staying + len(launches) == 0 and pauses:
            keep, _ = pauses.pop()  # never leave a page with nothing running
            notes.append(f"Kept {keep['key']}: nothing approved to replace it.")
        for a, why in pauses:
            changes.append({"do": "pause", "ad": a["key"], "why": why})
        for a in launches:
            why = f"back on for the {period['name'].lower()} run" if lineup else "next approved ad for the {} page".format(page)
            changes.append({"do": "launch", "ad": a["key"], "why": why})
        if unbuilt:
            notes.append(f"{page}: approved but not built in Meta yet: {', '.join(unbuilt)} (run build).")
        left = len(ready) - len(launches)
        if left < 2 and not lineup:
            notes.append(f"Bench low: {page} has {left} approved ad(s) left to launch. Draft 3 new ones.")

        daily = test_daily(cfg, period, today, spent_total) if split is None else period["daily_total"] * split[page]
        if news and page == cfg["budget"]["news_reserve"]["page"]:
            daily += cfg["budget"]["news_reserve"]["daily"]
        changes.append({"do": "budget", "set": page, "daily": round(daily, 2), "why": period["name"]})

    return changes, notes


# ---------------------------------------------------------------------------------------------
# Meta Marketing API and Superwall
# ---------------------------------------------------------------------------------------------

class Meta:
    def __init__(self, cfg):
        if not TOKEN.exists():
            sys.exit(f"No Meta token at {TOKEN.relative_to(ROOT)}. See docs/release/meta/README.md.")
        self.token = TOKEN.read_text().strip()
        self.base = f"https://graph.facebook.com/{cfg['graph_version']}/"

    def call(self, method, path, params=None, files=None):
        params = dict(params or {}, access_token=self.token)
        url = self.base + path.lstrip("/")
        data = None
        if method == "GET":
            url += "?" + urllib.parse.urlencode(params)
        else:
            data = urllib.parse.urlencode({k: v if isinstance(v, str) else json.dumps(v) for k, v in params.items()}).encode()
        for attempt in range(4):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method), timeout=60) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                body = e.read().decode(errors="replace")
                code = json.loads(body).get("error", {}).get("code") if body.startswith("{") else None
                # Rate limits: the app is on Meta's development tier, whose allowance refills within minutes.
                if code in RATE_LIMIT_CODES and attempt < 3:
                    print(f"Meta rate limit on {path}; waiting 5 minutes ({attempt + 1}/3).", file=sys.stderr)
                    time.sleep(300)
                    continue
                if '"is_transient":true' in body.replace(" ", "") and attempt < 3:
                    print(f"Meta hiccup on {path}; retrying in 30 seconds ({attempt + 1}/3).", file=sys.stderr)
                    time.sleep(30)
                    continue
                sys.exit(f"Meta {method} {path} failed ({e.code}): {body}")

    def get_all(self, path, params):
        out, page = [], self.call("GET", path, params)
        while True:
            out += page.get("data", [])
            nxt = page.get("paging", {}).get("next")
            if not nxt:
                return out
            with urllib.request.urlopen(nxt, timeout=60) as r:
                page = json.load(r)

    def post(self, path, **params):
        return self.call("POST", path, params)


def superwall_per_ad(cfg):
    sql = PER_AD_SQL.format(app=int(cfg["superwall_app"]))
    out = subprocess.run(["superwall", "query", sql, "--json"], capture_output=True, text=True)
    data = json.loads(out.stdout or "{}")
    if "data" not in data:
        sys.exit(f"Superwall query failed: {out.stdout or out.stderr}")
    return {r["ad_id"]: r for r in data["data"]}


def superwall_paywall_opens(cfg, since):
    sql = (f"SELECT count() AS opens FROM sw.events_rep WHERE applicationId = {int(cfg['superwall_app'])} "
           f"AND isSandbox = 0 AND isDeleted = 0 AND name = 'paywall_open' AND ts >= '{since}'")
    out = subprocess.run(["superwall", "query", sql, "--json"], capture_output=True, text=True)
    data = json.loads(out.stdout or "{}").get("data")
    if data is None:
        sys.exit(f"Superwall query failed: {out.stdout or out.stderr}")
    return int(data[0]["opens"]) if data else 0


def gather(cfg, meta, today):
    """One row per ad in config["ads"], with Meta's numbers and Superwall's."""
    camp = cfg["campaign"]["id"]
    campaigns = cfg["campaign"].get("all", [camp])
    status = {a["id"]: a for a in meta.get_all(f"{camp}/ads", {"fields": "id,name,status,effective_status", "limit": 200})}
    # An ad keeps its key when the ad sets move to another goal, so its old ad IDs count toward it too.
    key_of = {ad["id"]: key for key, ad in cfg["ads"].items()} | cfg.get("retired_ads", {})
    insights, sw, spent = {}, {}, 0.0
    for c in campaigns:
        for r in meta.get_all(f"{c}/insights", {"level": "ad", "date_preset": "maximum", "limit": 500,
                                                "fields": "ad_id,spend,impressions,inline_link_clicks,frequency"}):
            agg = insights.setdefault(key_of.get(r["ad_id"]), {"spend": 0.0, "impressions": 0, "inline_link_clicks": 0, "frequency": 0.0})
            agg["spend"] += float(r.get("spend", 0)); agg["impressions"] += int(r.get("impressions", 0))
            agg["inline_link_clicks"] += int(r.get("inline_link_clicks", 0))
            agg["frequency"] = max(agg["frequency"], float(r.get("frequency", 0)))
        total = meta.get_all(f"{c}/insights", {"date_preset": "maximum", "fields": "spend"})
        spent += to_plan(cfg, total[0]["spend"]) if total else 0.0
    for ad_id, r in superwall_per_ad(cfg).items():
        agg = sw.setdefault(key_of.get(ad_id), {"installs": 0, "trials": 0, "paid": 0, "proceeds": 0.0})
        for k in ("installs", "trials", "paid"):
            agg[k] += int(r.get(k) or 0)
        agg["proceeds"] += float(r.get("proceeds") or 0)
    rows = []
    for key, ad in cfg["ads"].items():
        n, page = key.split("-", 1)
        i, s = insights.get(key, {}), sw.get(key, {})
        launched = ad.get("launched")
        rows.append({
            "key": key, "n": n, "page": page, "id": ad["id"],
            "approved": cfg["creatives"][n]["approved"], "holiday": cfg["creatives"][n].get("holiday", False),
            "status": status.get(ad["id"], {}).get("status", "PAUSED"), "launched": launched, "paused": ad.get("paused"),
            "days_live": (today - dt.date.fromisoformat(launched)).days if launched and not ad.get("paused") else 0,
            "spend": to_plan(cfg, i.get("spend", 0)), "impressions": int(i.get("impressions", 0)),
            "clicks": int(i.get("inline_link_clicks", 0)), "frequency": float(i.get("frequency", 0)),
            "installs": int(s.get("installs", 0)), "trials": int(s.get("trials", 0)),
            "paid": int(s.get("paid", 0)), "proceeds": float(s.get("proceeds") or 0),
        })
    return rows, spent


def apply(cfg, meta, changes, today):
    for c in changes:
        if c["do"] in ("pause", "launch"):
            ad = cfg["ads"][c["ad"]]
            meta.post(ad["id"], status="PAUSED" if c["do"] == "pause" else "ACTIVE")
            if c["do"] == "launch":
                ad["launched"], ad["paused"] = today.isoformat(), None
            else:
                ad["paused"], ad["reason"] = today.isoformat(), c["why"]
        elif c["do"] == "budget":
            meta.post(cfg["ad_sets"][c["set"]]["id"], daily_budget=to_account(cfg, c["daily"]), status="ACTIVE")
        elif c["do"] == "pause_set":
            meta.post(cfg["ad_sets"][c["set"]]["id"], status="PAUSED")
        elif c["do"] == "record_baseline":
            next(p for p in cfg["budget"]["periods"] if p["name"] == c["period"])["baseline"] = c["baseline"]
        elif c["do"] == "record_split":
            cfg["page_rule"]["split"] = c["split"]
        elif c["do"] == "optimise":
            move_ad_sets(cfg, meta, c["goal"])
        elif c["do"] == "record_spend_call":
            cfg["spend_call"].update(made=today.isoformat(), verdict=c["verdict"])


# ---------------------------------------------------------------------------------------------
# Build: campaign, three ad sets, and one paused ad per approved creative per page
# ---------------------------------------------------------------------------------------------

def search_id(meta, kind, q, **extra):
    hits = meta.call("GET", "search", {"type": kind, "q": q, **extra}).get("data", [])
    match = next((h for h in hits if h.get("name", "").lower() == q.lower()), None)
    if not match:
        sys.exit(f"Meta has no {kind} called exactly {q!r}. Closest: {[h.get('name') for h in hits[:5]]}")
    return match.get("id") or match.get("key")


def targeting(cfg, meta):
    t = cfg["targeting"]
    regions = [{"key": search_id(meta, "adgeolocation", r, location_types='["region"]', country_code="US")}
               for r in t["exclude_regions"]]
    return {
        "geo_locations": {"countries": t["countries"], "location_types": ["home", "recent"]},
        "excluded_geo_locations": {"regions": regions},
        "age_min": t["age_min"], "age_max": 65,
        "flexible_spec": [{
            "interests": [{"id": search_id(meta, "adinterest", q)} for q in t["interests"]],
            "behaviors": [{"id": search_id(meta, "adTargetingCategory", q, **{"class": "behaviors"})} for q in t["behaviors"]],
        }],
        "targeting_automation": {"advantage_audience": 1},
        "publisher_platforms": ["facebook", "instagram"],
        # No Reels (Lanre, Oct 31): 88% of taps came from Instagram Reels and almost none installed.
        "facebook_positions": ["feed", "story"],
        "instagram_positions": ["stream", "story"],
        "device_platforms": ["mobile"],
        "user_os": ["iOS"],
    }


def creative_spec(cfg, n, page, hashes):
    c = cfg["creatives"][n]
    feed, story = hashes
    spec = {
        "images": [{"hash": feed, "adlabels": [{"name": "feed"}]}, {"hash": story, "adlabels": [{"name": "story"}]}],
        "bodies": [{"text": c["primary"]}],
        "titles": [{"text": c["headline"]}],
        "descriptions": [{"text": cfg["description"]}],
        "link_urls": [{"website_url": cfg["ad_sets"][page]["link"]}],
        "call_to_action_types": [cfg["call_to_action"]],
        "ad_formats": ["SINGLE_IMAGE"],
        "optimization_type": "PLACEMENT",
        "asset_customization_rules": [
            {"customization_spec": {"publisher_platforms": ["facebook", "instagram"],
                                    "facebook_positions": ["feed"], "instagram_positions": ["stream"]},
             "image_label": {"name": "feed"}, "priority": 1},
            {"customization_spec": {"publisher_platforms": ["facebook", "instagram"],
                                    "facebook_positions": ["story"], "instagram_positions": ["story"]},
             "image_label": {"name": "story"}, "priority": 2},
        ],
    }
    story_spec = {"page_id": cfg["page_id"]}
    if cfg.get("instagram_user_id"):
        story_spec["instagram_user_id"] = cfg["instagram_user_id"]
    return {"name": f"{n} {c['slug']} · {page}", "object_story_spec": story_spec, "asset_feed_spec": spec}


def build(cfg, dry_run):
    missing = [k for k in ("ad_account", "page_id", "dataset_id") if not cfg.get(k)]
    missing += [f"ad_sets.{p}.link" for p in PAGES if not cfg["ad_sets"][p]["link"]]
    if missing:
        sys.exit("Fill these in docs/release/meta/config.json first: " + ", ".join(missing))
    wanted = [(n, page) for page in PAGES
              for n in cfg["queue"][page] + [cfg["holiday"][page]]
              if cfg["creatives"][n]["approved"] and f"{n}-{page}" not in cfg["ads"]]
    wanted = list(dict.fromkeys(wanted))
    if dry_run:
        print("Campaign:", cfg["campaign"]["name"], "(exists)" if cfg["campaign"]["id"] else "(new, Sales, paused)")
        for p in PAGES:
            print(f"Ad set: {cfg['ad_sets'][p]['name']}", "(exists)" if cfg["ad_sets"][p]["id"] else "(new, paused)")
        for n, page in wanted:
            print(f"Ad: {n} {cfg['creatives'][n]['slug']} · {page} (paused)")
        return
    meta, act = Meta(cfg), cfg["ad_account"]
    first = cfg["budget"]["periods"][0]
    if not cfg["campaign"]["id"]:
        cfg["campaign"]["id"] = meta.post(f"{act}/campaigns", name=cfg["campaign"]["name"], objective="OUTCOME_SALES",
                                          status="PAUSED", special_ad_categories=[], buying_type="AUCTION",
                                          is_adset_budget_sharing_enabled=False)["id"]
        save(cfg)
    tgt = None
    for p in PAGES:
        s = cfg["ad_sets"][p]
        if s["id"]:
            continue
        tgt = tgt or targeting(cfg, meta)
        s["id"] = meta.post(f"{act}/adsets", name=s["name"], campaign_id=cfg["campaign"]["id"], status="PAUSED",
                            daily_budget=to_account(cfg, first["daily_per_set"]), billing_event="IMPRESSIONS",
                            optimization_goal="OFFSITE_CONVERSIONS", bid_strategy="LOWEST_COST_WITHOUT_CAP",
                            destination_type="WEBSITE", targeting=tgt,
                            promoted_object={"pixel_id": cfg["dataset_id"], "custom_event_type": "OTHER",
                                             "custom_event_str": cfg["optimization_event"]},
                            **({"start_time": f"{first['from']}T00:00:00-0500"}
                               if dt.date.fromisoformat(first["from"]) > dt.date.today() else {}))["id"]
        save(cfg)
    hashes = {}
    for n, page in wanted:
        if n not in hashes:
            hashes[n] = tuple(upload_image(meta, act, f"{n}-{cfg['creatives'][n]['slug']}-{kind}.png") for kind in ("feed", "story"))
        spec = creative_spec(cfg, n, page, hashes[n])
        creative = meta.post(f"{act}/adcreatives", **spec)["id"]
        ad = meta.post(f"{act}/ads", name=spec["name"], adset_id=cfg["ad_sets"][page]["id"],
                       creative={"creative_id": creative}, status="PAUSED")["id"]
        cfg["ads"][f"{n}-{page}"] = {"id": ad, "launched": None, "paused": None}
        save(cfg)
        print("Built", spec["name"])


def publish(cfg, meta):
    """Turn on the campaign, the ad sets and the first day's ads now, so Meta reviews them before day one.
    The ad sets' start_time keeps delivery from starting early."""
    first = dt.date.fromisoformat(cfg["budget"]["periods"][0]["from"])
    # Everything was just built paused and nothing has run, so start from config instead of reading
    # Meta back (a new app's API allowance is small).
    rows = []
    for key, ad in cfg["ads"].items():
        n, page = key.split("-", 1)
        rows.append({"key": key, "n": n, "page": page, "id": ad["id"], "approved": cfg["creatives"][n]["approved"],
                     "holiday": cfg["creatives"][n].get("holiday", False), "status": "PAUSED", "launched": None,
                     "days_live": 0, "spend": 0.0, "impressions": 0, "clicks": 0, "frequency": 0.0,
                     "installs": 0, "trials": 0, "paid": 0, "proceeds": 0.0})
    changes, notes = decide(cfg, first, rows, 0.0)
    apply(cfg, meta, changes, first)
    meta.post(cfg["campaign"]["id"], status="ACTIVE")
    cfg["status"] = "live"
    save(cfg)
    for c in changes:
        print(describe(c))
    for n in notes:
        print(n)
    print(f"Campaign on. Delivery starts {first:%b %-d}.")


def move_ad_sets(cfg, meta, goal):
    """Recreate the three ad sets with another performance goal, since Meta won't change an ad set's
    attribution window in place. Every ad is copied with the same creative and on/off state, and the
    old ad sets are paused, never deleted. goal: "LINK_CLICKS" or "OFFSITE_CONVERSIONS"."""
    act, opt, camp = cfg["ad_account"], cfg.setdefault("optimization", {}), cfg["campaign"]
    by_goal = camp.setdefault("by_goal", {"OFFSITE_CONVERSIONS": camp["id"]})
    camp.setdefault("all", [camp["id"]])
    old_campaign = camp["id"]
    if goal not in by_goal:
        # Meta only offers link-click optimisation in a Traffic campaign.
        by_goal[goal] = meta.post(f"{act}/campaigns", name=f"{camp['name']} · clicks", objective="OUTCOME_TRAFFIC",
                                  status="PAUSED", special_ad_categories=[], buying_type="AUCTION",
                                  is_adset_budget_sharing_enabled=False)["id"]
        camp["all"].append(by_goal[goal])
        save(cfg)
    target = by_goal[goal]
    creative_of = {a["id"]: a["creative"]["id"] for a in
                   meta.get_all(f"{old_campaign}/ads", {"fields": "id,creative{id}", "limit": 100})}
    for page in PAGES:
        old = cfg["ad_sets"][page]
        if old.get("goal", "OFFSITE_CONVERSIONS") == goal:
            continue
        src = meta.call("GET", old["id"], {"fields": "daily_budget,targeting"})
        set_name = f"{old['name'].split(' · ')[0]} · {'clicks' if goal == 'LINK_CLICKS' else 'paywall opens'}"
        # Resume an interrupted move: reuse an ad set and ads that already exist under the same names.
        existing = {a["name"]: a["id"] for a in meta.get_all(f"{target}/adsets", {"fields": "id,name", "limit": 50})}
        params = {"name": set_name,
                  "campaign_id": target, "status": "ACTIVE", "daily_budget": src["daily_budget"],
                  "billing_event": "IMPRESSIONS", "optimization_goal": goal, "bid_strategy": "LOWEST_COST_WITHOUT_CAP",
                  "destination_type": "WEBSITE", "targeting": src["targeting"],
                  "attribution_spec": [{"event_type": "CLICK_THROUGH", "window_days": 1 if goal == "LINK_CLICKS" else 7}]}
        if goal == "OFFSITE_CONVERSIONS":
            params["promoted_object"] = {"pixel_id": cfg["dataset_id"], "custom_event_type": "OTHER",
                                         "custom_event_str": cfg["optimization_event"]}
        new_set = existing.get(set_name) or meta.post(f"{act}/adsets", **params)["id"]
        made = {a["name"]: a["id"] for a in meta.get_all(f"{new_set}/ads", {"fields": "id,name", "limit": 100})}
        for key, ad in cfg["ads"].items():
            if key.split("-", 1)[1] != page:
                continue
            live = bool(ad.get("launched")) and not ad.get("paused")
            n = key.split("-")[0]
            name = f"{n} {cfg['creatives'][n]['slug']} · {page}"
            new_ad = made.get(name) or meta.post(f"{act}/ads", name=name, adset_id=new_set,
                                                 creative={"creative_id": creative_of[ad["id"]]},
                                                 status="ACTIVE" if live else "PAUSED")["id"]
            cfg.setdefault("retired_ads", {})[ad["id"]] = key
            ad["id"] = new_ad
        meta.post(old["id"], status="PAUSED")
        cfg.setdefault("retired_ad_sets", []).append(old["id"])
        old.update(id=new_set, goal=goal)
        save(cfg)
        print(f"Moved the {page} ad set to {goal}.")
    if target != old_campaign:
        meta.post(target, status="ACTIVE")
        meta.post(old_campaign, status="PAUSED")
        camp["id"] = target
    opt.update(current=goal, since=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S"))
    save(cfg)


def upload_image(meta, act, filename):
    import base64
    data = base64.b64encode((IMAGES / filename).read_bytes()).decode()
    images = meta.post(f"{act}/adimages", bytes=data)["images"]
    return next(iter(images.values()))["hash"]


# ---------------------------------------------------------------------------------------------

def load():
    return json.loads(CONFIG.read_text())


def to_account(cfg, amount):
    """A plan amount (USD) in the ad account's minor units (cents), for Meta's budget fields."""
    return str(int(round(amount * cfg.get("usd_to_account", 1.0) * 100)))


def to_plan(cfg, amount):
    """An amount Meta reports in the ad account's currency, in plan dollars."""
    return float(amount) / cfg.get("usd_to_account", 1.0)


def save(cfg):
    CONFIG.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")


def table(rows):
    lines = ["| Ad | Spend | Shown | Tap rate | Installs | Per install | Trials | Paid | Live |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---|"]
    for r in sorted(rows, key=lambda r: (r["page"], r["n"])):
        if not r["spend"] and r["status"] != "ACTIVE":
            continue
        ctr = f"{r['clicks'] / r['impressions']:.2%}" if r["impressions"] else "–"
        cpi = f"${r['spend'] / r['installs']:.2f}" if r["installs"] else "–"
        lines.append(f"| {r['key']} | ${r['spend']:.2f} | {r['impressions']:,} | {ctr} | {r['installs']} | {cpi} "
                     f"| {r['trials']} | {r['paid']} | {'yes' if r['status'] == 'ACTIVE' else 'no'} |")
    return "\n".join(lines)


def standings(rows, min_spend=3.0):
    """(winners, losers) among ads that have spent enough to judge: cheapest per install first,
    then ads with no installs by tap rate. Up to two of each, and never the same ad in both."""
    judged = [r for r in rows if r["spend"] >= min_spend]

    def key(r):
        cpi = r["spend"] / r["installs"] if r["installs"] else float("inf")
        ctr = r["clicks"] / r["impressions"] if r["impressions"] else 0
        return (cpi, -ctr)

    judged.sort(key=key)
    n = min(2, len(judged) // 2)
    return judged[:n], judged[len(judged) - n:][::-1] if n else []


def funnel(rows):
    """Taps and installs per page and overall, over the campaign so far."""
    per = {page: (sum(r["clicks"] for r in rows if r["page"] == page),
                  sum(r["installs"] for r in rows if r["page"] == page)) for page in PAGES}
    return per, sum(t for t, _ in per.values()), sum(i for _, i in per.values())


def funnel_line(rows):
    per, taps, installs = funnel(rows)
    rate = lambda t, i: f"{i}/{t} ({i / t:.1%})" if t else "no taps yet"
    return "Taps to installs: " + ", ".join(f"{p} {rate(*per[p])}" for p in PAGES) + f"; overall {rate(taps, installs)}."


def spend_call(cfg, today, rows):
    """From the date in config "spend_call", a one-time raise / hold / fix recommendation from the share
    of taps that become installs. Returns (verdict, reason, final) or None. Not final until there are
    enough taps; the review never changes budgets on it, Lanre does."""
    sc = cfg.get("spend_call")
    if not sc or sc.get("made") or today < dt.date.fromisoformat(sc["on"]):
        return None
    _, taps, installs = funnel(rows)
    if taps < sc["min_taps"]:
        return "hold", f"only {taps} taps so far, and the call needs {sc['min_taps']}. Asking again tomorrow", False
    rate, spend = installs / taps, sum(r["spend"] for r in rows)
    cpi = f"about ${spend / installs:.2f} per install" if installs else f"no installs from ${spend:.2f}"
    if rate >= sc["raise_at"]:
        return "raise", f"{rate:.1%} of {taps} taps installed ({cpi}). Raise spend for the rest of the test", True
    if rate >= sc["fix_below"]:
        return "hold", (f"{rate:.1%} of {taps} taps installed ({cpi}). Hold, and let the review keep pausing "
                        f"the weakest ads"), True
    return "fix", (f"only {rate:.1%} of {taps} taps installed ({cpi}). Fix the gap before spending more: "
                   f"check which placements the taps come from and the App Store pages they land on"), True


def verdict(r):
    ctr = r["clicks"] / r["impressions"] if r["impressions"] else 0
    if r["installs"]:
        extra = "".join(f", {r[k]} {k}" for k in ("trials", "paid") if r[k])
        return (f"{r['key']}: ${r['spend'] / r['installs']:.2f} per install ({r['installs']} installs from "
                f"${r['spend']:.2f}{extra}, {ctr:.1%} taps)")
    return f"{r['key']}: no installs from ${r['spend']:.2f} ({ctr:.1%} taps)"


def cfg_event():
    return "paywall opens (sw_paywall_open)"


def describe(c):
    if c["do"] == "pause":
        return f"Paused {c['ad']}: {c['why']}."
    if c["do"] == "launch":
        return f"Launched {c['ad']}: {c['why']}."
    if c["do"] == "pause_set":
        return f"Paused the {c['set']} ad set: {c['why']}."
    if c["do"] == "record_baseline":
        return f"{c['period']} starts: counting from " + ", ".join(
            f"{p} ${b['spend']:.2f}, {b['installs']} installs, {b['paid']} paid" for p, b in c["baseline"].items()) + "."
    if c["do"] == "record_spend_call":
        return f"Spend call made: {c['verdict']}."
    if c["do"] == "optimise":
        return f"Switched the ad sets back to optimising for {cfg_event()}: {c['why']}."
    if c["do"] == "record_split":
        return "Thanksgiving budget: " + ", ".join(f"{p} {share:.0%}" for p, share in c["split"].items()) + "."
    return f"{c['set']} budget ${c['daily']:.2f}/day ({c['why']})."


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["build", "publish", "status", "daily", "optimise"])
    ap.add_argument("--goal", choices=["LINK_CLICKS", "OFFSITE_CONVERSIONS"], help="optimise: the new performance goal")
    ap.add_argument("--apply", action="store_true", help="daily: make the changes")
    ap.add_argument("--news", action="store_true", help="daily: spend the news reserve today")
    ap.add_argument("--dry-run", action="store_true", help="build: print what it would create")
    ap.add_argument("--today", type=dt.date.fromisoformat, default=dt.date.today())
    args = ap.parse_args()
    cfg = load()

    if args.command == "build":
        return build(cfg, args.dry_run)

    meta = Meta(cfg)
    if args.command == "publish":
        return publish(cfg, meta)
    if args.command == "optimise":
        return move_ad_sets(cfg, meta, args.goal)
    rows, spent = gather(cfg, meta, args.today)
    if args.command == "status":
        print(f"Spent ${spent:.2f} of ${cfg['budget']['total']}.\n")
        print(table(rows))
        return

    opt = cfg.get("optimization", {})
    opens = superwall_paywall_opens(cfg, opt["since"]) if opt.get("current") == "LINK_CLICKS" else None
    y = meta.get_all(f"{cfg['campaign']['id']}/insights", {"date_preset": "yesterday", "fields": "impressions"})
    shown_yesterday = int(y[0]["impressions"]) if y else 0
    news = args.news and args.today.isoformat() not in cfg["budget"]["news_reserve_used"]
    reserve = cfg["budget"]["news_reserve"]
    if news and len(cfg["budget"]["news_reserve_used"]) * reserve["daily"] >= reserve["amount"]:
        news = False
        print("The news reserve is already spent.")
    changes, notes = decide(cfg, args.today, rows, spent, news=news, paywall_opens=opens, shown_yesterday=shown_yesterday)
    # Meta's account spending limit is the hard stop; it has to cover the plan's total.
    acct = meta.call("GET", cfg["ad_account"], {"fields": "spend_cap,amount_spent"})
    cap, plan = int(acct.get("spend_cap") or 0) / 100, cfg["budget"]["total"] * cfg.get("usd_to_account", 1.0)
    if cap and cap < plan - 1:
        notes.insert(0, f"ACCOUNT LIMIT: Meta's spending limit is CA${cap:.0f}, below the plan's CA${plan:.0f}; the ads stop at "
                        f"CA${cap:.0f} (CA${int(acct.get('amount_spent', 0)) / 100:.2f} spent). Raise it in Billing & payments.")
    winners, losers = standings(rows)
    if winners:
        board = [f"Winners: {'; '.join(verdict(r) for r in winners)}.", f"Losers: {'; '.join(verdict(r) for r in losers)}."]
    else:
        board = ["Too early to call winners: fewer than two ads have spent $3."]
    board.append(funnel_line(rows))
    summary = [describe(c) for c in changes if c["do"] != "budget"] or ["No ads paused or launched."]
    budgets = " ".join(describe(c) for c in changes if c["do"] == "budget")
    report = "\n".join([f"## {args.today:%a %b %-d}", "", f"Spent ${spent:.2f} of ${cfg['budget']['total']} so far."
                        + (" News reserve on today." if news else ""), "", table(rows), "",
                        *[f"- {s}" for s in board], *[f"- {s}" for s in summary], *([f"- Budgets: {budgets}"] if budgets else []),
                        *[f"- {n}" for n in notes], ""])
    print(report)
    if args.apply:
        apply(cfg, meta, changes, args.today)
        if news:
            cfg["budget"]["news_reserve_used"].append(args.today.isoformat())
        save(cfg)
        with LOG.open("a") as f:
            f.write("\n" + report)
    else:
        print("(Dry run: nothing changed. Add --apply to make these changes.)")


if __name__ == "__main__":
    main()
