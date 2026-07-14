#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$repo_root/Leise.xcodeproj/project.pbxproj"

usage() {
  cat <<'EOF'
Usage: ./scripts/version.sh <command> [argument]

Commands:
  current             Print the current semantic version.
  set X.Y.Z           Set the project version explicitly.
  bump patch          Increment X.Y.Z to X.Y.(Z+1).
  bump minor          Increment X.Y.Z to X.(Y+1).0.
  bump major          Increment X.Y.Z to (X+1).0.0.

Versions intentionally use stable X.Y.Z syntax. GitHub releases use the
matching vX.Y.Z tag. Numeric build identifiers are derived from Git history.
EOF
}

fail() {
  printf '[leise-version] error: %s\n' "$*" >&2
  exit 1
}

validate_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "version must use X.Y.Z numeric syntax: $1"
}

current_version() {
  local versions=()
  local value first

  while IFS= read -r value; do
    [[ -n "$value" ]] && versions+=("$value")
  done < <(
    sed -n \
      '/<key>MARKETING_VERSION<\/key>/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;}' \
      "$project_file"
  )

  ((${#versions[@]} > 0)) || fail "MARKETING_VERSION was not found in the Xcode project"
  first="${versions[0]}"
  for value in "${versions[@]}"; do
    [[ "$value" == "$first" ]] \
      || fail "Xcode configurations disagree on MARKETING_VERSION: ${versions[*]}"
  done
  validate_version "$first"
  printf '%s\n' "$first"
}

set_version() {
  local version="$1"
  local previous

  validate_version "$version"
  previous="$(current_version)"
  LEISE_NEW_VERSION="$version" /usr/bin/perl -0pi -e '
    s{(<key>MARKETING_VERSION</key>\s*<string>)[^<]*(</string>)}
     {$1 . $ENV{LEISE_NEW_VERSION} . $2}ge
  ' "$project_file"

  [[ "$(current_version)" == "$version" ]] || fail "failed to update the Xcode project"
  if [[ "$previous" == "$version" ]]; then
    printf '[leise-version] version is already %s\n' "$version"
  else
    printf '[leise-version] %s -> %s\n' "$previous" "$version"
  fi
}

bump_version() {
  local part="$1"
  local current major minor patch next

  current="$(current_version)"
  IFS=. read -r major minor patch <<< "$current"

  case "$part" in
    patch)
      next="$major.$minor.$((patch + 1))"
      ;;
    minor)
      next="$major.$((minor + 1)).0"
      ;;
    major)
      next="$((major + 1)).0.0"
      ;;
    *)
      fail "bump must be one of: patch, minor, major"
      ;;
  esac

  set_version "$next"
}

command_name="${1:-}"
case "$command_name" in
  current)
    (($# == 1)) || fail "current takes no arguments"
    current_version
    ;;
  set)
    (($# == 2)) || fail "set requires a version"
    set_version "$2"
    ;;
  bump)
    (($# == 2)) || fail "bump requires patch, minor, or major"
    bump_version "$2"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
