"""Write a sample Sky Report from made-up weather, for previewing the pages and cards offline.

Runs the worker's real report builder over a synthetic sky: a band of bumps along the jet
stream that drifts during the day, and chop over the Rockies below cruise. The report is marked
`"sample": true`, and the page and card builders refuse it unless given --allow-sample.

    uv run --project worker python marketing/skyreport/sample_report.py [--now 2026-10-26T14:00Z]
"""

import argparse
import json
import math
from datetime import UTC, datetime
from pathlib import Path

from smooth_worker import forecast, skyreport

OUT = Path(__file__).resolve().parent / "fixtures" / "sample-report.json"


class SampleSky:
    name = "gfs"

    def __init__(self, now: datetime):
        self.cycle = now

    def covers(self, valid):
        return True

    def edr(self, lat, lon, altitude_ft, valid):
        hours = (valid - self.cycle).total_seconds() / 3600
        jet_lat = 41 + 3 * math.sin(hours / 9) + 0.04 * (lon + 100)
        jet = 0.2 * math.exp(-(((lat - jet_lat) / 1.6) ** 2)) * (1 if altitude_ft > 28000 else 0.3)
        rockies = 0.16 if -114 < lon < -105 and 12000 < altitude_ft < 30000 else 0.0
        gulf = 0.12 * math.exp(-(((lat - 29) / 2) ** 2)) * (0.5 + 0.5 * math.sin(hours / 5 + lon / 7))
        return 0.03 + jet + rockies + max(gulf, 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--now", help="Report time, ISO 8601 UTC (default: now)")
    args = parser.parse_args()
    now = datetime.fromisoformat(args.now.replace("Z", "+00:00")) if args.now else datetime.now(UTC)
    sky = SampleSky(now)
    report = skyreport.build(
        now, lambda o, d, dep: forecast.compute(o, d, dep, now, [sky], global_coverage=False)
    )
    report["sample"] = True
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{OUT.relative_to(Path.cwd()) if OUT.is_relative_to(Path.cwd()) else OUT}: {len(report['routes'])} routes")


if __name__ == "__main__":
    main()
