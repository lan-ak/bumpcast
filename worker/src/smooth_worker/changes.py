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


def confidence(source: str | None) -> str:
    return "confirmed" if source == "gtg" else "partly confirmed" if source == "mixed" else "early"


def _overlaps(a: dict, b: dict, slack: int = 5) -> bool:
    return a["start_min"] <= b["end_min"] + slack and b["start_min"] <= a["end_min"] + slack


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

    old_segs, new_segs = old.get("segments") or [], new.get("segments") or []
    for seg in new_segs:
        match = next((o for o in old_segs if _overlaps(o, seg)), None)
        label = SEVERITY_TITLES.get(seg["severity"], seg["severity"])
        if match is None:
            points.append(f"New: {label} {when_text(seg['start_min'])}, while {PHASES.get(seg['phase'], 'cruising')}.")
        elif severity.ORDER.index(seg["severity"]) != severity.ORDER.index(match["severity"]):
            was = SEVERITY_TITLES.get(match["severity"], match["severity"])
            points.append(f"The bumps {when_text(seg['start_min'])} are now {label} (were {was}).")
    for seg in old_segs:
        if not any(_overlaps(seg, n) for n in new_segs):
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
    if confidence(new.get("source")) != confidence(old.get("source")) and new.get("source") in ("gtg", "mixed"):
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
