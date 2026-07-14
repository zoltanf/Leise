#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_ref="${1:-origin/main}"

log() {
  printf '[pr-preflight] %s\n' "$*"
}

run_if_exists() {
  local script_path="$1"
  shift

  if [[ -x "$script_path" ]]; then
    "$script_path" "$@"
  else
    bash "$script_path" "$@"
  fi
}

cd "$repo_root"

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
  log "error: base ref '$base_ref' was not found"
  log "hint: fetch the base branch first, or pass an existing ref explicitly"
  exit 2
fi

log "checking whitespace and conflict markers against $base_ref"
git diff --check "$base_ref"...HEAD

log "checking shell scripts parse"
while IFS= read -r script_file; do
  [[ -n "$script_file" ]] || continue
  bash -n "$script_file"
done < <(git ls-files 'scripts/*.sh')

log "checking release instrumentation helper"
run_if_exists scripts/check_release_binary_instrumentation.sh --self-test

log "checking static built-in architecture"
run_if_exists scripts/check_static_components.sh

log "running component package tests"
swift test --package-path LeiseComponents

log "preflight complete"
