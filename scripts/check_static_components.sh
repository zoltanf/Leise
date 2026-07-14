#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf '[static-components] error: %s\n' "$*" >&2
  exit 1
}

production_roots=(Leise LeiseComponents LeiseTests Leise.xcodeproj)
legacy_runtime_pattern='PluginManager|LoadedPlugin|loadAndReturnError|LeisePluginSDK|LeisePluginSDKTesting'
removed_product_pattern='ParakeetPlugin|FillerWordsPlugin|GeminiPlugin|GroqPlugin|OpenAIPlugin|WebhookPlugin|XAIPlugin'

if rg -n "$legacy_runtime_pattern" "${production_roots[@]}"; then
  fail 'legacy runtime plugin architecture was reintroduced'
fi

if rg -n "$removed_product_pattern" "${production_roots[@]}"; then
  fail 'a removed provider or bundle product identifier was reintroduced'
fi

if rg -n 'NSClassFromString' Leise/App/ServiceContainer.swift LeiseComponents; then
  fail 'built-in composition must use direct construction'
fi

if rg -n 'Contents/PlugIns|\.bundle.*(Parakeet|Filler)|PBXCopyFilesBuildPhase.*PlugIns' Leise.xcodeproj; then
  fail 'the app project embeds a plugin bundle'
fi

if find LeiseComponents -path '*/.build' -prune -o -type f -name manifest.json -print -quit | grep -q .; then
  fail 'component manifests are not part of the static architecture'
fi

printf '[static-components] direct static component architecture verified\n'
