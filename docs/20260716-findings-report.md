# Leise fork review — findings report

Date: 2026-07-16
Scope: full review of all changes since the TypeWhisper fork point (`4208303`), 14 commits, 675 files (+31.7k/−146.8k), ~44k lines of current Swift.
Method: six parallel area reviews (services, app core/view models, views, LeiseComponents package, tests, build/release + fork hygiene) plus one independent GPT‑5.5 pass over the end-to-end dictation path. All findings verified against actual code.

## TL;DR

The fork is in good shape: removal work matched the approved retained-feature matrix exactly (no kept feature lost test coverage), the `ServiceContainer` composition root and the `LeiseComponents` package boundary are clean, release scripts are disciplined, and licensing/provenance are consistent. Package tests pass (46 cases, 0 failures).

The review found **1 crash bug, 1 silent dictation-loss bug, and 2 pieces of dead/broken UI** on the primary user path, plus three fork-independence risks: **zero CI**, a **live runtime dependency on upstream's domain**, and a **dependency pinned to a moving branch**.

---

## Critical findings

- **C1. Crash on the main text-insertion path** — `Leise/Services/TextInsertionService.swift:299-305` (also :533, :556). `getFocusedTextElement()` does `focusedElement as! AXUIElement` after checking only the AX return code. `kAXFocusedUIElementAttribute` can return `.success` with a nil value (no focused element, transient focus loss); the force-cast traps. `getTextSelection()` (:279-283) has the correct nil + `CFGetTypeID` guard.
- **C2. Silent, unrecoverable dictation loss at the insertion boundary** — `TextInsertionService.swift:462` + `DictationViewModel.swift:1217`. Unverified paste (e.g. no focused text element → Cmd+V no-ops → `.focusedTextStateUnavailable`) is treated as success; with clipboard preservation the old clipboard is restored, and recovery audio is discarded. Text is in neither the target app nor the clipboard.
- **C3. Recordings silently lost as never-written files** — `Leise/Services/AudioRecorderService.swift:1206-1252, 1470-1490`. `mixAudioFiles`/`copyOrConvert` are `throws` but plain-`return` on allocation/format failures or `totalFrames == 0`; `stopRecording` (:776-791) reports success, deletes temps, returns a URL to a nonexistent file.
- **C4. Profiles settings screen unreachable** — `Leise/Views/SettingsView.swift:65,158`. `.profiles` has a destination and detail view but appears in no `SettingsSidebarLayout` array; nothing sets `selectedTab = .profiles`. The entire profiles editor has no entry point.
- **C5. Corrupt profiles store makes the app unlaunchable** — `Leise/Services/ProfileService.swift:56-58`. Store-creation failure calls `fatalError` at launch; `DictionaryService` handles the identical failure gracefully.

## Major findings

### Correctness / UX
- **M1. `StreamingHandler.finish()` always returns nil** — `Leise/ViewModels/StreamingHandler.swift:151-162`. The `liveSessionResult` reuse paths in `DictationViewModel.finalizeStopDictation` (:1023-1031, :1087-1124) and `AudioRecorderViewModel.runFinalTranscription` (:672-684) are dead; every stop re-transcribes the full buffer. Incomplete refactor — restore or excise.
- **M2. Recorder double-stop race** — `Leise/ViewModels/AudioRecorderViewModel.swift:465-503`. `state` stays `.recording` across two awaits with no re-entrancy guard; second toggle ~150–300ms later double-stops/finalizes. `DictationViewModel` solves this with `isStopInFlight` (:972-982).
- **M3. Orphaned SwiftUI state** — `Leise/Views/GeneralSettingsView.swift:19` renders `RecordingSettingsView().settingsSections` without installing the view: its `@State` has no identity, `.onAppear` never runs, disk re-read every render, drag-reorder glitches.
- **M4. "html" auto-format pastes literal tags** — `Leise/Services/AppFormatterService.swift:79-102,172-210` + `ClipboardContentFormatter.swift:52-70`. Mail/Outlook/Gmail map to `"html"` markup but the clipboard layer only supports rtf/richtext and doesn't route html through pasteboard insertion → raw `<ul><li>…` as plain text.
- **M5. Japanese localization structurally broken** — `Leise/App/AppConstants.swift:30-35`. App ships 日本語 but ~178 `localizedAppText(en/de)` view call sites fall back to English for `ja`, mixed with catalog-localized strings.

