#!/usr/bin/env bash

set -euo pipefail

performance_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

performance_timestamp() {
  date -u '+%Y%m%dT%H%M%SZ'
}

performance_default_output_dir() {
  printf '%s\n' "$performance_repo_root/.build/performance/$(performance_timestamp)"
}

performance_require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '[performance] required command not found: %s\n' "$1" >&2
    exit 2
  fi
}

performance_prepare_output_dir() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  printf '%s\n' "$output_dir"
}

performance_now_seconds() {
  perl -MTime::HiRes=time -e 'printf "%.9f\n", time'
}

performance_elapsed_ms() {
  awk -v start="$1" -v end="$2" 'BEGIN { printf "%.3f", (end - start) * 1000 }'
}

performance_csv_escape() {
  local value="${1//$'\n'/ }"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

performance_wait_for_json_array() {
  local path="$1"
  local attempt
  for attempt in $(seq 1 50); do
    if [[ -s "$path" ]] && tail -c 32 "$path" | tr -d '[:space:]' | grep -q ']$'; then
      return 0
    fi
    sleep 0.1
  done
  printf '[performance] signpost JSON did not finish flushing: %s\n' "$path" >&2
  return 1
}
