#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$repo_root/.build/DerivedData-Release"
artifact_dir="$repo_root/dist"
app_name="Leise"
architecture="arm64"
create_dmg=true
clean=true

usage() {
  cat <<'EOF'
Usage: ./scripts/build-release-local.sh [options]

Build, ad-hoc sign, verify, and package a local Leise release.

Options:
  --no-dmg       Create only the ZIP archive and checksum file.
  --no-clean     Reuse the existing Release DerivedData directory.
  -h, --help     Show this help message.

Artifacts are written to dist/. No Apple Developer account is required.
The resulting app is ad-hoc signed and is not notarized by Apple.
EOF
}

log() {
  printf '[leise-release-build] %s\n' "$*"
}

while (($# > 0)); do
  case "$1" in
    --no-dmg)
      create_dmg=false
      ;;
    --no-clean)
      clean=false
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

for command in xcodebuild codesign ditto shasum plutil; do
  if ! command -v "$command" >/dev/null 2>&1; then
    log "error: required command is unavailable: $command"
    exit 1
  fi
done

version="$(bash "$repo_root/scripts/version.sh" current)"
build_number="$(git -C "$repo_root" rev-list --count HEAD 2>/dev/null || true)"
if [[ -z "$build_number" || ! "$build_number" =~ ^[0-9]+$ ]]; then
  build_number="$(date -u '+%Y%m%d%H%M')"
fi

if [[ -n "$(git -C "$repo_root" status --short)" ]]; then
  log "warning: building from a working tree with uncommitted changes"
fi

if [[ "$clean" == true ]]; then
  rm -rf -- "$derived_data_path"
fi
rm -rf -- "$artifact_dir"
mkdir -p "$derived_data_path" "$artifact_dir"

log "version: $version ($build_number)"
log "architecture: $architecture"
log "resolving Swift packages"
xcodebuild -resolvePackageDependencies \
  -project "$repo_root/Leise.xcodeproj" \
  -scheme Leise \
  -derivedDataPath "$derived_data_path"

build_log="$derived_data_path/release-build.log"
log "building Release configuration"
set -o pipefail
xcodebuild build \
  -project "$repo_root/Leise.xcodeproj" \
  -scheme Leise \
  -configuration Release \
  -derivedDataPath "$derived_data_path" \
  -destination "platform=macOS,arch=$architecture" \
  ARCHS="$architecture" \
  ONLY_ACTIVE_ARCH=YES \
  ENABLE_CODE_COVERAGE=NO \
  ENABLE_DEBUG_DYLIB=NO \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_IDENTITY='-' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO | tee "$build_log"

bash "$repo_root/scripts/check_first_party_warnings.sh" "$build_log"

app_path="$derived_data_path/Build/Products/Release/$app_name.app"
if [[ ! -d "$app_path" ]]; then
  log "error: built application was not found: $app_path"
  exit 1
fi

log "applying local ad-hoc signature"
find "$app_path" -name '._*' -delete
xattr -cr "$app_path" >/dev/null 2>&1 || true
codesign \
  --force \
  --deep \
  --sign - \
  --timestamp=none \
  "$app_path"
codesign \
  --force \
  --sign - \
  --timestamp=none \
  --entitlements "$repo_root/Leise/Resources/Leise.entitlements" \
  "$app_path"

bash "$repo_root/scripts/test-release-build.sh" "$app_path" "$version" "$build_number"

artifact_base="$app_name-$version-macOS-$architecture"
zip_path="$artifact_dir/$artifact_base.zip"
dmg_path="$artifact_dir/$artifact_base.dmg"
checksum_path="$artifact_dir/$app_name-$version-SHA256SUMS.txt"

log "creating ZIP archive"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

artifacts=("$(basename "$zip_path")")
if [[ "$create_dmg" == true ]]; then
  if ! command -v hdiutil >/dev/null 2>&1; then
    log "error: hdiutil is required to create the DMG"
    exit 1
  fi

  dmg_root="$derived_data_path/dmg-root"
  rm -rf -- "$dmg_root"
  mkdir -p "$dmg_root"
  ditto "$app_path" "$dmg_root/$app_name.app"
  ln -s /Applications "$dmg_root/Applications"

  log "creating DMG archive"
  hdiutil create \
    -volname "$app_name $version" \
    -srcfolder "$dmg_root" \
    -ov \
    -format UDZO \
    "$dmg_path" >/dev/null
  artifacts+=("$(basename "$dmg_path")")
fi

(
  cd "$artifact_dir"
  shasum -a 256 "${artifacts[@]}" > "$(basename "$checksum_path")"
)

log "artifacts ready"
for artifact in "${artifacts[@]}" "$(basename "$checksum_path")"; do
  printf '  %s\n' "$artifact_dir/$artifact"
done
log "note: these artifacts are ad-hoc signed and not Apple-notarized"