### Performance
- **M6. Global mouse monitor does window-list + AX queries on every OS click** — `Leise/Services/IndicatorCoordinator.swift:199-207,216-229`; monitor also never removed (:120-230, no deinit/teardown).
- **M7. `startRecording` blocks main thread with sleeps** — `Leise/Services/AudioRecordingService.swift:701,739-829`: up to 1.0s×2 format settling, 1.5s BT route stabilization (:883-889), 1.0s input readiness (:1401-1424) → multi-second UI freezes.
- **M8. Unbounded O(m×n) word diff** — `Leise/Services/TextDiffService.swift:25-56`; ~5k-word dictation → ~25M-entry LCS matrix.
- **M9. Memory growth on long dictations** — `AudioRecordingService.swift:1142` + `StreamingHandler.swift:204`: full-session samples in up to three arrays simultaneously.
- **M10. Slow stop/cancel** — stop awaits cancelled precompute before final decode (`StreamingHandler.swift:151` + `ParakeetEngine.swift:614`); `ParakeetEngine.swift:1345` checks `isCancelled` once before the serialized gate — Esc during processing holds the gate until ASR/rescoring returns.

### Fork independence / infrastructure
- **M11. Live runtime dependency on upstream infra** — `Leise/Services/TermPackRegistryService.swift:62`: default registry is `typewhisper.github.io/typewhisper-termpacks/termpacks.json`, a domain the fork doesn't control. Also :91 no HTTP status check / size cap.
- **M12. Zero CI** — `.github/workflows/` doesn't exist; guards (`pr-preflight.sh`, `check_static_components.sh`, test suites) never run automatically; CODEOWNERS toothless.
- **M13. Broken, self-contradictory sync guard** — `.codex/skills/sync-typewhisper-upstream/audit_sync.sh:40` greps deleted `PluginManager.swift` → always exits 1; contradicts `check_static_components.sh:13`, which forbids `PluginManager` references. Also :27 fragile rg error handling.
- **M14. FluidAudio pinned to `branch: "main"`** — `LeiseComponents/Package.swift:15`; any resolve can advance the deepest dependency to untested upstream code.
- **M15. Flaky timing test** — `LeiseTests/AudioEngineRecoverySupportTests.swift:91-96`: real 5ms/45ms sleeps asserting a ~40ms throttle boundary; sibling tests correctly inject `sleep:`.

## Minor findings (grouped)

### Silent-failure / error-handling inconsistency
- `try?` file writes: `HistoryExporter.swift:166,199`, `DictionaryExporter.swift:62` (SubtitleExporter logs properly).
- `HistoryExporter.swift:92-144,184-186`: per-record `"{}"` fallback inside exported JSON arrays → silent per-record data loss.
- SwiftData save failures don't roll back context: `ProfileService.swift:252-258`, `DictionaryService.swift:177-219` (only `setEntryEnabled` rolls back); a failed delete can be committed later by an unrelated save.
- `ProfileService.swift:241-250`: fetch error silently publishes `[]` (rule matching silently disabled).
- `DictionaryService.swift:54-65`: `try?` store setup; nil context → all mutations silently no-op.
- `TermPackRegistryService.swift:136-146`: no guard against overlapping background fetches; :150-161 `compareVersions` drops non-numeric components.

### Concurrency (implicit invariants)
- `HotkeyService.swift:138`: `@unchecked Sendable` relying on main-run-loop confinement (currently race-free; should be `@MainActor`). Also :315-317 deinit teardown calls main-thread-only APIs.
- `ParakeetEngine.swift:104`: redundant `@unchecked Sendable` on `@MainActor`-inferred class silences diagnostics.
- `AudioRecorderService.swift:471-499,694-703,799`: unlocked mutable fields touched from async start/stop; `startTime` read by main-run-loop Timer while nil'ed off-thread.
- `PunctuationRulesLoader.swift:3-29`: unsynchronized cache shared between `@MainActor` and non-isolated consumers.
- `MediaPlaybackService.swift:148-227`: `@MainActor` state mutated inside plain adapter callbacks (adapter thread unverified).
- `AudioRecordingService.swift:126,589`: `isRecording` read racily on recovery queue.
- `AudioDeviceService.swift:456-460`: deinit → `stopPreview` mutates `@Published` possibly off-main; :3001-3034 activation-guard TOCTOU.
- `PostProcessingPipeline.swift:61`: unstable sort on priority — equal priorities → nondeterministic order.
- `TextInsertionService.swift:180-208`: AppleScript blocks a cooperative-pool thread via `semaphore.wait` up to 2.5s.

