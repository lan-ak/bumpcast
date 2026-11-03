"""The daily review's rules on made-up numbers.

    python3 -m unittest discover -s scripts -p 'test_meta_ads.py'
"""

import datetime as dt
import json
import unittest
from pathlib import Path

import meta_ads

CONFIG = json.loads((Path(__file__).resolve().parents[1] / "docs/release/meta/config.json").read_text())
D = dt.date.fromisoformat
# The rules as planned, before the live campaign's own decisions.
CONFIG["spend_call"].pop("made", None)
CONFIG["spend_call"].pop("verdict", None)
CONFIG.pop("off_pages", None)
# The $400 plan with Thanksgiving, before Lanre capped it at $300 on Nov 2.
CONFIG["budget"].update(total=400, news_reserve={"amount": 15, "daily": 7.5, "page": "turbulence"})
CONFIG["budget"]["periods"][0].update(to="2026-11-18", total=253)
CONFIG["budget"]["periods"][1:] = [CONFIG["budget"].pop("dropped_thanksgiving")]


def cfg():
    c = json.loads(json.dumps(CONFIG))
    for creative in c["creatives"].values():
        creative["approved"] = True
    return c


def ad(key, status="PAUSED", spend=0, impressions=0, clicks=0, installs=0, days=0, freq=1.0, launched=None, holiday=False):
    n, page = key.split("-", 1)
    return {"key": key, "n": n, "page": page, "approved": True, "holiday": holiday, "status": status,
            "launched": launched or ("2026-11-02" if status == "ACTIVE" else None), "days_live": days,
            "spend": spend, "impressions": impressions, "clicks": clicks, "frequency": freq,
            "installs": installs, "trials": 0, "paid": 0, "proceeds": 0}


def first_day():
    """Every approved ad built and paused, as on the morning of Nov 2."""
    c = cfg()
    keys = {f"{n}-{p}" for p in meta_ads.PAGES for n in c["queue"][p] + [c["holiday"][p]]}
    return [ad(k, holiday=c["creatives"][k.split("-")[0]].get("holiday", False)) for k in sorted(keys)]


def by(changes, do):
    return sorted(c.get("ad") or c.get("set") for c in changes if c["do"] == do)


