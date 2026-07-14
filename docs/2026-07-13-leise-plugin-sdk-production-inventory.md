# LeisePluginSDK Production Symbol Inventory

Status: complete

Date: 2026-07-13

Plan: [remaining simplification and performance plan](2026-07-13-remaining-simplification-and-performance-plan.md)

## Scope and method

This is the Milestone B1 inventory of the current public surface in
`LeisePluginSDK` and `LeisePluginSDKTesting`. Production consumers mean Swift
sources under `Leise/` and the non-test Parakeet and filler-word sources. Test
targets were searched separately and do not justify retaining an API.
All 47 public top-level SDK declarations and the one public testing declaration
are named below; public members are called out separately when their production
use or disposition differs from their enclosing declaration.

The inventory uses four dispositions:

- **replace**: preserve the production behavior behind a narrower app-owned
  contract in Milestone B2;
- **move local**: preserve the behavior inside Leise, Parakeet, or filler-word
  implementation code, but do not expose it through the shared boundary;
- **bridge only**: needed only until runtime bundle composition is removed;
- **delete**: no retained production behavior requires the declaration.

The production implementation census is small:

| Implementation | Current production conformances |
| --- | --- |
| `ParakeetPlugin` | `DictionaryTermHintSourceProgressTranscriptionEnginePlugin`, `DictionaryTermsCapabilityProviding`, `TranscriptPreviewFallbackPolicyProviding`, `PluginSettingsActivityReporting` |
| `FillerWordsPlugin` | `PostProcessorPlugin` |

No production type conforms to a structured-result, multi-language-hint,
model-catalog, dictionary-budget, or live-session protocol. Those branches in
`ModelManagerService` are compatibility scaffolding exercised by test doubles,
not retained engine behavior.

## Proposed retained boundary

These are the only shared declarations justified by production call sites.
Names are working names for B2; none require compatibility with the current SDK.

| Candidate | Required surface | Production consumers |
| --- | --- | --- |
| `TranscriptionAudio` | 16 kHz mono `samples` and `duration` | `ModelManagerService.makeAudioData`; Parakeet transcription, progress, and short-clip confidence handling |
| `TranscriptionModel` | `id`, `displayName` | Parakeet model list; `ModelManagerService`; setup, recorder, recovery, and file-transcription model pickers |
| `DictionaryTermHint` | `text`, optional `ctcMinSimilarity` | `DictionaryService`; `DictationViewModel`; `StreamingHandler`; recorder; Parakeet vocabulary boosting |
| `TranscriptionSourceProgress` | `processedDuration`, `totalDuration`, derived fraction | Parakeet source-progress producer; `FileTranscriptionViewModel` and `FileTranscriptionView` |
| `EngineTranscriptionSegment` | `text`, `start`, `end` | Parakeet token grouping; `ModelManagerService` conversion to the app result |
| `EngineTranscriptionResult` | `text`, optional detected language, segments | Parakeet producer; `ModelManagerService` normalization; streaming fallback |
| `TranscriptionCapabilities` | supported languages, batch-preview support, dictionary-hint support | Parakeet producer; `ModelManagerService`; `DictionaryService`; settings and transcription views |
| `TranscriptionRequest` | audio, one requested language, prompt, dictionary hints, optional text/source progress, cancellation check | `ModelManagerService` producer; Parakeet consumer; file-transcription and streaming progress/cancellation paths |
| `ModelPreparationStatus` | message, optional fraction, failure state | Parakeet model/vocabulary loading; `ModelManagerService` timeout diagnostics; `SetupWizardView` |
| `TranscriptionEngine` | identity, models, selection, capabilities, explicit prepare/transcribe/unload operations and observable readiness | Parakeet implementation; built-in composition; `ModelManagerService`; recorder, recovery, file transcription, settings, and setup consumers |
| `TextPostProcessor` | identity/name, priority, async text processing | `FillerWordsPlugin`; `PostProcessingPipeline` |
| `DictionaryHintNormalizer` or equivalent internal functions | normalize/deduplicate hints, parse prompt fallback, apply the app's prompt limit | `DictionaryService`; Parakeet vocabulary fallback |

Every candidate above has both a named production producer or owner and at
least one production consumer. The table intentionally does not retain generic
plugin lifecycle, manifests, SwiftUI settings views, structured transcription,
speaker metadata, model catalogs, cloud authentication, or live sessions.

## Audio and transcription values

