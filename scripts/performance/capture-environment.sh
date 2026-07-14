#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

output_dir="${1:-$(performance_default_output_dir)/environment}"
performance_prepare_output_dir "$output_dir" >/dev/null

cd "$performance_repo_root"

git rev-parse HEAD > "$output_dir/commit.txt"
git branch --show-current > "$output_dir/branch.txt"
git status --porcelain=v1 > "$output_dir/git-status.txt"
while IFS= read -r -d '' source_file; do
  [[ -f "$source_file" ]] || continue
  shasum -a 256 "$source_file"
done < <(git ls-files --cached --others --exclude-standard -z) \
  | LC_ALL=C sort > "$output_dir/source-files.sha256"
sw_vers > "$output_dir/macos.txt"
xcodebuild -version > "$output_dir/xcode.txt"
uname -a > "$output_dir/uname.txt"
system_profiler SPHardwareDataType 2> "$output_dir/hardware.stderr.txt" \
  | sed -E '/^[[:space:]]+(Serial Number|Hardware UUID|Provisioning UDID) \([^)]*\)?:/d; /^[[:space:]]+(Serial Number|Hardware UUID|Provisioning UDID):/d' \
  > "$output_dir/hardware.txt" || true
pmset -g batt 2> "$output_dir/power.stderr.txt" \
  | sed -E 's/id=[0-9]+/id=redacted/' > "$output_dir/power.txt" || true
pmset -g therm > "$output_dir/thermal.txt" 2> "$output_dir/thermal.stderr.txt" || true
for sysctl_name in hw.model hw.machine hw.ncpu hw.physicalcpu hw.logicalcpu hw.memsize machdep.cpu.brand_string; do
  printf '%s=' "$sysctl_name"
  sysctl -n "$sysctl_name" 2>/dev/null || printf 'unavailable'
  printf '\n'
done > "$output_dir/sysctl.txt"

commit="$(git rev-parse HEAD)"
branch="$(git branch --show-current)"
dirty=false
if [[ -s "$output_dir/git-status.txt" ]]; then
  dirty=true
fi
macos_version="$(sw_vers -productVersion)"
xcode_version="$(xcodebuild -version | paste -sd ' ' -)"
architecture="$(uname -m)"
cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf 'unavailable')"
memory_bytes="$(sysctl -n hw.memsize 2>/dev/null || printf 'unavailable')"
source_tree_sha256="$(shasum -a 256 "$output_dir/source-files.sha256" | awk '{ print $1 }')"

{
  printf 'recorded_at_utc,commit,branch,dirty,source_tree_sha256,macos_version,xcode_version,architecture,cpu,memory_bytes\n'
  performance_csv_escape "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf ','
  performance_csv_escape "$commit"
  printf ','
  performance_csv_escape "$branch"
  printf ',%s,%s,' "$dirty" "$source_tree_sha256"
  performance_csv_escape "$macos_version"
  printf ','
  performance_csv_escape "$xcode_version"
  printf ','
  performance_csv_escape "$architecture"
  printf ','
  performance_csv_escape "$cpu"
  printf ',%s\n' "$memory_bytes"
} > "$output_dir/environment.csv"

printf '[performance] environment captured at %s\n' "$output_dir"
