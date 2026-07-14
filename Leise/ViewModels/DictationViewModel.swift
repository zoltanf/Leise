import AppKit
import ApplicationServices
import Foundation
import Combine
import os
import LeiseCore

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "leise-mac", category: "DictationViewModel")

@MainActor
enum DictationLanguageResolver {
    static func resolve(
        profile: Profile?,
        globalLanguageSelection: LanguageSelection
    ) -> LanguageSelection {
        if let profile {
            let profileSelection = profile.inputLanguageSelection
            if profileSelection != .inheritGlobal {
                return profileSelection
            }
        }

        return globalLanguageSelection
    }
}

/// Orchestrates the dictation flow: recording → transcription → text insertion.
@MainActor
final class DictationViewModel: ObservableObject {
    private struct FinalTranscriptionOutput {
        let result: TranscriptionResult
        let modelId: String?
        let modelDisplayName: String?
    }

    enum State: Equatable {
        case idle
        case recording
        case processing
        case inserting
        case error(String)
    }

    private enum CancelWarningTarget {
        case recording
        case processing
    }

    @Published var state: State = .idle {
        didSet { clearCancelWarningIfStateNoLongerMatches() }
    }
    @Published var audioLevel: Float = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published var hotkeyMode: HotkeyService.HotkeyMode?
    @Published var partialText: String = ""
    @Published var isStreaming: Bool = false
    @Published var audioDuckingEnabled: Bool {
        didSet { UserDefaults.standard.set(audioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled) }
    }
    @Published var audioDuckingLevel: Double {
        didSet { UserDefaults.standard.set(audioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel) }
    }
    @Published var soundFeedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(soundFeedbackEnabled, forKey: UserDefaultsKeys.soundFeedbackEnabled) }
    }
    @Published var indicatorTranscriptPreviewEnabled: Bool {
        didSet { Self.persistIndicatorTranscriptPreviewEnabled(indicatorTranscriptPreviewEnabled) }
    }
    @Published var indicatorTranscriptPreviewFontSizeOffset: Int {
        didSet {
            let clampedOffset = Self.clampedIndicatorTranscriptPreviewFontSizeOffset(indicatorTranscriptPreviewFontSizeOffset)
            if clampedOffset != indicatorTranscriptPreviewFontSizeOffset {
                indicatorTranscriptPreviewFontSizeOffset = clampedOffset
                return
            }

            Self.persistIndicatorTranscriptPreviewFontSizeOffset(clampedOffset)
        }
    }
    @Published var preserveClipboard: Bool {
        didSet { UserDefaults.standard.set(preserveClipboard, forKey: UserDefaultsKeys.preserveClipboard) }
    }
    @Published var mediaPauseEnabled: Bool {
        didSet { UserDefaults.standard.set(mediaPauseEnabled, forKey: UserDefaultsKeys.mediaPauseEnabled) }
    }
    @Published var transcribeShortQuietClipsAggressively: Bool {
        didSet { Self.persistTranscribeShortQuietClipsAggressively(transcribeShortQuietClipsAggressively) }
    }
    @Published var microphoneBoostEnabled: Bool {
        didSet {
            Self.persistMicrophoneBoostEnabled(microphoneBoostEnabled)
            applyEffectiveMicrophoneBoostToAudioService()
        }
    }
    @Published private(set) var lastTranscribedText: String?
    @Published private(set) var lastTranscriptionLanguage: String?
    @Published var hotkeyLabelsVersion = 0
    var hybridHotkeyLabel: String { Self.loadHotkeyLabel(for: .hybrid) }
    var pttHotkeyLabel: String { Self.loadHotkeyLabel(for: .pushToTalk) }
    var toggleHotkeyLabel: String { Self.loadHotkeyLabel(for: .toggle) }
    var recentTranscriptionsHotkeyLabel: String { Self.loadHotkeyLabel(for: .recentTranscriptions) }
    var copyLastTranscriptionHotkeyLabel: String { Self.loadHotkeyLabel(for: .copyLastTranscription) }
    var recorderToggleHotkeyLabel: String { Self.loadHotkeyLabel(for: .recorderToggle) }
    @Published var activeRuleName: String?
    @Published var activeRuleReasonLabel: String?
    @Published var activeRuleExplanation: String?
    @Published var processingPhase: String?
    @Published private(set) var isRecordingInputReady = false
    @Published var actionFeedbackMessage: String?
    @Published var actionFeedbackIcon: String?
    @Published var actionFeedbackIsError: Bool = false
    @Published var actionFeedbackUndoTitle: String?
    @Published var activeAppIcon: NSImage?
    private var actionDisplayDuration: TimeInterval = 3.5

    @Published var indicatorStyle: IndicatorStyle {
        didSet { Self.persistIndicatorStyle(indicatorStyle) }
    }

    @Published var notchIndicatorVisibility: NotchIndicatorVisibility {
        didSet { UserDefaults.standard.set(notchIndicatorVisibility.rawValue, forKey: UserDefaultsKeys.notchIndicatorVisibility) }
    }

    @Published var notchIndicatorLeftContent: NotchIndicatorContent {
        didSet { UserDefaults.standard.set(notchIndicatorLeftContent.rawValue, forKey: UserDefaultsKeys.notchIndicatorLeftContent) }
    }

    @Published var notchIndicatorRightContent: NotchIndicatorContent {
        didSet { UserDefaults.standard.set(notchIndicatorRightContent.rawValue, forKey: UserDefaultsKeys.notchIndicatorRightContent) }
    }

    @Published var notchIndicatorDisplay: NotchIndicatorDisplay {
        didSet { UserDefaults.standard.set(notchIndicatorDisplay.rawValue, forKey: UserDefaultsKeys.notchIndicatorDisplay) }
    }

    @Published var overlayPosition: OverlayPosition {
        didSet { UserDefaults.standard.set(overlayPosition.rawValue, forKey: UserDefaultsKeys.overlayPosition) }
    }

    private let audioRecordingService: AudioRecordingService
    private let textInsertionService: TextInsertionService
    private let hotkeyService: HotkeyService
    private let modelManager: ModelManagerService
    private let settingsViewModel: SettingsViewModel
    private let historyService: HistoryService
    private let usageStatisticsRecorder: UsageStatisticsRecording?
    private let recentTranscriptionStore: RecentTranscriptionStore
    private let profileService: ProfileService
    private let audioDuckingService: AudioDuckingService
    private let dictionaryService: DictionaryService
    private let soundService: SoundService
    private let audioDeviceService: AudioDeviceService
    private let accessibilityAnnouncementService: AccessibilityAnnouncementService
    private let errorLogService: ErrorLogService
    private let mediaPlaybackService: MediaPlaybackService
    private let postProcessingPipeline: PostProcessingPipeline
    private var matchedProfile: Profile?
    private var activeProfileMatch: RuleMatchResult?
    private var forcedProfileId: UUID?
    private var capturedActiveApp: (name: String?, bundleId: String?, url: String?)?
    private var capturedSelectedText: String?

    private var cancellables = Set<AnyCancellable>()
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private let streamingHandler: StreamingHandler
    private let recentTranscriptionPaletteHandler: RecentTranscriptionPaletteHandler
    private let settingsHandler: DictationSettingsHandler
    private var transcriptionTask: Task<Void, Never>?
    private var stopFinalizationTask: Task<Void, Never>?
    private var errorResetTask: Task<Void, Never>?
    private var insertingResetTask: Task<Void, Never>?
    @Published private var cancelWarningTarget: CancelWarningTarget?
    private var urlResolutionTask: Task<Void, Never>?
    private var metadataCaptureTask: Task<Void, Never>?
    var pasteboardProvider: () -> NSPasteboard = { .general }
    /// Snapshot of the streaming params used in the most recent `streamingHandler.start(...)`.
    /// Used to detect when an on-the-fly rule refinement (e.g. browser URL resolution)
    /// changes the effective engine/language selection/task/cloud-model so the live
    /// session can be restarted and stay consistent with the final transcription
    /// (release review K3).
    private struct StreamingParamsSnapshot: Equatable {
        let engineOverrideId: String?
        let providerId: String?
        let languageSelection: LanguageSelection
        let task: TranscriptionTask
        let cloudModelOverride: String?
        let normalizeNumbers: Bool?
    }
    private var lastStreamingParams: StreamingParamsSnapshot?
    private var isStopInFlight = false
    private var activeDictationSessionID: UUID?
    private var pendingPushToTalkDiscardMessage: String?
    private var recordingStartCuePending = false
    private var firstRecordingAudioBufferSeen = false
    private var recordingStartContextReady = false
    private var shouldPlayRecordingStartSoundWhenReady = false
    private var pendingRecordingAudioDuckingLevel: Float?
    private var pendingRecordingAudioDuckingTask: Task<Void, Never>?

    var cancelWarningMessage: String? {
        switch (state, cancelWarningTarget) {
        case (.recording, .recording):
            return String(localized: "Press Esc again to cancel recording")
        case (.processing, .processing):
            return String(localized: "Press Esc again to cancel transcription")
        default:
            return nil
        }
    }

    init(
        audioRecordingService: AudioRecordingService,
        textInsertionService: TextInsertionService,
        hotkeyService: HotkeyService,
        modelManager: ModelManagerService,
        settingsViewModel: SettingsViewModel,
        historyService: HistoryService,
        recentTranscriptionStore: RecentTranscriptionStore,
        profileService: ProfileService,
        audioDuckingService: AudioDuckingService,
        dictionaryService: DictionaryService,
        soundService: SoundService,
        audioDeviceService: AudioDeviceService,
        appFormatterService: AppFormatterService,
        punctuationStrategyResolver: PunctuationStrategyResolver,
        speechPunctuationService: SpeechPunctuationService,
        accessibilityAnnouncementService: AccessibilityAnnouncementService,
        errorLogService: ErrorLogService,
        mediaPlaybackService: MediaPlaybackService,
        postProcessors: [any TextPostProcessor] = [],
        usageStatisticsRecorder: UsageStatisticsRecording? = nil
    ) {
        self.audioRecordingService = audioRecordingService
        self.textInsertionService = textInsertionService
        self.hotkeyService = hotkeyService
        self.modelManager = modelManager
        self.settingsViewModel = settingsViewModel
        self.historyService = historyService
        self.usageStatisticsRecorder = usageStatisticsRecorder
        self.recentTranscriptionStore = recentTranscriptionStore
        self.profileService = profileService
        self.audioDuckingService = audioDuckingService
        self.dictionaryService = dictionaryService
        self.soundService = soundService
        self.audioDeviceService = audioDeviceService
        self.accessibilityAnnouncementService = accessibilityAnnouncementService
        self.errorLogService = errorLogService
        self.mediaPlaybackService = mediaPlaybackService
        self.postProcessingPipeline = PostProcessingPipeline(
            dictionaryService: dictionaryService,
            appFormatterService: appFormatterService,
            speechPunctuationService: speechPunctuationService,
            punctuationStrategyResolver: punctuationStrategyResolver,
            postProcessors: postProcessors
        )
        self.streamingHandler = StreamingHandler(
            modelManager: modelManager,
            recentBufferProvider: { [weak audioRecordingService] maxDuration in
                audioRecordingService?.getRecentBuffer(maxDuration: maxDuration) ?? []
            }
        )
        self.recentTranscriptionPaletteHandler = RecentTranscriptionPaletteHandler(
            textInsertionService: textInsertionService,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore
        )
        self.settingsHandler = DictationSettingsHandler(
            hotkeyService: hotkeyService,
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            profileService: profileService
        )
        self.audioDuckingEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.audioDuckingEnabled)
        self.audioDuckingLevel = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingLevel) as? Double ?? 0.2
        self.soundFeedbackEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.soundFeedbackEnabled) as? Bool ?? true
        self.indicatorTranscriptPreviewEnabled = Self.loadIndicatorTranscriptPreviewEnabled()
        self.indicatorTranscriptPreviewFontSizeOffset = Self.loadIndicatorTranscriptPreviewFontSizeOffset()
        self.preserveClipboard = UserDefaults.standard.bool(forKey: UserDefaultsKeys.preserveClipboard)
        self.mediaPauseEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.mediaPauseEnabled)
        self.transcribeShortQuietClipsAggressively = Self.loadTranscribeShortQuietClipsAggressively()
        self.microphoneBoostEnabled = Self.loadMicrophoneBoostEnabled()
        self.indicatorStyle = Self.loadIndicatorStyle()
        self.notchIndicatorVisibility = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorVisibility)
            .flatMap { NotchIndicatorVisibility(rawValue: $0) } ?? .duringActivity
        self.notchIndicatorLeftContent = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorLeftContent)
            .flatMap { NotchIndicatorContent(rawValue: $0) } ?? .timer
        self.notchIndicatorRightContent = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorRightContent)
            .flatMap { NotchIndicatorContent(rawValue: $0) } ?? .waveform
        self.notchIndicatorDisplay = UserDefaults.standard.string(forKey: UserDefaultsKeys.notchIndicatorDisplay)
            .flatMap { NotchIndicatorDisplay(rawValue: $0) } ?? .activeScreen
        self.overlayPosition = UserDefaults.standard.string(forKey: UserDefaultsKeys.overlayPosition)
            .flatMap { OverlayPosition(rawValue: $0) } ?? .bottom
        audioRecordingService.microphoneBoostEnabled = microphoneBoostEnabled

        setupBindings()

        streamingHandler.onPartialTextUpdate = { [weak self] text in
            guard let self else { return }
            if self.partialText != text {
                if self.partialText.isEmpty,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PerformanceMilestones.firstTranscriptPreview()
                }
                self.partialText = text
            }
        }
        streamingHandler.onStreamingStateChange = { [weak self] streaming in
            self?.isStreaming = streaming
        }
        audioRecordingService.onFirstRecordingAudioBuffer = { [weak self] in
            self?.handleFirstRecordingAudioBuffer()
        }

        recentTranscriptionPaletteHandler.onShowNotchFeedback = { [weak self] message, icon, duration, isError, category in
            self?.showNotchFeedback(message: message, icon: icon, duration: duration, isError: isError, errorCategory: category ?? "general")
        }
        recentTranscriptionPaletteHandler.getPreserveClipboard = { [weak self] in
            self?.preserveClipboard ?? false
        }

        settingsHandler.onObjectWillChange = { [weak self] in
            self?.objectWillChange.send()
        }
        settingsHandler.onHotkeyLabelsChanged = { [weak self] in
            self?.hotkeyLabelsVersion += 1
        }
        hotkeyService.discardPushToTalkRecordingOnExtraKeyPress = true
    }

    var canDictate: Bool {
        modelManager.canTranscribe
    }

    nonisolated static func loadIndicatorTranscriptPreviewEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled) as? Bool ?? true
    }

    nonisolated static func persistIndicatorTranscriptPreviewEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled)
    }

    nonisolated static func loadIndicatorTranscriptPreviewFontSizeOffset(defaults: UserDefaults = .standard) -> Int {
        guard let storedValue = defaults.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset) else {
            return 0
        }

        guard let number = storedValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return 0
        }

        return Self.clampedIndicatorTranscriptPreviewFontSizeOffset(number.intValue)
    }

    nonisolated static func persistIndicatorTranscriptPreviewFontSizeOffset(_ offset: Int, defaults: UserDefaults = .standard) {
        defaults.set(Self.clampedIndicatorTranscriptPreviewFontSizeOffset(offset), forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset)
    }

    nonisolated static func loadIndicatorStyle(defaults: UserDefaults = .standard) -> IndicatorStyle {
        defaults.string(forKey: UserDefaultsKeys.indicatorStyle)
            .flatMap { IndicatorStyle(rawValue: $0) } ?? .notch
    }

    nonisolated static func persistIndicatorStyle(_ style: IndicatorStyle, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: UserDefaultsKeys.indicatorStyle)
    }

    nonisolated static func loadTranscribeShortQuietClipsAggressively(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively) as? Bool ?? true
    }

    nonisolated static func persistTranscribeShortQuietClipsAggressively(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively)
    }

    nonisolated static func loadMicrophoneBoostEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.microphoneBoostEnabled) as? Bool ?? false
    }

    nonisolated static func persistMicrophoneBoostEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: UserDefaultsKeys.microphoneBoostEnabled)
    }

    nonisolated static func indicatorTranscriptPreviewFontSize(for style: IndicatorStyle, offset: Int) -> CGFloat {
        style.transcriptPreviewBaseFontSize + CGFloat(Self.clampedIndicatorTranscriptPreviewFontSizeOffset(offset))
    }

    nonisolated static func indicatorTranscriptPreviewExpandedHeight(for style: IndicatorStyle, offset: Int) -> CGFloat {
        let fontSize = Self.indicatorTranscriptPreviewFontSize(for: style, offset: offset)
        return style.scaledTranscriptPreviewMetric(style.transcriptPreviewBaseExpandedHeight, fontSize: fontSize)
    }

    func indicatorTranscriptPreviewFontSize(for style: IndicatorStyle) -> CGFloat {
        Self.indicatorTranscriptPreviewFontSize(for: style, offset: indicatorTranscriptPreviewFontSizeOffset)
    }

    func indicatorTranscriptPreviewExpandedHeight(for style: IndicatorStyle) -> CGFloat {
        Self.indicatorTranscriptPreviewExpandedHeight(for: style, offset: indicatorTranscriptPreviewFontSizeOffset)
    }

    nonisolated private static func clampedIndicatorTranscriptPreviewFontSizeOffset(_ offset: Int) -> Int {
        min(max(offset, 0), 8)
    }

    nonisolated private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Double? {
        guard end >= start else { return nil }
        return Double(end - start) / 1_000_000
    }

    nonisolated private static func formatMilliseconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f", value)
    }

    var needsMicPermission: Bool {
        !audioRecordingService.hasMicrophonePermission
    }

    var needsAccessibilityPermission: Bool {
        !textInsertionService.isAccessibilityGranted
    }

    private func beginDictationSession(id: UUID) {
        activeDictationSessionID = id
    }

    private func completeDictationSession(id: UUID) {
        if activeDictationSessionID == id {
            activeDictationSessionID = nil
        }
    }

    private func failDictationSession(id: UUID, error _: String) {
        if activeDictationSessionID == id {
            activeDictationSessionID = nil
        }
    }

    private func cancelActiveDictationSessionIfNeeded(message: String = String(localized: "Cancelled")) {
        guard let sessionID = activeDictationSessionID else { return }
        failDictationSession(id: sessionID, error: message)
    }

    private func restoreRecordingSideEffects() {
        audioDuckingService.restoreAudio()
        mediaPlaybackService.resumeIfWePaused()
    }

    private func prepareRecordingStartCue(playsSound: Bool) {
        isRecordingInputReady = false
        recordingStartCuePending = true
        firstRecordingAudioBufferSeen = false
        recordingStartContextReady = false
        shouldPlayRecordingStartSoundWhenReady = playsSound
    }

    private func updateRecordingStartCuePayload(activeApp _: (name: String?, bundleId: String?, url: String?)?) {
        recordingStartContextReady = true
        emitRecordingStartCueIfReady()
    }

    private func handleFirstRecordingAudioBuffer() {
        PerformanceMilestones.firstRecordingAudioBuffer()
        firstRecordingAudioBufferSeen = true
        emitRecordingStartCueIfReady()
    }

    private func emitRecordingStartCueIfReady() {
        guard recordingStartCuePending,
              firstRecordingAudioBufferSeen,
              state == .recording,
              recordingStartContextReady else {
            return
        }

        recordingStartCuePending = false
        isRecordingInputReady = true
        if shouldPlayRecordingStartSoundWhenReady {
            let startSoundDuration = soundService.playbackDuration(for: .recordingStarted, enabled: soundFeedbackEnabled)
            if !soundService.play(.recordingStarted, enabled: soundFeedbackEnabled) {
                applyPendingRecordingAudioDuckingIfNeeded()
            } else {
                applyPendingRecordingAudioDuckingIfNeeded(after: startSoundDuration)
            }
        } else {
            applyPendingRecordingAudioDuckingIfNeeded()
        }
        accessibilityAnnouncementService.announceRecordingStarted()
    }

    private func applyPendingRecordingAudioDuckingIfNeeded(after delay: TimeInterval? = nil) {
        guard let level = pendingRecordingAudioDuckingLevel else { return }
        pendingRecordingAudioDuckingLevel = nil
        pendingRecordingAudioDuckingTask?.cancel()
        guard let delay, delay > 0 else {
            audioDuckingService.duckAudio(to: level)
            return
        }

        let nanoseconds = UInt64((delay * 1_000_000_000).rounded(.up))
        pendingRecordingAudioDuckingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.audioDuckingService.duckAudio(to: level)
            self?.pendingRecordingAudioDuckingTask = nil
        }
    }

    private func clearRecordingStartCueState(resetReadiness: Bool = true) {
        if resetReadiness {
            isRecordingInputReady = false
        }
        recordingStartCuePending = false
        firstRecordingAudioBufferSeen = false
        recordingStartContextReady = false
        shouldPlayRecordingStartSoundWhenReady = false
        pendingRecordingAudioDuckingLevel = nil
        pendingRecordingAudioDuckingTask?.cancel()
        pendingRecordingAudioDuckingTask = nil
    }

    private func clearDeferredRecordingContext() {
        metadataCaptureTask?.cancel()
        metadataCaptureTask = nil
        urlResolutionTask?.cancel()
        urlResolutionTask = nil
        lastStreamingParams = nil
    }

    private func abortActiveRecordingImmediately(sessionMessage: String, preserveRecoveryAudio: Bool = false) {
        clearRecordingStartCueState()
        clearDeferredRecordingContext()
        restoreRecordingSideEffects()
        streamingHandler.stop()
        stopRecordingTimer()
        Task {
            _ = await audioRecordingService.stopRecording(policy: .immediate)
            if preserveRecoveryAudio {
                audioRecordingService.preserveActiveRecoveryRecording()
            } else {
                audioRecordingService.discardActiveRecoveryRecording()
            }
        }
        cancelActiveDictationSessionIfNeeded(message: sessionMessage)
        hotkeyService.cancelDictation()
    }

    private func setupBindings() {
        hotkeyService.onDictationStart = { [weak self] requestTimestamp in
            guard let self else { return }
            PerformanceMilestones.dictationRequested()
            logger.info("hotkey→onDictationStart (state=\(String(describing: self.state), privacy: .public))")
            self.startRecording(requestUptimeNanoseconds: requestTimestamp)
        }

        hotkeyService.onDictationStop = { [weak self] in
            guard let self else { return }
            logger.info("hotkey→onDictationStop (state=\(String(describing: self.state), privacy: .public), stopInFlight=\(String(describing: self.isStopInFlight), privacy: .public))")
            self.stopDictation()
        }

        hotkeyService.onProfileDictationStart = { [weak self] profileId, requestTimestamp in
            self?.startRecording(forcedProfileId: profileId, requestUptimeNanoseconds: requestTimestamp)
        }

        hotkeyService.onCancelPressed = { [weak self] in
            self?.handleCancelHotkey()
        }

        hotkeyService.onPushToTalkInterruption = { [weak self] in
            self?.handlePushToTalkInterruption()
        }

        profileService.$profiles
            .dropFirst()
            .sink { [weak self] profiles in
                guard let self else { return }
                self.settingsHandler.syncProfileHotkeys(profiles)
            }
            .store(in: &cancellables)

        audioRecordingService.$audioLevel
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
            .store(in: &cancellables)

        // When the recovery coordinator's circuit breaker gives up mid-session,
        // `AudioRecordingService` publishes the terminal error here. Surface
        // it to the UI and unwind the dictation session cleanly — restore
        // ducking, resume media, stop streaming, cancel the session.
        audioRecordingService.$recoveryError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                // Always drain the publisher so `recoveryError` never lingers
                // on `AudioRecordingService`, even when the session is no
                // longer active (stop-in-flight, already processed, etc.).
                defer { self.audioRecordingService.clearRecoveryError() }
                guard self.state == .recording, !self.isStopInFlight else { return }
                let errorMessage = error.localizedDescription
                self.abortActiveRecordingImmediately(sessionMessage: errorMessage, preserveRecoveryAudio: true)
                self.accessibilityAnnouncementService.announceError(errorMessage)
                self.showError(errorMessage, category: "recording")
            }
            .store(in: &cancellables)

        hotkeyService.$currentMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.hotkeyMode = mode
            }
            .store(in: &cancellables)

        audioDeviceService.$disconnectedDeviceName
            .compactMap { $0 }
            .sink { [weak self] _ in
                guard let self, self.state == .recording, !self.isStopInFlight else { return }
                let errorMessage = String(localized: "Microphone disconnected")
                self.abortActiveRecordingImmediately(sessionMessage: errorMessage)
                self.showNotchFeedback(
                    message: errorMessage,
                    icon: "mic.slash",
                    duration: 3.0,
                    isError: true,
                    errorCategory: "recording"
                )
            }
            .store(in: &cancellables)
    }

    func handleCancelHotkey() {
        guard let target = cancelWarningTargetForCurrentState() else { return }

        if cancelWarningTarget == target {
            clearCancelWarning()
            cancelCurrentOperation()
        } else {
            cancelWarningTarget = target
        }
    }

    private func cancelWarningTargetForCurrentState() -> CancelWarningTarget? {
        switch state {
        case .recording:
            return .recording
        case .processing:
            return .processing
        default:
            return nil
        }
    }

    private func clearCancelWarningIfStateNoLongerMatches() {
        guard let cancelWarningTarget,
              cancelWarningTargetForCurrentState() != cancelWarningTarget else {
            return
        }
        self.cancelWarningTarget = nil
    }

    private func clearCancelWarning() {
        cancelWarningTarget = nil
    }

    private func cancelCurrentOperation() {
        let cancelledMessage = String(localized: "Cancelled")
        clearCancelWarning()

        switch state {
        case .recording:
            guard !isStopInFlight else { return }
            abortActiveRecordingImmediately(sessionMessage: cancelledMessage)
            showNotchFeedback(message: cancelledMessage, icon: "xmark.circle", duration: 1.5)
        case .processing:
            cancelActiveDictationSessionIfNeeded(message: cancelledMessage)
            stopFinalizationTask?.cancel()
            stopFinalizationTask = nil
            streamingHandler.stop()
            lastStreamingParams = nil
            transcriptionTask?.cancel()
            transcriptionTask = nil
            audioRecordingService.discardActiveRecoveryRecording()
            showNotchFeedback(message: cancelledMessage, icon: "xmark.circle", duration: 1.5)
        default:
            break
        }
    }

    private func startRecording(
        forcedProfileId: UUID? = nil,
        sessionID: UUID = UUID(),
        requestUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard state == .idle else {
            logger.warning("startRecording rejected: state=\(String(describing: self.state), privacy: .public); resetting hotkey state")
            hotkeyService.cancelDictation()
            return
        }

        let startTimestamp = CFAbsoluteTimeGetCurrent()
        clearRecordingStartCueState()

        // Cancel any pending transcription from a previous recording
        if transcriptionTask != nil {
            cancelActiveDictationSessionIfNeeded()
        }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        clearPendingUndoActionFeedback()
        insertingResetTask?.cancel()
        insertingResetTask = nil
        clearCancelWarning()
        pendingPushToTalkDiscardMessage = nil
        metadataCaptureTask?.cancel()
        metadataCaptureTask = nil
        urlResolutionTask?.cancel()
        urlResolutionTask = nil

        self.forcedProfileId = forcedProfileId
        beginDictationSession(id: sessionID)

        guard canDictate else {
            let errorMessage = TranscriptionEngineError.modelNotLoaded.localizedDescription
            logger.warning("startRecording rejected: canDictate=false; resetting hotkey state")
            failDictationSession(id: sessionID, error: errorMessage)
            showError(errorMessage, category: "recording")
            // Resync the hotkey toggle: HotkeyService already flipped isActive=true
            // before invoking onDictationStart. Without this, a rejected start leaves
            // the toggle stuck "active", so the next press is consumed as a phantom
            // stop and every subsequent start/stop needs an extra press.
            hotkeyService.cancelDictation()
            return
        }

        guard audioRecordingService.hasMicrophonePermission else {
            let errorMessage = "Microphone permission required."
            logger.warning("startRecording rejected: microphone permission missing; resetting hotkey state")
            failDictationSession(id: sessionID, error: errorMessage)
            showError(errorMessage, category: "recording")
            hotkeyService.cancelDictation()
            return
        }

        let resolvedInputSelection = audioDeviceService.resolvedRecordingInputSelection()

        do {
            let initialForcedProfile = forcedProfile(for: forcedProfileId)
            audioRecordingService.microphoneBoostEnabled = microphoneBoostEnabled
            audioRecordingService.selectedDeviceID = resolvedInputSelection.deviceID
            audioRecordingService.hasExplicitDeviceSelection = resolvedInputSelection.hasExplicitDeviceSelection
            let selectedInputUsesBluetooth = resolvedInputSelection.usesBluetoothTransport
            audioRecordingService.selectedInputDeviceUsesBluetoothTransport = selectedInputUsesBluetooth
            prepareRecordingStartCue(playsSound: !selectedInputUsesBluetooth)
            let audioStartTimestamp = DispatchTime.now().uptimeNanoseconds
            try PerformanceMilestones.measure(.audioStart) {
                try audioRecordingService.startRecording(requestUptimeNanoseconds: requestUptimeNanoseconds)
            }
            let audioStartCompletedTimestamp = DispatchTime.now().uptimeNanoseconds
            let audioStartMs = Self.elapsedMilliseconds(
                from: audioStartTimestamp,
                to: audioStartCompletedTimestamp
            )
            let requestToAudioStartMs = Self.elapsedMilliseconds(
                from: requestUptimeNanoseconds,
                to: audioStartCompletedTimestamp
            )
            recentTranscriptionPaletteHandler.hide()
            modelManager.cancelAutoUnloadTimer()
            if selectedInputUsesBluetooth {
                logger.info("Skipping recording start sound for Bluetooth input device")
            }
            if mediaPauseEnabled { mediaPlaybackService.pauseIfPlaying() }
            if audioDuckingEnabled {
                pendingRecordingAudioDuckingLevel = max(0, min(1, Float(audioDuckingLevel)))
            } else {
                pendingRecordingAudioDuckingLevel = nil
            }
            state = .recording
            // Reset hotkey timer so hybrid threshold counts from recording start,
            // not from key press. Slow device init (e.g. iPhone Continuity ~2-3s)
            // would otherwise make the hold appear as "long press" → PTT stop.
            hotkeyService.resetKeyDownTime()
            partialText = ""
            isStopInFlight = false
            recordingStartTime = Date()
            startRecordingTimer()

            let contextStartTimestamp = CFAbsoluteTimeGetCurrent()
            // Match rule after the audio engine is live so app/context lookup does
            // not delay capture of the user's first spoken words.
            let activeApp = textInsertionService.captureActiveApp()
            capturedActiveApp = activeApp
            capturedSelectedText = nil
            activeAppIcon = nil

            if let initialForcedProfile {
                applyProfileMatch(profileService.forcedRuleMatch(for: initialForcedProfile), activeApp: activeApp)
            } else if let profileMatch = profileService.matchRule(bundleIdentifier: activeApp.bundleId, url: nil) {
                applyProfileMatch(profileMatch, activeApp: activeApp)
            } else {
                clearActiveRuleState()
            }
            applyEffectiveMicrophoneBoostToAudioService()
            updateRecordingStartCuePayload(activeApp: activeApp)
            let contextMs = (CFAbsoluteTimeGetCurrent() - contextStartTimestamp) * 1000

            modelManager.prepareForDictation(
                engineOverrideId: effectiveEngineOverrideId,
                modelOverrideId: effectiveCloudModelOverride
            )
            startLiveStreaming(allowLiveTranscription: indicatorTranscriptPreviewEnabled)
            scheduleDeferredRecordingMetadataCapture(
                activeApp: activeApp,
                forcedProfileId: forcedProfileId
            )

            let totalStartMs = (CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000
            logger.info(
                "Recording started: requestToAudioStartMs=\(Self.formatMilliseconds(requestToAudioStartMs), privacy: .public), audioStartMs=\(Self.formatMilliseconds(audioStartMs), privacy: .public), contextMs=\(String(format: "%.1f", contextMs), privacy: .public), totalStartMs=\(String(format: "%.1f", totalStartMs), privacy: .public)"
            )
        } catch {
            clearRecordingStartCueState()
            clearDeferredRecordingContext()
            restoreRecordingSideEffects()
            let errorMessage: String
            if let recordingError = error as? AudioRecordingService.AudioRecordingError,
               case .noMicrophoneDetected = recordingError {
                errorMessage = String(localized: "No mic detected.")
            } else if let recordingError = error as? AudioRecordingService.AudioRecordingError,
                      case .selectedInputDeviceIncompatible(let issue) = recordingError {
                audioDeviceService.markRecordingInputSelectionCompatibility(
                    .incompatible(issue),
                    selection: resolvedInputSelection
                )
                errorMessage = recordingError.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
            accessibilityAnnouncementService.announceError(errorMessage)
            failDictationSession(id: sessionID, error: errorMessage)
            showError(errorMessage, category: "recording")
            hotkeyService.cancelDictation()
        }
    }

    private func scheduleDeferredRecordingMetadataCapture(
        activeApp: (name: String?, bundleId: String?, url: String?),
        forcedProfileId: UUID?
    ) {
        let metadataStartTimestamp = CFAbsoluteTimeGetCurrent()

        metadataCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let selectedText = textInsertionService.getSelectedText()
            guard !Task.isCancelled else { return }
            capturedSelectedText = selectedText
            if let selectedText {
                logger.info("Captured selected text (\(selectedText.count) chars)")
            }

            if let bundleId = activeApp.bundleId,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                activeAppIcon = NSWorkspace.shared.icon(forFile: appURL.path)
            } else {
                activeAppIcon = nil
            }

            let elapsedMs = (CFAbsoluteTimeGetCurrent() - metadataStartTimestamp) * 1000
            logger.info("Deferred recording metadata captured in \(String(format: "%.1f", elapsedMs), privacy: .public)ms")
        }

        // Resolve browser URL asynchronously after recording has already started.
        // If a more specific URL profile matches, update the active rule on the fly.
        // Skip URL resolution when a forced profile is set (manual shortcut overrides app matching).
        guard forcedProfileId == nil, let bundleId = activeApp.bundleId else { return }
        urlResolutionTask = Task { [weak self] in
            guard let self else { return }
            logger.info("URL resolution: starting for bundleId=\(bundleId)")
            let resolvedURL = await textInsertionService.resolveBrowserURL(bundleId: bundleId)
            logger.info("URL resolution: resolvedURL=\(resolvedURL ?? "nil"), state=\(String(describing: self.state))")
            guard state == .recording || state == .processing else {
                logger.info("URL resolution: skipped - state is \(String(describing: self.state))")
                return
            }
            guard let currentApp = capturedActiveApp, currentApp.bundleId == bundleId else {
                logger.info("URL resolution: skipped - bundleId mismatch")
                return
            }

            capturedActiveApp = (name: currentApp.name, bundleId: currentApp.bundleId, url: resolvedURL)

            guard let resolvedURL else {
                logger.info("URL resolution: no URL resolved")
                return
            }

            if let profileMatch = profileService.matchRule(bundleIdentifier: bundleId, url: resolvedURL) {
                logger.info("URL resolution: matched profile '\(profileMatch.profile.name)'")
                applyProfileMatch(profileMatch, activeApp: capturedActiveApp)
                refreshLiveStreamingIfParamsChanged()
                return
            }

            logger.info("URL resolution: no profile matched for URL \(resolvedURL)")
        }
    }

    private var effectiveLanguageSelection: LanguageSelection {
        DictationLanguageResolver.resolve(
            profile: matchedProfile,
            globalLanguageSelection: settingsViewModel.languageSelection
        )
    }

    private var effectiveTask: TranscriptionTask {
        .transcribe
    }

    private var effectiveEngineOverrideId: String? {
        nonEmpty(matchedProfile?.engineOverride)
    }

    private var effectiveCloudModelOverride: String? {
        effectiveEngineOverrideId == nil ? nil : nonEmpty(matchedProfile?.cloudModelOverride)
    }

    private var effectiveMicrophoneBoostEnabled: Bool {
        microphoneBoostEnabled
    }

    private var effectiveOutputFormat: String? {
        nonEmpty(matchedProfile?.outputFormat)
    }

    private func resolvedEffectiveOutputFormat(
        for activeApp: (name: String?, bundleId: String?, url: String?)
    ) -> String? {
        effectiveOutputFormat
    }

    private var effectiveNumberNormalizationOverride: Bool? {
        nil
    }

    private var effectiveAutoEnterEnabled: Bool {
        matchedProfile?.autoEnterEnabled ?? false
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func stopDictation() {
        guard state == .recording, !isStopInFlight else { return }
        clearCancelWarning()
        isStopInFlight = true
        state = .processing
        processingPhase = String(localized: "Processing...")
        stopFinalizationTask = Task { [weak self] in
            guard let self else { return }
            await finalizeStopDictation()
        }
    }

    private func finalizeStopDictation() async {
        defer {
            if Task.isCancelled {
                isStopInFlight = false
            }
            stopFinalizationTask = nil
        }
        let sessionID = activeDictationSessionID

        clearRecordingStartCueState(resetReadiness: false)
        restoreRecordingSideEffects()
        if let discardMessage = pendingPushToTalkDiscardMessage {
            pendingPushToTalkDiscardMessage = nil
            streamingHandler.stop()
            lastStreamingParams = nil
            stopRecordingTimer()
            _ = await audioRecordingService.stopRecording(policy: .immediate)
            audioRecordingService.discardActiveRecoveryRecording()
            if let sessionID {
                failDictationSession(id: sessionID, error: discardMessage)
            }
            showNotchFeedback(
                message: discardMessage,
                icon: "xmark.circle",
                duration: 1.8
            )
            return
        }

        let stopStart = CFAbsoluteTimeGetCurrent()
        func stopElapsedMs() -> String { String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - stopStart) * 1000) }

        lastStreamingParams = nil
        stopRecordingTimer()
        let previewText = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stopPolicy = AudioRecordingService.StopPolicy.finalizeShortSpeech()
        var samples = await audioRecordingService.stopRecording(policy: stopPolicy)
        guard !Task.isCancelled else { return }
        logger.info("Stop timing: stopRecording done elapsedMs=\(stopElapsedMs(), privacy: .public), previewTextLength=\(previewText.count, privacy: .public)")
        let liveSessionResultBeforePreviewFallback = await streamingHandler.finish()
        guard !Task.isCancelled else { return }
        logger.info("Stop timing: streamingHandler.finish done elapsedMs=\(stopElapsedMs(), privacy: .public), resultTextLength=\(liveSessionResultBeforePreviewFallback?.text.count ?? -1, privacy: .public)")
        let liveSessionResult = liveSessionResultBeforePreviewFallback.map {
            StreamingHandler.resultPreferringStablePreviewIfNeeded($0, stablePreview: previewText)
        }
        let hasPreviewText = !previewText.isEmpty

        let peakLevel = audioRecordingService.peakRawAudioLevel
        let rawDuration = Double(samples.count) / AudioRecordingService.targetSampleRate
        let hasConfirmedText = hasConfirmedTranscriptionResultText(liveSessionResult)
        let decision = classifyShortSpeech(
            rawDuration: rawDuration,
            peakLevel: peakLevel,
            hasConfirmedText: hasConfirmedText,
            transcribeShortQuietClipsAggressively: transcribeShortQuietClipsAggressively
        )
        let graceApplied = audioRecordingService.lastStopGraceCaptureApplied

        logger.info(
            "Stop finalized: rawDuration=\(String(format: "%.3f", rawDuration), privacy: .public)s, bufferedSamples=\(samples.count), peakLevel=\(String(format: "%.4f", peakLevel), privacy: .public), hasPreviewText=\(hasPreviewText, privacy: .public), previewTextLength=\(previewText.count, privacy: .public), hasConfirmedText=\(hasConfirmedText, privacy: .public), stopPolicy=\(stopPolicy.logDescription, privacy: .public), graceApplied=\(graceApplied, privacy: .public), decision=\(decision.logDescription, privacy: .public)"
        )

        switch decision {
        case .discardTooShort:
            audioRecordingService.discardActiveRecoveryRecording()
            let errorMessage = String(localized: "Too short, hold the hotkey a bit longer")
            if let sessionID {
                failDictationSession(id: sessionID, error: errorMessage)
            }
            showNotchFeedback(
                message: errorMessage,
                icon: "waveform.badge.exclamationmark",
                duration: 1.8
            )
            return
        case .discardNoSpeech:
            audioRecordingService.discardActiveRecoveryRecording()
            logger.info("Peak level too low (\(String(format: "%.4f", peakLevel))) - no speech detected")
            let errorMessage = String(localized: "No speech detected")
            if let sessionID {
                failDictationSession(id: sessionID, error: errorMessage)
            }
            showNotchFeedback(
                message: errorMessage,
                icon: "mic.slash",
                duration: 2.0
            )
            return
        case .transcribe:
            break
        }

        samples = paddedSamplesForFinalTranscription(samples, rawDuration: rawDuration)

        let saveAudio = UserDefaults.standard.bool(forKey: UserDefaultsKeys.saveAudioWithHistory)
        let audioSamplesForHistory: [Float]? = saveAudio ? samples : nil

        let audioDuration = Double(samples.count) / AudioRecordingService.targetSampleRate
        processingPhase = liveSessionResult == nil
            ? String(localized: "Transcribing...")
            : String(localized: "Processing...")

        guard !Task.isCancelled else { return }
        let usedLiveSessionResult = liveSessionResult != nil
        transcriptionTask = Task {
            do {
                // Wait for browser URL resolution so URL-based profile overrides apply
                await urlResolutionTask?.value
                logger.info("Stop timing: urlResolutionTask done elapsedMs=\(stopElapsedMs(), privacy: .public)")

                let activeApp = capturedActiveApp ?? textInsertionService.captureActiveApp()
                let resolvedOutputFormat = self.resolvedEffectiveOutputFormat(for: activeApp)
                let languageSelection = effectiveLanguageSelection
                let language = languageSelection.requestedLanguage
                let languageCandidates = languageSelection.selectedCodes
                let task = effectiveTask
                let engineOverride = effectiveEngineOverrideId
                let cloudModelOverride = effectiveCloudModelOverride
                let primaryEngineId = engineOverride ?? modelManager.selectedProviderId
                let dictionaryProviderId = primaryEngineId
                let termsPrompt = dictionaryService.getTermsForPrompt(providerId: dictionaryProviderId)
                let termHints = dictionaryService.getTermHints(providerId: dictionaryProviderId)

                let transcription = if let liveSessionResult {
                    FinalTranscriptionOutput(
                        result: liveSessionResult,
                        modelId: modelManager.resolvedModelId(
                            engineOverrideId: engineOverride,
                            cloudModelOverride: cloudModelOverride
                        ),
                        modelDisplayName: modelManager.resolvedModelDisplayName(
                            engineOverrideId: engineOverride,
                            cloudModelOverride: cloudModelOverride
                        )
                    )
                } else {
                    try await transcribeFinalAudioWithPerformanceMilestone(
                        audioSamples: samples,
                        languageSelection: languageSelection,
                        task: task,
                        primaryEngineId: primaryEngineId,
                        primaryCloudModelOverride: cloudModelOverride,
                        prompt: termsPrompt,
                        dictionaryTermHints: termHints,
                        normalizeNumbers: effectiveNumberNormalizationOverride
                    )
                }
                let result = transcription.result
                logger.info("Stop timing: final transcription ready elapsedMs=\(stopElapsedMs(), privacy: .public), usedLiveResult=\(usedLiveSessionResult, privacy: .public)")

                // Bail out if a new recording started while we were transcribing
                guard !Task.isCancelled else { return }

                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    logger.info("Transcription returned empty text (duration: \(String(format: "%.2f", result.duration))s, engine: \(result.engineUsed))")
                    audioRecordingService.preserveActiveRecoveryRecording()
                    let errorMessage = String(localized: "No speech recognized")
                    if let sessionID {
                        failDictationSession(id: sessionID, error: errorMessage)
                    }
                    showNotchFeedback(
                        message: errorMessage,
                        icon: "text.magnifyingglass",
                        duration: 2.0
                    )
                    soundService.play(.error, enabled: soundFeedbackEnabled)
                    return
                }

                guard !Task.isCancelled else { return }

                // Post-processing pipeline (priority-based)
                self.processingPhase = String(localized: "Processing...")
                await metadataCaptureTask?.value
                let ppContext = PostProcessingContext(
                    bundleIdentifier: activeApp.bundleId,
                    url: activeApp.url,
                    language: language
                )
                let dictationContext = DictationRuntimeContext(
                    engineId: result.engineUsed,
                    modelId: transcription.modelId,
                    configuredLanguage: language,
                    configuredLanguageCandidates: languageCandidates,
                    detectedLanguage: result.detectedLanguage
                )
                let ppResult = try await PerformanceMilestones.measure(.postProcessing) {
                    try await postProcessingPipeline.process(
                        text: text, context: ppContext, dictationContext: dictationContext,
                        outputFormat: resolvedOutputFormat,
                        normalizeNumbers: self.effectiveNumberNormalizationOverride
                    )
                }
                text = ppResult.text
                logger.info("Stop timing: post-processing done elapsedMs=\(stopElapsedMs(), privacy: .public)")
                let transcriptionID = sessionID ?? UUID()
                let completionTimestamp = Date()
                recentTranscriptionStore.recordTranscription(
                    id: transcriptionID,
                    finalText: text,
                    timestamp: completionTimestamp,
                    appName: activeApp.name,
                    appBundleIdentifier: activeApp.bundleId
                )

                partialText = ""

                let contextualInsertionEnabled = DictationInsertionTextFormatter.contextualInsertionEnabled()
                let insertionContext = contextualInsertionEnabled
                    ? textInsertionService.captureInsertionContext()
                    : nil
                let insertionText = DictationInsertionTextFormatter.textForInsertion(
                    text,
                    insertionContext: insertionContext,
                    contextualInsertionEnabled: contextualInsertionEnabled
                )
                let insertionResult = try await PerformanceMilestones.measure(.textInsertion) {
                    try await textInsertionService.insertText(
                        insertionText,
                        preserveClipboard: preserveClipboard,
                        autoEnter: self.effectiveAutoEnterEnabled,
                        outputFormat: resolvedOutputFormat
                    )
                }
                logger.info("Stop timing: text inserted elapsedMs=\(stopElapsedMs(), privacy: .public)")
                if case .pasted(.unverified(let reason)) = insertionResult {
                    logger.info(
                        "Text insertion paste could not be verified; continuing with clipboard paste fallback. reason=\(reason.rawValue, privacy: .public), app=\(activeApp.bundleId ?? "nil", privacy: .public)"
                    )
                }
                let modelDisplayName = transcription.modelDisplayName
                let pipelineSteps = ppResult.appliedSteps

                if UserDefaults.standard.object(forKey: UserDefaultsKeys.historyEnabled) as? Bool ?? true {
                    let persistenceToken = PerformanceMilestones.begin(.persistence)
                    historyService.addRecord(
                        id: transcriptionID,
                        rawText: result.text,
                        finalText: text,
                        appName: activeApp.name,
                        appBundleIdentifier: activeApp.bundleId,
                        appURL: activeApp.url,
                        durationSeconds: audioDuration,
                        language: language,
                        engineUsed: result.engineUsed,
                        modelUsed: modelDisplayName,
                        audioSamples: audioSamplesForHistory,
                        pipelineSteps: pipelineSteps.isEmpty ? nil : pipelineSteps
                    )
                    PerformanceMilestones.end(persistenceToken)
                }

                audioRecordingService.discardActiveRecoveryRecording()
                soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                let wordCount = text.split(separator: " ").count
                let statisticsToken = PerformanceMilestones.begin(.persistence)
                usageStatisticsRecorder?.recordTranscription(
                    timestamp: completionTimestamp,
                    wordsCount: wordCount,
                    durationSeconds: audioDuration,
                    appBundleIdentifier: activeApp.bundleId
                )
                PerformanceMilestones.end(statisticsToken)
                let detectedLang = result.detectedLanguage ?? language
                if let sessionID {
                    completeDictationSession(id: sessionID)
                }
                accessibilityAnnouncementService.announceTranscriptionComplete(wordCount: wordCount)
                lastTranscribedText = text
                lastTranscriptionLanguage = detectedLang

                state = .inserting
                insertingResetTask?.cancel()
                let resetDelay: Duration = actionFeedbackMessage != nil ? .seconds(actionDisplayDuration) : .seconds(1.5)
                insertingResetTask = Task {
                    try? await Task.sleep(for: resetDelay)
                    guard !Task.isCancelled else { return }
                    resetDictationState()
                }
            } catch {
                guard !Task.isCancelled else { return }
                audioRecordingService.preserveActiveRecoveryRecording()
                if let sessionID {
                    failDictationSession(id: sessionID, error: error.localizedDescription)
                }
                accessibilityAnnouncementService.announceError(error.localizedDescription)
                showError(error.localizedDescription, category: "transcription")
                clearActiveRuleState()
                capturedActiveApp = nil
                activeAppIcon = nil
            }
            self.transcriptionTask = nil
        }
        stopFinalizationTask = nil
    }

    private func transcribeFinalAudio(
        audioSamples: [Float],
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        primaryEngineId: String?,
        primaryCloudModelOverride: String?,
        prompt: String?,
        dictionaryTermHints: [DictionaryTermHint],
        normalizeNumbers: Bool?
    ) async throws -> FinalTranscriptionOutput {
        let result = try await modelManager.transcribe(
            audioSamples: audioSamples,
            languageSelection: languageSelection,
            task: task,
            engineOverrideId: primaryEngineId,
            cloudModelOverride: primaryCloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            normalizeNumbers: normalizeNumbers
        )
        return finalTranscriptionOutput(
            result: result,
            engineId: primaryEngineId,
            modelId: primaryCloudModelOverride
        )
    }

    private func transcribeFinalAudioWithPerformanceMilestone(
        audioSamples: [Float],
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        primaryEngineId: String?,
        primaryCloudModelOverride: String?,
        prompt: String?,
        dictionaryTermHints: [DictionaryTermHint],
        normalizeNumbers: Bool?
    ) async throws -> FinalTranscriptionOutput {
        let performanceToken = PerformanceMilestones.begin(.finalTranscription)
        defer { PerformanceMilestones.end(performanceToken) }
        return try await transcribeFinalAudio(
            audioSamples: audioSamples,
            languageSelection: languageSelection,
            task: task,
            primaryEngineId: primaryEngineId,
            primaryCloudModelOverride: primaryCloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            normalizeNumbers: normalizeNumbers
        )
    }

    private func finalTranscriptionOutput(
        result: TranscriptionResult,
        engineId: String?,
        modelId: String?
    ) -> FinalTranscriptionOutput {
        FinalTranscriptionOutput(
            result: result,
            modelId: modelManager.resolvedModelId(
                engineOverrideId: engineId,
                cloudModelOverride: modelId
            ),
            modelDisplayName: modelManager.resolvedModelDisplayName(
                engineOverrideId: engineId,
                cloudModelOverride: modelId
            )
        )
    }

    func requestMicPermission() { settingsHandler.requestMicPermission() }
    func requestAccessibilityPermission() { settingsHandler.requestAccessibilityPermission() }
    func hotkeys(for slot: HotkeySlotType) -> [UnifiedHotkey] { settingsHandler.hotkeys(for: slot) }
    func setHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.setHotkey(hotkey, for: slot) }
    func addHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.addHotkey(hotkey, for: slot) }
    func replaceHotkey(_ existingHotkey: UnifiedHotkey, with newHotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.replaceHotkey(existingHotkey, with: newHotkey, for: slot) }
    func removeHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.removeHotkey(hotkey, for: slot) }
    func removeConflictingHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) { settingsHandler.removeConflictingHotkey(hotkey, for: slot) }
    func clearHotkey(for slot: HotkeySlotType) { settingsHandler.clearHotkey(for: slot) }
    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? { settingsHandler.isHotkeyAssigned(hotkey, excluding: excluding) }

    private static func loadHotkeyLabel(for slotType: HotkeySlotType) -> String {
        DictationSettingsHandler.loadHotkeyLabel(for: slotType)
    }

    /// Register profile hotkeys after app is fully initialized.
    /// Called from ServiceContainer.initialize() to avoid early monitor setup.
    func registerInitialTriggerHotkeys() { settingsHandler.registerInitialTriggerHotkeys() }

    private func resetDictationState() {
        errorResetTask?.cancel()
        insertingResetTask?.cancel()
        insertingResetTask = nil
        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        urlResolutionTask?.cancel()
        urlResolutionTask = nil
        metadataCaptureTask?.cancel()
        metadataCaptureTask = nil
        lastStreamingParams = nil
        isStopInFlight = false
        activeDictationSessionID = nil
        pendingPushToTalkDiscardMessage = nil
        clearRecordingStartCueState()
        clearCancelWarning()
        state = .idle
        partialText = ""
        recordingStartTime = nil
        clearActiveRuleState()
        capturedActiveApp = nil
        capturedSelectedText = nil
        activeAppIcon = nil
        processingPhase = nil
        actionFeedbackMessage = nil
        actionFeedbackIcon = nil
        actionFeedbackIsError = false
        clearPendingUndoActionFeedback()
        actionDisplayDuration = 3.5
    }

    private func handlePushToTalkInterruption() {
        guard state == .recording, !isStopInFlight else { return }
        pendingPushToTalkDiscardMessage = String(localized: "Recording discarded because additional keys were pressed")
    }

    private func applyEffectiveMicrophoneBoostToAudioService() {
        audioRecordingService.microphoneBoostEnabled = effectiveMicrophoneBoostEnabled
    }

    /// Starts the live streaming handler with the currently effective profile/global params
    /// and records a snapshot for later change detection (release review K3).
    private func startLiveStreaming(allowLiveTranscription: Bool) {
        let params = StreamingParamsSnapshot(
            engineOverrideId: effectiveEngineOverrideId,
            providerId: modelManager.selectedProviderId,
            languageSelection: effectiveLanguageSelection,
            task: effectiveTask,
            cloudModelOverride: effectiveCloudModelOverride,
            normalizeNumbers: effectiveNumberNormalizationOverride
        )
        lastStreamingParams = allowLiveTranscription ? params : nil
        let dictionaryProviderId = params.engineOverrideId ?? params.providerId
        streamingHandler.start(
            streamPrompt: dictionaryService.getTermsForPrompt(providerId: dictionaryProviderId) ?? "",
            dictionaryTermHints: dictionaryService.getTermHints(providerId: dictionaryProviderId),
            engineOverrideId: params.engineOverrideId,
            selectedProviderId: params.providerId,
            languageSelection: params.languageSelection,
            task: params.task,
            cloudModelOverride: params.cloudModelOverride,
            normalizeNumbers: params.normalizeNumbers,
            allowLiveTranscription: allowLiveTranscription,
            stateCheck: { [weak self] in self?.state == .recording }
        )
    }

    /// Restart live streaming if the currently effective params differ from the ones
    /// used when `streamingHandler.start(...)` was last called. Called after URL
    /// resolution refines the rule, to keep live preview consistent with the final
    /// transcription. No-op when recording already stopped, when live streaming was
    /// disabled, or when no meaningful param changed.
    private func refreshLiveStreamingIfParamsChanged() {
        guard state == .recording else { return }
        guard let previous = lastStreamingParams else { return }
        let newParams = StreamingParamsSnapshot(
            engineOverrideId: effectiveEngineOverrideId,
            providerId: modelManager.selectedProviderId,
            languageSelection: effectiveLanguageSelection,
            task: effectiveTask,
            cloudModelOverride: effectiveCloudModelOverride,
            normalizeNumbers: effectiveNumberNormalizationOverride
        )
        guard newParams != previous else { return }
        logger.info("Streaming params changed after URL resolution, restarting live session")
        let allowLive = indicatorTranscriptPreviewEnabled
        startLiveStreaming(allowLiveTranscription: allowLive)
    }

    private func clearActiveRuleState() {
        matchedProfile = nil
        activeProfileMatch = nil
        forcedProfileId = nil
        activeRuleName = nil
        activeRuleReasonLabel = nil
        activeRuleExplanation = nil
    }

    private func applyProfileMatch(
        _ match: RuleMatchResult?,
        activeApp: (name: String?, bundleId: String?, url: String?)?
    ) {
        activeProfileMatch = match
        matchedProfile = match?.profile
        activeRuleName = match?.profile.name
        activeRuleReasonLabel = match?.kind.label
        activeRuleExplanation = match.map { profileExplanation(for: $0, activeApp: activeApp) }
    }

    private func forcedProfile(for id: UUID?) -> Profile? {
        guard let id else { return nil }
        return profileService.profiles.first { $0.id == id && $0.isEnabled }
    }

    private func profileExplanation(
        for match: RuleMatchResult,
        activeApp: (name: String?, bundleId: String?, url: String?)?
    ) -> String {
        let appDescriptor = activeApp?.name ?? activeApp?.bundleId ?? "the active app"

        let base: String
        switch match.kind {
        case .appAndWebsite:
            if let domain = match.matchedDomain {
                base = localizedAppText(
                    "This profile applies because \(appDescriptor) was detected together with \(domain).",
                    de: "Dieses Profil greift, weil \(appDescriptor) zusammen mit \(domain) erkannt wurde.",
                    ja: "\(appDescriptor) と \(domain) が一緒に検出されたため、このプロファイルが適用されます。"
                )
            } else {
                base = localizedAppText(
                    "This profile applies because the app and website were detected together.",
                    de: "Dieses Profil greift, weil App und Website zusammen erkannt wurden.",
                    ja: "アプリとWebサイトが一緒に検出されたため、このプロファイルが適用されます。"
                )
            }
        case .websiteOnly:
            if let domain = match.matchedDomain {
                base = localizedAppText(
                    "This profile applies because \(domain) was detected.",
                    de: "Dieses Profil greift, weil \(domain) erkannt wurde.",
                    ja: "\(domain) が検出されたため、このプロファイルが適用されます。"
                )
            } else {
                base = localizedAppText(
                    "This profile applies because the current website was detected.",
                    de: "Dieses Profil greift, weil die aktuelle Website erkannt wurde.",
                    ja: "現在のWebサイトが検出されたため、このプロファイルが適用されます。"
                )
            }
        case .appOnly:
            base = localizedAppText(
                "This profile applies because \(appDescriptor) was detected.",
                de: "Dieses Profil greift, weil \(appDescriptor) erkannt wurde.",
                ja: "\(appDescriptor) が検出されたため、このプロファイルが適用されます。"
            )
        case .globalFallback:
            base = localizedAppText(
                "This profile applies because no more specific profile matched.",
                de: "Dieses Profil greift, weil kein spezifischeres Profil gepasst hat.",
                ja: "より具体的なプロファイルに一致しなかったため、このプロファイルが適用されます。"
            )
        case .manualOverride:
            base = localizedAppText(
                "This profile was manually triggered via its keyboard shortcut.",
                de: "Dieses Profil wurde manuell über seine Tastenkombination ausgelöst.",
                ja: "このプロファイルはキーボードショートカットで手動実行されました。"
            )
        }

        guard match.wonByPriority else { return base }
        return base + localizedAppText(
            " Among multiple matching profiles, the higher-priority profile wins here.",
            de: " Unter mehreren passenden Profilen gewinnt hier das Profil mit höherer Priorität.",
            ja: " 複数の一致するプロファイルがある場合は、優先度が高いものが選ばれます。"
        )
    }

    var canCopyLastTranscription: Bool {
        recentTranscriptionStore.latestEntry(historyRecords: historyService.records) != nil
    }

    func copyLastTranscriptionToClipboard() {
        guard let entry = recentTranscriptionStore.latestEntry(historyRecords: historyService.records) else { return }
        let text = entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let pasteboard = pasteboardProvider()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func recoverLastRecording(openSettingsWindow: Bool = true) {
        guard audioRecordingService.latestRecoveryRecordingURL != nil else { return }

        if let navigationCoordinator = SettingsNavigationCoordinator.shared {
            navigationCoordinator.navigate(to: .dictationRecovery)
        }
        if openSettingsWindow {
            ManagedAppWindowOpener.shared.open(id: "settings")
        }
    }

    func triggerRecentTranscriptionsPalette() {
        recentTranscriptionPaletteHandler.triggerSelection(currentState: state)
    }

    private func clearPendingUndoActionFeedback() {
        actionFeedbackUndoTitle = nil
    }

    func undoActionFeedback() {
        clearPendingUndoActionFeedback()
    }

    private func showNotchFeedback(
        message: String,
        icon: String,
        duration: TimeInterval = 2.5,
        isError: Bool = false,
        errorCategory: String = "general",
        undoTitle: String? = nil
    ) {
        actionFeedbackMessage = message
        actionFeedbackIcon = icon
        actionFeedbackIsError = isError
        if undoTitle == nil {
            clearPendingUndoActionFeedback()
        } else {
            actionFeedbackUndoTitle = undoTitle
        }
        actionDisplayDuration = duration
        state = .inserting

        if isError {
            errorLogService.addEntry(message: message, category: errorCategory)
        }

        insertingResetTask?.cancel()
        insertingResetTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            resetDictationState()
        }
    }

    private func showError(_ message: String, category: String = "general") {
        soundService.play(.error, enabled: soundFeedbackEnabled)
        showNotchFeedback(message: message, icon: "xmark.circle.fill", duration: 3.0, isError: true, errorCategory: category)
    }

    private func startRecordingTimer() {
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0
    }
}

