#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$repo_root/.build/DerivedData-Release"
offline_models_path="$repo_root/.build/OfflineModels"
artifact_dir="$repo_root/dist"
app_name="Leise"
architecture="arm64"
variant="all"
create_dmg=true
clean=true

usage() {
  cat <<'EOF'
Usage: ./scripts/build-release-local.sh [options]

Build, ad-hoc sign, verify, and package local Leise release editions.

Options:
  --variant VALUE Build all, on-demand, or offline editions (default: all).
  --no-dmg       Create only ZIP archives and the checksum file.
  --no-clean     Reuse the existing Release DerivedData and offline-model cache.
  -h, --help     Show this help message.

The offline edition preparation downloads about 1 GB of model assets once and
caches them in .build/OfflineModels. Artifacts are written to dist/. No Apple
Developer account is required. Apps are ad-hoc signed and not Apple-notarized.
EOF
}

log() {
  printf '[leise-release-build] %s\n' "$*"
}

while (($# > 0)); do
  case "$1" in
    --variant)
      [[ $# -ge 2 ]] || { printf 'Missing value for --variant\n' >&2; exit 2; }
      variant="$2"
      shift
      ;;
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

case "$variant" in
  all|on-demand|offline) ;;
  *)
    printf 'Invalid --variant value: %s (expected all, on-demand, or offline)\n' "$variant" >&2
    exit 2
    ;;
esac

for command in xcodebuild codesign ditto shasum plutil; do
  if ! command -v "$command" >/dev/null 2>&1; then
    log "error: required command is unavailable: $command"
    exit 1
  fi
done

remove_tree() {
  local path="$1"
  if [[ -e "$path" ]]; then
    chmod -R u+w "$path" 2>/dev/null || true
    rm -rf -- "$path"
  fi
}

version="$(bash "$repo_root/scripts/version.sh" current)"
build_number="$(git -C "$repo_root" rev-list --count HEAD 2>/dev/null || true)"
if [[ -z "$build_number" || ! "$build_number" =~ ^[0-9]+$ ]]; then
  build_number="$(date -u '+%Y%m%d%H%M')"
fi

if [[ -n "$(git -C "$repo_root" status --short)" ]]; then
  log "warning: building from a working tree with uncommitted changes"
fi

if [[ "$clean" == true ]]; then
  remove_tree "$derived_data_path"
fi
remove_tree "$artifact_dir"
mkdir -p "$derived_data_path" "$artifact_dir"

log "version: $version ($build_number)"
log "architecture: $architecture"
log "editions: $variant"
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

built_app_path="$derived_data_path/Build/Products/Release/$app_name.app"
if [[ ! -d "$built_app_path" ]]; then
  log "error: built application was not found: $built_app_path"
  exit 1
fi

sign_app() {
  local app_path="$1"
  find "$app_path" -name '._*' -delete
  xattr -cr "$app_path" >/dev/null 2>&1 || true
  codesign --force --deep --sign - --timestamp=none "$app_path"
  codesign \
    --force \
    --sign - \
    --timestamp=none \
    --entitlements "$repo_root/Leise/Resources/Leise.entitlements" \
    "$app_path"
}

artifacts=()
package_edition() {
  local edition="$1"
  local app_path="$2"
  local artifact_base volume_name zip_path dmg_path dmg_root

  if [[ "$edition" == "offline" ]]; then
    artifact_base="$app_name-$version-Offline-macOS-$architecture"
    volume_name="$app_name Offline $version"
  else
    artifact_base="$app_name-$version-macOS-$architecture"
    volume_name="$app_name $version"
  fi

  log "signing and verifying $edition edition"
  sign_app "$app_path"
  bash "$repo_root/scripts/test-release-build.sh" \
    "$app_path" "$version" "$build_number" "$edition"

  zip_path="$artifact_dir/$artifact_base.zip"
  log "creating $edition ZIP archive"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
  artifacts+=("$(basename "$zip_path")")

  if [[ "$create_dmg" == true ]]; then
    command -v hdiutil >/dev/null 2>&1 || {
      log "error: hdiutil is required to create the DMG"
      exit 1
    }
    dmg_path="$artifact_dir/$artifact_base.dmg"
    dmg_root="$derived_data_path/dmg-root-$edition"
    remove_tree "$dmg_root"
    mkdir -p "$dmg_root"
    ditto "$app_path" "$dmg_root/$app_name.app"
    ln -s /Applications "$dmg_root/Applications"
    log "creating $edition DMG archive"
    hdiutil create \
      -volname "$volume_name" \
      -srcfolder "$dmg_root" \
      -ov \
      -format UDZO \
      "$dmg_path" >/dev/null
    artifacts+=("$(basename "$dmg_path")")
  fi
}

if [[ "$variant" == "all" || "$variant" == "on-demand" ]]; then
  package_edition "on-demand" "$built_app_path"
fi

if [[ "$variant" == "all" || "$variant" == "offline" ]]; then
  offline_app_path="$derived_data_path/Offline/$app_name.app"
  remove_tree "$(dirname "$offline_app_path")"
  mkdir -p "$(dirname "$offline_app_path")"
  ditto "$built_app_path" "$offline_app_path"

  bash "$repo_root/scripts/prepare-offline-models.sh" "$offline_models_path"
  offline_resources="$offline_app_path/Contents/Resources/OfflineModels"
  remove_tree "$offline_resources"
  ditto "$offline_models_path" "$offline_resources"
  chmod -R a-w "$offline_resources"
  package_edition "offline" "$offline_app_path"
fi

checksum_path="$artifact_dir/$app_name-$version-SHA256SUMS.txt"
(
  cd "$artifact_dir"
  shasum -a 256 "${artifacts[@]}" > "$(basename "$checksum_path")"
)

log "artifacts ready"
for artifact in "${artifacts[@]}" "$(basename "$checksum_path")"; do
  printf '  %s\n' "$artifact_dir/$artifact"
done
log "note: these artifacts are ad-hoc signed and not Apple-notarized"
