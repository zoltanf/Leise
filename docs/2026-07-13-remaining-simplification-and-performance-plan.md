# Leise Remaining Simplification and Performance Plan

Status: implementation complete; documented performance exceptions and manual release smoke gate

Date: 2026-07-13

Prerequisite: all product rows marked `remove` in the retained-feature matrix are removed

## Execution progress

Milestone A is complete. The Debug app emits stable signposts; deterministic
short, medium, and long fixtures and repeatable collectors cover environment,
build, size, launch, local transcription, and memory measurements. The accepted
seven-run baseline, compact raw data, methodology, and concrete budgets are in
`docs/performance/baseline-2026-07-13.md`.

Milestones B–I are complete. Leise now constructs `ParakeetEngine` and
`FillerWordCleanup` directly through the minimal `LeiseCore` boundary in
`LeiseComponents`; runtime bundles, manifests, lifecycle protocols,
`PluginManager`, SDK testing products, and view-model `_shared` storage are
removed. Hotkeys are ready before retained maintenance, retained editor graphs
are memoized, and maintenance is cancellable and bounded. The final comparison,
raw evidence, passed checks, and explicit startup/memory/build exceptions are in
`docs/performance/final-2026-07-13.md`. The shipping dependency graph is in
`docs/architecture.md`.

## 1. Outcome

Finish the simplification program by replacing the two fixed runtime bundles with compile-time composition, reducing or eliminating the internal plugin SDK, staging startup around hotkey readiness, and optimizing only the bottlenecks demonstrated by measurements.

The completed architecture should have these properties:

- `ParakeetEngine` and `FillerWordCleanup` are constructed directly by Leise.
- No manifest, bundle scan, `Bundle.load`, `NSClassFromString`, or plugin lifecycle is required.
- App consumers depend on narrow typed interfaces, not `PluginManager.shared`.
- The remaining shared module contains only types used by production code.
- Launch constructs only the dictation-critical graph.
- Retained editors, maintenance work, and exports initialize on demand.
- Launch, memory, build, and dictation improvements are demonstrated by repeatable results.

This work does not include UI redesign, new engines, new product features, compatibility migrations, or support for external extensions.

## 2. Final checkpoint

The app has one fixed transcription engine and one fixed cleanup processor,
both linked from `LeiseComponents`. `ServiceContainer` is the documented
process composition owner; retained feature view models initialize once on
demand. First-hotkey actions are queued until dictation callbacks are attached.
Statistics backfill and history retention run after hotkey readiness in an
owned maintenance task. Structural checks prevent the deleted dynamic
architecture from returning. See `docs/architecture.md` and the final
performance report for the accepted tradeoffs.

## 3. Execution rules

1. Capture the baseline before changing composition or startup.
2. Keep every change buildable and testable; do not combine loader deletion, SDK deletion, and startup rewiring in one patch.
3. Introduce a replacement at the same time as its first consumer, then delete the old path as soon as its last consumer moves.
4. Do not maintain compatibility for old settings, manifests, bundles, or stores.
5. Keep AppKit and observable UI state on `MainActor`; keep file I/O, model discovery, resource parsing, and maintenance work off it.
6. Require evidence for performance changes. Source-line reduction alone is not a performance result.
7. Preserve current Parakeet v2/v3 behavior, vocabulary boosting, streaming, fallback behavior, model controls, and filler cleanup.

## 4. Milestone A — Measurement harness and baseline

### A1. Add signposts

Create a small development-only `PerformanceMilestones` wrapper using `OSSignposter`. Instrument:

- process/app initialization;
- `ServiceContainer` construction and asynchronous initialization;
- hotkey setup and initial registration complete;
- first settings/menu UI ready;
- built-in component construction;
- retained database/store opening;
- model selection restoration;
- audio start;
- model preparation/load;
- streaming session creation;
- final transcription;
- normalization and filler cleanup;
- history/statistics persistence;
- text insertion complete.

Use stable signpost names so results remain comparable after classes are renamed or deleted. Signposting must compile out or become negligible in release builds.

### A2. Create repeatable measurement scripts

Add scripts under `scripts/performance/` that:

- record commit, dirty-state flag, macOS version, Xcode version, architecture, CPU, and memory;
- build into a dedicated DerivedData directory;
- run clean builds with `-showBuildTimingSummary`;
- force a one-file incremental compile through a documented harmless source touch and restore step;
- capture app and executable sizes;
- collect warm-launch signposts;
- record resident and peak memory before and after model load;
- write raw results as CSV or JSON without interpreting them.

Cold launch should be measured only under a documented repeatable cache condition. Do not claim a cold-launch improvement from uncontrolled runs.

