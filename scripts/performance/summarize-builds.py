#!/usr/bin/env python3

import argparse
import csv
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
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()

    grouped: dict[tuple[str, str], list[float]] = defaultdict(list)
    with (args.directory / "build-times.csv").open(newline="") as handle:
        for row in csv.DictReader(handle):
            grouped[(row["configuration"], row["kind"])].append(float(row["elapsed_ms"]))

    fields = ["configuration", "kind", "count", "median_ms", "p90_ms", "minimum_ms", "maximum_ms"]
    with (args.directory / "summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for (configuration, kind), values in sorted(grouped.items()):
            writer.writerow(
                {
                    "configuration": configuration,
                    "kind": kind,
                    "count": len(values),
                    "median_ms": f"{statistics.median(values):.3f}",
                    "p90_ms": f"{percentile(values, 0.9):.3f}",
                    "minimum_ms": f"{min(values):.3f}",
                    "maximum_ms": f"{max(values):.3f}",
                }
            )


if __name__ == "__main__":
    main()
