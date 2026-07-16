import Foundation

/// Central registry for all UserDefaults keys used throughout the app.
/// Prevents typo-induced bugs and makes keys discoverable via autocomplete.
enum UserDefaultsKeys {
    // MARK: - Dictation
    static let audioDuckingEnabled = "audioDuckingEnabled"
    static let audioDuckingLevel = "audioDuckingLevel"
    static let soundFeedbackEnabled = "soundFeedbackEnabled"
    static let soundRecordingStarted = "soundRecordingStarted"
    static let soundTranscriptionSuccess = "soundTranscriptionSuccess"
    static let soundError = "soundError"
    static let indicatorStyle = "indicatorStyle"
    static let indicatorTranscriptPreviewEnabled = "indicatorTranscriptPreviewEnabled"
    static let indicatorTranscriptPreviewFontSizeOffset = "indicatorTranscriptPreviewFontSizeOffset"
    static let preserveClipboard = "preserveClipboard"
    static let mediaPauseEnabled = "mediaPauseEnabled"
    static let dictationHotkeysPaused = "dictationHotkeysPaused"
    static let transcribeShortQuietClipsAggressively = "transcribeShortQuietClipsAggressively"
    static let microphoneBoostEnabled = "microphoneBoostEnabled"

    // MARK: - Hotkey (JSON-encoded UnifiedHotkey per slot, legacy mirror for first binding)
    static let hybridHotkey = "hybridHotkey"
    static let pttHotkey = "pttHotkey"
    static let toggleHotkey = "toggleHotkey"
    static let recentTranscriptionsHotkey = "recentTranscriptionsHotkey"
    static let copyLastTranscriptionHotkey = "copyLastTranscriptionHotkey"
    static let recorderToggleHotkey = "recorderToggleHotkey"

    // MARK: - Hotkeys (JSON-encoded [UnifiedHotkey] per slot)
    static let hybridHotkeys = "hybridHotkeys"
    static let pttHotkeys = "pttHotkeys"
    static let toggleHotkeys = "toggleHotkeys"
    static let recentTranscriptionsHotkeys = "recentTranscriptionsHotkeys"
    static let copyLastTranscriptionHotkeys = "copyLastTranscriptionHotkeys"
    static let recorderToggleHotkeys = "recorderToggleHotkeys"

    // MARK: - Model / Engine
    static let selectedEngine = "selectedEngine"
    static let selectedModelId = "selectedModelId"
    static let loadedModelIds = "loadedModelIds"
    static let modelAutoUnloadSeconds = "modelAutoUnloadSeconds"

    // MARK: - Settings
    static let selectedLanguage = "selectedLanguage"
    static let preferredAppLanguage = "preferredAppLanguage"
    static let updateChannel = "updateChannel"

    // MARK: - Audio Device
    static let selectedInputDeviceUID = "selectedInputDeviceUID"
    static let inputDevicePriorityList = "inputDevicePriorityList"

    // MARK: - Home / Setup
    static let setupWizardCompleted = "setupWizardCompleted"
    static let setupWizardCurrentStep = "setupWizardCurrentStep"

    // MARK: - Dictionary
    static let activatedTermPackStates = "activatedTermPackStates"
    static let termPackRegistryLastUpdateCheck = "termPackRegistryLastUpdateCheck"
    /// Optional user-configured remote registry; when unset, the bundled snapshot is used.
    static let termPackRegistryURL = "termPackRegistryURL"
    static let selectedIndustryPreset = "selectedIndustryPreset"

    // MARK: - History
    static let historyEnabled = "historyEnabled"
    static let historyRetentionDays = "historyRetentionDays"
    static let saveAudioWithHistory = "saveAudioWithHistory"

    // MARK: - Notch Indicator
    static let overlayPosition = "overlayPosition"
    static let notchIndicatorVisibility = "notchIndicatorVisibility"
    static let notchIndicatorLeftContent = "notchIndicatorLeftContent"
    static let notchIndicatorRightContent = "notchIndicatorRightContent"
    static let notchIndicatorDisplay = "notchIndicatorDisplay"

    // MARK: - Appearance
    static let showMenuBarIcon = "showMenuBarIcon"
    static let dockIconBehaviorWhenMenuBarHidden = "dockIconBehaviorWhenMenuBarHidden"
    static let menuBarIconHiddenAlertShown = "menuBarIconHiddenAlertShown"

    // MARK: - Formatting
    static let appFormattingEnabled = "appFormattingEnabled"
    static let transcriptionNumberNormalizationEnabled = "transcriptionNumberNormalizationEnabled"
    static let dictationPunctuationProfiles = "dictationPunctuationProfiles"

    // MARK: - Recorder
    static let recorderMicEnabled = "recorderMicEnabled"
    static let recorderSystemAudioEnabled = "recorderSystemAudioEnabled"
    static let recorderOutputFormat = "recorderOutputFormat"
    static let recorderOutputDirectory = "recorderOutputDirectory"
    static let recorderTranscriptionEnabled = "recorderTranscriptionEnabled"
    static let recorderLivePreviewEnabled = "recorderLivePreviewEnabled"
    static let recorderTranscriptionEngine = "recorderTranscriptionEngine"
    static let recorderTranscriptionModel = "recorderTranscriptionModel"
    static let recorderMicDuckingMode = "recorderMicDuckingMode"
    static let recorderTrackMode = "recorderTrackMode"

    // MARK: - File Transcription
    static let fileTranscriptionEngine = "fileTranscriptionEngine"
    static let fileTranscriptionModel = "fileTranscriptionModel"
    static let fileTranscriptionLanguage = "fileTranscriptionLanguage"

    // MARK: - Dictation Recovery
    static let dictationRecoveryEngine = "dictationRecoveryEngine"
    static let dictationRecoveryModel = "dictationRecoveryModel"
    static let dictationRecoveryLanguage = "dictationRecoveryLanguage"

}
