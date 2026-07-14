# Leise Release Readiness

Leise is currently a green-field, local-only macOS application. There is no supported upgrade path or persisted-data compatibility contract yet; local settings and stores may be reset while the product is simplified.

## Supported product

- System-wide dictation with push-to-talk, toggle, and hybrid hotkeys
- Parakeet v2/v3 transcription, including model management and streaming where supported
- Text insertion and target-app formatting
- Profiles for application and website matching
- History, dictionary, snippets, term packs, and usage statistics
- File transcription, audio recording, and failed-dictation recovery
- Filler-word cleanup, spoken punctuation, and number normalization
- Notch, Overlay, and Minimal indicators
- Local folder synchronization for retained user data
- Support diagnostics and error logging

## Release gates

- The app and internal SDK test suites pass.
- A release configuration builds without first-party warnings.
- Parakeet and filler-word cleanup pass their behavioral tests.
- Removed product surfaces are absent from the runtime, project targets, entitlements, scripts, settings, and documentation.
- Launch, idle-memory, dictation, and build measurements meet the budgets in the simplification plan or have a documented exception.
- Manual smoke checks in `docs/release-checklist.md` pass on a clean local installation.

## Distribution

Until the product scope and persistence model stabilize, builds are for local testing only. Public release channels, upgrade guarantees, and compatibility commitments will be defined later.