| Current declaration | Production call sites and observed use | Disposition |
| --- | --- | --- |
| `AudioData` | Constructed by `ModelManagerService`; Parakeet reads `samples` and `duration`. No retained source reads `wavData`. | **replace** with `TranscriptionAudio`; remove WAV encoding from this boundary. |
| `PluginAudioUtils` | Parakeet alone uses `paddedSamples` and `shouldAcceptShortClipTranscription`. | **move local** to the Parakeet implementation. |
| `AudioUtils` | Deprecated compatibility alias with no production call site. | **delete**. |
| `PluginTranscriptionSegment` | Produced by Parakeet token grouping and converted by `ModelManagerService`. | **replace** with the three-field engine segment. |
| `PluginTranscriptionResult` | Produced by Parakeet and consumed by `ModelManagerService`; live-session references have no production producer. | **replace** with `EngineTranscriptionResult`. |
| `PluginStructuredTranscriptionSegment` | Constructed only by compatibility conversion in `ModelManagerService`; no production engine produces speaker metadata. | **delete** from the boundary and remove the conversion branch. |
| `PluginStructuredTranscriptionResult` | Same compatibility-only path; no production conformer returns it. | **delete**. |
| `PluginTranscriptionError` | Parakeet throws only `.notConfigured`. `DictationViewModel` still switches over removed cloud/file cases. | **delete**; explicit preparation should prevent the Parakeet case, and app-owned errors should classify presentation. |

The app-owned `TranscriptionResult` remains the normalized result with duration,
processing time, engine identity, and optional speaker fields for stored-data
compatibility. Those app fields do not justify structured engine protocols.

## Model metadata and lifecycle

| Current declaration or member | Production call sites and observed use | Disposition |
| --- | --- | --- |
| `PluginModelInfo` | Parakeet produces all fields. Only `id` and `displayName` are read by Leise. `sizeDescription` and `languageCount` are read only from Parakeet's private model definitions; `downloaded` and `loaded` are neither populated nor consumed. | **replace** with two-field `TranscriptionModel`. |
| `TranscriptionEnginePlugin` | Central dependency of `PluginManager`, `ModelManagerService`, recorder, recovery, file transcription, settings, and views. Parakeet is the only production conformer. | **replace** with one narrow `TranscriptionEngine`. |
| `providerId`, `providerDisplayName`, `transcriptionModels`, `selectedModelId`, `selectModel`, `isConfigured` | All have production consumers in `ModelManagerService` and retained UI. | **replace** with typed identity, model list/selection, and explicit readiness. |
| `supportsStreaming`, `supportedLanguages` | Batch streaming fallback and language pickers consume these values. | **replace** as capability fields. |
| `TranscriptionModelCatalogProviding` and `modelCatalog` | Leise reads the fallback property, but no production engine provides a distinct catalog; only tests do. | **delete** the distinction; expose one model list. |
| `TranscriptPreviewFallbackPolicyProviding` | Parakeet returns the default `true`; no production implementation opts out. | **delete** and keep Parakeet's current fallback behavior directly. |
| Objective-C `triggerRestoreModel` and `triggerAutoUnload` selectors | `ModelManagerService` invokes hidden Parakeet lifecycle methods through `NSObject.perform`. | **replace** with explicit async `prepareModel` and synchronous/async `unloadModel` contract operations. |
| `PluginSettingsActivity` and `PluginSettingsActivityReporting` | Parakeet reports model/vocabulary download state; `ModelManagerService` and `SetupWizardView` consume it. | **replace** with model-preparation status, not a settings/plugin protocol. |

Selection restoration, cloud-model override restoration, auto-unload protection,
and readiness polling are real app behaviors. They should call explicit engine
operations and observe engine state; they do not require generic plugin
lifecycle or Objective-C dispatch.

## Language selection and dictionary hints

| Current declaration | Production call sites and observed use | Disposition |
| --- | --- | --- |
| `PluginLanguageSelection` | Created only by `ModelManagerService`. Because Parakeet does not conform to a language-hint protocol, a multi-selection is reduced to its first supported code before transcription. | **replace** with one optional requested-language field in `TranscriptionRequest`; keep the richer `LanguageSelection` app-owned for UI and normalization. |
| `PluginDictionaryTermHint` | Produced by `DictionaryService`; passed through dictation, recorder, file, and streaming paths; consumed by Parakeet vocabulary boosting. Both fields are used. | **replace** with `DictionaryTermHint`. |
| `DictionaryTermsSupport` and `DictionaryTermsCapabilityProviding` | Parakeet reports supported/requires-setting; dictionary settings display it and `DictionaryService` checks it. | **replace** with a capability value, not a cast-only protocol. |
| `DictionaryTermsBudget` | `DictionaryService` uses a local 600-character fallback. No production engine supplies a budget. | **move local** to `DictionaryService` if the limit remains necessary. |
| `DictionaryTermsBudgetProviding` | No production conformer; only test engines provide it. | **delete**. |
| `PluginDictionaryTerms` | Production uses hint/term normalization, prompt parsing, prompt formatting, and hint clipping. `clippedTerms` and `contextBiasTokens` have no external production call site. | **replace/move** only the used normalization and formatting behavior; delete unused helpers. |
| `DictionaryTermHintTranscriptionEnginePlugin`, `DictionaryTermHintSourceProgressTranscriptionEnginePlugin` | Parakeet conforms through the combined source-progress protocol; `ModelManagerService` casts through both variants. | **replace** with dictionary hints and optional source progress in one request. |
| `LanguageHintTranscriptionEnginePlugin`, `LanguageHintDictionaryTermHintTranscriptionEnginePlugin`, `SourceProgressLanguageHintTranscriptionEnginePlugin`, `LanguageHintDictionaryTermHintSourceProgressTranscriptionEnginePlugin` | No production conformer. Branches exist only in `ModelManagerService`; tests provide the implementations. | **delete**. |