### A3. Capture the baseline

Record at least seven runs for noisy launch and latency scenarios; report median and p90. Capture:

| Metric | Required state |
| --- | --- |
| Warm process start to UI ready | No model loaded |
| Warm process start to hotkey ready | No model loaded |
| Idle resident memory | UI settled, no model loaded |
| First dictation latency | Model downloaded but unloaded |
| Subsequent dictation latency | Model already loaded |
| Short/medium/long transcription stages | Fixed local audio fixtures |
| Clean build time | Dedicated DerivedData path |
| One-file incremental build time | Same machine and configuration |
| App, executable, and embedded component size | Debug and Release |

Write `docs/performance/baseline-2026-07-13.md` with raw-data links, methodology, medians, p90 values, and known sources of variance.

### A exit criteria

- The harness can be rerun without hand-editing code.
- Signposts identify hotkey readiness separately from full initialization.
- Baseline raw data and summary are committed.
- Existing provisional budgets are accepted or adjusted before optimization work.

## 5. Milestone B — Define the internal typed boundary

### B1. Inventory real production needs

Generate a symbol/call-site inventory for `LeisePluginSDK`, grouped into:

- audio and transcription values;
- model metadata and model lifecycle;
- language selection and dictionary hints;
- streaming/live-session behavior;
- progress reporting and cancellation;
- post-processing;
- settings/state callbacks;
- test-only support.

Every retained symbol must name at least one production consumer. Test-only protocol combinations are not sufficient justification.

### B2. Introduce narrow interfaces

Define app-owned contracts with explicit names and option structs. The intended shape is:

```swift
protocol TranscriptionEngine: AnyObject {
    var id: TranscriptionEngineID { get }
    var displayName: String { get }
    var models: [TranscriptionModel] { get }
    var selectedModelID: String? { get }
    var capabilities: TranscriptionCapabilities { get }

    func selectModel(id: String)
    func prepareModel(id: String?) async throws
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
    func makeLiveSession(_ request: LiveTranscriptionRequest) async throws -> (any LiveTranscriptionSession)?
    func unloadModel()
}

protocol TextPostProcessor: AnyObject {
    var id: String { get }
    var priority: Int { get }
    func process(_ text: String, context: PostProcessingContext) async throws -> String
}
```

Prefer one request type with optional progress, source-progress, language hints, dictionary hints, and cancellation over combinations of capability protocols. Capabilities describe availability; they must not require consumers to cast through many protocol variants.

### B3. Choose the module boundary

Start with a small internal module so Leise, Parakeet, and filler cleanup can share contracts without circular imports. Working name: `LeiseCore`.

Only place implementation-neutral values and protocols there. Do not move app services, SwiftUI views, defaults access, bundle loading, or plugin lifecycle into it.

Decision gate after build measurements:

- Keep `LeiseCore` if it provides useful compile isolation or test reuse.
- Fold it into the app if the module adds complexity without measurable build benefit.

### B4. Add adapters first

Wrap the existing Parakeet and filler implementations behind the new interfaces while the old loader still exists. This gives consumers a stable migration target without changing behavior and provides an easy rollback boundary.

### B exit criteria

- New contracts cover every retained production behavior.
- No removed feature appears in the contracts.
- Adapters pass Parakeet, streaming, dictionary-hint, recorder, recovery, file-transcription, and filler-cleanup tests.
- The old protocols remain only as an implementation bridge, not in new consumer code.

## 6. Milestone C — Replace global plugin access with dependency injection

### C1. Add a fixed built-in registry

Create `BuiltInComponents` with typed fields:

```swift
@MainActor
final class BuiltInComponents: ObservableObject {
    let transcriptionEngine: any TranscriptionEngine
    let postProcessors: [any TextPostProcessor]
}
```

There is one transcription engine and one cleanup processor today. Do not preserve an open-ended plugin abstraction merely to hold arrays; use a collection only where pipeline ordering genuinely requires one.

### C2. Migrate consumers in this order

1. `ModelManagerService` — inject the engine; replace all provider scans and casts with direct calls.
2. `StreamingHandler` and `DictationViewModel` — accept the engine or model manager explicitly.
3. `FileTranscriptionViewModel`, `DictationRecoveryViewModel`, and `AudioRecorderViewModel`.
4. `DictionaryService` — inject a dictionary-hint capability or formatter instead of consulting a global manager.
5. `PostProcessingPipeline` — inject the ordered processors.
6. `SettingsViewModel` and retained settings views.
7. Setup wizard and model-settings surfaces.

At each step, remove the corresponding `observePluginManager` subscription and replace readiness observation with explicit engine/model state.

