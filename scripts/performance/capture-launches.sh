#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

app_path="${APP_PATH:-$performance_repo_root/.build/DerivedData-RemainingPlan/Build/Products/Debug/Leise.app}"
runs="${RUNS:-7}"
settle_seconds="${SETTLE_SECONDS:-5}"
output_dir="${OUTPUT_DIR:-$(performance_default_output_dir)/warm-launch}"

usage() {
  cat <<'EOF'
Usage: capture-launches.sh [--app PATH] [--runs COUNT] [--settle-seconds SECONDS] [--output DIR]

Captures raw unified-log signposts and resident-memory samples for repeated warm
launches. Run only after the app has completed onboarding and the model is unloaded.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app_path="$2"; shift 2 ;;
    --runs) runs="$2"; shift 2 ;;
    --settle-seconds) settle_seconds="$2"; shift 2 ;;
    --output) output_dir="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

executable="$app_path/Contents/MacOS/Leise"
if [[ ! -x "$executable" ]]; then
  printf '[performance] app executable not found: %s\n' "$executable" >&2
  exit 2
fi

performance_require_command python3
performance_prepare_output_dir "$output_dir" >/dev/null
printf 'scenario,run,pid,sample,elapsed_ms,rss_kb\n' > "$output_dir/memory.csv"

logger_pid=""
app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]]; then kill -TERM "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$logger_pid" ]]; then kill -INT "$logger_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

for run in $(seq 1 "$runs"); do
  raw_json="$output_dir/signposts-run-$(printf '%02d' "$run").json"
  raw_stream="$output_dir/signposts-run-$(printf '%02d' "$run").raw.txt"
  raw_log_stderr="$output_dir/signposts-run-$(printf '%02d' "$run").stderr.txt"
  run_csv="$output_dir/signposts-run-$(printf '%02d' "$run").csv"

  /usr/bin/log stream \
    --style json \
    --level debug \
    --signpost \
    --predicate 'subsystem == "com.leise.mac" AND category == "Performance"' \
    > "$raw_stream" 2> "$raw_log_stderr" &
  logger_pid=$!
  sleep 0.5

  "$executable" > "$output_dir/app-run-$(printf '%02d' "$run").stdout.txt" \
    2> "$output_dir/app-run-$(printf '%02d' "$run").stderr.txt" &
  app_pid=$!
  measured_pid="$app_pid"
  start_seconds="$(performance_now_seconds)"
  sample=0

  while kill -0 "$app_pid" 2>/dev/null; do
    now_seconds="$(performance_now_seconds)"
    elapsed_ms="$(performance_elapsed_ms "$start_seconds" "$now_seconds")"
    rss_kb="$({ ps -o rss= -p "$app_pid" 2>/dev/null || true; } | tr -d '[:space:]')"
    if [[ -n "$rss_kb" && "$rss_kb" -gt 0 ]]; then
      printf 'warm-launch,%s,%s,%s,%s,%s\n' "$run" "$app_pid" "$sample" "$elapsed_ms" "$rss_kb" \
        >> "$output_dir/memory.csv"
    fi
    sample=$((sample + 1))
    if awk -v elapsed="$elapsed_ms" -v limit="$settle_seconds" 'BEGIN { exit !(elapsed >= limit * 1000) }'; then
      break
    fi
    sleep 0.1
  done

  kill -TERM "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  app_pid=""
  sleep 0.5
  kill -INT "$logger_pid" 2>/dev/null || true
  wait "$logger_pid" 2>/dev/null || true
  logger_pid=""
  performance_wait_for_json_array "$raw_stream"
  sed -n '/^\[/,$p' "$raw_stream" > "$raw_json"

  python3 "$script_dir/summarize-signposts.py" \
    "$raw_json" "$run_csv" \
    --scenario warm-launch \
    --run "$run" \
    --pid "$measured_pid"
done

first_csv="$output_dir/signposts-run-01.csv"
cp "$first_csv" "$output_dir/signposts.csv"
for run_csv in "$output_dir"/signposts-run-*.csv; do
  [[ "$run_csv" == "$first_csv" ]] && continue
  tail -n +2 "$run_csv" >> "$output_dir/signposts.csv"
done

printf '[performance] warm-launch data captured at %s\n' "$output_dir"
