#!/usr/bin/env python3

import argparse
import csv
import json
from collections import defaultdict
from datetime import datetime
from pathlib import Path


def parse_timestamp(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%f%z")


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert raw macOS signpost JSON to comparable CSV rows.")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--run", required=True, type=int)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--pid", required=True, type=int)
    args = parser.parse_args()

    events = json.loads(args.input.read_text())
    events = [event for event in events if event.get("processID") == args.pid]
    events.sort(key=lambda event: event.get("machTimestamp", 0))

    starts: dict[str, list[dict]] = defaultdict(list)
    rows: list[dict[str, object]] = []
    current_dictation_request: dict | None = None
    recorded_first_audio_buffer = False
    recorded_first_preview = False

    def append_derived_interval(name: str, start: dict, end: dict) -> None:
        start_time = parse_timestamp(start["timestamp"])
        end_time = parse_timestamp(end["timestamp"])
        rows.append(
            {
                "scenario": args.scenario,
                "run": args.run,
                "pid": args.pid,
                "name": name,
                "type": "derived_interval",
                "start_timestamp": start["timestamp"],
                "end_timestamp": end["timestamp"],
                "duration_ms": f"{(end_time - start_time).total_seconds() * 1000:.3f}",
            }
        )

    for event in events:
        name = event.get("signpostName", "")
        signpost_type = event.get("signpostType", "")
        if signpost_type == "begin":
            starts[name].append(event)
        elif signpost_type == "end" and starts[name]:
            start = starts[name].pop()
            start_time = parse_timestamp(start["timestamp"])
            end_time = parse_timestamp(event["timestamp"])
            rows.append(
                {
                    "scenario": args.scenario,
                    "run": args.run,
                    "pid": args.pid,
                    "name": name,
                    "type": "interval",
                    "start_timestamp": start["timestamp"],
                    "end_timestamp": event["timestamp"],
                    "duration_ms": f"{(end_time - start_time).total_seconds() * 1000:.3f}",
                }
            )
        elif signpost_type == "event":
            rows.append(
                {
                    "scenario": args.scenario,
                    "run": args.run,
                    "pid": args.pid,
                    "name": name,
                    "type": "event",
                    "start_timestamp": event["timestamp"],
                    "end_timestamp": "",
                    "duration_ms": "",
                }
            )
            if name == "dictation_requested":
                current_dictation_request = event
                recorded_first_audio_buffer = False
                recorded_first_preview = False
            elif (
                name == "first_recording_audio_buffer"
                and current_dictation_request is not None
                and not recorded_first_audio_buffer
            ):
                append_derived_interval(
                    "dictation_request_to_first_audio_buffer",
                    current_dictation_request,
                    event,
                )
                recorded_first_audio_buffer = True
            elif (
                name == "first_transcript_preview"
                and current_dictation_request is not None
                and not recorded_first_preview
            ):
                append_derived_interval(
                    "dictation_request_to_first_transcript_preview",
                    current_dictation_request,
                    event,
                )
                recorded_first_preview = True

    fieldnames = [
        "scenario",
        "run",
        "pid",
        "name",
        "type",
        "start_timestamp",
        "end_timestamp",
        "duration_ms",
    ]
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
