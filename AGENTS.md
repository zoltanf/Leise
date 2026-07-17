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

## Localization conventions

- All UI strings use `String(localized:)` (packages:
  `String(localized:bundle:.module)`) against a string catalog with de and ja
  maintained. Do not reintroduce ad-hoc translation helpers.
- `String(localized:)` resolution is effectively fixed for the process
  lifetime; UI that must follow an in-app language change before relaunch
  (`localizedAppLanguageName`) keeps its translations in code.
- Interpolated catalog keys use format specifiers (`%lld`, `%@`, `%%`);
  translations with reordered arguments use positional specifiers (`%1$lld`).

## Dependency conventions

- Swift package dependencies are pinned to exact revisions or versions —
  never a branch. Bump deliberately and run both test suites.