class Rules(unittest.TestCase):
    def test_first_day_launches_three_per_page(self):
        changes, _ = meta_ads.decide(cfg(), D("2026-11-02"), first_day(), 0)
        self.assertEqual(by(changes, "launch"), ["01-standard", "01-tracker", "01-turbulence", "02-turbulence",
                                                 "04-tracker", "05-tracker", "07-turbulence", "08-standard", "16-standard"])
        budgets = {c["set"]: c["daily"] for c in changes if c["do"] == "budget"}
        per_set = meta_ads.test_daily(CONFIG, CONFIG["budget"]["periods"][0], D("2026-11-02"), 0)
        self.assertEqual(budgets, {"turbulence": per_set, "tracker": per_set, "standard": per_set})

    def test_before_and_after_the_campaign(self):
        start = D(CONFIG["budget"]["periods"][0]["from"])
        changes, notes = meta_ads.decide(cfg(), start - dt.timedelta(days=1), first_day(), 0)
        self.assertEqual(changes, [])
        live = [ad("01-turbulence", "ACTIVE", spend=20)]
        changes, _ = meta_ads.decide(cfg(), D("2026-11-30"), live, 299)
        self.assertEqual(by(changes, "pause"), ["01-turbulence"])

    def test_budget_spent_pauses_everything(self):
        live = [ad("01-turbulence", "ACTIVE", spend=150), ad("02-turbulence", "ACTIVE", spend=150)]
        changes, _ = meta_ads.decide(cfg(), D("2026-11-20"), live, CONFIG["budget"]["total"] + 0.4)
        self.assertEqual(by(changes, "pause"), ["01-turbulence", "02-turbulence"])
        self.assertEqual(by(changes, "launch"), [])

    def test_no_installs_and_low_tap_rate_are_paused_and_replaced(self):
        ads = first_day()
        live = {"01-turbulence": dict(spend=4, impressions=400, clicks=6, installs=1),
                "02-turbulence": dict(spend=7.5, impressions=700, clicks=9, installs=0),       # no installs
                "07-turbulence": dict(spend=5.2, impressions=600, clicks=2, installs=1)}       # 0.33% tap rate
        ads = [ad(a["key"], "ACTIVE", days=5, **live[a["key"]]) if a["key"] in live else a for a in ads]
        changes, _ = meta_ads.decide(cfg(), D("2026-11-07"), ads, 30)
        self.assertEqual(by(changes, "pause"), ["02-turbulence", "07-turbulence"])
        self.assertEqual(by(changes, "launch")[:2], ["01-standard", "01-tracker"])
        self.assertIn("10-turbulence", by(changes, "launch"))
        self.assertIn("09-turbulence", by(changes, "launch"))

    def test_anchor_is_spared_the_relative_rules_in_the_test(self):
        ads = [ad("01-tracker", "ACTIVE", spend=14, impressions=1500, clicks=20, installs=2, days=6),
               ad("04-tracker", "ACTIVE", spend=10, impressions=1000, clicks=15, installs=4, days=6),
               ad("05-tracker", "ACTIVE", spend=10, impressions=1000, clicks=15, installs=3, days=6),
               ad("12-tracker")]
        changes, _ = meta_ads.decide(cfg(), D("2026-11-08"), ads, 34)
        self.assertNotIn("01-tracker", by(changes, "pause"))
        changes, _ = meta_ads.decide(cfg(), D("2026-11-20"), ads, 200)
        self.assertIn("01-tracker", by(changes, "pause"))

    def test_starved_ad_makes_room(self):
        ads = [ad("01-standard", "ACTIVE", spend=9, impressions=900, clicks=10, installs=2, days=5),
               ad("16-standard", "ACTIVE", spend=8, impressions=800, clicks=9, installs=2, days=5),
               ad("08-standard", "ACTIVE", spend=0.6, impressions=120, clicks=1, installs=0, days=5),
               ad("11-standard")]
        changes, _ = meta_ads.decide(cfg(), D("2026-11-07"), ads, 18)
        self.assertEqual(by(changes, "pause"), ["08-standard"])
        self.assertEqual(by(changes, "launch"), ["11-standard"])

    def test_never_leaves_a_page_empty(self):
        ads = [ad("01-standard", "ACTIVE", spend=9, impressions=900, clicks=10, installs=0, days=5)]
        changes, notes = meta_ads.decide(cfg(), D("2026-11-07"), ads, 9)
        self.assertEqual(by(changes, "pause"), [])
        self.assertTrue(any("Kept 01-standard" in n for n in notes))

    def test_holiday_ad_goes_first_from_nov_16(self):
        ads = [ad("01-turbulence", "ACTIVE", spend=9, impressions=900, clicks=12, installs=2, days=14),
               ad("02-turbulence", "ACTIVE", spend=8, impressions=800, clicks=10, installs=2, days=14),
               ad("07-turbulence", "ACTIVE", spend=7.2, impressions=700, clicks=8, installs=0, days=14),
               ad("10-turbulence"), ad("03-turbulence", holiday=True)]
        changes, _ = meta_ads.decide(cfg(), D("2026-11-16"), ads, 24)
        self.assertEqual(by(changes, "launch"), ["03-turbulence"])

    def test_thanksgiving_goes_to_the_cheapest_page(self):
        ads = [ad("01-turbulence", "ACTIVE", spend=30, impressions=3000, clicks=40, installs=10, days=17),
               ad("01-tracker", "ACTIVE", spend=30, impressions=3000, clicks=40, installs=5, days=17),
               ad("01-standard", "ACTIVE", spend=30, impressions=3000, clicks=40, installs=6, days=17)]
        changes, notes = meta_ads.decide(cfg(), D("2026-11-19"), ads, 90)
        self.assertEqual(by(changes, "pause_set"), ["standard", "tracker"])
        self.assertEqual({c["set"]: c["daily"] for c in changes if c["do"] == "budget"}, {"turbulence": 12})

    def test_thanksgiving_splits_when_pages_are_close(self):
        ads = [ad("01-turbulence", "ACTIVE", spend=30, impressions=3000, clicks=40, installs=10, days=17),
               ad("01-tracker", "ACTIVE", spend=30, impressions=3000, clicks=40, installs=9, days=17),
               ad("01-standard", "ACTIVE", spend=30, impressions=3000, clicks=40, installs=2, days=17)]
        changes, _ = meta_ads.decide(cfg(), D("2026-11-19"), ads, 90)
        self.assertEqual({c["set"]: c["daily"] for c in changes if c["do"] == "budget"}, {"turbulence": 6, "tracker": 6})

    def test_thanksgiving_split_is_kept_once_decided(self):
        c = cfg()
        c["page_rule"]["split"] = {"tracker": 1.0}
        ads = [ad("01-turbulence", "ACTIVE", spend=30, impressions=3000, clicks=40, installs=10, days=17),
               ad("01-tracker", "ACTIVE", spend=90, impressions=9000, clicks=90, installs=9, days=20)]
        changes, _ = meta_ads.decide(c, D("2026-11-22"), ads, 160)
        self.assertEqual(by(changes, "record_split"), [])
        self.assertEqual(by(changes, "pause_set"), ["standard", "turbulence"])
        self.assertEqual({c["set"]: c["daily"] for c in changes if c["do"] == "budget"}, {"tracker": 12})

    def test_news_reserve_adds_to_the_turbulence_page(self):
        changes, _ = meta_ads.decide(cfg(), D("2026-11-05"), first_day(), 20, news=True)
        per_set = meta_ads.test_daily(CONFIG, CONFIG["budget"]["periods"][0], D("2026-11-05"), 20)
        extra = CONFIG["budget"]["news_reserve"]["daily"]
        self.assertEqual({c["set"]: c["daily"] for c in changes if c["do"] == "budget"},
                         {"turbulence": round(per_set + extra, 2), "tracker": per_set, "standard": per_set})

    def test_winners_and_losers(self):
        rows = [ad("01-turbulence", "ACTIVE", spend=9, impressions=900, clicks=12, installs=3),   # $3.00
                ad("02-turbulence", "ACTIVE", spend=8, impressions=800, clicks=10, installs=4),   # $2.00
                ad("04-tracker", "ACTIVE", spend=6, impressions=700, clicks=3, installs=0),       # none, 0.43%
                ad("05-tracker", "ACTIVE", spend=7, impressions=700, clicks=9, installs=1),       # $7.00
                ad("16-standard", "ACTIVE", spend=1, impressions=90, clicks=1, installs=0)]       # too little spend
        winners, losers = meta_ads.standings(rows)
        self.assertEqual([r["key"] for r in winners], ["02-turbulence", "01-turbulence"])
        self.assertEqual([r["key"] for r in losers], ["04-tracker", "05-tracker"])
        self.assertIn("$2.00 per install", meta_ads.verdict(winners[0]))
        self.assertIn("no installs from $6.00", meta_ads.verdict(losers[0]))
        self.assertEqual(meta_ads.standings(rows[4:]), ([], []))

    def test_switches_back_to_paywall_opens_at_50(self):
        c = cfg()
        c["optimization"] = {"current": "LINK_CLICKS", "since": "2026-10-28 14:10:08", "switch_back_at": 50}
        changes, notes = meta_ads.decide(c, D("2026-11-05"), first_day(), 20, paywall_opens=12)
        self.assertEqual(by(changes, "optimise"), [])
        self.assertTrue(any("now 12" in n for n in notes))
        changes, _ = meta_ads.decide(c, D("2026-11-05"), first_day(), 20, paywall_opens=51)
        self.assertEqual([x["goal"] for x in changes if x["do"] == "optimise"], ["OFFSITE_CONVERSIONS"])
        self.assertEqual(changes[0]["do"], "optimise")  # before launches and budgets, which use the new IDs
        c["optimization"]["current"] = "OFFSITE_CONVERSIONS"
        changes, _ = meta_ads.decide(c, D("2026-11-06"), first_day(), 30, paywall_opens=80)
        self.assertEqual(by(changes, "optimise"), [])

    def test_flags_a_campaign_that_isnt_delivering(self):
        live = [ad("01-turbulence", "ACTIVE", days=1)]
        _, notes = meta_ads.decide(cfg(), D("2026-11-05"), live, 0, shown_yesterday=2)
        self.assertTrue(any(n.startswith("NOT DELIVERING") for n in notes))
        _, notes = meta_ads.decide(cfg(), D("2026-11-05"), live, 0, shown_yesterday=450)
        self.assertFalse(any(n.startswith("NOT DELIVERING") for n in notes))

    def test_taps_to_installs_line(self):
        rows = [ad("01-turbulence", "ACTIVE", spend=5, impressions=900, clicks=40, installs=2),
                ad("02-turbulence", "ACTIVE", spend=3, impressions=500, clicks=10, installs=0),
                ad("04-tracker", "ACTIVE", spend=2, impressions=300, clicks=12, installs=0)]
        line = meta_ads.funnel_line(rows)
        self.assertIn("turbulence 2/50 (4.0%)", line)
        self.assertIn("tracker 0/12 (0.0%)", line)
        self.assertIn("standard no taps yet", line)
        self.assertIn("overall 2/62 (3.2%)", line)

    def spend_rows(self, taps, installs, spend=40.0):
        return [ad("01-turbulence", "ACTIVE", spend=spend, impressions=taps * 20, clicks=taps, installs=installs, days=6)]

    def test_spend_call_waits_for_nov_2_and_100_taps(self):
        self.assertIsNone(meta_ads.spend_call(cfg(), D("2026-11-01"), self.spend_rows(150, 30)))
        verdict, reason, final = meta_ads.spend_call(cfg(), D("2026-11-02"), self.spend_rows(60, 6))
        self.assertEqual((verdict, final), ("hold", False))
        self.assertIn("only 60 taps", reason)

    def test_spend_call_raise_hold_fix(self):
        self.assertEqual(meta_ads.spend_call(cfg(), D("2026-11-02"), self.spend_rows(120, 15))[0], "raise")  # 12.5%
        self.assertEqual(meta_ads.spend_call(cfg(), D("2026-11-02"), self.spend_rows(120, 8))[0], "hold")    # 6.7%
        verdict, reason, final = meta_ads.spend_call(cfg(), D("2026-11-03"), self.spend_rows(120, 3))      # 2.5%
        self.assertEqual((verdict, final), ("fix", True))
        self.assertIn("placements", reason)

    def test_spend_call_is_made_once(self):
        c = cfg()
        changes, notes = meta_ads.decide(c, D("2026-11-02"), self.spend_rows(120, 15), 40)
        self.assertTrue(any(n.startswith("SPEND CALL: RAISE") for n in notes))
        self.assertEqual([x["verdict"] for x in changes if x["do"] == "record_spend_call"], ["raise"])
        c["spend_call"]["made"] = "2026-11-02"
        changes, notes = meta_ads.decide(c, D("2026-11-03"), self.spend_rows(130, 15), 45)
        self.assertFalse(any(n.startswith("SPEND CALL") for n in notes))

    def test_boost_until_the_spend_call_then_respread(self):
        c = cfg()
        test = c["budget"]["periods"][0]
        test.update(total=153, boost_per_set=7.0, min_per_set=1.0)
        self.assertEqual(meta_ads.test_daily(c, test, D("2026-10-31"), 20), 7.0)
        c["spend_call"]["made"] = "2026-11-02"
        # $153 - $60 spent, 17 days left (Nov 2-18), 3 pages: $1.82 a page.
        self.assertEqual(meta_ads.test_daily(c, test, D("2026-11-02"), 60), 1.82)
        self.assertEqual(meta_ads.test_daily(c, test, D("2026-11-17"), 152), 1.0)  # never below the floor

    def test_a_page_switched_off_is_skipped_and_its_budget_shared(self):
        c = cfg()
        c["off_pages"] = {"tracker": "no installs"}
        c["spend_call"]["made"] = "2026-11-02"
        test = c["budget"]["periods"][0]
        rows = [ad("02-turbulence", "ACTIVE", spend=5, days=1), ad("04-tracker", "ACTIVE", spend=30, days=1),
                ad("08-standard", "ACTIVE", spend=5, days=1)]
        changes, notes = meta_ads.decide(c, D("2026-11-03"), rows, 200)
        self.assertNotIn("04-tracker", by(changes, "pause") + by(changes, "launch"))
        self.assertEqual(by(changes, "budget"), ["standard", "turbulence"])
        self.assertFalse(any("tracker" in n for n in notes))
        # $253 - $200, 16 days left (Nov 3-18), 2 pages: $1.66 a page.
        self.assertEqual(meta_ads.test_daily(c, test, D("2026-11-03"), 200), 1.66)

    def test_cad_account_converts_both_ways(self):
        c = cfg()
        c["usd_to_account"] = 1.4
        self.assertEqual(meta_ads.to_account(c, 3), "420")
        self.assertAlmostEqual(meta_ads.to_plan(c, "14.00"), 10.0)
        c["usd_to_account"] = 1.0
        self.assertEqual(meta_ads.to_account(c, 7.5), "750")

    def test_unapproved_ads_never_launch(self):
        c = cfg()
        c["creatives"]["02"]["approved"] = False
        ads = [dict(a, approved=c["creatives"][a["n"]]["approved"]) for a in first_day()]
        changes, _ = meta_ads.decide(c, D("2026-11-02"), ads, 0)
        self.assertNotIn("02-turbulence", by(changes, "launch"))
        self.assertIn("10-turbulence", by(changes, "launch"))


if __name__ == "__main__":
    unittest.main()
