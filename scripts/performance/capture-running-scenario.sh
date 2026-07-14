#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

pid=""
scenario=""
duration_seconds=60
output_dir="${OUTPUT_DIR:-$(performance_default_output_dir)/scenario}"

usage() {
  cat <<'EOF'
Usage: capture-running-scenario.sh --pid PID --scenario NAME [--duration SECONDS] [--output DIR]

Attach this recorder to a running Debug Leise process, then perform exactly one
documented scenario (for example first-dictation-short or model-load-v3). It
captures raw signpost JSON and a 10 Hz RSS time series without controlling the UI.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid) pid="$2"; shift 2 ;;
    --scenario) scenario="$2"; shift 2 ;;
    --duration) duration_seconds="$2"; shift 2 ;;
    --output) output_dir="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$pid" || -z "$scenario" ]]; then
  usage >&2
  exit 2
fi
if ! kill -0 "$pid" 2>/dev/null; then
  printf '[performance] process is not running: %s\n' "$pid" >&2
  exit 2
fi

performance_require_command python3
performance_prepare_output_dir "$output_dir" >/dev/null
raw_json="$output_dir/$scenario-signposts.json"
raw_stream="$output_dir/$scenario-signposts.raw.txt"
raw_stderr="$output_dir/$scenario-signposts.stderr.txt"
memory_csv="$output_dir/$scenario-memory.csv"

logger_pid=""
cleanup() {
  if [[ -n "$logger_pid" ]]; then kill -INT "$logger_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

/usr/bin/log stream \
  --style json \
  --level debug \
  --signpost \
  --predicate 'subsystem == "com.leise.mac" AND category == "Performance"' \
  > "$raw_stream" 2> "$raw_stderr" &
logger_pid=$!
sleep 0.5

printf 'scenario,pid,sample,elapsed_ms,rss_kb\n' > "$memory_csv"
start_seconds="$(performance_now_seconds)"
sample=0
while kill -0 "$pid" 2>/dev/null; do
  now_seconds="$(performance_now_seconds)"
  elapsed_ms="$(performance_elapsed_ms "$start_seconds" "$now_seconds")"
  rss_kb="$({ ps -o rss= -p "$pid" 2>/dev/null || true; } | tr -d '[:space:]')"
  if [[ -n "$rss_kb" && "$rss_kb" -gt 0 ]]; then
    printf '%s,%s,%s,%s,%s\n' "$scenario" "$pid" "$sample" "$elapsed_ms" "$rss_kb" >> "$memory_csv"
  fi
  sample=$((sample + 1))
  if awk -v elapsed="$elapsed_ms" -v limit="$duration_seconds" 'BEGIN { exit !(elapsed >= limit * 1000) }'; then
    break
  fi
  sleep 0.1
done

kill -INT "$logger_pid" 2>/dev/null || true
wait "$logger_pid" 2>/dev/null || true
logger_pid=""
performance_wait_for_json_array "$raw_stream"
sed -n '/^\[/,$p' "$raw_stream" > "$raw_json"

python3 "$script_dir/summarize-signposts.py" \
  "$raw_json" "$output_dir/$scenario-signposts.csv" \
  --scenario "$scenario" \
  --run 1 \
  --pid "$pid"

printf '[performance] scenario data captured at %s\n' "$output_dir"
