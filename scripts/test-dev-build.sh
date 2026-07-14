#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="${1:-$HOME/Applications/Leise.app}"
expected_bundle_id="com.leise.mac"
expected_requirement_pattern='designated => cdhash H"[[:xdigit:]]{40}"'

fail() {
  printf '[leise-dev-self-test] error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[leise-dev-self-test] %s\n' "$*"
}

binary_contains() {
  strings "$1" | grep -F "$2" >/dev/null
}

bash -n \
  "$repo_root/scripts/build-and-run.sh" \
  "$repo_root/scripts/build-dev-local.sh" \
  "$repo_root/scripts/test-dev-build.sh"

[[ -d "$app_path" ]] || fail "app not found at $app_path"

info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail "missing Info.plist"

bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
[[ "$bundle_id" == "$expected_bundle_id" ]] || fail "unexpected bundle identifier: $bundle_id"

executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist")"
[[ "$executable_name" == "Leise" ]] || fail "unexpected executable: $executable_name"
[[ -x "$app_path/Contents/MacOS/$executable_name" ]] || fail "main executable is missing or not executable"
[[ ! -e "$app_path/Contents/MacOS/Leise.debug.dylib" ]] \
  || fail "dev build must disable the debug dylib before stable post-signing"

codesign --verify --deep --strict --verbose=2 "$app_path"
requirement_output="$(codesign -d --requirements - "$app_path" 2>&1)"
grep -Eq "$expected_requirement_pattern" <<< "$requirement_output" \
  || fail "dev build must use its standard ad-hoc code-hash requirement: $requirement_output"
entitlements_output="$(codesign -d --entitlements - "$app_path" 2>&1)"
grep -Fq 'com.apple.security.automation.apple-events' <<< "$entitlements_output" \
  || fail "Accessibility-supporting app entitlements are missing"

marker="$app_path/Contents/Resources/DevBuildSource.txt"
[[ -f "$marker" ]] || fail "missing DevBuildSource.txt"
grep -Fxq 'app=Leise' "$marker" || fail "invalid app name in DevBuildSource.txt"
grep -Fxq "repo=$repo_root" "$marker" || fail "invalid repository path in DevBuildSource.txt"
grep -Eq '^branch=.+$' "$marker" || fail "missing branch in DevBuildSource.txt"
grep -Eq '^commit=.+$' "$marker" || fail "missing commit in DevBuildSource.txt"
grep -Eq '^built_at_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$marker" \
  || fail "invalid timestamp in DevBuildSource.txt"

[[ ! -d "$app_path/Contents/PlugIns" ]] \
  || fail "static build unexpectedly contains Contents/PlugIns"

component_binary="$app_path/Contents/MacOS/Leise.debug.dylib"
[[ -f "$component_binary" ]] || component_binary="$app_path/Contents/MacOS/$executable_name"
binary_contains "$component_binary" 'parakeet-tdt-0.6b-v3' \
  || fail "Parakeet component identifier is missing from the app binary"
binary_contains "$component_binary" 'filler-words' \
  || fail "filler cleanup component identifier is missing from the app binary"
codesign --verify --strict --verbose=2 "$component_binary"

log "app identity: $bundle_id ($executable_name)"
log "standard ad-hoc code-hash designated requirement"
log "monolithic executable, entitlements, build marker, and statically linked built-ins verified"
log "passed: $app_path"
