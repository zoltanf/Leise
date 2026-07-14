#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:-$repo_root/.build/OfflineModels}"

log() {
  printf '[leise-offline-models] %s\n' "$*"
}

mkdir -p "$destination"

fluid_cache="$HOME/Library/Application Support/FluidAudio/Models"
if command -v ditto >/dev/null 2>&1 && [[ -d "$fluid_cache" ]]; then
  for folder in \
    parakeet-tdt-0.6b-v2 \
    parakeet-tdt-0.6b-v3 \
    parakeet-ctc-110m-coreml; do
    if [[ -d "$fluid_cache/$folder" && ! -d "$destination/$folder" ]]; then
      log "seeding $folder from the existing FluidAudio cache"
      ditto "$fluid_cache/$folder" "$destination/$folder"
    fi
  done
fi

log "preparing model cache at $destination"
swift run \
  --package-path "$repo_root/LeiseComponents" \
  --scratch-path "$repo_root/.build/OfflineModelPrep" \
  OfflineModelPrep \
  "$destination"

cp "$repo_root/release/offline-models/manifest.json" "$destination/manifest.json"
cp "$repo_root/release/offline-models/NOTICE.txt" "$destination/NOTICE.txt"

log "offline model cache is complete"
