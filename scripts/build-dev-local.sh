#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$repo_root/.build/DerivedData-Dev"
install_dir="$HOME/Applications"
installed_app="$install_dir/Leise.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

log() {
  printf '[leise-dev-build] %s\n' "$*"
}

quit_running_leise() {
  local pids
  pids="$(running_dev_leise_pids)"
  if [[ -z "$pids" ]]; then
    return
  fi

  log "quitting only development Leise processes before rebuilding"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done <<< "$pids"
  for _ in {1..20}; do
    if [[ -z "$(running_dev_leise_pids)" ]]; then
      return
    fi
    sleep 0.25
  done

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done <<< "$(running_dev_leise_pids)"
}

running_dev_leise_pids() {
  local pid args
  while IFS= read -r pid; do
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    case "$args" in
      "$installed_app/Contents/MacOS/Leise"*)
        printf '%s\n' "$pid"
        ;;
      "$repo_root/.build/"*"/Build/Products/Debug/Leise.app/Contents/MacOS/Leise"*)
        printf '%s\n' "$pid"
        ;;
      "$HOME/Library/Developer/Xcode/DerivedData/"*"/Build/Products/Debug/Leise.app/Contents/MacOS/Leise"*)
        printf '%s\n' "$pid"
        ;;
    esac
  done < <(pgrep -x Leise 2>/dev/null || true)
}

trash_if_present() {
  local path="$1"
  if [[ -e "$path" ]]; then
    if ! command -v trash >/dev/null 2>&1; then
      log "error: trash command not found; install trash or remove stale dev apps manually"
      return 1
    fi
    if [[ -x "$lsregister" ]] && [[ "$path" == *.app ]]; then
      "$lsregister" -u "$path" >/dev/null 2>&1 || true
    fi
    trash "$path"
  fi
}

write_build_marker() {
  local app="$1"
  local marker="$app/Contents/Resources/DevBuildSource.txt"
  local branch commit built_at

  branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
  commit="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || true)"
  built_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  {
    printf 'app=Leise\n'
    printf 'repo=%s\n' "$repo_root"
    printf 'branch=%s\n' "${branch:-unknown}"
    printf 'commit=%s\n' "${commit:-unknown}"
    printf 'built_at_utc=%s\n' "$built_at"
  } > "$marker"
}

trash_stale_dev_apps() {
  local keep_app="$1"
  local search_roots=(
    "$HOME/Library/Developer/Xcode/DerivedData"
    "$repo_root/.build"
  )

  for root in "${search_roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' app_path; do
      [[ "$app_path" != "$keep_app" ]] || continue
      trash_if_present "$app_path"
      log "trashed stale app: $app_path"
    done < <(find "$root" -path '*/Build/Products/Debug/Leise.app' -type d -print0 2>/dev/null)
  done
}

quit_running_leise

xcodebuild build \
  -project "$repo_root/Leise.xcodeproj" \
  -scheme Leise \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  ENABLE_DEBUG_DYLIB=NO \
  CODE_SIGN_IDENTITY='-' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

app_path="$derived_data_path/Build/Products/Debug/Leise.app"
if [[ ! -d "$app_path" ]]; then
  app_path="$(find "$derived_data_path" -path '*/Build/Products/Debug/Leise.app' -type d -print -quit 2>/dev/null || true)"
fi
if [[ -z "${app_path:-}" ]] || [[ ! -d "$app_path" ]]; then
  log "error: built Leise.app was not found"
  exit 1
fi

mkdir -p "$install_dir"
trash_if_present "$installed_app"
ditto "$app_path" "$installed_app"
write_build_marker "$installed_app"
xattr -cr "$installed_app" >/dev/null 2>&1 || true
codesign \
  --force \
  --deep \
  --sign - \
  --timestamp=none \
  "$installed_app"
codesign \
  --force \
  --sign - \
  --timestamp=none \
  --entitlements "$repo_root/Leise/Resources/Leise.entitlements" \
  "$installed_app"
codesign --verify --deep --strict --verbose=2 "$installed_app"
"$repo_root/scripts/test-dev-build.sh" "$installed_app"

trash_stale_dev_apps "$installed_app"

if [[ -x "$lsregister" ]]; then
  "$lsregister" -f "$installed_app" >/dev/null 2>&1 || true
fi

log "installed app: $installed_app"
log "launch: open '$installed_app'"
