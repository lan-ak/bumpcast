"""Create BumpCast's Apple Ads campaigns, all PAUSED, from the launch plan.

The plan: https://claude.ai/artifact/SjHcq1JNTpDFTjQ8jjPGV3
Apple Ads org "Akinyemi & Co Ltd." bills in CAD, so US amounts are converted at USD_TO_CAD.
Campaigns that already exist (by name) are skipped, so the script is safe to re-run.

    python3 scripts/apple_ads_setup.py --dry-run     # print what it would create
    python3 scripts/apple_ads_setup.py               # create everything, paused
    python3 scripts/apple_ads_setup.py --app 58179   # once BumpCast's own connection is set up
"""

import argparse
import json
import subprocess
import sys

ADAM_ID = 6824269447  # BumpCast Flight: Turbulence
USD_TO_CAD = 1.40
CURRENCY = "CAD"
PREFIX = "BumpCast"

NEGATIVES = [
    "game", "games", "simulator", "flight simulator", "pilot", "pilot training", "flight school",
    "aviation weather", "crash", "plane crash", "ticket", "tickets", "cheap flights", "booking",
    "hotel", "drone", "movie", "film", "rc", "model", "stock", "market", "wind turbine",
]
NEGATIVES_CA = ["training", "flightsafety international"]

TURBULENCE_TAIL = [
    "turbulence app", "turbulence tracker", "flight turbulence", "turbulence map", "turbulence forecast app",
    "turbulence radar", "turbulence prediction", "turbulence report", "turbulence alert",
    "flight turbulence forecast", "will my flight be bumpy", "bumpy flight", "airplane turbulence",
    "plane turbulence", "forecast turbulence", "flying forecast", "flight forecast",
]
NERVOUS_TAIL = [
    "flight anxiety", "nervous flyer", "flying anxiety", "afraid of flying", "fear of flying app",
    "scared of flying", "aviophobia", "nervous flying", "flight anxiety app", "calm flying",
    "plane anxiety", "flying phobia", "airplane anxiety",
]
COMPETITORS = [
    "turbli", "turbuli", "turbli forecast", "soar fear of flying", "sky guru", "flycalm",
    "turbulence forecast flight+",
]
DISCOVERY_BROAD = ["turbulence", "fear of flying", "flight anxiety"]


def group(name, bid, keywords=(), broad=(), search_match=False):
    return {"name": name, "bid": bid, "exact": list(keywords), "broad": list(broad), "search_match": search_match}


# Bids and budgets in each campaign's plan currency: "USD" ones get converted.
CAMPAIGNS = [
    {"name": "US - Brand", "countries": ["US"], "cur": "USD", "daily": 3, "groups": [
        group("bumpcast", 0.50, ["bumpcast"]),
        group("bump cast", 0.50, ["bump cast"]),
    ]},
    {"name": "US - Turbulence", "countries": ["US"], "cur": "USD", "daily": 20, "groups": [
        group("turbulence forecast", 2.50, ["turbulence forecast"]),
        group("turbulence", 2.25, ["turbulence"]),
        group("Turbulence long tail", 1.75, TURBULENCE_TAIL),
    ]},
    {"name": "US - Nervous flyer", "countries": ["US"], "cur": "USD", "daily": 12, "groups": [
        group("fear of flying", 2.00, ["fear of flying"]),
        group("Nervous flyer long tail", 1.50, NERVOUS_TAIL),
    ]},
    {"name": "US - Competitors", "countries": ["US"], "cur": "USD", "daily": 5, "groups": [
        group("skyguru", 1.40, ["skyguru"]),
        group("Competitors", 1.00, COMPETITORS),
    ]},
    {"name": "US - Flight-adjacent", "countries": ["US"], "cur": "USD", "daily": 15, "groups": [
        group("my flight", 1.00, ["my flight"]),
        group("flight path", 0.80, ["flight path"]),
    ]},
    {"name": "US - Discovery", "countries": ["US"], "cur": "USD", "daily": 5, "discovery": True, "groups": [
        group("Discovery", 1.00, broad=DISCOVERY_BROAD, search_match=True),
    ]},
    {"name": "CA - All", "countries": ["CA"], "cur": "CAD", "daily": 15, "ca": True, "groups": [
        group("Brand", 0.50, ["bumpcast", "bump cast"]),
        group("turbulence forecast", 2.00, ["turbulence forecast"]),
        group("turbulence", 1.75, ["turbulence"]),
        group("fear of flying", 1.50, ["fear of flying"]),
        group("Turbulence long tail", 1.25, TURBULENCE_TAIL),
        group("Nervous flyer long tail", 1.00, NERVOUS_TAIL),
        group("Competitors", 1.00, COMPETITORS + ["skyguru"]),
        group("flight safety", 0.75, ["flight safety"]),
        group("Discovery", 0.75, broad=DISCOVERY_BROAD, search_match=True),
    ]},
]