### C3. Rework tests alongside consumers

Replace mutable `PluginManager.shared` fixtures with constructors such as:

- `TestTranscriptionEngine`;
- `TestLiveTranscriptionSession`;
- `TestPostProcessor`;
- `TestModelStore`.

Test doubles should expose recorded requests and controlled async outcomes. Avoid restoring global singleton state in `defer` blocks because parallel tests will eventually make that unsafe.

### C exit criteria

- No production consumer reads `PluginManager.shared`.
- Tests do not mutate `PluginManager.shared`.
- Readiness and settings update through typed observable state.
- The full app suite passes with parallel testing enabled where test isolation permits it.

## 7. Milestone D — Direct construction and bundle removal

### D1. Construct built-ins directly

Instantiate `ParakeetEngine` and `FillerWordCleanup` in the composition root. Give them explicit dependencies:

- Parakeet settings/model store;
- secret/token store if still required;
- model-state callback or observable state;
- FluidAudio-backed implementation;
- filler-cleanup settings store.

Replace generic `HostServicesImpl` defaults and activation with these explicit dependencies. Delete activation-time callbacks that exist only to emulate plugin lifecycle.

### D2. Make retained settings app-owned

Expose Parakeet and filler settings directly from their existing settings destinations. Remove `LeisePlugin.settingsView`, generic settings-window routing, manifest display metadata, and loaded-plugin lookup.

### D3. Remove runtime loading

Delete:

- `PluginManager` and `LoadedPlugin`;
- `HostServicesImpl` once its last explicit dependency is extracted;
- `PluginManifest` if no packaging consumer remains;
- the two `manifest.json` files;
- bundle-loading errors and architecture checks;
- `Bundle.loadAndReturnError` and `NSClassFromString` paths;
- principal-class annotations and plugin activation methods.

### D4. Remove bundle targets

Convert Parakeet and filler cleanup to statically linked internal targets or app sources. Update the Xcode project and package graph so the app links the implementations directly. Remove:

- `ParakeetPlugin.bundle` and `FillerWordsPlugin.bundle` products;
- bundle embed/copy phases;
- bundle schemes and target settings;
- development and release-script checks for embedded bundles.

Change the dev-build self-test to verify the app executable links/contains the retained built-in identifiers and that no `Contents/PlugIns` directory is required.

### D5. Measure the architecture change

Repeat Milestone A measurements. Specifically compare:

- built-in initialization duration;
- launch-to-hotkey and launch-to-UI;
- idle resident memory;
- app and embedded binary size;
- clean and incremental build time.

If direct linking regresses startup, first verify that static initialization—not linking itself—is responsible. Keep construction lazy before considering a return to bundles.

### D exit criteria

- No plugin bundles or manifests ship.
- No runtime type lookup or filesystem component loading occurs.
- Parakeet and filler cleanup are constructed through typed code.
- Core acceptance and model lifecycle tests pass.
- Before/after composition metrics are recorded.

## 8. Milestone E — Collapse or remove `LeisePluginSDK`

### E1. Move retained types

Move the minimum used values and protocols into `LeiseCore` or the app:

- audio sample container and transcription result;
- model metadata/state;
- language selection;
- dictionary term hints and budgets, if still needed;
- transcription request/progress values;
- live session interface;
- post-processing request/context.

Rename types to remove `Plugin` prefixes when they are no longer plugin APIs.

### E2. Delete combinatorial protocols

Replace structured/language-hint/dictionary-hint/source-progress permutations with the single request-based engine interface. Remove compatibility extensions that forward one permutation into another.

### E3. Remove generic host APIs

Replace generic host defaults, secret, notification, and model-restore APIs with narrowly named stores owned by the relevant component. For example:

- `ParakeetSettingsStore`;
- `ParakeetModelStore`;
- `FillerCleanupSettings`;
- `HuggingFaceTokenStore`, only if still used.

### E4. Simplify the package graph

Preferred end state:

```text
Leise app
├── LeiseCore (optional internal target)
├── ParakeetEngine → FluidAudio
└── FillerWordCleanup
```

Remove `LeisePluginSDK`, `LeisePluginSDKTesting`, dynamic-library products, obsolete resources, and package tests that only assert deleted protocol compatibility. Retain behavioral tests in the implementation targets or app tests.

### E exit criteria

- No source imports `LeisePluginSDK` or `LeisePluginSDKTesting`.
- Every public declaration in an internal module has a production consumer.
- No dynamic library exists solely for the former SDK boundary.
- Package resolution and clean-build timing are re-recorded.

## 9. Milestone F — Stage startup around hotkey readiness

