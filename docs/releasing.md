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

By default the command builds both release editions and writes these files to `dist/`:

- `Leise-X.Y.Z-macOS-arm64.zip`
- `Leise-X.Y.Z-macOS-arm64.dmg`
- `Leise-X.Y.Z-Offline-macOS-arm64.zip`
- `Leise-X.Y.Z-Offline-macOS-arm64.dmg`
- `Leise-X.Y.Z-SHA256SUMS.txt`

The standard edition keeps the existing on-demand model downloads. The offline edition
includes Parakeet TDT v2, Parakeet TDT v3, and Parakeet CTC 110M for vocabulary boosting.
The first offline build restores the pinned model archive from GitHub Releases into
`.build/OfflineModels`; later builds reuse that ignored cache. Model files are deliberately not
committed to Git and normal application releases do not contact Hugging Face.

The script builds with code coverage and the debug dylib disabled, applies a local ad-hoc
signature after each edition's resources are final, restores Leise's entitlements, verifies
the bundle, binary, model manifest, required model files, and attribution notice, and uses
native macOS packaging tools. Pass `--variant on-demand` or `--variant offline` to build one
edition, `--no-dmg` when only ZIPs are needed, or `--no-clean` to reuse Release DerivedData.

Offline model preparation can also be run separately:

```sh
./scripts/prepare-offline-models.sh
```

## Offline model bundle

The model archive is a separately versioned GitHub Release asset declared in
`release/offline-models/manifest.json`. Its SHA-256 is verified before extraction, and the
offline build then validates all three Core ML models with networking disabled.

When deliberately upgrading the bundled models, increment `bundle.version` in the manifest and
publish a new pinned archive:

```sh
./scripts/publish-offline-model-bundle.sh
git add release/offline-models/manifest.json
git commit -m "Pin offline model bundle vN"
```

This is the only workflow that permits a cache refresh from the model providers. Use
`--dry-run` to build and checksum the prospective archive without publishing it.

The included FluidInference Core ML conversions and their underlying NVIDIA Parakeet models
are distributed under CC BY 4.0. Attribution and source links are embedded at
`Leise.app/Contents/Resources/OfflineModels/NOTICE.txt` in the offline edition.

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
annotated `vX.Y.Z` tag only after the tests and both editions' artifact verification succeed,
then uploads both ZIPs, both DMGs, and their shared checksum file. Once GitHub reports the
release's asset digest, it updates `zoltanf/homebrew-leise` with the matching **offline** DMG
version and SHA-256. Use `--draft` to create a draft release. `--skip-tests` and `--skip-build`
are available for recovery from a partially completed publication, but should not be used for a
normal release.

To retry only the deterministic Homebrew update after a successful release:

```sh
./scripts/publish-homebrew-cask.sh --version X.Y.Z
```

The script reads the SHA-256 digest from GitHub Release metadata, refuses an asset that is not
the offline DMG, changes only the cask version and checksum, and pushes the resulting tap commit.
Use `--dry-run` to verify a published release without changing the tap.

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
