## Project

Leise is a GPL, local-first macOS speech-to-text app, forked from
TypeWhisper for Mac (`upstream` remote) with commercial and plugin surfaces
removed. `origin` is `zoltanf/Leise`; set `gh repo set-default zoltanf/Leise`
in a fresh clone, or `gh` silently queries the upstream repository.

- App target: `Leise/` (MVVM, `ServiceContainer` composition root).
  Internal SPM package: `LeiseComponents/` (`LeiseCore`, `ParakeetEngine`,
  `FillerWordCleanup`). See `docs/architecture.md`.
- Toolchain: Xcode 26+ (Swift 6.3+, strict concurrency). CI runs
  `.github/workflows/ci.yml` on `macos-26`.
- Checks (both must pass before merge):

  ```sh
  scripts/pr-preflight.sh origin/main
  xcodebuild test -project Leise.xcodeproj -scheme Leise \
    -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
    CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
  ```

- Releases: `docs/releasing.md` (`scripts/version.sh`,
  `scripts/publish-github-release.sh`, Homebrew cask in `zoltanf/homebrew-leise`).
- Upstream syncs: `.codex/skills/sync-typewhisper-upstream/SKILL.md`.

## Project file conventions

- New files in the `Leise` or `LeiseTests` targets must be registered in
  `Leise.xcodeproj/project.pbxproj` by hand (XML plist: a `PBXFileReference`,
  a `PBXBuildFile`, the group's `children`, and the target's
  `PBXSourcesBuildPhase`). `LeiseComponents` picks files up automatically.

## Pull Requests

When a pull request fixes or implements a GitHub issue, always:
- include the issue context in the PR body
- include an auto-close reference such as `Closes #123`
- include a short test plan with the exact verification command(s)

## Concurrency conventions

These invariants are load-bearing; violating them produces runtime isolation
traps in debug builds or SwiftUI corruption in release builds:

- `@Published` properties are mutated on the main thread only. Services whose
  work runs off-main (e.g. `AudioRecordingService` on its detached
  engine-start queue) route mutations through a main-hopping helper
  (`publishIsRecording(_:)`-style) and, when non-main readers exist, maintain a
  lock-protected mirror (`isRecordingNow`) instead of reading the published var.
- Prefer `@MainActor` over `@unchecked Sendable`. The remaining
  `@unchecked Sendable` classes (`AudioRecordingService`,
  `AudioRecorderService`, `StreamingHandler`) each document which lock guards
  which state; new mutable state in them must join an existing lock.
  `RecordingFinalizer.ChunkReader` is the one confinement exception: it is
  used only on its render thread (documented at its declaration).
- External callbacks with undocumented threads (C thunks, adapter completions)
  enter isolation explicitly: `MainActor.assumeIsolated` for main-run-loop
  callbacks (CGEventTap, Carbon), an explicit main-actor completion type for
  adapters (`MediaPlaybackControlling`).
- Never block a cooperative-pool thread (no `DispatchSemaphore.wait` /
  `Thread.sleep` in async contexts); bridge with continuations or run blocking
  sequences on a dedicated `DispatchQueue`.
- The dictation start/stop/cancel state machine is guarded by
  `isStartInFlight` / `isStopInFlight` / pending-during-start flags in
  `DictationViewModel`; changes there must extend
  `LeiseTests/DictationViewModelStateMachineTests`.

## Audio file conventions

- Never read or write a whole recording through one `AVAudioPCMBuffer`.
  Recordings can run for hours; process them in fixed-size chunks the way
  `RecordingFinalizer` does (flat memory, and a stalled encoder is detectable
  between chunks).
- Never delete a recording's source audio until the output is verified. On any
  finalization failure the recorder keeps the raw WAV tracks in the recordings
  folder; changes there must extend `LeiseTests/RecordingFinalizerTests`.
- On macOS 15+ call `AVAudioFile.close()` when done writing; on 14 the
  container trailer (m4a `moov` atom) is only written at deinit.

## Localization conventions

- All UI strings use `String(localized:)` (packages:
  `String(localized:bundle:.module)`) against a string catalog with de and ja
  maintained. Do not reintroduce ad-hoc translation helpers.
- `String(localized:)` resolution is effectively fixed for the process
  lifetime; UI that must follow an in-app language change before relaunch
  (`localizedAppLanguageName`) keeps its translations in code. Tests must not
  flip `preferredAppLanguage` mid-process and expect catalog strings to follow.
- Interpolated catalog keys use format specifiers (`%lld`, `%@`, `%%`);
  translations with reordered arguments use positional specifiers (`%1$lld`).

## Dependency conventions

- Swift package dependencies are pinned to exact revisions or versions —
  never a branch. Bump deliberately and run both test suites.
