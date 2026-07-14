# Building and Releasing Leise

Leise uses a local release pipeline. GitHub Actions, an Apple Developer account, Developer
ID certificates, and Apple notarization are not required.

## Versioning

The Xcode target's `MARKETING_VERSION` is the source of truth. Leise begins from the
inherited upstream version `1.6.0` and uses stable semantic versions:

```text
MAJOR.MINOR.PATCH
```

The corresponding Git tag is `vMAJOR.MINOR.PATCH`. Release build numbers are numeric and
derived from `git rev-list --count HEAD`, so they increase with repository history without
requiring a second manually edited version field.

Inspect or change the version with:

```sh
./scripts/version.sh current
./scripts/version.sh bump patch
./scripts/version.sh bump minor
./scripts/version.sh bump major
./scripts/version.sh set 1.7.0
```

A version change edits both Debug and Release Xcode configurations. Commit that change
before publishing.

## Local development build

The standard local workflow builds a Debug app, installs it at
`~/Applications/Leise.app`, verifies its ad-hoc signature and retained components, and
launches it:

```sh
./scripts/build-and-run.sh
```

No signing account is needed. Use `./scripts/reset-build-caches.sh --all` when a fully clean
Xcode and SwiftPM state is required.

## Local release artifacts

Build a clean Apple Silicon Release app and package it with:

```sh
./scripts/build-release-local.sh
```

The command writes these files to `dist/`:

- `Leise-X.Y.Z-macOS-arm64.zip`
- `Leise-X.Y.Z-macOS-arm64.dmg`
- `Leise-X.Y.Z-SHA256SUMS.txt`

It builds with code coverage and the debug dylib disabled, applies a local ad-hoc signature,
restores Leise's entitlements, verifies the bundle and binary, and uses only native macOS
packaging tools. Pass `--no-dmg` when only a ZIP is needed or `--no-clean` to reuse the
Release DerivedData cache.

## Publish to GitHub Releases

Install and authenticate the GitHub CLI once:

```sh
brew install gh
gh auth login -h github.com
```

Prepare a release as a normal committed change:

```sh
./scripts/version.sh bump patch
git add Leise.xcodeproj/project.pbxproj
git commit -m "Prepare Leise X.Y.Z"
git push
```

Preview the publication without changing anything:

```sh
./scripts/publish-github-release.sh --dry-run
```

Then test, build, tag, push, and publish:

```sh
./scripts/publish-github-release.sh
```

The publisher requires a clean working tree and valid `gh` authentication. It creates the
annotated `vX.Y.Z` tag only after the tests and artifact verification succeed. Use `--draft`
to create a draft release. `--skip-tests` and `--skip-build` are available for recovery from
a partially completed publication, but should not be used for a normal release.

## Gatekeeper and signing limitations

An ad-hoc signature proves bundle integrity locally but does not establish an Apple-verified
developer identity. GitHub downloads may therefore be blocked by Gatekeeper. After copying
the app to `/Applications`, a user can explicitly remove quarantine and launch it:

```sh
xattr -dr com.apple.quarantine /Applications/Leise.app
open /Applications/Leise.app
```

Users must grant Microphone and Accessibility permissions themselves. Because ad-hoc code
identity changes when the binary changes, a new release may require Accessibility permission
to be granted again. If the project later obtains a Developer ID certificate, the same build
pipeline can be extended with Developer ID signing and notarization without changing the
semantic version or GitHub Release scheme.
