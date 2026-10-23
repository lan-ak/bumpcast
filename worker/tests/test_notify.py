from datetime import UTC, datetime, timedelta

from smooth_worker import changes, notify

READY = {"status": "ready", "source": "gfs", "grade": "smooth", "segments": []}


def seg(start, end, sev, phase="cruise"):
    return {"start_min": start, "end_min": end, "severity": sev, "phase": phase}


def test_current_milestone():
    assert notify.current_milestone(60) is None
    assert notify.current_milestone(47.9) == "48h"
    assert notify.current_milestone(23) == "24h"
    assert notify.current_milestone(5.5) == "6h"
    assert notify.current_milestone(0.5) == "2h"


def test_first_notification_is_ready_and_free():
    p = notify.plan(30, READY, [])
    assert (p.milestone, p.kind, p.pro_only) == ("48h", "ready", False)
    # A flight saved late still gets "ready" first, at whatever milestone it's in.
    assert notify.plan(4, READY, []).milestone == "6h"


def test_updates_are_pro_and_not_repeated():
    sent = [{"milestone": "48h", "kind": "ready", "source": "gfs"}]
    assert notify.plan(30, READY, sent) is None
    p = notify.plan(20, READY, sent)
    assert (p.milestone, p.kind, p.pro_only) == ("24h", "update", True)


def test_noaa_confirmation_between_milestones():
    sent = [{"milestone": "48h", "kind": "ready", "source": "gfs"}, {"milestone": "24h", "kind": "update", "source": "gfs"}]
    confirmed = {**READY, "source": "gtg"}
    p = notify.plan(16, confirmed, sent)
    assert (p.milestone, p.kind) == ("noaa", "confirmed")
    # Not when the user already heard a NOAA-based forecast.
    sent[-1]["source"] = "mixed"
    assert notify.plan(16, confirmed, sent) is None


def test_retry_undelivered_until_a_device_registers():
    now = datetime(2026, 10, 18, 17, 35, tzinfo=UTC)
    sent = [{"milestone": "24h", "kind": "ready", "delivered": False, "error": "no device", "created_at": "2026-10-18T17:30:46Z"}]
    assert notify.retry(sent, now) is sent[0]
    # Not once it's old, delivered, or failed for a reason a retry won't fix.
    assert notify.retry(sent, now + timedelta(hours=2)) is None
    assert notify.retry([{**sent[0], "delivered": True, "error": None}], now) is None
    assert notify.retry([{**sent[0], "error": "locked: needs Pro or a flight pass"}], now) is None
    assert notify.retry([], now) is None


def test_no_notification_for_unready_forecast():
    assert notify.plan(10, {"status": "out_of_coverage"}, []) is None


def test_describe_changes():
    old = {"grade": "some_bumps", "source": "gfs", "segments": [seg(30, 40, "light"), seg(90, 100, "light")]}
    new = {"grade": "bumpy", "source": "gtg", "segments": [seg(32, 45, "moderate"), seg(150, 160, "light")]}
    points = changes.describe(old, new)
    assert points[0] == "Looking bumpier: A few bumps → Bumpy in places."
    assert "The bumps 32 min in are now moderate bumps (were light chop)." in points
    assert "New: light chop 2 h 30 min in, while cruising." in points
    assert "Eased: the light chop 1 h 30 min in is no longer expected." in points
    assert points[-1] == "Why: your forecast is now confirmed with our detailed forecast."


def test_a_replanned_flight_moves_its_stretches_without_change_notes():
    """A new flight-path model (or new winds) lands BAW112 JFK-LHR at 352 min instead of 405: the
    same light chop is now 261-269 min in, not 300-310. Same weather, so no "New"/"Eased"."""
    old = {"grade": "some_bumps", "source": "gfs", "duration_min": 405}
    old["segments"] = [seg(20, 26, "light", "climb"), seg(300, 310, "light")]
    new = {"grade": "some_bumps", "source": "gfs", "duration_min": 352}
    new["segments"] = [seg(17, 23, "light", "climb"), seg(261, 269, "light")]
    points = changes.describe(old, new)
    assert points[:2] == ["Still a few bumps.", "The bumpy stretches have shifted slightly."]
    assert len(points) == 3
    from smooth_worker import status

    assert status.forecast_changed({**old, "status": "ready"}, {**new, "status": "ready"}) is False
    # A real change on the new timeline is still news.
    rougher = {**new, "segments": [seg(17, 23, "light", "climb"), seg(261, 269, "moderate")]}
    assert "The bumps 4 h 21 min in are now moderate bumps (were light chop)." in changes.describe(old, rougher)
    assert status.forecast_changed({**old, "status": "ready"}, {**rougher, "status": "ready"}) is True