def cad(amount, cur):
    value = amount * USD_TO_CAD if cur == "USD" else amount
    return {"amount": f"{value:.2f}", "currency": CURRENCY}


class Runner:
    def __init__(self, app, dry_run):
        self.app, self.dry_run = app, dry_run

    def asa(self, *args, body=None):
        cmd = ["superwall", "asa", *args, "--app", str(self.app), "--json"]
        if body is not None:
            cmd += ["--body", json.dumps(body)]
        if self.dry_run:
            print("  $", " ".join(cmd[:-2] if body is not None else cmd))
            if body is not None:
                print("   ", json.dumps(body)[:400])
            return {"data": {"id": "DRY"}}
        out = subprocess.run(cmd, capture_output=True, text=True)
        try:
            result = json.loads(out.stdout or out.stderr)
        except json.JSONDecodeError:
            sys.exit(f"Unreadable output from {' '.join(args)}:\n{out.stdout}\n{out.stderr}")
        if "error" in result and result["error"]:
            sys.exit(f"Failed: {' '.join(args)}\n{json.dumps(result['error'], indent=2)}")
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", default="58179", help="Superwall app whose Apple Ads connection to use (BumpCast)")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    run = Runner(args.app, args.dry_run)

    if not args.dry_run:
        found = run.asa("apps", "get", str(ADAM_ID))
        print(f"App: {found['data'].get('appName')} ({ADAM_ID})")
        existing = {c["name"] for c in run.asa("campaigns", "list", "--all")["data"]}
    else:
        existing = set()

    for spec in CAMPAIGNS:
        name = f"{PREFIX} {spec['name']}"
        if name in existing:
            print(f"skip  {name} (exists)")
            continue
        print(f"create {name}")
        campaign = run.asa("campaigns", "create", body={
            "name": name,
            "adamId": ADAM_ID,
            "countriesOrRegions": spec["countries"],
            "dailyBudgetAmount": cad(spec["daily"], spec["cur"]),
            "supplySources": ["APPSTORE_SEARCH_RESULTS"],
            "adChannelType": "SEARCH",
            "billingEvent": "TAPS",
            "status": "PAUSED",
        })["data"]
        cid = str(campaign["id"])

        negatives = NEGATIVES + (NEGATIVES_CA if spec.get("ca") else [])
        run.asa("negative-keywords", "create", "--campaign", cid,
                body=[{"text": t, "matchType": "BROAD"} for t in negatives])

        # Discovery groups exclude every exact keyword in the same country.
        country_exact = sorted({k for s in CAMPAIGNS if s["countries"] == spec["countries"]
                                for g in s["groups"] for k in g["exact"]})

        for g in spec["groups"]:
            adgroup = run.asa("adgroups", "create", "--campaign", cid, body={
                "name": g["name"],
                "defaultBidAmount": cad(g["bid"], spec["cur"]),
                "automatedKeywordsOptIn": g["search_match"],
                "pricingModel": "CPC",
                "startTime": campaign.get("startTime") or "2026-11-09T00:00:00.000",
                "targetingDimensions": {"deviceClass": {"included": ["IPHONE"]}},
                "status": "PAUSED",
            })["data"]
            gid = str(adgroup["id"])
            keywords = [{"text": k, "matchType": "EXACT", "bidAmount": cad(g["bid"], spec["cur"])} for k in g["exact"]]
            keywords += [{"text": k, "matchType": "BROAD", "bidAmount": cad(g["bid"], spec["cur"])} for k in g["broad"]]
            if keywords:
                run.asa("keywords", "create", "--campaign", cid, "--adgroup", gid, body=keywords)
            if g["search_match"]:
                run.asa("negative-keywords", "create", "--campaign", cid, "--adgroup", gid,
                        body=[{"text": k, "matchType": "EXACT"} for k in country_exact])
            print(f"   group {g['name']}: {len(keywords)} keywords")

    print("Done. Everything is PAUSED." if not args.dry_run else "Dry run only; nothing was created.")


if __name__ == "__main__":
    main()
