#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/release/offline-models/manifest.json"
destination="$repo_root/.build/OfflineModels"
refresh_from_source=false

usage() {
  cat <<'EOF'
Usage: ./scripts/prepare-offline-models.sh [--refresh-from-source] [destination]

Prepare the pinned offline model cache. Normal builds download the verified
Leise offline-model bundle from GitHub Releases when the cache is missing;
they never fall back to Hugging Face.

Use --refresh-from-source only when deliberately creating a new model bundle.
It permits FluidAudio to fetch missing models from their upstream source.
EOF
}

log() { printf '[leise-offline-models] %s\n' "$*"; }
fail() { printf '[leise-offline-models] error: %s\n' "$*" >&2; exit 1; }

while (($# > 0)); do
  case "$1" in
    --refresh-from-source) refresh_from_source=true ;;
    -h|--help) usage; exit 0 ;;
    -*) fail "unknown option: $1" ;;
    *)
      [[ "$destination" == "$repo_root/.build/OfflineModels" ]] || fail 'only one destination is allowed'
      destination="$1"
      ;;
  esac
  shift
done

[[ -f "$manifest" ]] || fail "missing model manifest: $manifest"
command -v ruby >/dev/null 2>&1 || fail 'ruby is required to read the model manifest'

read_manifest_value() {
  ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("bundle").fetch(ARGV[1])' "$manifest" "$1"
}

bundle_tag="$(read_manifest_value tag)"
bundle_asset="$(read_manifest_value asset)"
bundle_sha256="$(read_manifest_value sha256)"
[[ "$bundle_tag" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid bundle tag: $bundle_tag"
[[ "$bundle_asset" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]] || fail "invalid bundle asset: $bundle_asset"
if [[ "$refresh_from_source" == false ]]; then
  [[ "$bundle_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || fail 'offline model bundle is not published; run scripts/publish-offline-model-bundle.sh'
fi

model_directories=(
  parakeet-tdt-0.6b-v2
  parakeet-tdt-0.6b-v3
  parakeet-ctc-110m-coreml
)

has_model_directories() {
  local directory
  for directory in "${model_directories[@]}"; do
    [[ -d "$destination/$directory" ]] || return 1
  done
}

remove_model_directories() {
  local directory
  for directory in "${model_directories[@]}"; do
    rm -rf "$destination/$directory"
  done
}

download_bundle() {
  command -v curl >/dev/null 2>&1 || fail 'curl is required to download the offline model bundle'
  command -v tar >/dev/null 2>&1 || fail 'tar is required to unpack the offline model bundle'
  command -v shasum >/dev/null 2>&1 || fail 'shasum is required to verify the offline model bundle'

  local temporary_directory archive actual_sha256 expected_prefix
  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/leise-offline-models.XXXXXX")"
  trap 'rm -rf "$temporary_directory"' RETURN
  archive="$temporary_directory/$bundle_asset"

  log "downloading pinned bundle $bundle_tag from GitHub Releases"
  curl --fail --location --retry 3 --output "$archive" \
    "https://github.com/zoltanf/Leise/releases/download/$bundle_tag/$bundle_asset"
  actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual_sha256" == "$bundle_sha256" ]] \
    || fail "bundle checksum mismatch: expected $bundle_sha256, got $actual_sha256"

  expected_prefix="${model_directories[0]}/"
  tar -tzf "$archive" | grep -Fq "$expected_prefix" \
    || fail 'bundle does not contain the expected model directories'
  mkdir -p "$destination"
  remove_model_directories
  tar -xzf "$archive" -C "$destination"
  trap - RETURN
  rm -rf "$temporary_directory"
}

mkdir -p "$destination"
if [[ "$refresh_from_source" == true ]]; then
  log "refreshing model cache from upstream sources at $destination"
  swift run \
    --package-path "$repo_root/LeiseComponents" \
    --scratch-path "$repo_root/.build/OfflineModelPrep" \
    OfflineModelPrep \
    "$destination"
elif ! has_model_directories; then
  download_bundle
fi

log "validating model cache without network access"
swift run \
  --package-path "$repo_root/LeiseComponents" \
  --scratch-path "$repo_root/.build/OfflineModelPrep" \
  OfflineModelPrep \
  --validate \
  "$destination"

cp "$manifest" "$destination/manifest.json"
cp "$repo_root/release/offline-models/NOTICE.txt" "$destination/NOTICE.txt"
log "offline model cache is complete"