def test_a_stretch_that_moved_a_little_is_not_compared_with_its_neighbour():
    """Light chop then moderate bumps, both a few minutes later: no "now moderate (were light)"."""
    old = {"grade": "some_bumps", "source": "gtg", "segments": [seg(10, 14, "light"), seg(16, 20, "moderate")]}
    new = {"grade": "some_bumps", "source": "gtg", "segments": [seg(12, 16, "light"), seg(19, 23, "moderate")]}
    points = changes.describe(old, new)
    assert points[1] == "The bumpy stretches have shifted slightly." and len(points) == 3


def test_old_stretches_only_move_with_a_similar_flight_time():
    old = {"duration_min": 100, "segments": [seg(50, 60, "light")]}
    assert changes.on_timeline(old, {"duration_min": 110})[0]["start_min"] == 55
    assert changes.on_timeline(old, {"duration_min": 200})[0]["start_min"] == 50  # a different flight
    assert changes.on_timeline(old, {})[0]["start_min"] == 50
    assert changes.on_timeline({"segments": [seg(50, 60, "light")]}, {"duration_min": 110})[0]["start_min"] == 50


def test_describe_unchanged_uses_model_run_time():
    f = {"grade": "smooth", "source": "gfs", "segments": [], "model_run": "2026-10-18T12:00:00+00:00"}
    points = changes.describe(f, f, tz="America/Toronto")
    assert points == [
        "Still smooth flight.",
        "No change to where the bumps are.",
        "Why: updated with the latest forecast data (8 am).",
    ]


def test_quiet_hours_hold_overnight_unless_flying_early():
    night = datetime(2026, 10, 19, 6, tzinfo=UTC)  # 2 am in Toronto
    assert notify.is_quiet(night, "America/Toronto", night + timedelta(hours=20))
    assert not notify.is_quiet(night, "America/Toronto", night + timedelta(hours=3))  # early flight
    day = datetime(2026, 10, 19, 16, tzinfo=UTC)  # noon in Toronto
    assert not notify.is_quiet(day, "America/Toronto", day + timedelta(hours=20))


# Connecting flights share a push


def leg(fid, origin, destination, departure, user="u1", grade="smooth", forecast_id=None):
    return {
        "id": fid,
        "user_id": user,
        "origin": origin,
        "destination": destination,
        "departure_at": departure.isoformat(),
        "forecasts": [{**READY, "id": forecast_id or f"fc-{fid}", "grade": grade}],
    }


T0 = datetime(2026, 10, 22, 13, tzinfo=UTC)  # 9 am in Toronto: never quiet hours


def test_connections_link_legs_of_one_trip():
    a = leg("a", "KEWR", "KDEN", T0)
    b = leg("b", "KDEN", "KSFO", T0 + timedelta(hours=4))
    other_user = leg("c", "KDEN", "KSFO", T0 + timedelta(hours=4), user="u2")
    return_trip = leg("d", "KSFO", "KEWR", T0 + timedelta(days=3))
    assert notify.connections([b, other_user, a, return_trip]) == {"a": b}


def test_folds_only_for_short_layovers():
    a = leg("a", "KEWR", "KDEN", T0)
    assert notify.folds("48h", a, leg("b", "KDEN", "KSFO", T0 + timedelta(hours=8)))
    assert not notify.folds("48h", a, leg("b", "KDEN", "KSFO", T0 + timedelta(hours=9)))
    assert notify.folds("6h", a, leg("b", "KDEN", "KSFO", T0 + timedelta(hours=3)))
    assert not notify.folds("6h", a, leg("b", "KDEN", "KSFO", T0 + timedelta(hours=4)))
    assert not notify.folds("2h", a, leg("b", "KDEN", "KSFO", T0 + timedelta(hours=1)))