## Streaming and live-session behavior

| Current declaration | Production call sites and observed use | Disposition |
| --- | --- | --- |
| `supportsStreaming` on `TranscriptionEnginePlugin` | Parakeet returns `true`. `StreamingHandler` uses repeated batch transcription to update previews. | **replace** with a batch-preview capability and preserve the current fallback. |
| `LiveTranscriptionSession` | `ModelManagerService` and `StreamingHandler` can append, finish, and cancel, but no production engine can create a session. | **delete** with the unreachable live path; test consumers alone do not justify it. |
| `LiveTranscriptionCapablePlugin`, `LiveLanguageHintTranscriptionCapablePlugin`, `LiveDictionaryTermHintTranscriptionCapablePlugin`, `LiveLanguageHintDictionaryTermHintTranscriptionCapablePlugin` | Cast and dispatch branches exist in `ModelManagerService`; all production casts fail for Parakeet. | **delete**. |

The retained product behavior called “streaming” is Parakeet batch-preview
fallback, not a live engine session. A live-session contract should be added
later only alongside a production implementation and measurements.

## Progress reporting and cancellation

| Current declaration or behavior | Production call sites and observed use | Disposition |
| --- | --- | --- |
| `PluginTranscriptionSourceProgress` | Parakeet emits processed/total duration for sufficiently long input; file transcription normalizes and displays it. `previewText` is never produced by retained code. | **replace** without `previewText`; text preview already has its own callback. |
| Text `onProgress` callback | Parakeet emits the final text; `ModelManagerService`, `StreamingHandler`, and `FileTranscriptionViewModel` use it for preview updates. | **replace** as one optional request callback. |
| Source-progress `Bool` callback result | Parakeet uses `false` only to stop its progress-observation task, not inference. | **replace** with an optional callback plus explicit cancellation checking. |
| `SourceProgressTranscriptionEnginePlugin` and `DictionaryTermHintSourceProgressTranscriptionEnginePlugin` | The combined dictionary/source variant is Parakeet's real path; separate protocols exist to select overloads. | **replace** with one request and delete both protocols. |
| Task cancellation | File transcription and streaming already check cancellation outside the SDK; Parakeet operations run in Swift tasks. | **retain behavior** through `Task.isCancelled` or an injected request check, with no cancellation capability protocol. |

## Post-processing

| Current declaration | Production call sites and observed use | Disposition |
| --- | --- | --- |
| `PostProcessorPlugin` | `PluginManager` orders processors and `PostProcessingPipeline` invokes them. Filler cleanup is the only production conformer. `processorName` and `priority` are used. | **replace** with `TextPostProcessor`; remove plugin lifecycle inheritance. |
| `PostProcessingContext` | `DictationViewModel` constructs it. `PostProcessingPipeline` reads `bundleIdentifier`, `url`, and `language` for app-owned formatting, punctuation, and normalization; the filler processor ignores every field. `appName`, `ruleName`, `selectedText`, and deprecated `profileName` have no production reader. | **move local** to Leise and narrow it for the app-owned pipeline; do not pass it through the shared processor contract. |

Filler settings remain production behavior, but the settings store belongs with
the filler implementation. The processor can read or receive a snapshot of its
configured words without a generic host protocol. Leise may keep a separate,
narrow pipeline context for its formatter and normalization steps.

## Settings and state callbacks

