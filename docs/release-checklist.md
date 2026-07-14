# Release Checklist

## Automated checks

- `xcodebuild test -project Leise.xcodeproj -scheme Leise -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `bash scripts/check_static_components.sh`
- `swift test --package-path LeiseComponents`
- `xcodebuild -project Leise.xcodeproj -scheme Leise -configuration Release -derivedDataPath build -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `bash scripts/check_first_party_warnings.sh build.log`
- `bash scripts/check_release_binary_instrumentation.sh --self-test`

## Manual smoke checks

- Fresh install and onboarding
- Microphone and Accessibility permission recovery
- Push-to-talk, toggle, and hybrid dictation hotkeys
- Parakeet v2/v3 model selection, download, loading, and transcription
- Streaming preview and very short speech handling
- Text insertion in plain-text, rich-text, browser, and code targets
- Profile matching by application and website
- History save, edit, retention, and export
- Dictionary import/export, vocabulary hints, and term packs
- File transcription, recorder, and failed-dictation recovery
- Filler-word cleanup, spoken punctuation, and number normalization
- Notch, Overlay, and Minimal indicators
- Audio-device changes, including Bluetooth route changes
- Media pause/resume and audio ducking during dictation
- Error-log diagnostics export

## Before tagging

- Confirm the app contains only the two reviewed built-in components: Parakeet and filler-word cleanup.
- Confirm removed product surfaces have no settings route, runtime service, target, entitlement, script, or documentation entry.
- Review `README.md`, `SECURITY.md`, and `docs/support-matrix.md`.
- Record launch, memory, dictation, and build measurements from the simplification plan.
- Verify the DMG/ZIP and update feed metadata on a clean machine.
