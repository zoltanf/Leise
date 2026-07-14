#!/usr/bin/env python3

import argparse
import csv
import math
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()

    metrics: dict[str, list[float]] = defaultdict(list)
    events_by_run: dict[str, dict[str, datetime]] = defaultdict(dict)
    with (args.directory / "signposts.csv").open(newline="") as handle:
        for row in csv.DictReader(handle):
            if row["duration_ms"]:
                metrics[row["name"]].append(float(row["duration_ms"]))
            elif row["type"] == "event":
                events_by_run[row["run"]][row["name"]] = datetime.strptime(
                    row["start_timestamp"], "%Y-%m-%d %H:%M:%S.%f%z"
                )

    for events in events_by_run.values():
        if "process_started" in events and "hotkey_ready" in events:
            metrics["process_to_hotkey_ready"].append(
                (events["hotkey_ready"] - events["process_started"]).total_seconds() * 1_000
            )

    memory_by_run: dict[str, list[float]] = defaultdict(list)
    with (args.directory / "memory.csv").open(newline="") as handle:
        for row in csv.DictReader(handle):
            memory_by_run[row["run"]].append(float(row["rss_kb"]))
    metrics["idle_rss_settled_kb"] = [samples[-1] for samples in memory_by_run.values() if samples]
    metrics["launch_rss_peak_kb"] = [max(samples) for samples in memory_by_run.values() if samples]

    with (args.directory / "summary.csv").open("w", newline="") as handle:
        fields = ["metric", "count", "median", "p90", "minimum", "maximum"]
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for metric, values in sorted(metrics.items()):
            writer.writerow(
                {
                    "metric": metric,
                    "count": len(values),
                    "median": f"{statistics.median(values):.3f}",
                    "p90": f"{percentile(values, 0.9):.3f}",
                    "minimum": f"{min(values):.3f}",
                    "maximum": f"{max(values):.3f}",
                }
            )


if __name__ == "__main__":
    main()
