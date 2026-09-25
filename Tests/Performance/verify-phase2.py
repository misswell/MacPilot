#!/usr/bin/env python3
"""Validate an opt-in MacPilot resource sample against Phase 2 thresholds."""

import argparse
import csv
import statistics
import sys
from datetime import datetime
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv_file", type=Path)
    parser.add_argument("--mode", choices=("idle", "all"), required=True)
    parser.add_argument("--min-duration", type=int, default=1800)
    parser.add_argument("--max-gap", type=int, default=15,
                        help="largest allowed gap between consecutive samples, in seconds")
    parser.add_argument("--max-growth-mb", type=float)
    args = parser.parse_args()

    with args.csv_file.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) < 2:
        parser.error("at least two samples are required")
    times = [datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")) for row in rows]
    cpu = [float(row["cpu_percent"]) for row in rows]
    rss = [float(row["rss_mb"]) for row in rows]
    duration = (times[-1] - times[0]).total_seconds()
    span = max(1, len(rss) // 5)
    growth = statistics.mean(rss[-span:]) - statistics.mean(rss[:span])
    average_cpu = statistics.mean(cpu)
    peak_rss = max(rss)

    failures = []
    if duration < args.min_duration:
        failures.append(f"duration {duration:.0f}s < {args.min_duration}s")
    for earlier, later in zip(times, times[1:]):
        gap = (later - earlier).total_seconds()
        if gap <= 0 or gap > args.max_gap:
            failures.append(f"invalid sample gap {gap:.0f}s (allowed: 0-{args.max_gap}s)")
            break
    if args.mode == "idle":
        if average_cpu >= 0.1:
            failures.append(f"idle CPU {average_cpu:.3f}% >= 0.1%")
        if peak_rss >= 80:
            failures.append(f"idle peak RSS {peak_rss:.1f} MB >= 80 MB")
    elif average_cpu >= 5:
        failures.append(f"full-feature CPU {average_cpu:.3f}% >= 5%")
    if args.max_growth_mb is not None and growth > args.max_growth_mb:
        failures.append(f"RSS growth {growth:+.1f} MB > {args.max_growth_mb:.1f} MB")

    print(f"Mode: {args.mode}")
    print(f"Duration: {duration:.0f}s ({len(rows)} samples)")
    print(f"Average CPU: {average_cpu:.3f}%")
    print(f"Peak RSS: {peak_rss:.1f} MB")
    print(f"RSS growth (first/last fifth): {growth:+.1f} MB")
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