### Dictation-path details
- `TextInsertionService.swift:331`: AX verification checks only value change → identical replacement text classified as failure → fallback paste can duplicate.
- `AudioRecorderService.swift:541-620,1616-1651`: `transcriptionBufferLock` held during O(n) mixing, contended from SCStream + mic-tap threads.
- `AudioDeviceService.swift:2626-2644`: HAL render callback allocates buffers + sync convert on the render thread (real-time-safety violation).
- `AudioFileService.swift:110-113`: `baseAddress!` traps on zero-length buffer.
- `AudioDuckingService.swift:260-271`: restore applies saved volume of the old device to a new default output.

### LeiseComponents package
- `TranscriptionContracts.swift:4-12`: `TranscriptionAudio` hardcodes 16 kHz (no `sampleRate` field, no conversion at boundary).
- `TranscriptionContracts.swift:126-162` + `ParakeetEngine.swift:1345`: `isCancelled` contract effectively decorative for in-flight work (Task-cancellation only).
- `ParakeetEngine.swift:314-317,390-404`: progress callbacks' `Bool` return only breaks the reporting loop, doesn't cancel ASR.
- `ParakeetEngine.swift:573-639`: CTC spotter calls not serialized by the transcription gate (safe only under the app's cancel-and-await usage).
- `ParakeetEngine.swift:1216-1221`: global `ModelRegistry.baseURL` mutated, never restored.
- `FillerWordCleanup.swift:66`: boundary punctuation eaten → sentences merge; :147,264-274 default-locale lowercasing (Turkish-I), CJK terms routed to Japanese path; :155-178 leading newline lost; settings view unlocalized (bare English `Text`).

### UI / polish
- `HomeSettingsView.swift:549-554`: every recent-transcription row navigates identically (unfiltered History), ignoring the tapped record.
- `Overlay/Minimal/NotchIndicatorPanel`: ~90% duplicated; Notch has task-based animation handling the others lack.
- `SettingsView.swift:5,122-126,144-145`: vestigial `.recording` tab; :75 no-op `compactMap`; :223 fragile force-unwrap.
- `MenuBarView.swift:283`: singleton mutation inside `body`.
- `main.swift:13-39`: `OverrideBundle` re-resolves `.lproj` bundles on every localized lookup, no caching.
- `SettingsNavigationCoordinator.swift:11`: `nonisolated(unsafe) static var shared: ...!` IUO.
- `AudioRecorderViewModel.swift:523`, `DictationViewModel.swift:1587-1591`: service-locator escapes bypass injected dependencies. `DictationViewModel.swift:1093`: `transcriptionTask` strong-captures self (siblings weak).
- Pending WIP wizard change (`SetupWizardView.swift:913-928`): coherent overall, but bundled path hardcodes exactly two model cards instead of iterating `engine.models`.
- `SpeechPunctuationService.swift:29-61`: regexes recompiled per rule per call; :89 whole-string trim once any rule fires loses intended edge whitespace.

### Hygiene
- `.github/ISSUE_TEMPLATE/*.yml` still say "TypeWhisper" (user-facing).
- `Leise/Resources/Leise.entitlements:5-8` sandbox-style entitlements while `ENABLE_APP_SANDBOX = NO` (inert/misleading).
- `scripts/build-release-local.sh:78-84,99`: `remove_tree` lacks the repo-containment guard `reset-build-caches.sh:62-72` has; :142 `codesign --deep` deprecated.
- Committed `.DS_Store` in `LeiseTests/` and `LeiseComponents/Tests/`.
- `LeiseTests/DictionaryServiceTests.swift:6-16`: mutates global `UserDefaults.standard` without save/restore (wipes developer settings).
- `LeiseTests/StreamingHandlerTests.swift:335-357`: fixed 200ms sleeps asserting absence-of-event; five tests use bounded 20× `Task.yield` polling with silent timeout.
- Stale `LeiseComponents/.build` cache from a previous checkout path breaks `swift test` ("XCFramework Info.plist not found") — `rm -rf LeiseComponents/.build` fixes it.

## Verified strengths

- Removal work complete and honest: all 22 deleted upstream test files map to removed features; kept features retained/rewrote coverage; no stale commercial headers; LICENSE/FORK/TRADEMARK consistent; plugin remnants actively guarded against.
- `ServiceContainer` composition root: no retain cycles, race-free `MemoizedFeature`, weak Combine wiring. `DictationViewModel` state machine meticulous (session IDs, stop-in-flight, cooperative cancellation).
- `AsyncTranscriptionGate`, model-load generation guards, vocabulary-asset TOCTOU handling, CTC chunk math, token→segment grouping, and the `CoreAudioHALCallbackContext.c` teardown state machine all verified correct.
- Release scripts: strict bash hygiene, no secrets committed (team ID in gitignored `CodeSigning.local.xcconfig`), SHA-256-pinned offline model bundles, deep artifact verification, dry-run support. `OfflineModelPrep` load-verifies payloads.
- Tests behavior-driven with strong isolation; package suite 46/46 passing. Deployment target consistent (14.0). `HotkeyService` Carbon/event-tap layering and dedup verified correct.

## Architecture assessment

The big bets — compile-time components over a plugin runtime, one explicit composition root, engine work behind `TranscriptionEngine` in a separate package — are right and match `docs/architecture.md`. Four recurring systemic weaknesses:

1. **Invariants held by convention, not the compiler** — `@unchecked Sendable` + main-thread confinement, the 16 kHz assumption, Task-only cancellation, ungated CTC.
2. **Inconsistent failure-handling philosophy** — `fatalError` vs silent `try?`/plain-`return` vs proper propagation, sometimes in sibling files. C2/C3/C5 are all instances.
3. **Hand-maintained parallel structures drift** — sidebar arrays vs `SettingsTab` enum (stranded Profiles), three indicator panels, two localization mechanisms, two contradictory repo guards.
4. **DI leaks at the edges** — `ServiceContainer.shared` call-site escapes; engine-capability logic (`SetupWizardRecommendationAvailability`, model selection) living in a 1,600-line view file instead of beside the engine contract.

Biggest test hole: `DictationViewModel` (1,954 LOC) has essentially no tests of its state transitions — exactly where M1/M2/C2 live.

---

## Remediation plan

### Phase 0 — Stop the bleeding (before next release)
1. Fix the three AX force-casts with the guard pattern from `getTextSelection` (C1).
2. Treat unverified paste as failure: keep dictated text on the clipboard, keep recovery audio, surface recovery UI (C2). Fix the identical-text false-negative at `TextInsertionService.swift:331`.
3. Make `mixAudioFiles`/`copyOrConvert` throw on every early-out (C3).
4. Replace `ProfileService`'s `fatalError` with the `DictionaryService` graceful-nil pattern (C5).
5. Add `.profiles` to the sidebar layout (C4).
6. Add an `isStopInFlight` guard to `AudioRecorderViewModel` (M2).
7. Fix the orphaned-state embedding in `GeneralSettingsView` (M3).
8. Fix "html" formatting to write an HTML pasteboard representation, or map Mail/Outlook to `rtf` until it works (M4).
9. Before committing the WIP: make the bundled-model cards iterate `engine.models`.

### Phase 1 — Own your fork (infrastructure)
1. GitHub Actions workflow: build + `swift test` + app tests + `check_static_components.sh` + `pr-preflight.sh` on PRs.
2. Pin FluidAudio to an exact revision or release (M14).
3. Re-home the term-pack registry to a Leise-controlled URL (or vendor a snapshot as default); add HTTP status check + size cap (M11).
4. Fix or delete `audit_sync.sh` so the two repo guards agree (M13).
5. Rename "TypeWhisper" in issue templates; untrack `.DS_Store`s; align entitlements with the sandbox setting.
6. Deflake `AudioEngineRecoverySupportTests` (injected sleep); add save/restore to `DictionaryServiceTests`.

### Phase 2 — Dictation-path hardening
1. Resolve `StreamingHandler.finish()` (M1): restore live-result reuse (also the biggest stop-latency win) or excise dead branches.
2. Cancellation responsiveness (M10): check cancellation around gate acquisition; don't await stale precompute before the final decode.
3. Gate the `IndicatorCoordinator` global mouse monitor on visible/recording state; add teardown (M6).
4. Move `startRecording` settle/stabilization waits off the main thread (M7).
5. Cap `computeWordDiff` input or switch to `CollectionDifference` (M8); bound duplicate audio buffers (M9).
6. One failure-handling policy: SwiftData saves roll back on failure, exporters propagate write errors, `DictionaryService` surfaces a dead store.

### Phase 3 — Structural debt
1. Compiler-enforced concurrency: `@MainActor` on `HotkeyService`, drop redundant `@unchecked Sendable`s, lock/isolate `PunctuationRulesLoader`, add `sampleRate` to `TranscriptionAudio` (or converter at the boundary).
2. Single source of truth for settings navigation; remove `.recording` vestige.
3. Unify localization on `String(localized:)` + catalog; delete `localizedAppText` (path to shipping Japanese, M5).
4. Consolidate the three indicator panels.
5. Move `SetupWizardRecommendationAvailability` + model-selection resolvers into `LeiseComponents`; remove `ServiceContainer.shared` call-site escapes.
6. Add `DictationViewModel` state-machine tests — highest-value test investment; safety net for Phase 2 items 1–2.
