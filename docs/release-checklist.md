# Release Checklist

The canonical publication command runs the automated checks, creates the artifacts, tags
the release commit, pushes the tag, and uploads a GitHub Release:

```sh
./scripts/publish-github-release.sh
```

## Automated checks

The publisher runs these exact checks before creating a tag:

```sh
bash scripts/check_static_components.sh

xcodebuild test \
  -project Leise.xcodeproj \
  -scheme Leise \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData-Release \
  -parallel-testing-enabled NO \
  ENABLE_DEBUG_DYLIB=NO \
  CODE_SIGN_IDENTITY='-' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

swift test \
  --package-path LeiseComponents \
  --scratch-path .build/LeiseComponents

./scripts/build-release-local.sh --no-clean
```

The release build additionally checks first-party compiler warnings, instrumentation,
architecture, bundle metadata, entitlements, the ad-hoc signature, and statically linked
components.

## Manual smoke checks

- Fresh install and onboarding
- Microphone and Accessibility permission recovery
- Push-to-talk, toggle, and hybrid dictation hotkeys
- Parakeet v2/v3 model selection, download, loading, and transcription
- Streaming preview and very short speech handling
- Text insertion in plain-text, rich-text, browser, and code targets
- Profile matching by application and website
- History save, edit, retention, and export
- Dictionary import/export and vocabulary hints
- File transcription, recorder, and failed-dictation recovery
- Filler-word cleanup, spoken punctuation, and number normalization
- Notch, Overlay, and Minimal indicators
- Audio-device changes, including Bluetooth route changes
- Media pause/resume and audio ducking during dictation
- Error-log diagnostics export

## Before publishing

- Run `./scripts/version.sh current` and confirm the intended version.
- Commit the version and release contents; the publisher requires a clean working tree.
- Run `./scripts/publish-github-release.sh --dry-run`.
- Confirm `gh auth status` succeeds for the `zoltanf/Leise` repository.
- Complete the manual smoke checks on the packaged app.
- Remember that the artifacts are ad-hoc signed and not Apple-notarized.
