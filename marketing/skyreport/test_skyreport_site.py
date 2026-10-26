"""Run with: uv run --project worker pytest marketing/skyreport"""

import json
import sys
from datetime import UTC, date, datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

import build_site  # noqa: E402
import render_cards  # noqa: E402
import report as rpt  # noqa: E402

SAMPLE = Path(__file__).parent / "fixtures" / "sample-report.json"


@pytest.fixture
def report():
    return json.loads(SAMPLE.read_text())


def test_refuses_sample_and_stale(report):
    with pytest.raises(SystemExit, match="sample"):
        rpt.check_fresh(report, rpt.parse_time(report["generated_at"]))
    with pytest.raises(SystemExit, match="old"):
        rpt.check_fresh(report, datetime(2026, 10, 27, tzinfo=UTC), allow_sample=True)
    rpt.check_fresh(report, rpt.parse_time(report["generated_at"]), allow_sample=True)


def test_summary_finds_worst_and_smoothest():
    route = {"days": [{"date": "2026-10-27", "departures": [
        {"slot": "morning", "status": "ready", "grade": "smooth", "score": 98},
        {"slot": "afternoon", "status": "ready", "grade": "bumpy", "score": 60},
        {"slot": "evening", "status": "out_of_coverage"},
    ]}]}
    s = rpt.summary(route, date(2026, 10, 27))
    assert s["grade"] == "bumpy" and s["best"]["slot"] == "morning" and s["varies"]
    assert rpt.summary(route, date(2026, 10, 28)) is None


def test_site_has_a_page_per_route_and_no_timeline(report, tmp_path):
    pages = build_site.build(report, tmp_path / "site", "https://example.test")
    assert len(pages) == len(report["routes"]) + 2
    page = (tmp_path / "site" / "routes" / "jfk-lax" / "index.html").read_text()
    assert "Will New York to Los Angeles be bumpy?" in page
    assert '"@type": "FAQPage"' in page
    assert '<link rel="canonical" href="https://example.test/routes/jfk-lax/">' in page
    # Grades only: nothing about when or how long the bumps last, and no data sources named.
    for word in ("NOAA", "GTG", "GFS", "minute ", "stretch"):
        assert word not in page.replace("minute by minute", "")
    sitemap = (tmp_path / "site" / "sitemap.xml").read_text()
    assert "https://example.test/routes/lax-jfk/" in sitemap
    assert (tmp_path / "site" / "support.html").exists()


def test_accuracy_only_with_enough_reports():
    assert build_site.accuracy_html({"reports": 12, "within_one": 11}) == ""
    assert "92%" in build_site.accuracy_html({"reports": 100, "within_one": 92})


def test_cards_and_caption(report):
    on = date(2026, 10, 27)
    names = [name for name, _ in render_cards.cards(report, on)]
    assert names[0] == "01-cover" and names[-1] == "04-app"
    calm, bumps, count = render_cards.pick(report, on)
    assert count == len(report["routes"]) and len(calm) <= render_cards.ROWS
    assert all(s["grade"] in ("smooth", "mostly_smooth") for s in calm)
    assert "#turbulence" in render_cards.caption(report, on)


def test_server_renders_the_same_pages(report):
    import serve

    site = serve.Site("https://example.test", str(SAMPLE), allow_sample=True)
    site.refresh()
    assert set(site.pages) == set(build_site.paths(report)[1:]) | {"/sitemap.xml", "/robots.txt"}
    assert b'class="stale on"' in site.pages["/routes/jfk-lax/"]  # the sample is old
    assert "/" in site.assets and "/fonts/IBMPlexMono-Medium.ttf" in site.assets


def test_server_refuses_the_sample_in_production():
    import serve

    site = serve.Site("https://example.test", str(SAMPLE), allow_sample=False)
    site.refresh()
    assert site.pages == {}
