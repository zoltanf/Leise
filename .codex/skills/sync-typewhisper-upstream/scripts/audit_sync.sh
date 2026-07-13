#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" || ! -f "$repo_root/Leise.xcodeproj/project.pbxproj" ]]; then
  echo "error: run this guard inside the Leise repository" >&2
  exit 2
fi

cd "$repo_root"
failed=0

require_remote() {
  local name="$1"
  local expected="$2"
  local actual
  actual="$(git remote get-url "$name" 2>/dev/null || true)"
  if [[ "$actual" != *"$expected"* ]]; then
    echo "error: remote '$name' is '$actual'; expected it to contain '$expected'" >&2
    failed=1
  fi
}

reject_pattern() {
  local pattern="$1"
  local label="$2"
  if rg -n --glob '!**/*.xcstrings' --glob '!docs/**' --glob '!TRADEMARK.md' --glob '!FORK.md' "$pattern" Leise LeiseTests Leise.xcodeproj LICENSE-COMMERCIAL.md 2>/dev/null; then
    echo "error: $label was reintroduced" >&2
    failed=1
  fi
}

require_remote origin "zoltanf/Leise"
require_remote upstream "TypeWhisper/typewhisper-mac"

reject_pattern 'api\.polar\.sh|LicenseService|SupporterDiscordService' "product entitlement code"
reject_pattern 'PremiumSettingsView|LicenseSettingsView|PostUpdateLicensePromptView' "commercial UI"
reject_pattern 'contentsOfDirectory\(at: pluginsDirectory|Scanning plugins directory' "external plugin loading"

local_filter_count="$(rg -c '\.filter \{ \$0\.isEnabled && \$0\.isBundled && \$0\.manifest\.resolvedHosting == \.local \}' Leise/Services/PluginManager.swift || true)"
if [[ "${local_filter_count:-0}" -lt 3 ]]; then
  echo "error: local-only provider filters are missing from PluginManager" >&2
  failed=1
fi

if [[ -e LICENSE-COMMERCIAL.md ]]; then
  echo "error: LICENSE-COMMERCIAL.md was reintroduced" >&2
  failed=1
fi

if (( failed != 0 )); then
  exit 1
fi

echo "Leise upstream-sync guard passed"
