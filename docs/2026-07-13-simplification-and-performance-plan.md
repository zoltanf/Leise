# Leise Simplification and Performance Plan

Status: active
Date: 2026-07-13
Scope: the Leise fork after the interface and core local-dictation workflow have stabilized

## Execution status

As of 2026-07-13:

- Phase 0 development-build identity and verification work is complete.
- Phase 1 performance baselining is next; no performance claim should be made until its measurements exist.
- Phase 2 removal is complete for every `remove` row in the retained-feature matrix. Obsolete settings, stores, migrations, targets, scripts, localization entries, and historical release promises were deleted rather than deferred.
- Phase 3 has removed external/community discovery and reduced runtime loading to the two fixed reviewed bundles. Compile-time construction and bundle-target removal remain.
- Phase 4 has removed unused provider implementations and broad host capabilities. Folding the remaining internal SDK boundary into direct app-owned interfaces remains.
- Phases 5–10 remain pending.

Detailed execution sequence for the remaining work: `docs/2026-07-13-remaining-simplification-and-performance-plan.md`.

## 1. Objective

Make Leise materially smaller, faster, and easier to maintain by aligning the implementation with the product that now exists: a focused macOS dictation application with Parakeet transcription and a small set of built-in processing features.

The work should improve four outcomes:

1. Faster launch and earlier hotkey readiness.
2. Lower idle memory and less main-thread work.
3. Faster clean and incremental builds.
4. Less code and fewer abstraction layers without changing the established interface or core dictation behavior.

This is not a single deletion pass. Each phase must establish a working checkpoint and be measured before proceeding. Leise is a green-field, local-only application at this stage, so removal work does not preserve or migrate existing settings or stores.

## 2. Product scope to confirm first

The approved retained-feature matrix is the source of truth for deletion work. Every product surface is decided as either `retain` or `remove`; there is no deferred product scope.

Expected retained scope:

- Parakeet v2 and v3 model selection, download, loading, transcription, streaming, and vocabulary boosting.
- Filler-word cleanup if it remains part of the shipped interface.
- Dictation hotkeys, text insertion, indicators, history, dictionary, profiles, recorder, recovery, and the settings pages currently exposed by Leise.
- Local HTTP/CLI, widgets, watch folders, workflows, translation, prompt actions, memory, spoken feedback, and Apple Intelligence are removal scope.

Approved removal:

- Apple Intelligence from the setup tutorial and provider pipeline.
- External/community plugin discovery, installation, update, compatibility, enable/disable, and marketplace behavior.
- Provider implementations, SDK protocols, settings, migrations, tests, assets, scripts, and documentation that only supported removed plugins.

Important: removing Apple Intelligence is a product-scope change, not a consequence of the Parakeet tutorial fix. It should be implemented and tested as its own small change.

Deliverable:

- `docs/leise-retained-feature-matrix.md`

Exit criteria:

- Every visible settings destination and background feature is marked `retain` or `remove`.
- Each `retain` item has an owner service or entry point.
- No affected feature remains undecided.

## 3. Phase 0 — Make development builds trustworthy

### Work

- Keep one canonical installed development app at `~/Applications/Leise.app`.
- Give ad-hoc development builds a stable designated requirement so Accessibility permission is not tied to a new code hash after every build.
- Add explicit build-and-run options to reset onboarding and Accessibility state; never reset either silently.
- Keep `DevBuildSource.txt` in the built app and display its timestamp/source in an About or diagnostics view.
- Ensure the script quits only the development Leise instance and launches the exact installed path.
- Add a script self-test that validates shell syntax, app identity, signature requirements, build marker, and embedded built-in bundles.

Commands:

```sh
bash -n build-and-run.sh scripts/build-dev-local.sh
./build-and-run.sh --help
codesign --verify --deep --strict --verbose=2 "$HOME/Applications/Leise.app"
codesign -d --requirements - "$HOME/Applications/Leise.app"
cat "$HOME/Applications/Leise.app/Contents/Resources/DevBuildSource.txt"
```

Manual clean-onboarding run:

```sh
./build-and-run.sh --reset-setup --reset-accessibility
```

Exit criteria:

- Two consecutive rebuilds produce the same textual designated requirement.
- Accessibility is granted once and remains valid after the second rebuild.
- `--reset-setup` opens step one of the current setup tutorial.
- A normal `./build-and-run.sh` does not reset preferences unless explicitly requested; removal phases may delete obsolete keys without migration.

## 4. Phase 1 — Establish performance baselines and budgets

Do not use perceived speed as the primary signal. Record at least five runs for each scenario and report median and p90.

### Scenarios