### F1. Split the composition root

Replace the single eager `ServiceContainer` with:

```text
AppComposition
├── LaunchScope
│   ├── built-in engine descriptor/light state
│   ├── audio recording path
│   ├── hotkey service
│   ├── dictation coordinator
│   ├── text insertion
│   └── minimal sound/indicator state
└── LazyFeatureScopes
    ├── history + usage statistics
    ├── dictionary + term packs
    ├── profiles
    ├── file transcription
    ├── recorder
    ├── recovery
    ├── diagnostics/export
    └── model/settings editors
```

Use memoized lazy factories with explicit ownership. A feature scope should initialize once, expose its observable view model, and cancel owned tasks when appropriate.

### F2. Remove view-model globals

Pass view models through SwiftUI environment values, `@StateObject` roots, or explicit initializers. Remove `_shared` storage for file transcription, recovery, settings, dictation, history, profiles, dictionary, home, and recorder.

Keep a global only when it represents a true process-wide OS integration and document why constructor injection is impractical.

### F3. Establish launch ordering

Target order:

1. Create minimal app state.
2. Register hotkeys.
3. Make menu/settings UI responsive.
4. Restore lightweight selected-engine metadata.
5. Schedule retained maintenance.
6. Construct editors and export services only when opened.
7. Load the Parakeet model only on explicit restoration policy or first use; never download automatically.

Handle the first-hotkey race explicitly: hotkeys may register before the engine object is fully ready, but the dictation coordinator must queue or surface a deterministic preparing state rather than drop the trigger.

### F4. Add initialization tests

Use counters/spies to assert that a cold app composition does not create:

- history/editor view models;
- dictionary/term-pack editors;
- file transcription or recorder UI state;
- diagnostics exporters;
- full model settings UI.

Add tests that opening each destination creates its scope exactly once.

### F exit criteria

- Hotkey readiness precedes noncritical store scans and maintenance.
- No `_shared` view-model storage remains.
- Lazy scopes are deterministic and test-covered.
- Launch-to-hotkey, launch-to-UI, and idle-memory metrics improve against baseline.

## 10. Milestone G — Move retained maintenance off launch

### G1. Usage statistics

- Check a lightweight completion marker before reading history.
- Fetch records in bounded batches only when backfill is required.
- Perform aggregation away from the main actor.
- Publish completion/error state on the main actor.

### G2. History retention

- Schedule cleanup after hotkey and UI readiness.
- Delete in bounded batches.
- Make repeated launch scheduling idempotent.

### G3. Model restoration and resource parsing

- Restore only model identity/state metadata during startup.
- Perform filesystem checks off the main actor.
- Do not trigger model downloads.
- Cache punctuation rules and term-pack resources after first use.

### G4. Lifecycle and cancellation

Give each maintenance task an owner, cancellation path, idempotency rule, and error-log category. Prevent duplicate work when settings windows reopen.

### G exit criteria

- Instruments shows no avoidable history scan, resource parse, or model filesystem walk on the launch main thread.
- Maintenance completes after launch and reports failures.
- Reopening retained screens does not duplicate tasks or observers.

## 11. Milestone H — Optimize the measured dictation hot path

Do not start a change in this milestone without a profile identifying the cost.

### H1. Attribute latency

Measure separately:

- audio callback and buffering;
- sample conversion/resampling;
- live-session submission;
- model preparation and inference;
- vocabulary-hint construction;
- final normalization;
- filler cleanup;
- history/statistics writes;
- insertion and clipboard restoration.

Use fixed short, medium, and long local audio fixtures. Separate first-use model cost from steady-state transcription.

### H2. Candidate optimizations

Apply only candidates supported by profiles:

- remove duplicate `[Float]` or `Data` copies;
- reuse converters and stable audio buffers;
- cache model and vocabulary asset existence checks;
- build dictionary hints only when dictionary revision changes;
- replace repeated engine/model filtering with direct indexed state;
- reduce high-frequency `@Published` updates from streaming callbacks;
- batch progress/UI publication at a perceptually sufficient cadence;
- perform history/statistics persistence after successful insertion when safe;
- avoid re-running normalization or filler cleanup on unchanged preview text.

### H3. Correctness and memory gates

For each optimization, compare transcript text, detected language, timestamps/segments where retained, insertion output, and failure behavior. Reject changes that trade a small latency win for unbounded memory or fragile ownership.

### H exit criteria

- First and steady-state dictation meet the accepted budgets.
- No correctness or insertion regression appears in fixtures or manual acceptance.
- Peak memory changes are reported with the latency result.

## 12. Milestone I — Final cleanup and enforcement

