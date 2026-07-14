#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$HOME/Applications/Leise.app"
reset_setup=false
reset_accessibility=false
self_test_only=false

usage() {
  cat <<'EOF'
Usage: ./scripts/build-and-run.sh [options]

Options:
  --reset-setup          Show the startup tutorial from its first step.
  --reset-accessibility  Remove the existing Accessibility grant before launch.
  --self-test            Build and verify the canonical app without launching it.
  -h, --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-setup)
      reset_setup=true
      ;;
    --reset-accessibility)
      reset_accessibility=true
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

if [[ "$reset_accessibility" == true ]]; then
  tccutil reset Accessibility com.leise.mac
  printf 'Reset Accessibility permission; grant it once when Leise opens.\n'
fi

printf 'Launching %s\n' "$app_path"
open "$app_path"
