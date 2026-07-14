#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
xcode_derived_data_root="$HOME/Library/Developer/Xcode/DerivedData"

dry_run=false
include_xcode_derived_data=false

usage() {
  cat <<'EOF'
Usage: scripts/reset-build-caches.sh [options]

Remove generated build products and caches for Leise.

Options:
  --dry-run                 Show what would be removed without deleting it.
  --xcode-derived-data      Also remove Leise-* directories from Xcode's global
                            DerivedData directory.
  --all                     Alias for --xcode-derived-data.
  -h, --help                Show this help message.

The installed application, source files, tracked performance captures, and
Swift package lockfiles are never removed.
EOF
}

log() {
  printf '[leise-reset] %s\n' "$*"
}

while (($# > 0)); do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    --xcode-derived-data|--all)
      include_xcode_derived_data=true
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

if [[ ! -d "$repo_root/.git" || ! -d "$repo_root/Leise.xcodeproj" ]]; then
  log "error: repository markers are missing from $repo_root"
  exit 1
fi

display_size() {
  du -sh "$1" 2>/dev/null | awk '{print $1}' || printf 'unknown'
}

remove_repo_path() {
  local path="$1"

  [[ -e "$path" || -L "$path" ]] || return
  case "$path" in
    "$repo_root"/*) ;;
    *)
      log "error: refusing to remove path outside the repository: $path"
      exit 1
      ;;
  esac

  if [[ "$dry_run" == true ]]; then
    log "would remove ($(display_size "$path")): ${path#"$repo_root"/}"
  else
    log "removing ($(display_size "$path")): ${path#"$repo_root"/}"
    rm -rf -- "$path"
  fi
}

remove_xcode_derived_data_path() {
  local path="$1"

  [[ -d "$path" ]] || return
  case "$path" in
    "$xcode_derived_data_root"/Leise-*) ;;
    *)
      log "error: refusing unexpected Xcode DerivedData path: $path"
      exit 1
      ;;
  esac

  if [[ "$dry_run" == true ]]; then
    log "would remove ($(display_size "$path")): $path"
  else
    log "removing ($(display_size "$path")): $path"
    rm -rf -- "$path"
  fi
}

repo_targets=(
  "$repo_root/.build"
  "$repo_root/build"
  "$repo_root/DerivedData"
  "$repo_root/LeiseComponents/.build"
  "$repo_root/LeiseComponents/.swiftpm"
  "$repo_root/Leise.xcodeproj/xcuserdata"
  "$repo_root/Leise.xcodeproj/project.xcworkspace/xcuserdata"
)

while IFS= read -r -d '' path; do
  repo_targets+=("$path")
done < <(find "$repo_root" -maxdepth 1 -type d -name 'build-*' -print0)

# Remove metadata and interpreter caches outside the build directories above.
while IFS= read -r -d '' path; do
  repo_targets+=("$path")
done < <(
  find "$repo_root" \
    \( \
      -path "$repo_root/.git" -o \
      -path "$repo_root/.build" -o \
      -path "$repo_root/build-*" -o \
      -path "$repo_root/LeiseComponents/.build" -o \
      -path "$repo_root/LeiseComponents/.swiftpm" \
    \) -prune -o \
    \( -type d -name '__pycache__' \) -print0 -prune -o \
    \( \
      -type f \
      \( -name '*.pyc' -o -name '*.profraw' -o -name '.DS_Store' \) \
    \) -print0
)

found_any=false
for path in "${repo_targets[@]}"; do
  if [[ -e "$path" || -L "$path" ]]; then
    found_any=true
    remove_repo_path "$path"
  fi
done

if [[ "$include_xcode_derived_data" == true && -d "$xcode_derived_data_root" ]]; then
  while IFS= read -r -d '' path; do
    found_any=true
    remove_xcode_derived_data_path "$path"
  done < <(find "$xcode_derived_data_root" -maxdepth 1 -type d -name 'Leise-*' -print0)
fi

if [[ "$found_any" == false ]]; then
  log "nothing to remove"
elif [[ "$dry_run" == true ]]; then
  log "dry run complete; no files were removed"
else
  log "reset complete"
fi