enum ShortSpeechDecision: Equatable {
    case discardTooShort
    case discardNoSpeech
    case transcribe

    var logDescription: String {
        switch self {
        case .discardTooShort:
            "discardTooShort"
        case .discardNoSpeech:
            "discardNoSpeech"
        case .transcribe:
            "transcribe"
        }
    }
}

func hasConfirmedTranscriptionResultText(_ result: TranscriptionResult?) -> Bool {
    guard let result else { return false }
    return !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

enum DictationInsertionTextFormatter {
    static func contextualInsertionEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: UserDefaultsKeys.appFormattingEnabled)
    }

    static func textForInsertion(
        _ text: String,
        insertionContext: TextInsertionService.InsertionContext? = nil,
        contextualInsertionEnabled: Bool = true
    ) -> String {
        guard contextualInsertionEnabled, let insertionContext else {
            return text
        }

        let boundaries = insertionBoundaries(for: insertionContext)
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isHighConfidenceMidSentenceInsertion(boundaries) {
            result = lowercasingFirstWordIfSafe(result)
        }
        if shouldStripFinalPeriod(boundaries) {
            result = strippingSingleFinalPeriod(result)
        }

        if let previous = boundaries.previousCharacter,
           let first = result.first,
           shouldInsertSpace(between: previous, and: first) {
            result = " " + result
        }

        if let next = boundaries.nextCharacter {
            if let last = result.last,
               shouldInsertSpace(between: last, and: next) {
                result += " "
            }
        }

        return result
    }

    private struct InsertionBoundaries {
        let previousCharacter: Character?
        let nextCharacter: Character?
        let previousNonWhitespaceCharacter: Character?
        let nextNonWhitespaceCharacter: Character?
    }

    private static func insertionBoundaries(
        for context: TextInsertionService.InsertionContext
    ) -> InsertionBoundaries {
        guard let selectedRange = Range(context.selectedRange, in: context.value) else {
            return InsertionBoundaries(
                previousCharacter: context.previousCharacter,
                nextCharacter: context.nextCharacter,
                previousNonWhitespaceCharacter: nonWhitespaceCharacter(context.previousCharacter),
                nextNonWhitespaceCharacter: nonWhitespaceCharacter(context.nextCharacter)
            )
        }

        let previousCharacter = selectedRange.lowerBound > context.value.startIndex
            ? context.value[context.value.index(before: selectedRange.lowerBound)]
            : nil
        let nextCharacter = selectedRange.upperBound < context.value.endIndex
            ? context.value[selectedRange.upperBound]
            : nil

        return InsertionBoundaries(
            previousCharacter: previousCharacter,
            nextCharacter: nextCharacter,
            previousNonWhitespaceCharacter: previousNonWhitespaceCharacter(
                before: selectedRange.lowerBound,
                in: context.value
            ),
            nextNonWhitespaceCharacter: nextNonWhitespaceCharacter(
                after: selectedRange.upperBound,
                in: context.value
            )
        )
    }

    private static func previousNonWhitespaceCharacter(
        before index: String.Index,
        in value: String
    ) -> Character? {
        var currentIndex = index
        while currentIndex > value.startIndex {
            let previousIndex = value.index(before: currentIndex)
            let character = value[previousIndex]
            if !isWhitespace(character) {
                return character
            }
            currentIndex = previousIndex
        }
        return nil
    }

    private static func nextNonWhitespaceCharacter(
        after index: String.Index,
        in value: String
    ) -> Character? {
        var currentIndex = index
        while currentIndex < value.endIndex {
            let character = value[currentIndex]
            if !isWhitespace(character) {
                return character
            }
            currentIndex = value.index(after: currentIndex)
        }
        return nil
    }

    private static func nonWhitespaceCharacter(_ character: Character?) -> Character? {
        guard let character, !isWhitespace(character) else { return nil }
        return character
    }

    private static func isHighConfidenceMidSentenceInsertion(
        _ boundaries: InsertionBoundaries
    ) -> Bool {
        guard let previous = boundaries.previousNonWhitespaceCharacter else { return false }
        return isWordLike(previous)
    }

    private static func shouldStripFinalPeriod(_ boundaries: InsertionBoundaries) -> Bool {
        guard isHighConfidenceMidSentenceInsertion(boundaries),
              let next = boundaries.nextNonWhitespaceCharacter else {
            return false
        }
        return isWordLike(next) || closingPunctuation.contains(next)
    }

    private static func lowercasingFirstWordIfSafe(_ text: String) -> String {
        var result = text
        guard let wordRange = firstWordRange(in: result),
              shouldLowercaseFirstWord(String(result[wordRange])) else {
            return result
        }

        let firstIndex = wordRange.lowerBound
        let nextIndex = result.index(after: firstIndex)
        result.replaceSubrange(firstIndex..<nextIndex, with: String(result[firstIndex]).lowercased())
        return result
    }

    private static func firstWordRange(in text: String) -> Range<String.Index>? {
        var start = text.startIndex
        while start < text.endIndex, isWhitespace(text[start]) {
            start = text.index(after: start)
        }
        guard start < text.endIndex, isWordLike(text[start]) else {
            return nil
        }

        var end = text.index(after: start)
        while end < text.endIndex, isWordLike(text[end]) {
            end = text.index(after: end)
        }
        return start..<end
    }

    private static func shouldLowercaseFirstWord(_ word: String) -> Bool {
        guard word.count > 1,
              let first = word.first,
              isUppercaseLetter(first) else {
            return false
        }

        let remainder = word.dropFirst()
        guard remainder.contains(where: isLowercaseLetter) else {
            return false
        }
        return !remainder.contains(where: isUppercaseLetter)
    }

    private static func strippingSingleFinalPeriod(_ text: String) -> String {
        var result = text
        var currentIndex = result.endIndex

        while currentIndex > result.startIndex {
            let previousIndex = result.index(before: currentIndex)
            if isWhitespace(result[previousIndex]) {
                currentIndex = previousIndex
                continue
            }

            guard result[previousIndex] == "." else {
                return result
            }
            if previousIndex > result.startIndex {
                let beforePeriod = result.index(before: previousIndex)
                guard result[beforePeriod] != "." else {
                    return result
                }
            }
            result.removeSubrange(previousIndex..<currentIndex)
            return result
        }

        return result
    }

    private static func shouldInsertSpace(between left: Character, and right: Character) -> Bool {
        if isWhitespace(left) || isWhitespace(right) {
            return false
        }
        if closingPunctuation.contains(right) || openingPunctuation.contains(left) {
            return false
        }
        if isWordLike(left) && isWordLike(right) {
            return true
        }
        if isWordLike(right) && punctuationThatTakesFollowingSpace.contains(left) {
            return true
        }
        return false
    }

    private static let openingPunctuation: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘"]
    private static let closingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "\"", "'", "”", "’"]
    private static let punctuationThatTakesFollowingSpace: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "\"", "'", "”", "’"]

    private static func isWordLike(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isUppercaseLetter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func isLowercaseLetter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
    }
}

