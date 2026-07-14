#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

runs="${RUNS:-3}"
output_dir="${OUTPUT_DIR:-$(performance_default_output_dir)/builds}"
derived_data_path="${DERIVED_DATA_PATH:-$performance_repo_root/.build/DerivedData-Performance}"
incremental_source="${INCREMENTAL_SOURCE:-$performance_repo_root/Leise/App/AppConstants.swift}"

usage() {
  cat <<'EOF'
Usage: measure-builds.sh [--runs COUNT] [--output DIR] [--derived-data DIR]

Resolves packages once, records repeated clean Debug and Release builds with
-showBuildTimingSummary, measures a one-file Debug incremental compile by touching
AppConstants.swift, restores its original timestamp, and records product sizes.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) runs="$2"; shift 2 ;;
    --output) output_dir="$2"; shift 2 ;;
    --derived-data) derived_data_path="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

performance_prepare_output_dir "$output_dir" >/dev/null
cd "$performance_repo_root"

common_args=(
  -project Leise.xcodeproj
  -scheme Leise
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$derived_data_path"
  CODE_SIGNING_ALLOWED=NO
)

xcodebuild -resolvePackageDependencies "${common_args[@]}" \
  > "$output_dir/package-resolution.log" 2>&1

printf 'configuration,kind,run,elapsed_ms,exit_code,log\n' > "$output_dir/build-times.csv"

record_build() {
  local configuration="$1"
  local kind="$2"
  local run="$3"
  local configuration_slug
  configuration_slug="$(printf '%s' "$configuration" | tr '[:upper:]' '[:lower:]')"
  local log_file="$output_dir/$configuration_slug-$kind-run-$(printf '%02d' "$run").log"
  local start_seconds end_seconds elapsed_ms exit_code

  start_seconds="$(performance_now_seconds)"
  set +e
  xcodebuild build \
    "${common_args[@]}" \
    -configuration "$configuration" \
    -showBuildTimingSummary \
    -disableAutomaticPackageResolution \
    > "$log_file" 2>&1
  exit_code=$?
  set -e
  end_seconds="$(performance_now_seconds)"
  elapsed_ms="$(performance_elapsed_ms "$start_seconds" "$end_seconds")"
  printf '%s,%s,%s,%s,%s,%s\n' \
    "$configuration" "$kind" "$run" "$elapsed_ms" "$exit_code" "$(basename "$log_file")" \
    >> "$output_dir/build-times.csv"
  if [[ "$exit_code" -ne 0 ]]; then
    printf '[performance] build failed; see %s\n' "$log_file" >&2
    exit "$exit_code"
  fi
}

for configuration in Debug Release; do
  configuration_slug="$(printf '%s' "$configuration" | tr '[:upper:]' '[:lower:]')"
  for run in $(seq 1 "$runs"); do
    xcodebuild clean "${common_args[@]}" -configuration "$configuration" \
      -disableAutomaticPackageResolution \
      > "$output_dir/$configuration_slug-clean-run-$(printf '%02d' "$run").log" 2>&1
    record_build "$configuration" clean "$run"
  done
done

timestamp_reference="$(mktemp "$TMPDIR/leise-performance-source-time.XXXXXX")"
touch -r "$incremental_source" "$timestamp_reference"
restore_source_timestamp() {
  touch -r "$timestamp_reference" "$incremental_source"
}
cleanup_timestamp_reference() {
  restore_source_timestamp
  rm -f "$timestamp_reference"
}
trap cleanup_timestamp_reference EXIT INT TERM

xcodebuild build "${common_args[@]}" -configuration Debug -disableAutomaticPackageResolution \
  > "$output_dir/incremental-prime.log" 2>&1
for run in $(seq 1 "$runs"); do
  touch "$incremental_source"
  record_build Debug incremental "$run"
  restore_source_timestamp
done
trap - EXIT INT TERM
cleanup_timestamp_reference

printf 'configuration,artifact,bytes,path\n' > "$output_dir/sizes.csv"
for configuration in Debug Release; do
  app_path="$derived_data_path/Build/Products/$configuration/Leise.app"
  executable="$app_path/Contents/MacOS/Leise"
  debug_dylib="$app_path/Contents/MacOS/Leise.debug.dylib"
  if [[ -d "$app_path" ]]; then
    app_bytes="$(du -sk "$app_path" | awk '{ print $1 * 1024 }')"
    printf '%s,app_bundle,%s,%s\n' "$configuration" "$app_bytes" "$app_path" >> "$output_dir/sizes.csv"
  fi
  if [[ -f "$executable" ]]; then
    executable_bytes="$(stat -f '%z' "$executable")"
    printf '%s,executable,%s,%s\n' "$configuration" "$executable_bytes" "$executable" >> "$output_dir/sizes.csv"
  fi
  if [[ -f "$debug_dylib" ]]; then
    debug_dylib_bytes="$(stat -f '%z' "$debug_dylib")"
    printf '%s,debug_dylib,%s,%s\n' "$configuration" "$debug_dylib_bytes" "$debug_dylib" \
      >> "$output_dir/sizes.csv"
  fi
done

printf '[performance] build and size data captured at %s\n' "$output_dir"
