#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dry_run=false
version=""

usage() {
  cat <<'EOF'
Usage: ./scripts/publish-homebrew-cask.sh [options]

Update zoltanf/homebrew-leise to install the verified offline DMG from an
existing Leise GitHub Release.

Options:
  --version X.Y.Z  Update this release version (default: current project version).
  --dry-run        Verify the release asset and print the intended cask update.
  -h, --help       Show this help.

Environment:
  GH_REPO                       Source GitHub repository (default: origin remote).
  LEISE_HOMEBREW_TAP_REPO       Homebrew tap repository (default: zoltanf/homebrew-leise).
EOF
}

log() { printf '[leise-homebrew] %s\n' "$*"; }

fail() {
  printf '[leise-homebrew] error: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --version)
      shift
      (($# > 0)) || fail '--version requires X.Y.Z'
      version="$1"
      ;;
    --dry-run) dry_run=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

[[ -n "$version" ]] || version="$(bash "$repo_root/scripts/version.sh" current)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be X.Y.Z: $version"

origin_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
source_repo="${GH_REPO:-$(printf '%s' "$origin_url" | sed -E \
  -e 's#^git@github\.com:##' -e 's#^https://github\.com/##' -e 's#\.git$##')}"
[[ "$source_repo" =~ ^[^/]+/[^/]+$ ]] || fail "origin is not a recognizable GitHub repository: $origin_url"

tap_repo="${LEISE_HOMEBREW_TAP_REPO:-zoltanf/homebrew-leise}"
[[ "$tap_repo" =~ ^[^/]+/[^/]+$ ]] || fail "tap repository must be owner/name: $tap_repo"

command -v gh >/dev/null 2>&1 || fail 'GitHub CLI is not installed'
gh auth status >/dev/null 2>&1 || fail 'GitHub CLI authentication is invalid; run: gh auth login -h github.com'

asset="Leise-$version-Offline-macOS-arm64.dmg"
digest="$(gh release view "v$version" --repo "$source_repo" --json assets --jq ".assets[] | select(.name == \"$asset\") | .digest")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "release asset is missing or has no SHA-256 digest: $asset"
sha256="${digest#sha256:}"

log "source: $source_repo v$version"
log "asset: $asset"
log "sha256: $sha256"

if [[ "$dry_run" == true ]]; then
  log "would update Casks/leise.rb in $tap_repo and push its version-and-checksum commit"
  exit 0
fi

command -v git >/dev/null 2>&1 || fail 'git is not installed'
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/leise-homebrew.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
tap_dir="$work_dir/homebrew-leise"

log "cloning tap: $tap_repo"
git clone --quiet "https://github.com/$tap_repo.git" "$tap_dir"
cask_path="$tap_dir/Casks/leise.rb"
[[ -f "$cask_path" ]] || fail "tap does not contain Casks/leise.rb"
grep -Fq 'Offline-macOS-arm64.dmg' "$cask_path" \
  || fail 'cask is not configured for the offline release; refusing to replace it'

ruby -0pi -e \
  "gsub(/version \"[^\"]+\"/, 'version \"$version\"'); gsub(/sha256 \"[0-9a-f]+\"/, 'sha256 \"$sha256\"')" \
  "$cask_path"

grep -Fq "version \"$version\"" "$cask_path" || fail 'failed to update cask version'
grep -Fq "sha256 \"$sha256\"" "$cask_path" || fail 'failed to update cask checksum'

if git -C "$tap_dir" diff --quiet -- "$cask_path"; then
  log 'tap already contains the verified offline cask'
  exit 0
fi

git -C "$tap_dir" add Casks/leise.rb
git -C "$tap_dir" commit -m "Update Leise to $version"
git -C "$tap_dir" push origin HEAD:main
log "updated: https://github.com/$tap_repo"
