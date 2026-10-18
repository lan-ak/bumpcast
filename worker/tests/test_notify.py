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


def test_describe_unchanged_uses_model_run_time():
    f = {"grade": "smooth", "source": "gfs", "segments": [], "model_run": "2026-10-18T12:00:00+00:00"}
    points = changes.describe(f, f, tz="America/Toronto")
    assert points == [
        "Still smooth flight.",
        "No change to where the bumps are.",
        "Why: updated with the latest forecast data (8 am).",
    ]


def test_quiet_hours_hold_overnight_unless_flying_early():
    from datetime import UTC, datetime, timedelta

    night = datetime(2026, 10, 19, 6, tzinfo=UTC)  # 2 am in Toronto
    assert notify.is_quiet(night, "America/Toronto", night + timedelta(hours=20))
    assert not notify.is_quiet(night, "America/Toronto", night + timedelta(hours=3))  # early flight
    day = datetime(2026, 10, 19, 16, tzinfo=UTC)  # noon in Toronto
    assert not notify.is_quiet(day, "America/Toronto", day + timedelta(hours=20))