def test_compose_trip():
    a = leg("a", "KEWR", "KDEN", T0)
    b = leg("b", "KDEN", "KSFO", T0 + timedelta(hours=4), grade="some_bumps")
    ready = notify.Plan("48h", "ready", pro_only=False)
    title, body = notify.compose_trip(ready, a, b, a["forecasts"][0], b["forecasts"][0])
    assert title == "Your trip via DEN: forecasts ready"
    assert body.startswith("EWR→DEN: smooth flight. DEN→SFO: a few bumps.")
    update = notify.Plan("24h", "update", pro_only=True)
    assert notify.compose_trip(update, a, b, a["forecasts"][0], b["forecasts"][0])[0] == "Your trip via DEN in 24 hours"


class FakeDB:
    def __init__(self, flights, sent=None, pro=False):
        self.flights, self.sent, self.pro = flights, sent or {}, pro
        self.rows, self.updates = [], []

    def upcoming_flights_with_latest_forecast(self, now):
        return self.flights

    def notifications_for(self, ids):
        return self.sent

    def profiles(self, ids):
        return {u: {"is_pro": self.pro, "timezone": "America/Toronto"} for u in ids}

    def flights_with_passes(self, ids):
        return set()

    def devices(self, ids):
        return {u: [{"token": "t", "environment": "production"}] for u in ids}

    def forecast(self, fid):
        return None

    def insert_notification(self, row):
        self.rows.append(row)
        return f"n{len(self.rows)}"

    def update_notification(self, nid, **outcome):
        self.updates.append((nid, outcome))


class FakeApns:
    def __init__(self):
        self.pushes = []

    def send(self, token, environment, payload, collapse_id=None):
        self.pushes.append(payload)

        class Result:
            ok, reason, token_dead = True, None, False

        return Result()


def test_trip_legs_share_one_ready_push():
    now = T0 - timedelta(hours=40)  # both legs inside 48 h
    a = leg("a", "KEWR", "KDEN", T0)
    b = leg("b", "KDEN", "KSFO", T0 + timedelta(hours=4), grade="some_bumps")
    db, apns = FakeDB([b, a]), FakeApns()
    notify.run(db, apns, now)
    assert len(apns.pushes) == 1
    assert apns.pushes[0]["aps"]["alert"]["title"] == "Your trip via DEN: forecasts ready"
    # Each leg keeps its own record, both marked delivered.
    assert sorted(r["flight_id"] for r in db.rows) == ["a", "b"]
    assert all(o["delivered"] for _, o in db.updates)


def test_first_leg_waits_for_the_second_then_goes_alone():
    a = leg("a", "KEWR", "KDEN", T0)
    b = leg("b", "KDEN", "KSFO", T0 + timedelta(hours=4))
    b["forecasts"] = []  # the second leg's forecast isn't ready yet
    db, apns = FakeDB([a, b]), FakeApns()
    notify.run(db, apns, T0 - timedelta(hours=47))  # a is inside 48 h, b isn't yet
    assert apns.pushes == []
    notify.run(db, apns, T0 - timedelta(hours=42))  # past the wait: a goes on its own
    assert apns.pushes[0]["aps"]["alert"]["title"] == "Your EWR→DEN forecast is ready"


def test_separate_trips_stay_separate():
    a = leg("a", "KEWR", "KDEN", T0)
    b = leg("b", "KDEN", "KSFO", T0 + timedelta(hours=20))  # long layover: no fold for 48 h
    db, apns = FakeDB([a, b]), FakeApns()
    notify.run(db, apns, T0 - timedelta(hours=20))
    titles = sorted(p["aps"]["alert"]["title"] for p in apns.pushes)
    assert titles == ["Your DEN→SFO forecast is ready", "Your EWR→DEN forecast is ready"]