1. Cold launch after reboot or purgeable-cache normalization.
2. Warm launch.
3. Time from process start to menu-bar/settings UI responsiveness.
4. Time from process start to registered dictation hotkey.
5. First dictation with an already downloaded model.
6. Subsequent dictation.
7. Idle resident memory before loading Parakeet.
8. Resident and peak memory with Parakeet loaded.
9. Clean build and one-file incremental build.
10. App bundle size and built dependency size.

### Instrumentation

- Add `os_signpost` intervals around `LeiseApp.init`, `ServiceContainer.init`, `ServiceContainer.initialize`, plugin/built-in registration, database opening, hotkey registration, model restoration, first audio start, model preparation, transcription, and insertion.
- Add a development-only startup report that prints the same milestones once.
- Use Instruments App Launch, Time Profiler, Allocations, and System Trace.
- Capture main-thread stalls longer than 50 ms during launch and first dictation.
- Record Swift compiler build timing with `-showBuildTimingSummary`.

Suggested commands:

```sh
xcodebuild clean build \
  -project Leise.xcodeproj \
  -scheme Leise \
  -destination 'platform=macOS,arch=arm64' \
  -showBuildTimingSummary

/usr/bin/time -lp "$HOME/Applications/Leise.app/Contents/MacOS/Leise"
```

### Initial budgets

These are provisional until the baseline report exists:

- At least 30% lower warm-launch median.
- At least 25% lower pre-model idle resident memory.
- At least 25% faster clean build and 15% faster one-file incremental build.
- No launch main-thread interval longer than 100 ms without a documented platform constraint.
- No regression greater than 5% in first or subsequent dictation latency.

Deliverable:

- `docs/performance/baseline-YYYY-MM-DD.md`

Exit criteria:

- Raw measurements and machine/build metadata are recorded.
- Each later phase can reproduce the same benchmark procedure.

## 5. Phase 2 — Remove product features that are no longer in scope

Begin with complete vertical slices so no half-disabled feature remains.

### 2.1 Apple Intelligence

- Remove its setup tutorial card.
- Remove `FoundationModelsProvider` and the Apple Intelligence provider identifier.
- Remove provider selection, fallback, availability, temperature, migration, and UI branches.
- Delete persisted fallback keys that existed only for Apple Intelligence; no compatibility migration is required.
- Remove localization entries and tests that only cover Apple Intelligence.
- Verify prompt actions either have a retained execution provider or are themselves removed.

### 2.2 Other feature removals

For each removal—memory, generic LLM prompt actions, workflows, translation, TTS/spoken feedback, HTTP API/CLI, widgets, and watch folders—apply this checklist:

1. Confirm `retain` or `remove` in the feature matrix.
2. Find UI entry points, services, models, persistence keys, migrations, app entitlements, targets, assets, tests, scripts, and documentation.
3. Delete obsolete persistence keys and migrations directly. Local settings and stores may be wiped; do not add compatibility code.
4. Remove the complete slice.
5. Build and run the core acceptance suite.

Useful inventory commands:

```sh
rg -n 'Apple Intelligence|appleIntelligence|FoundationModels' Leise LeiseTests
rg -n 'MemoryService|WorkflowService|TranslationService|SpeechFeedbackService' Leise LeiseTests
rg -n 'HTTPServer|APIServer|leise-cli|Widget' Leise LeiseTests Leise.xcodeproj
```

Exit criteria:

- Removed features have no UI, runtime initialization, build target, entitlement, persisted-selection default, or documentation path left behind.
- Removed settings and stores are no longer read.
- Core dictation acceptance tests pass.

## 6. Phase 3 — Replace runtime plugin discovery with direct built-in composition

The current application loads only two reviewed bundles, but still scans directories, reads manifests, checks compatibility, loads bundles dynamically, and exposes lifecycle machinery designed for external plugins.

### Work

- Introduce narrow app-owned interfaces such as `TranscriptionEngine`, `PostProcessor`, and `ModelDownloadState` based only on actual Leise call sites.
- Register `ParakeetEngine` and `FillerWordCleanup` directly in a `BuiltInComponents` composition root.
- Replace `PluginManager.loadedPlugins` queries with typed dependencies or a small fixed registry.
- Replace manifest IDs and principal-class lookup with compile-time construction.
- Move built-in settings views into app-owned settings destinations.
- Keep only the current Parakeet model IDs and settings keys needed by the retained UI; no legacy-key migration is required.
- Once consumers are migrated, remove bundle scanning, manifest decoding, `NSClassFromString`, dynamic bundle load/unload, disabled placeholders, compatibility checks, external bundle notices, plugin directories, and model deletion routing through plugin IDs.
- Remove the Parakeet and filler-word bundle targets if static linking does not create unacceptable startup or memory behavior. Measure both layouts before choosing.

