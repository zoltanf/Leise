#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="${1:-}"
expected_version="${2:-}"
expected_build="${3:-}"

fail() {
  printf '[leise-release-test] error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[leise-release-test] %s\n' "$*"
}

if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  printf 'Usage: %s <Leise.app> [expected-version] [expected-build]\n' "$0" >&2
  exit 2
fi

info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail "Info.plist is missing"

bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist")"
actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
actual_build="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
binary_path="$app_path/Contents/MacOS/$executable_name"

[[ "$bundle_id" == "com.leise.mac" ]] || fail "unexpected bundle identifier: $bundle_id"
[[ "$executable_name" == "Leise" ]] || fail "unexpected executable: $executable_name"
[[ -x "$binary_path" ]] || fail "main executable is missing or not executable"
[[ ! -e "$app_path/Contents/MacOS/Leise.debug.dylib" ]] || fail "release contains Leise.debug.dylib"
[[ ! -d "$app_path/Contents/PlugIns" ]] || fail "release unexpectedly contains Contents/PlugIns"

if [[ -n "$expected_version" && "$actual_version" != "$expected_version" ]]; then
  fail "version mismatch: expected $expected_version, found $actual_version"
fi
if [[ -n "$expected_build" && "$actual_build" != "$expected_build" ]]; then
  fail "build mismatch: expected $expected_build, found $actual_build"
fi

architectures="$(lipo -archs "$binary_path")"
[[ " $architectures " == *" arm64 "* ]] || fail "arm64 architecture is missing: $architectures"

codesign --verify --deep --strict --verbose=2 "$app_path"
requirement_output="$(codesign -d --requirements - "$app_path" 2>&1)"
grep -Eq 'designated => cdhash H"[[:xdigit:]]{40}"' <<< "$requirement_output" \
  || fail "application does not have the expected ad-hoc requirement: $requirement_output"
entitlements_output="$(codesign -d --entitlements - "$app_path" 2>&1)"
grep -Fq 'com.apple.security.automation.apple-events' <<< "$entitlements_output" \
  || fail "Apple Events entitlement is missing"

strings "$binary_path" | grep -F 'parakeet-tdt-0.6b-v3' >/dev/null \
  || fail "Parakeet component identifier is missing"
strings "$binary_path" | grep -F 'filler-words' >/dev/null \
  || fail "filler cleanup component identifier is missing"

bash "$repo_root/scripts/check_release_binary_instrumentation.sh" "$binary_path"

log "verified Leise $actual_version ($actual_build), $architectures"
log "ad-hoc signature, entitlements, static components, and release instrumentation passed"