def test_outlook_only_updates_push_only_for_real_changes():
    worth = notify.outlook_change_worth_pushing
    old = {"grade": "some_bumps", "warnings": []}
    outlook = {"noaa_possible": False, "warnings": []}
    assert not worth(old, {**outlook, "grade": "bumpy"})  # one step: recorded, not pushed
    assert not worth(old, {**outlook, "grade": "mostly_smooth"})
    assert worth(old, {**outlook, "grade": "rough"})  # two steps
    assert worth(old, {**outlook, "grade": "smooth"})
    warning = {"start_min": 60, "end_min": 120, "kind": "sigmet", "severity": "moderate"}
    assert worth(old, {**outlook, "grade": "some_bumps", "warnings": [warning]})  # new warning
    assert not worth({**old, "warnings": [warning]}, {**outlook, "grade": "some_bumps", "warnings": [warning]})
    # Routes NOAA can cover, and first looks, are unchanged.
    assert worth(old, {"grade": "bumpy", "noaa_possible": True})
    assert worth(old, {"grade": "bumpy"})
    assert worth(None, {**outlook, "grade": "bumpy"})


class BetaDB(FakeDB):
    def __init__(self, flights, beta, waitlisted=(), sent=None):
        super().__init__(flights, sent=sent)
        self.beta, self.waiting = beta, set(waitlisted)

    def profiles(self, ids):
        return {u: {"is_pro": False, "timezone": "America/Toronto", "global_beta": self.beta} for u in ids}

    def waitlisted(self, ids):
        return self.waiting & set(ids)


def outlook_leg(fid="x", **kw):
    flight = leg(fid, "KBOS", "EGLL", T0, **kw)
    flight["forecasts"][0]["noaa_possible"] = False
    return flight


def test_outlook_routes_are_quiet_until_the_beta_is_on():
    db, apns = BetaDB([outlook_leg()], beta=None), FakeApns()
    notify.run(db, apns, T0 - timedelta(hours=40))
    assert db.rows == [] and apns.pushes == []
    db, apns = BetaDB([outlook_leg()], beta=True), FakeApns()
    notify.run(db, apns, T0 - timedelta(hours=40))
    assert [r["kind"] for r in db.rows] == ["ready"] and len(apns.pushes) == 1


def test_waitlist_hears_once_that_their_route_is_covered():
    db, apns = BetaDB([outlook_leg()], beta=None, waitlisted={"u1"}), FakeApns()
    notify.run(db, apns, T0 - timedelta(hours=40))
    [row] = db.rows
    assert (row["milestone"], row["kind"], row["pro_only"]) == ("beta", "beta", False)
    assert row["title"] == "A forecast for your flight is ready to try"
    assert row["body"] == "BOS → LHR on Thu 22 Oct can use our beta global outlook. Tap to turn it on."
    # Not again, and not for people who already chose (on or off).
    sent = {"x": [{"milestone": "beta", "kind": "beta", "source": "mixed"}]}
    assert notify.beta_invite_due({"status": "ready", "noaa_possible": False}, {"global_beta": None}, True, sent["x"]) is False
    db, apns = BetaDB([outlook_leg()], beta=False, waitlisted={"u1"}), FakeApns()
    notify.run(db, apns, T0 - timedelta(hours=40))
    assert db.rows == []


def test_us_routes_ignore_the_beta_switch():
    db, apns = BetaDB([leg("us", "KEWR", "KDEN", T0)], beta=False), FakeApns()
    notify.run(db, apns, T0 - timedelta(hours=40))
    assert [r["kind"] for r in db.rows] == ["ready"]


def test_a_new_flight_profile_is_not_described_as_new_weather():
    old = {"grade": "some_bumps", "segments": [seg(11, 12, "light"), seg(21, 29, "light")], "model_run": "2026-10-22T16:00:00+00:00"}
    new = {**old, "profile": 2, "segments": [seg(14, 16, "light"), seg(25, 33, "light")]}
    points = changes.describe(old, new)
    assert points[0] == "Still a few bumps."
    assert not any("are now" in p or p.startswith("New:") or p.startswith("Eased:") for p in points)
    assert points[-1] == "Why: we've improved how we model your flight."
    # Both built with the new model: changes are described as usual.
    assert changes.describe({**old, "profile": 2}, new)[-1].startswith("Why: updated with the latest forecast data")