Suggested implementation order:

1. Add the narrow interfaces and adapters around the existing built-ins.
2. Migrate `ModelManagerService`.
3. Migrate dictation, recorder, recovery, and file transcription.
4. Migrate settings and setup tutorial.
5. Migrate post-processing.
6. Delete `PluginManager` runtime loading.
7. Remove bundle targets/manifests after parity verification.

Exit criteria:

- No runtime filesystem plugin scan occurs at launch.
- No dynamic principal-class lookup is required.
- Parakeet model selection/download and filler cleanup retain behavior.
- Startup and build metrics are re-recorded.

## 7. Phase 4 — Collapse or eliminate the plugin SDK

The SDK currently contains many capability combinations and host APIs inherited from a broad extension platform. After direct built-in registration, inventory SDK symbols against real call sites.

### Work

- Generate a used-symbol report for `LeisePluginSDK` from Leise, Parakeet, filler cleanup, and tests.
- Move genuinely shared audio/model value types into a small internal module only if a module boundary still provides build or test value.
- Replace combinatorial transcription protocols with one engine interface and option/configuration types.
- Remove LLM, TTS, memory, action, file-job, downloaded-model, external settings-window, workflow, event-bus, compatibility, diagnostics, and host-service APIs when their retained-feature consumers reach zero.
- Replace generic host user-default and event calls with explicit app-owned stores/callbacks.
- Delete SDK tests that test removed public compatibility contracts; retain behavioral tests around Parakeet and post-processing.
- Remove unused Swift package dependencies and lockfile entries.

Decision point:

- If only Leise consumes the remaining types, fold them into the app or a small internal `LeiseCore` target.
- Keep a separate module only if it measurably improves incremental builds, isolation, or reusable tests.

Exit criteria:

- Every remaining public protocol has at least one production consumer and a stated reason to be public.
- The SDK package is removed or reduced to the agreed internal core.
- Clean build time, dependency resolution time, and source line count are recorded.

## 8. Phase 5 — Make startup composition lazy and staged

`ServiceContainer` currently constructs the complete service and view-model graph on the main actor before normal initialization. Replace this with a small launch-critical graph and lazily initialized retained-feature scopes.

### Launch-critical scope

- Hotkey service.
- Minimal dictation coordinator.
- Audio input guard/recording path.
- Selected transcription engine metadata and lightweight state.
- Text insertion.
- Minimal settings/home state needed for the first visible UI.

### Lazily initialized retained scopes

- History and statistics views.
- Profiles and dictionary editors.
- File transcription and recorder UI.
- Diagnostics and export services.
- Model settings UI and other feature-specific view models.

### Work

- Split `ServiceContainer` into a composition root plus lazy feature scopes.
- Remove global `_shared` assignments where constructor injection or SwiftUI environment injection is sufficient.
- Construct feature view models when their destination first appears.
- Keep hotkey registration early, but avoid opening databases and constructing settings-only graphs before it completes.
- Add tests that assert disabled features are not initialized during launch.

Exit criteria:

- The launch-critical dependency graph is documented and small enough to review visually.
- Opening each lazy retained feature initializes it once and does not block unrelated UI.
- Startup milestones show hotkey readiness and visible UI earlier than baseline.

## 9. Phase 6 — Move noncritical work off the launch path

### Work

- Run usage-statistics backfill only when its completion marker says it is needed, on a utility task with batched persistence.
- Move history retention cleanup after UI/hotkey readiness and perform it in bounded batches.
- Avoid fetching full history merely to determine whether backfill is necessary.
- Start memory listeners only if memory remains in scope and is enabled.
- Resolve watch-folder bookmarks and start watching only when configured.
- Start the HTTP server only when enabled; construct its router/handlers lazily.
- Restore downloaded models without blocking the main actor and without triggering downloads automatically.
- Cache immutable punctuation/term-pack resources after first use rather than eagerly parsing them.
- Audit all `init`, singleton, `.task`, publisher subscription, and notification registration work for accidental eager execution.

Concurrency requirements:

- Keep AppKit, SwiftUI state, and model selection mutations on `MainActor`.
- Keep file I/O, database maintenance, model discovery, and parsing off the main actor.
- Make cancellation explicit when a feature scope or setup flow closes.

Exit criteria:

- Instruments shows no avoidable database scan, resource parse, or model filesystem scan on the main thread during launch.
- Deferred maintenance completes reliably and has error logging.
- Shutdown does not leave duplicate watchers, servers, or tasks.

## 10. Phase 7 — Optimize dictation and model hot paths

Only begin micro-optimization after architectural overhead is removed and measured.

