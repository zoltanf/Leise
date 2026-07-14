# TypeWhisper Upstream Integration Plan

Status: deferred; not included in Leise 1.7.0

Date: 2026-07-14

Upstream snapshot audited: `TypeWhisper/typewhisper-mac` `68b1aee`

Leise baseline: `42752ef`

## 1. Outcome

Selectively port the useful local dictionary and dependency-management work
added upstream after Leise diverged, while preserving Leise's GPL-only,
local-first architecture.

This is not a broad upstream merge. Each retained behavior will be adapted to
Leise names and current services, reviewed independently, and verified before
the next item begins.

## 2. Scope

### Import in the first implementation pass

| Upstream commit | Classification | Leise adaptation |
| --- | --- | --- |
| `7d4a355` Add dictionary search | Direct | Port search state, original/replacement matching, empty states, and focused tests. |
| `70fe2fa` Improve search field visibility | Adapt | Add a shared native macOS search field for Dictionary and History. Exclude unrelated plugin-package changes. |
| `523b5fb` Add safe dictionary reset actions | Adapt | Port stable-ID deletion, rollback, confirmations, and reset summaries without licensing dependencies. |
| `c3b8d79` Group dictionary correction variants | Adapt | Derive correction groups from flat entries, retain per-alias editing/enabling/deletion, and add alias creation. |
| `23c90bb` Improve correction learning reliability | Partial | Port only persistence failure rollback and useful typed diagnostics; do not restore target-app correction tracking. |
| `4dd7732` Pin FluidAudio | Direct, partial | Pin `LeiseComponents` to revision `2ea0727541135c34189194084531337a3518e1bf`; do not import WhisperKit code. |

### Consider as a separate feature

| Upstream commit | Classification | Decision gate |
| --- | --- | --- |
| `35ba373` Add guided microphone correction trainer | Adapt | Port only after the first pass is stable. Use Leise's bundled engine contracts, current audio lifecycle, and local dictionary service. |

### Explicitly reject

- `6cefb08` purchase attribution and commercial-license UI;
- `23ef811` and `68b1aee` webhook plugin behavior;
- WhisperKit implementation and manifest changes from `4dd7732`;
- upstream plugin marketplace, commercial, release, branding, and distribution
  infrastructure encountered while resolving context.

## 3. Execution rules

1. Start from a clean Leise `main` and fetch `upstream`.
2. Create a temporary `codex/upstream-dictionary-improvements` branch, then
   fast-forward `main` and delete the temporary branch after verification so
   the repository returns to its single-branch state.
3. Port behavior rather than cherry-picking complete commits.
4. Keep persisted dictionary entries flat and backward compatible. Grouping is
   a derived presentation model only.
5. Never overwrite an existing correction when adding an alias or training
   candidate.
6. Roll back SwiftData mutations after any failed save and reload observable
   state from the store.
7. Keep all transcription and training on bundled, local engines.
8. Do not change startup composition or eagerly initialize training UI/services.

## 4. Milestones

### A. Repair the upstream audit guard

Update `.codex/skills/sync-typewhisper-upstream/scripts/audit_sync.sh` for the
post-plugin architecture. The guard currently reports a false failure because
it expects the deleted `Leise/Services/PluginManager.swift`.

Exit criteria:

- the guard validates `BuiltInComponents`, `ModelManagerService`, and the
  absence of external provider/plugin loading;
- a clean current Leise checkout passes the guard.

### B. Pin FluidAudio

Replace the moving `main` dependency in `LeiseComponents/Package.swift` with
the audited upstream revision. Refresh both resolved-package files and run the
component plus application test suites.

Exit criteria:

- clean dependency resolution selects the same revision in both build paths;
- Parakeet model discovery, preparation, and transcription tests pass;
- clean and incremental builds remain functional.

### C. Add shared native search

Introduce `NativeSearchField`, use it in History, and add dictionary search
over both original and replacement text. Search must compose with all retained
filters and must not mutate dictionary storage.

Exit criteria:

- case-insensitive search works for terms and corrections;
- clearing search restores the same ordered entries and IDs;
- empty search and no-result states are distinct and accessible;
- History search behavior remains unchanged apart from presentation.

### D. Add safe reset operations

Add throwing stable-ID batch deletion with rollback. Expose confirmation-based
actions for auto-learned corrections, custom entries, and active term-pack
entries. Adapt the upstream implementation to Leise's retained term-pack model
without any license service.

Exit criteria:

- every destructive action previews exact affected counts;
- cancel performs no mutation;
- custom reset preserves tracked pack entries;
- pack deactivation preserves custom and auto-learned entries;
- persistence failures leave in-memory and stored state consistent.

### E. Group correction variants

Derive list rows that group non-empty, exactly matching replacement strings.
Keep empty-replacement corrections standalone. Search matches either a group
replacement or any alias and reveals the complete matching group.

Exit criteria:

- grouping does not alter stored entries or export format;
- alias toggling, editing, and deletion affect only the selected entry;
- adding an alias locks the group's replacement value;
- case-sensitive replacement groups remain distinct where upstream behavior
  requires exact matching.

### F. Evaluate the guided trainer

Implement the trainer only after milestones A-E are merged and stable. Capture
three local samples, transcribe against a stable engine/model snapshot, present
candidate corrections for review, and commit the selected entries atomically.

Decision criteria:

- it can share the existing recording service without conflicting with global
  dictation hotkeys or recorder state;
- cancellation reliably discards audio and late transcription results;
- the service remains lazy and does not regress launch or idle memory;
- the UI provides clear duplicate/conflict handling before any mutation.

## 5. Verification

For each milestone run:

```sh
.codex/skills/sync-typewhisper-upstream/scripts/audit_sync.sh
git diff --check
xcodebuild test -project Leise.xcodeproj -scheme Leise \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
swift test --package-path LeiseComponents
```

Also perform manual checks for Dictionary search focus, destructive reset
confirmations, correction-group expansion, alias editing, and—if implemented—
trainer cancellation while recording and transcribing.

## 6. Completion criteria

- Every imported upstream behavior is traceable to an audited commit.
- No rejected product, provider, plugin, license, or branding subsystem returns.
- Dictionary persistence and export remain backward compatible.
- The full automated and manual verification set passes.
- Performance measurements show no meaningful startup or hotkey regression.
