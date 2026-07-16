#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dry_run=false
draft=false
skip_tests=false
skip_build=false
create_dmg=true

usage() {
  cat <<'EOF'
Usage: ./scripts/publish-github-release.sh [options]

Test, build, tag, and publish the current Leise version to GitHub Releases.

Options:
  --dry-run       Print the intended release without building or publishing.
  --draft         Create a draft GitHub release.
  --skip-tests    Skip the Xcode and Swift package test suites.
  --skip-build    Publish artifacts that already exist in dist/.
  --no-dmg        Build and publish only the ZIP and checksum file.
  -h, --help      Show this help message.

The working tree must be clean for a real publication. The script creates and
pushes the matching vX.Y.Z tag only after tests and artifact verification pass.
EOF
}

log() {
  printf '[leise-publish] %s\n' "$*"
}

fail() {
  printf '[leise-publish] error: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    --draft)
      draft=true
      ;;
    --skip-tests)
      skip_tests=true
      ;;
    --skip-build)
      skip_build=true
      ;;
    --no-dmg)
      create_dmg=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

version="$(bash "$repo_root/scripts/version.sh" current)"
tag="v$version"
architecture="arm64"
artifact_dir="$repo_root/dist"
on_demand_base="Leise-$version-macOS-$architecture"
offline_base="Leise-$version-Offline-macOS-$architecture"
on_demand_zip_path="$artifact_dir/$on_demand_base.zip"
offline_zip_path="$artifact_dir/$offline_base.zip"
on_demand_dmg_path="$artifact_dir/$on_demand_base.dmg"
offline_dmg_path="$artifact_dir/$offline_base.dmg"
checksum_path="$artifact_dir/Leise-$version-SHA256SUMS.txt"

origin_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
github_repo="${GH_REPO:-}"
if [[ -z "$github_repo" ]]; then
  github_repo="$(printf '%s' "$origin_url" | sed -E \
    -e 's#^git@github\.com:##' \
    -e 's#^https://github\.com/##' \
    -e 's#\.git$##')"
fi
[[ "$github_repo" =~ ^[^/]+/[^/]+$ ]] \
  || fail "origin is not a recognizable GitHub repository: $origin_url"

log "repository: $github_repo"
log "release: $tag"
log "signing: local ad-hoc signature; no Apple notarization"

if [[ "$dry_run" == true ]]; then
  if [[ -n "$(git -C "$repo_root" status --short)" ]]; then
    log "working tree is currently dirty; a real publication would stop"
  else
    log "working tree is clean"
  fi
  [[ "$skip_tests" == true ]] || log "would run the Xcode and LeiseComponents tests"
  [[ "$skip_build" == true ]] || log "would build and verify on-demand and offline editions"
  log "would create and push tag $tag"
  if [[ "$draft" == true ]]; then
    log "would create a draft GitHub release"
  else
    log "would create a public GitHub release"
  fi
  log "dry run complete; no build, tag, push, or release was created"
  exit 0
fi

[[ -z "$(git -C "$repo_root" status --short)" ]] \
  || fail "working tree is not clean; commit the release contents first"

command -v gh >/dev/null 2>&1 || fail "GitHub CLI is not installed: https://cli.github.com"
gh auth status >/dev/null 2>&1 \
  || fail "GitHub CLI authentication is invalid; run: gh auth login -h github.com"

if gh release view "$tag" --repo "$github_repo" >/dev/null 2>&1; then
  fail "GitHub release already exists: $tag"
fi

if git -C "$repo_root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  tagged_commit="$(git -C "$repo_root" rev-list -n 1 "$tag")"
  head_commit="$(git -C "$repo_root" rev-parse HEAD)"
  [[ "$tagged_commit" == "$head_commit" ]] \
    || fail "$tag already points to a different commit"
fi

if [[ "$skip_tests" == false ]]; then
  log "running static architecture checks"
  bash "$repo_root/scripts/check_static_components.sh"

  log "running Xcode tests"
  xcodebuild test \
    -project "$repo_root/Leise.xcodeproj" \
    -scheme Leise \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$repo_root/.build/DerivedData-Release" \
    -parallel-testing-enabled NO \
    ENABLE_DEBUG_DYLIB=NO \
    CODE_SIGN_IDENTITY='-' \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

  log "running LeiseComponents tests"
  swift test \
    --package-path "$repo_root/LeiseComponents" \
    --scratch-path "$repo_root/.build/LeiseComponents"
fi

if [[ "$skip_build" == false ]]; then
  build_options=(--no-clean)
  [[ "$create_dmg" == true ]] || build_options+=(--no-dmg)
  bash "$repo_root/scripts/build-release-local.sh" "${build_options[@]}"
fi

artifacts=("$on_demand_zip_path" "$offline_zip_path")
if [[ "$create_dmg" == true ]]; then
  artifacts+=("$on_demand_dmg_path" "$offline_dmg_path")
fi
artifacts+=("$checksum_path")
for artifact in "${artifacts[@]}"; do
  [[ -f "$artifact" ]] || fail "release artifact is missing: $artifact"
done

if ! git -C "$repo_root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  log "creating annotated tag $tag"
  git -C "$repo_root" tag -a "$tag" -m "Leise $version"
fi

log "pushing tag $tag"
git -C "$repo_root" push origin "refs/tags/$tag"

previous_tag="$(
  git -C "$repo_root" tag --merged HEAD --sort=-version:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | grep -v -F "$tag" \
    | head -1 \
    || true
)"

installation_notes="$(cat <<'EOF'
## Choose an edition

- **Leise** is the smaller download and fetches the selected speech model on demand.
- **Leise Offline** includes Parakeet v2, Parakeet v3, and the vocabulary-boosting model. It needs no model downloads after installation.

## Installation note

This community build is ad-hoc signed and is **not notarized by Apple**. After
copying Leise to Applications, macOS may require this command before first use:

```sh
xattr -dr com.apple.quarantine /Applications/Leise.app
```

The app will request Microphone and Accessibility access when needed.
EOF
)"

release_options=(
  --repo "$github_repo"
  --title "Leise $version"
  --generate-notes
  --notes "$installation_notes"
)
[[ -z "$previous_tag" ]] || release_options+=(--notes-start-tag "$previous_tag")
[[ "$draft" == false ]] || release_options+=(--draft)

log "creating GitHub release"
gh release create "$tag" "${artifacts[@]}" "${release_options[@]}"
log "published: https://github.com/$github_repo/releases/tag/$tag"

if [[ "$draft" == false ]]; then
  log "updating the Homebrew cask with the verified offline DMG"
  GH_REPO="$github_repo" bash "$repo_root/scripts/publish-homebrew-cask.sh" --version "$version"
else
  log "skipping Homebrew cask update for the draft release"
fi
