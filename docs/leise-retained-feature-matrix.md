# Leise Retained-Feature Matrix

Status: approved
Date: 2026-07-13
Approval: all non-retained product and extension surfaces are removal scope.

## Visible product surface

| Feature or destination | Decision | Current owner / entry point |
| --- | --- | --- |
| Home and usage overview | retain | `HomeSettingsView`, `HomeViewModel`, `UsageStatisticsService` |
| General settings and launch behavior | retain | `GeneralSettingsView`, `SettingsViewModel` |
| Appearance and dictation indicators | retain | `AppearanceSettingsView`, `IndicatorCoordinator` |
| Dictation hotkeys: push-to-talk, toggle, and hybrid | retain | `HotkeySettingsView`, `HotkeyService`, `DictationViewModel` |
| Text insertion and target-app formatting | retain | `TextInsertionService`, `AppFormatterService` |
| Parakeet v2/v3 selection, download, loading, streaming, transcription, and vocabulary boosting | retain | `ParakeetSettingsPage`, `ModelManagerService`, built-in Parakeet component |
| Filler-word cleanup | retain | `FillerWordCleanupSettingsPage`, `PostProcessingPipeline`, built-in filler cleanup component |
| History, export, retention, and usage statistics | retain | `HistoryView`, `HistoryService`, `UsageStatisticsService` |
| Dictionary, vocabulary hints, and term packs | retain | `DictionarySettingsView`, `DictionaryService`, `TermPackRegistryService` |
| Profiles and target-app rules | retain | `ProfileService`, `ProfilesViewModel`, dictation runtime context |
| Audio recorder | retain | `AudioRecorderView`, `AudioRecorderService`, `AudioRecorderViewModel` |
| Failed-dictation recovery | retain | `DictationRecoveryView`, `DictationRecoveryAudioStore`, `DictationRecoveryViewModel` |
| File transcription | retain | `FileTranscriptionView`, `FileTranscriptionViewModel`, `AudioFileService` |
| Spoken punctuation and number normalization | retain | `SpokenPunctuationSettingsSection`, `SpeechPunctuationService`, `TranscriptionNormalizationService` |
| Support diagnostics and error log | retain | `AdvancedSettingsView`, `ErrorLogService`, diagnostics export |
| About, update channel, and setup-wizard relaunch | retain | `AboutSettingsView`, `UpdateChecker`, `SetupWizardView` |
| Watch-folder transcription | remove | `FileTranscriptionView`, `WatchFolderService`, `WatchFolderViewModel` |
| Memory extraction and storage | remove | `AdvancedSettingsView`, `MemoryService` |
| Prompt actions and prompt palette | remove | `PromptActionService`, `PromptProcessingService`, `PromptPaletteHandler` |
| Workflows | remove | `WorkflowService`, `WorkflowTextProcessingService` |
| Translation | remove | `TranslationService`, `TranslationHostWindow` |
| Spoken feedback and read-back | remove | `AdvancedSettingsView`, `SpeechFeedbackService`, `MenuBarView` |
| Local HTTP API, CLI, and Raycast integration | remove | `AdvancedSettingsView`, `APIServerViewModel`, `HTTPServer`, `leise-cli` |

## Background and extension surface

| Feature | Decision | Current owner / entry point |
| --- | --- | --- |
| Microphone selection, recording, audio ducking, and media pause/resume | retain | `AudioDeviceService`, `AudioRecordingService`, `AudioDuckingService`, `MediaPlaybackService` |
| Sound cues and Accessibility announcements | retain | `SoundService`, `AccessibilityAnnouncementService` |
| Saved-audio recovery and recent-transcription palette | retain | `DictationRecoveryAudioStore`, `RecentTranscriptionStore` |
| Widgets and widget synchronization | remove | `LeiseWidgetExtension`, `WidgetDataService` |
| Apple Intelligence setup recommendation and LLM provider | remove | `SetupWizardView`, `FoundationModelsProvider`, provider-selection migrations |
| External/community plugin discovery, install, update, compatibility, enable/disable, and marketplace behavior | remove | `PluginManager`, plugin registry code, external plugin directories and tooling |
| Provider implementations and SDK APIs used only by removed plugins | remove | `LeisePluginSDK`, obsolete provider targets, tests, assets, scripts, and documentation |

## Approval and change control

Approval of this document authorizes vertical removal work for every row marked `remove`. A `retain` row must preserve user-visible behavior, but obsolete local settings and stores do not require migration because the app is still green-field and local-only. Changes to these decisions require an explicit amendment to this matrix.
