#!/usr/bin/env python3

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def summary_row(category: str, metric: str, values: list[float]) -> dict[str, object]:
    return {
        "category": category,
        "metric": metric,
        "count": len(values),
        "median": f"{statistics.median(values):.3f}",
        "p90": f"{percentile(values, 0.9):.3f}",
        "minimum": f"{min(values):.3f}",
        "maximum": f"{max(values):.3f}",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--exclude-run-one", action="store_true")
    args = parser.parse_args()

    rows: list[dict[str, object]] = []
    records = [json.loads(line) for line in (args.directory / "benchmark.ndjson").read_text().splitlines() if line]
    if args.exclude_run_one:
        records = [record for record in records if int(record["run"]) > 1]
    for key in ("elapsedMilliseconds", "inferenceMilliseconds"):
        values = [float(record[key]) for record in records]
        if values:
            rows.append(summary_row("benchmark", key, values))

    with (args.directory / "signposts.csv").open(newline="") as handle:
        signposts = list(csv.DictReader(handle))
    by_signpost: dict[str, list[float]] = defaultdict(list)
    seen_measured_signposts: set[tuple[str, str]] = set()
    for signpost in signposts:
        signpost_key = (signpost["run"], signpost["name"])
        if (args.exclude_run_one
                and signpost["name"] in {"final_transcription", "model_preparation"}
                and signpost_key not in seen_measured_signposts):
            seen_measured_signposts.add(signpost_key)
            continue
        seen_measured_signposts.add(signpost_key)
        if signpost["duration_ms"]:
            by_signpost[signpost["name"]].append(float(signpost["duration_ms"]))
    for name, values in sorted(by_signpost.items()):
        rows.append(summary_row("signpost", name, values))

    with (args.directory / "memory.csv").open(newline="") as handle:
        memory = list(csv.DictReader(handle))
    by_instance: dict[str, list[float]] = defaultdict(list)
    for sample in memory:
        by_instance[sample["instance"]].append(float(sample["rss_kb"]))
    for metric, reducer in (("rss_first_kb", lambda values: values[0]),
                            ("rss_peak_kb", max),
                            ("rss_settled_kb", lambda values: values[-1])):
        values = [float(reducer(samples)) for samples in by_instance.values() if samples]
        if values:
            rows.append(summary_row("memory", metric, values))

    fields = ["category", "metric", "count", "median", "p90", "minimum", "maximum"]
    with (args.directory / "summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