### I1. Repository cleanup

Remove obsolete source, targets, schemes, products, assets, manifests, localization, tests, and scripts made unreachable by Milestones B–H. Remove old `TypeWhisper` compatibility names and remaining migrations.

### I2. Add structural checks

Add a lightweight repository check that fails on reintroduction of:

- `PluginManager`;
- `LoadedPlugin`;
- `NSClassFromString` in built-in composition;
- runtime bundle scanning/loading;
- `LeisePluginSDK` imports;
- removed provider or product identifiers;
- plugin manifests or embedded plugin-bundle build phases.

Run it from `scripts/pr-preflight.sh`.

### I3. Final measurements

Repeat the complete baseline procedure with the same machine, configuration, fixtures, and run count. Produce `docs/performance/final-2026-07-13.md` containing:

- baseline and final median/p90 tables;
- launch and dictation signpost comparisons;
- idle and model-loaded memory;
- clean and incremental builds;
- app/package size;
- any missed budget with explanation;
- remaining known bottlenecks.

### I exit criteria

- A clean clone resolves, builds, tests, and packages.
- Structural checks find no deleted architecture.
- Documentation describes the actual final dependency graph.
- Final metrics satisfy the accepted budgets or document an explicit decision.

## 13. Recommended pull-request sequence

Each item is a separate review and rollback boundary:

1. **Performance harness and baseline** — signposts, scripts, raw data, and budget confirmation.
2. **Internal core contracts** — request-based engine and post-processor interfaces plus adapters.
3. **Model manager injection** — direct engine dependency and engine-state observation.
4. **Dictation and streaming injection** — remove global manager access from the critical path.
5. **Recorder/recovery/file/dictionary injection** — migrate the remaining runtime consumers.
6. **Settings and test isolation** — migrate UI consumers and replace global plugin fixtures.
7. **Direct built-in construction** — explicit Parakeet/filler dependencies; remove host activation.
8. **Bundle and loader removal** — delete manifests, bundle targets, embedding, and `PluginManager`.
9. **SDK collapse** — move retained values, delete protocol permutations and dynamic SDK products.
10. **Lazy launch composition** — split launch and retained feature scopes; remove view-model globals.
11. **Post-launch maintenance** — batch and schedule statistics, retention, restoration, and parsing.
12. **Measured hot-path improvements** — one or more small PRs grouped by demonstrated bottleneck.
13. **Final cleanup and rebaseline** — structural guard, clean-clone verification, and final report.

Do not merge PR 8 until PRs 3–7 have removed every production and test dependency on the loader. Do not merge PR 9 until direct construction passes parity tests. Do not begin PR 12 until PRs 10–11 are measured.

## 14. Verification required for every PR

Automated minimum:

```sh
xcodebuild build-for-testing -quiet \
  -project Leise.xcodeproj \
  -scheme Leise \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData-RemainingPlan \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test -quiet \
  -project Leise.xcodeproj \
  -scheme Leise \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData-RemainingPlan \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO

swift test --package-path LeiseComponents --scratch-path .build/LeiseComponents

git diff --check
bash -n build-and-run.sh scripts/*.sh
```

After `LeisePluginSDK` is removed, replace its SwiftPM command with the test command for the retained internal package or targets.

Manual minimum at architecture checkpoints:

1. Complete clean onboarding and permissions.
2. Select, download, load, unload, and reload Parakeet v2 and v3.
3. Dictate through push-to-talk, toggle, and hybrid hotkeys.
4. Verify streaming preview and a final transcript.
5. Verify vocabulary hints and filler-word cleanup independently.
6. Insert into one native app and one browser/Electron app.
7. Exercise file transcription, recorder, and failed-dictation recovery.
8. Exercise missing permission, offline download, cancelled load, and unavailable-model failures.
9. Confirm history, statistics, dictionary, profiles, and retained settings remain correct.

Performance-affecting PRs must attach the relevant before/after raw results and median/p90 summary.

## 15. Final definition of done

The remaining program is complete only when all of the following are true:

- Leise directly constructs Parakeet and filler cleanup.
- No runtime bundle or manifest mechanism remains.
- No production or test code uses `PluginManager.shared`.
- `LeisePluginSDK` is gone or replaced by a minimal internal core with only production-used declarations.
- Startup creates only the launch-critical graph and registers hotkeys before retained maintenance.
- Retained feature scopes initialize once on demand.
- Dictation hot-path changes are profile-driven and correctness-tested.
- The complete test and manual acceptance matrices pass from a clean clone.
- Final launch, memory, build, size, and dictation measurements are recorded and meet the accepted budgets or have an explicit documented exception.