### Work

- Profile audio capture, buffer conversion, streaming callbacks, transcription, normalization, post-processing, history persistence, and insertion separately.
- Remove duplicate audio copies and format conversions.
- Reuse stable audio/model resources where safe.
- Avoid repeated capability scans and provider-array filtering during every dictation.
- Convert fixed provider/model lookup to direct references or dictionaries.
- Batch UI publications and reduce high-frequency `@Published` invalidations.
- Review Parakeet vocabulary asset checks and model existence checks for repeated filesystem access.
- Ensure history/statistics persistence happens after insertion unless durability requirements demand otherwise.
- Add signposted latency tests for short, medium, and long utterances.

Exit criteria:

- No regression in transcript correctness or insertion reliability.
- First and subsequent dictation latency meet the budgets set from Phase 1.
- Peak memory does not increase without a documented speed tradeoff.

## 11. Phase 8 — Dead-code, project, and repository cleanup

Run this only after runtime consumers are gone.

### Work

- Remove unused source files, targets, schemes, package products, assets, localization keys, entitlements, scripts, docs, tests, fixtures, and release tooling.
- Remove obsolete `TypeWhisper` compatibility names and migration code directly; there is no supported upgrade path yet.
- Use compiler warnings, Xcode target membership, symbol/reference searches, and linker dead-strip maps to find candidates.
- Add a repository check that rejects references to removed provider/plugin identifiers.
- Update README, architecture notes, support matrix, build scripts, release checklist, and diagnostics output.
- Clean ignored local build caches separately; do not confuse cache size with shipped app/runtime overhead.

Exit criteria:

- A clean clone resolves, builds, tests, and packages with no removed target references.
- No stale settings route or migration selects a removed provider.
- Release and development build scripts embed only retained components.

## 12. Verification matrix for every phase

Automated minimum:

```sh
xcodebuild test \
  -project Leise.xcodeproj \
  -scheme Leise \
  -destination 'platform=macOS,arch=arm64'

xcodebuild clean build \
  -project Leise.xcodeproj \
  -scheme Leise \
  -destination 'platform=macOS,arch=arm64'
```

Manual core acceptance:

1. Clean onboarding and permissions.
2. Select, download, load, unload, and reload both Parakeet models.
3. Dictate with push-to-talk, toggle, and hybrid hotkeys.
4. Insert into at least one native app and one browser/electron app.
5. Exercise failure states: no microphone permission, no Accessibility permission, offline model download, cancelled/failed model load, and unavailable model.
6. Verify history, dictionary hints, filler cleanup, recorder, recovery, and every retained background feature.
7. Rebuild and confirm permissions and fresh settings behave as designed.

Performance gate:

- Attach before/after median, p90, memory, app size, and build-time results to each phase PR.
- Reject an optimization that adds significant complexity without a measurable improvement.

## 13. Delivery strategy

Use small, reversible changes rather than one repository-wide rewrite:

1. Development build reliability.
2. Measurement instrumentation and baseline.
3. Apple Intelligence removal.
4. One PR per other removed vertical feature.
5. Built-in engine adapters and typed composition.
6. Consumer rewiring by retained feature.
7. Dynamic plugin-loader removal.
8. SDK collapse.
9. Lazy service graph.
10. Deferred maintenance.
11. Hot-path optimizations.
12. Final repository cleanup and new baseline.

Each PR should state:

- Feature and code removed or moved.
- Any settings or stores intentionally reset by the change.
- Exact test commands.
- Before/after measurements when performance is affected.
- Rollback boundary.

## 14. Principal risks

- Removing an abstraction before all hidden consumers are found.
- Leaving stale persisted provider/model selections in active code paths.
- Moving state off the main actor incorrectly.
- Delaying initialization so far that the first hotkey press races setup.
- Treating fewer source lines as proof of faster runtime.
- Statically linking model code that increases launch work even though plugin scanning disappears.
- Losing test coverage while deleting SDK contract tests.

Mitigation: use short-lived adapters only while rewiring retained consumers, gate each phase with core acceptance tests and measurements, and delete compatibility layers as soon as production consumers reach zero.

## 15. Definition of done

The program is complete when:

- The retained-feature matrix matches the visible product.
- Apple Intelligence and every other removed feature have no runtime/build/UI remnants.
- Leise uses direct typed composition for its fixed built-ins.
- External plugin loading and unused SDK surfaces are gone.
- Startup creates only launch-critical services.
- Noncritical maintenance is deferred and cancellable.
- Performance budgets are met on repeatable measurements.
- A clean clone builds and passes the complete retained-feature acceptance suite.
- Architecture and developer documentation describe the simplified system that actually ships.