| Current declaration or member | Production call sites and observed use | Disposition |
| --- | --- | --- |
| `HostServices.storeSecret` / `loadSecret` | Parakeet's Hugging Face token settings. | **move local** behind an injected Parakeet token store backed by `KeychainService`. |
| `HostServices.userDefault` / `setUserDefault` | Parakeet model/vocabulary preferences and filler-word settings. | **move local** to explicit implementation-owned settings stores. |
| `HostServices.shouldRestoreLoadedModelsPassively` | Parakeet activation decides whether to restore a loaded model. | **replace** with the app's explicit prepare/restore decision; no host-wide protocol. |
| `HostServices.notifyCapabilitiesChanged` | Parakeet model and vocabulary transitions notify `PluginManager`; `ModelManagerService` observes the manager revision. | **replace** with observable engine readiness/preparation state. |
| `HostServices` | Aggregates the five behaviors above for runtime plugin activation. | **bridge only**, then delete after direct construction. |
| `pluginSettingsClose` on `EnvironmentValues` | `ModelsSettingsView` injects it and Parakeet's SwiftUI settings view reads it. | **move local** to the directly composed model-settings UI; it is not a core contract. |
| `LeisePlugin.settingsView` | `ModelsSettingsView` opens the Parakeet and filler views through an existential. | **bridge only**; direct composition should reference concrete settings views. |
| `PluginHuggingFaceTokenHelper` | Used only by Parakeet for token normalization, validation, storage, and environment setup. | **move local** to Parakeet. |
| `PluginHTTPClient` | Parakeet uses it for vocabulary downloads and token validation; `LeiseApp` resets its shared session after wake. | **move local** to the retained downloader and expose only the narrow wake-recovery action if still required. |

## Loader, manifest, and compatibility support

| Current declaration | Production call sites and observed use | Disposition |
| --- | --- | --- |
| `LeisePlugin` | Required by dynamic principal-class lookup and inherited by both implementations. `deactivate` has no production caller. | **bridge only**, then delete with runtime bundles. |
| `PluginManifest` | `PluginManager` decodes it and uses `id`, `name`, and `principalClass`; `ModelManagerService` reads `requiresAPIKey`; `ModelsSettingsView` reads `resolvedHosting`. Remaining fields are not read by retained production code. | **bridge only**, then delete. Local/cloud checks are stale for the fixed local engine. |
| `PluginHosting` | Only `PluginManifest.resolvedHosting` and a model-settings visibility check. | **bridge only**, then delete. |
| `PluginCapability` | No production call site. | **delete**. |
| `PluginManifest.resolvedCategoryIdentifiers`, `resolvedCapabilityIdentifiers`, `supportsCapability`, and normalization helpers | No production call site. | **delete**. |
| `PluginSettingsActivityReporting`'s default implementation and `TranscriptPreviewFallbackPolicyProviding`'s default implementation | Compatibility defaults; retained behavior is represented directly by status/capability values. | **delete** with their protocols. |

## Test-only support and protocol combinations

| Current declaration | Test use | Disposition |
| --- | --- | --- |
| `PluginTestHostServices` in `LeisePluginSDKTesting` | Parakeet and filler package tests use mutable defaults/secrets and capability-change counts. | **test only**; replace with implementation-specific test stores, then delete the testing product. |
| `StructuredTranscriptionEnginePlugin`, `StructuredLanguageHintTranscriptionEnginePlugin`, `StructuredDictionaryTermHintTranscriptionEnginePlugin`, `StructuredLanguageHintDictionaryTermHintTranscriptionEnginePlugin` | App tests construct structured mock combinations; no production conformer exists. | **delete** and rewrite behavioral tests against the narrow engine fake. |
| `TranscriptionModelCatalogProviding` | Recorder/model-override tests provide a second catalog; production Parakeet does not. | **delete**. |
| `DictionaryTermsBudgetProviding` | Dictionary tests provide budgeted and unsupported mock engines; production Parakeet does not provide a budget. | **delete**; retain app-local clipping tests if the fallback limit remains. |
| All four `Live*Plugin` protocols and `LiveTranscriptionSession` | Streaming/model-manager tests exercise mock sessions; no production engine creates one. | **delete** those compatibility tests; keep tests for Parakeet's batch-preview fallback. |
| Multi-language-hint protocol combinations | Streaming/model-manager tests exercise mock engines; Parakeet accepts only the resolved requested language. | **delete** and test app-owned language resolution directly. |

## B2 constraints derived from the inventory

1. Use one transcription request rather than protocol/overload combinations.
2. Make model preparation and unloading explicit; remove Objective-C selectors and
   readiness polling as the lifecycle API.
3. Keep `LanguageSelection` in the app and pass Parakeet one resolved optional
   language code.
4. Represent dictionary support and batch preview as values in capabilities;
   pass hints and progress closures in the request.
5. Do not add structured, speaker, live-session, model-catalog, cloud-auth,
   manifest, or SwiftUI settings APIs to the new shared module.
6. Keep HTTP, token, defaults, keychain, model assets, and filler settings with
   their implementations.
7. Replace global capability revision notifications with explicit observable
   engine state.
