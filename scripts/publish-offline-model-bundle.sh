#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/release/offline-models/manifest.json"
cache="$repo_root/.build/OfflineModels"
dry_run=false

usage() {
  cat <<'EOF'
Usage: ./scripts/publish-offline-model-bundle.sh [--dry-run]

Create and publish the versioned offline-model archive defined by
release/offline-models/manifest.json. This is the only supported workflow that
may fetch missing model files from their upstream source.
EOF
}

log() { printf '[leise-model-bundle] %s\n' "$*"; }
fail() { printf '[leise-model-bundle] error: %s\n' "$*" >&2; exit 1; }

while (($# > 0)); do
  case "$1" in
    --dry-run) dry_run=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

command -v ruby >/dev/null 2>&1 || fail 'ruby is required to read the model manifest'
command -v tar >/dev/null 2>&1 || fail 'tar is required to create the model bundle'
command -v shasum >/dev/null 2>&1 || fail 'shasum is required to checksum the model bundle'
command -v gh >/dev/null 2>&1 || fail 'GitHub CLI is not installed'
gh auth status >/dev/null 2>&1 || fail 'GitHub CLI authentication is invalid; run: gh auth login -h github.com'

read_manifest_value() {
  ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("bundle").fetch(ARGV[1])' "$manifest" "$1"
}

bundle_version="$(read_manifest_value version)"
bundle_tag="$(read_manifest_value tag)"
bundle_asset="$(read_manifest_value asset)"
[[ "$bundle_version" =~ ^[0-9]+$ ]] || fail "bundle version must be a positive integer: $bundle_version"
[[ "$bundle_tag" == "offline-models-v$bundle_version" ]] || fail 'bundle tag must match its version'
[[ "$bundle_asset" == "Leise-OfflineModels-v$bundle_version.tar.gz" ]] || fail 'bundle asset must match its version'

if gh release view "$bundle_tag" --repo zoltanf/Leise >/dev/null 2>&1; then
  fail "bundle release already exists: $bundle_tag; increment bundle.version before publishing"
fi

log 'preparing model cache from upstream sources'
bash "$repo_root/scripts/prepare-offline-models.sh" --refresh-from-source "$cache"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/leise-model-bundle.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT
archive="$work_directory/$bundle_asset"
log "creating archive: $bundle_asset"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$cache" \
  parakeet-tdt-0.6b-v2 \
  parakeet-tdt-0.6b-v3 \
  parakeet-ctc-110m-coreml
sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
log "sha256: $sha256"

if [[ "$dry_run" == true ]]; then
  log "would publish $bundle_asset as $bundle_tag and update the manifest checksum"
  exit 0
fi

gh release create "$bundle_tag" "$archive" \
  --repo zoltanf/Leise \
  --title "Leise offline model bundle v$bundle_version" \
  --notes "Pinned Core ML model bundle for deterministic offline Leise builds."

ruby -rjson -e '
  path = ARGV.fetch(0)
  sha256 = ARGV.fetch(1)
  document = JSON.parse(File.read(path))
  document.fetch("bundle")["sha256"] = sha256
  File.write(path, JSON.pretty_generate(document) + "\n")
' "$manifest" "$sha256"
log "published: https://github.com/zoltanf/Leise/releases/tag/$bundle_tag"
log "commit the updated model manifest before the next application release"
