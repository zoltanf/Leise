#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$HOME/Applications/Leise.app"
reset_setup=false
reset_permissions=false
self_test_only=false

usage() {
  cat <<'EOF'
Usage: ./scripts/build-and-run.sh [options]

Options:
  --reset-setup           Show the startup tutorial from its first step.
  --reset-permissions     Reset all macOS privacy grants before launch.
  --reset-accessibility   Alias for --reset-permissions (backward compatibility).
  --self-test             Build and verify the canonical app without launching it.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-setup)
      reset_setup=true
      ;;
    --reset-permissions|--reset-accessibility)
      reset_permissions=true
      ;;
    --self-test)
      self_test_only=true
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

"$repo_root/scripts/build-dev-local.sh"

if [[ "$self_test_only" == true ]]; then
  exit 0
fi

if [[ ! -d "$app_path" ]]; then
  printf 'Build completed, but the app was not found at: %s\n' "$app_path" >&2
  exit 1
fi

if [[ "$reset_setup" == true ]]; then
  defaults write com.leise.mac setupWizardCompleted -bool false
  defaults write com.leise.mac setupWizardCurrentStep -int 0
  printf 'Reset the startup tutorial.\n'
fi

if [[ "$reset_permissions" == true ]]; then
  info_plist="$app_path/Contents/Info.plist"
  bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
  if [[ -z "$bundle_identifier" ]]; then
    printf 'Could not read the app bundle identifier from: %s\n' "$info_plist" >&2
    exit 1
  fi

  tccutil reset All "$bundle_identifier"
  printf 'Reset all macOS privacy permissions for %s.\n' "$bundle_identifier"
  printf 'Leise will request Accessibility, Microphone, and Screen & System Audio access again when needed.\n'
fi

printf 'Launching %s\n' "$app_path"
open "$app_path"
