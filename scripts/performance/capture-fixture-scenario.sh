#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

app_path="${APP_PATH:-$performance_repo_root/.build/DerivedData-RemainingPlan/Build/Products/Debug/Leise.app}"
fixture=""
model="parakeet-tdt-0.6b-v3"
scenario=""
instances=1
runs_per_instance=1
settle_seconds=2
timeout_seconds=180
exclude_run_one=false
output_dir=""

usage() {
  cat <<'EOF'
Usage: capture-fixture-scenario.sh --fixture WAV --scenario NAME --output DIR [options]

Options:
  --model ID                 Parakeet model ID (default: v3)
  --instances COUNT          Separate model-unloaded processes (default: 1)
  --runs-per-instance COUNT  Transcriptions within each process (default: 1)
  --settle-seconds SECONDS   Loaded-model RSS sampling after the last run (default: 2)
  --timeout SECONDS          Maximum seconds per process (default: 180)
  --exclude-run-one          Exclude the model-loading run from benchmark summaries
  --app PATH                 Debug Leise.app path

The script refuses to start while another Leise process is running. It snapshots
and restores the com.leise.mac preference domain, then writes raw signposts,
benchmark NDJSON, 10 Hz RSS, and median/p90 summaries.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app_path="$2"; shift 2 ;;
    --fixture) fixture="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --scenario) scenario="$2"; shift 2 ;;
    --instances) instances="$2"; shift 2 ;;
    --runs-per-instance) runs_per_instance="$2"; shift 2 ;;
    --settle-seconds) settle_seconds="$2"; shift 2 ;;
    --timeout) timeout_seconds="$2"; shift 2 ;;
    --exclude-run-one) exclude_run_one=true; shift ;;
    --output) output_dir="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$fixture" || -z "$scenario" || -z "$output_dir" ]]; then
  usage >&2
  exit 2
fi
fixture="$(cd "$(dirname "$fixture")" && pwd)/$(basename "$fixture")"
executable="$app_path/Contents/MacOS/Leise"
if [[ ! -f "$fixture" || ! -x "$executable" ]]; then
  printf '[performance] fixture or executable is missing\n' >&2
  exit 2
fi
if pgrep -x Leise >/dev/null 2>&1; then
  printf '[performance] quit all running Leise processes before capturing a fixture scenario\n' >&2
  exit 2
fi

performance_prepare_output_dir "$output_dir" >/dev/null
printf 'scenario,model,instance,sample,elapsed_ms,rss_kb\n' > "$output_dir/memory.csv"
: > "$output_dir/benchmark.ndjson"

preferences_snapshot="$(mktemp "$TMPDIR/leise-performance-defaults.XXXXXX")"
had_preferences=true
if ! defaults export com.leise.mac "$preferences_snapshot" >/dev/null 2>&1; then
  had_preferences=false
fi

logger_pid=""
app_pid=""
restore_preferences() {
  if [[ "$had_preferences" == true ]]; then
    defaults import com.leise.mac "$preferences_snapshot" >/dev/null
  else
    defaults delete com.leise.mac >/dev/null 2>&1 || true
  fi
  rm -f "$preferences_snapshot"
}
cleanup() {
  if [[ -n "$app_pid" ]]; then kill -TERM "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$logger_pid" ]]; then kill -INT "$logger_pid" 2>/dev/null || true; fi
  restore_preferences
}
trap cleanup EXIT INT TERM

for instance in $(seq 1 "$instances"); do
  prefix="$output_dir/instance-$(printf '%02d' "$instance")"
  raw_stream="$prefix-signposts.raw.txt"
  raw_json="$prefix-signposts.json"
  signpost_csv="$prefix-signposts.csv"
  app_stdout="$prefix-app.stdout.txt"
  app_stderr="$prefix-app.stderr.txt"

  /usr/bin/log stream \
    --style json --level debug --signpost \
    --predicate 'subsystem == "com.leise.mac" AND category == "Performance"' \
    > "$raw_stream" 2> "$prefix-signposts.stderr.txt" &
  logger_pid=$!
  sleep 0.5

  LEISE_PERFORMANCE_FIXTURE="$fixture" \
  LEISE_PERFORMANCE_MODEL="$model" \
  LEISE_PERFORMANCE_SCENARIO="$scenario" \
  LEISE_PERFORMANCE_INSTANCE="$instance" \
  LEISE_PERFORMANCE_RUNS="$runs_per_instance" \
  LEISE_PERFORMANCE_SETTLE_SECONDS="$settle_seconds" \
    "$executable" > "$app_stdout" 2> "$app_stderr" &
  app_pid=$!
  measured_pid="$app_pid"
  start_seconds="$(performance_now_seconds)"
  sample=0

  while kill -0 "$app_pid" 2>/dev/null; do
    now_seconds="$(performance_now_seconds)"
    elapsed_ms="$(performance_elapsed_ms "$start_seconds" "$now_seconds")"
    rss_kb="$({ ps -o rss= -p "$app_pid" 2>/dev/null || true; } | tr -d '[:space:]')"
    if [[ -n "$rss_kb" && "$rss_kb" -gt 0 ]]; then
      printf '%s,%s,%s,%s,%s,%s\n' \
        "$scenario" "$model" "$instance" "$sample" "$elapsed_ms" "$rss_kb" \
        >> "$output_dir/memory.csv"
    fi
    if awk -v elapsed="$elapsed_ms" -v limit="$timeout_seconds" 'BEGIN { exit !(elapsed >= limit * 1000) }'; then
      printf '[performance] benchmark process timed out: instance %s\n' "$instance" >&2
      kill -TERM "$app_pid" 2>/dev/null || true
      break
    fi
    sample=$((sample + 1))
    sleep 0.1
  done

  set +e
  wait "$app_pid"
  app_status=$?
  set -e
  app_pid=""
  sleep 0.5
  kill -INT "$logger_pid" 2>/dev/null || true
  wait "$logger_pid" 2>/dev/null || true
  logger_pid=""
  performance_wait_for_json_array "$raw_stream"
  sed -n '/^\[/,$p' "$raw_stream" > "$raw_json"

  python3 "$script_dir/summarize-signposts.py" \
    "$raw_json" "$signpost_csv" \
    --scenario "$scenario" --run "$instance" --pid "$measured_pid"
  grep '^{' "$app_stdout" >> "$output_dir/benchmark.ndjson" || true

  if [[ "$app_status" -ne 0 ]]; then
    printf '[performance] benchmark failed: instance %s; see %s\n' "$instance" "$app_stderr" >&2
    exit "$app_status"
  fi
done

first_csv="$output_dir/instance-01-signposts.csv"
cp "$first_csv" "$output_dir/signposts.csv"
for signpost_csv in "$output_dir"/instance-*-signposts.csv; do
  [[ "$signpost_csv" == "$first_csv" ]] && continue
  tail -n +2 "$signpost_csv" >> "$output_dir/signposts.csv"
done

if [[ "$exclude_run_one" == true ]]; then
  python3 "$script_dir/summarize-fixture-scenario.py" "$output_dir" --exclude-run-one
else
  python3 "$script_dir/summarize-fixture-scenario.py" "$output_dir"
fi

trap - EXIT INT TERM
restore_preferences
printf '[performance] fixture scenario captured at %s\n' "$output_dir"