func classifyShortSpeech(
    rawDuration: TimeInterval,
    peakLevel: Float,
    hasConfirmedText: Bool,
    transcribeShortQuietClipsAggressively: Bool = true
) -> ShortSpeechDecision {
    guard rawDuration >= 0.04 else { return .discardTooShort }
    if hasConfirmedText { return .transcribe }

    if rawDuration < 1.0 {
        // Bias toward transcribing short clips. False negatives here are worse than
        // letting the recognizer return empty text for actual silence.
        if peakLevel < 0.003 {
            return transcribeShortQuietClipsAggressively ? .transcribe : .discardNoSpeech
        }
        return .transcribe
    }

    if peakLevel < 0.006 { return .discardNoSpeech }
    return .transcribe
}

func paddedSamplesForFinalTranscription(_ samples: [Float], rawDuration: TimeInterval) -> [Float] {
    var paddedSamples = samples

    if rawDuration < 0.75 {
        let targetSampleCount = Int(0.75 * AudioRecordingService.targetSampleRate)
        let padCount = max(0, targetSampleCount - samples.count)
        paddedSamples.append(contentsOf: [Float](repeating: 0, count: padCount))
    } else {
        let tailPadCount = Int(0.3 * AudioRecordingService.targetSampleRate)
        paddedSamples.append(contentsOf: [Float](repeating: 0, count: tailPadCount))
    }

    return paddedSamples
}
