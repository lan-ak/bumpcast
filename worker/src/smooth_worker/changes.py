"""Plain-language "what changed and why" between two forecasts of the same flight."""

from datetime import datetime
from zoneinfo import ZoneInfo

from . import severity

GRADE_TITLES = {
    "smooth": "Smooth flight",
    "mostly_smooth": "Mostly smooth",
    "some_bumps": "A few bumps",
    "bumpy": "Bumpy in places",
    "rough": "Some rough patches",
}
GRADE_ORDER = list(GRADE_TITLES)
SEVERITY_TITLES = {"light": "light chop", "moderate": "moderate bumps", "severe": "strong bumps"}
PHASES = {"climb": "climbing", "cruise": "cruising", "descent": "descending"}


def grade_title(grade: str | None) -> str:
    return GRADE_TITLES.get(grade or "", "Forecast ready")


def minutes_text(minutes: int) -> str:
    h, m = divmod(minutes, 60)
    if h == 0:
        return f"{m} min"
    return f"{h} h" if m == 0 else f"{h} h {m} min"


def when_text(start_min: int) -> str:
    return "right after takeoff" if start_min <= 2 else f"{minutes_text(start_min)} in"


def confidence(source: str | None, noaa_possible: bool | None = None) -> str:
    """'early' also covers routes NOAA's detailed forecast will never fully cover: they stay an outlook."""
    if noaa_possible is False:
        return "early"
    return "confirmed" if source == "gtg" else "partly confirmed" if source == "mixed" else "early"


# Stretches (or warnings) within this many minutes of each other are the same one.
SLACK_MIN = 5
# Old stretches are moved onto the new forecast's timeline when its flight time changed by at most
# this ratio (winds, or a new flight-profile model); beyond it, it's a different flight.
MAX_RESCALE = 1.4


def overlaps(a: dict, b: dict, slack: int = SLACK_MIN) -> bool:
    return a["start_min"] <= b["end_min"] + slack and b["start_min"] <= a["end_min"] + slack


def on_timeline(old: dict, new: dict, key: str = "segments") -> list[dict]:
    """`old`'s stretches (or warnings) on `new`'s timeline. A recomputed flight path (new winds, or
    a better profile model) can land the flight minutes earlier or later, and every stretch then
    moves in proportion: AC 1507's 52-minute plan became 59 minutes, so bumps 45 min in are now
    51 min in. That isn't a change in the weather. Texts keep the old minutes the user heard."""
    items = old.get(key) or []
    before, after = old.get("duration_min"), new.get("duration_min")
    if not before or not after or before == after or not 1 / MAX_RESCALE <= after / before <= MAX_RESCALE:
        return items
    k = after / before
    return [{**i, "start_min": round(i["start_min"] * k), "end_min": round(i["end_min"] * k)} for i in items]


def _match(seg: dict, olds: list[dict]) -> int | None:
    """The old stretch a new one continues: an overlapping one, the same severity first, so a
    stretch that moved a few minutes isn't compared with its neighbour."""
    near = [i for i, o in enumerate(olds) if overlaps(o, seg)]
    return next((i for i in near if olds[i]["severity"] == seg["severity"]), near[0] if near else None)


def describe(old: dict | None, new: dict, tz: str | None = None) -> list[str]:
    """Bullet points, most important first. `old` is the forecast the user last heard about."""
    if old is None:
        return _first_look(new)

    points: list[str] = []
    old_grade, new_grade = old.get("grade"), new.get("grade")
    if old_grade != new_grade:
        direction = "better" if GRADE_ORDER.index(new_grade) < GRADE_ORDER.index(old_grade) else "bumpier"
        points.append(f"Looking {direction}: {grade_title(old_grade)} → {grade_title(new_grade)}.")
    else:
        points.append(f"Still {grade_title(new_grade).lower()}.")

    if old.get("profile") != new.get("profile"):
        # Built with an older flight profile: stretches moved because we now model the climb,
        # cruise and descent more closely, not because the weather changed. Say that instead.
        points.append("We now time your flight's climb, cruise and descent more closely, so bumps may sit a few minutes earlier or later.")
        points.append("Why: we've improved how we model your flight.")
        return points

    old_segs, new_segs = old.get("segments") or [], new.get("segments") or []
    moved = on_timeline(old, new)
    for seg in new_segs:
        match = _match(seg, moved)
        label = SEVERITY_TITLES.get(seg["severity"], seg["severity"])
        if match is None:
            points.append(f"New: {label} {when_text(seg['start_min'])}, while {PHASES.get(seg['phase'], 'cruising')}.")
        elif severity.ORDER.index(seg["severity"]) != severity.ORDER.index(moved[match]["severity"]):
            was = SEVERITY_TITLES.get(moved[match]["severity"], moved[match]["severity"])
            points.append(f"The bumps {when_text(seg['start_min'])} are now {label} (were {was}).")
    for seg, at in zip(old_segs, moved):
        if not any(overlaps(at, n) for n in new_segs):
            label = SEVERITY_TITLES.get(seg["severity"], seg["severity"])
            points.append(f"Eased: the {label} {when_text(seg['start_min'])} is no longer expected.")
    def shape(segs: list[dict]) -> list[tuple]:
        return [(seg["start_min"], seg["end_min"], seg["severity"]) for seg in segs]

    if len(points) == 1 and shape(old_segs) == shape(new_segs):
        points.append("No change to where the bumps are.")
    elif len(points) == 1:
        points.append("The bumpy stretches have shifted slightly.")

    points.append(_why(old, new, tz))
    return points


def _first_look(new: dict) -> list[str]:
    segs = new.get("segments") or []
    if not segs:
        return ["Calm air expected the whole way."]
    worst = max(segs, key=lambda s: severity.ORDER.index(s["severity"]))
    total = sum(s["end_min"] - s["start_min"] + 1 for s in segs)
    return [
        f"{len(segs)} bumpy stretch{'es' if len(segs) > 1 else ''}, about {minutes_text(total)} in total.",
        f"Strongest: {SEVERITY_TITLES.get(worst['severity'], worst['severity'])} {when_text(worst['start_min'])}.",
    ]


def _why(old: dict, new: dict, tz: str | None) -> str:
    new_confidence = confidence(new.get("source"), new.get("noaa_possible"))
    if new_confidence != confidence(old.get("source"), old.get("noaa_possible")) and new_confidence != "early":
        return "Why: your forecast is now confirmed with our detailed forecast."
    run = new.get("model_run")
    if not run:
        return "Why: updated with the latest forecast data."
    run_at = datetime.fromisoformat(str(run).replace("Z", "+00:00"))
    try:
        local = run_at.astimezone(ZoneInfo(tz)) if tz else run_at
    except (KeyError, ValueError):
        local = run_at
    stamp = local.strftime("%-I %p").lower() + ("" if tz else " UTC")
    return f"Why: updated with the latest forecast data ({stamp})."
