import Foundation
import Combine
import SwiftUI
import FillerWordCleanup
import LeiseCore
import ParakeetEngine

/// Owns an on-demand feature graph and guarantees that its factory runs once.
@MainActor
final class MemoizedFeature<Value> {
    private let factory: () -> Value
    private var storage: Value?

    init(factory: @escaping () -> Value) {
        self.factory = factory
    }

    var isInitialized: Bool { storage != nil }

    var value: Value {
        if let storage { return storage }
        let value = factory()
        storage = value
        return value
    }
}

@MainActor
final class BuiltInComponents: ObservableObject {
    let transcriptionEngine: any TranscriptionEngine
    let postProcessors: [any TextPostProcessor]
    let parakeetSettingsView: AnyView
    let fillerCleanupSettingsView: AnyView

    init() {
        let parakeet = ParakeetComponentFactory.make(
            store: ComponentSettingsStore(namespace: "parakeet")
        )
        let filler = FillerWordCleanupFactory.make(
            store: ComponentSettingsStore(namespace: "filler-words")
        )
        transcriptionEngine = parakeet.engine
        postProcessors = [filler.processor]
        parakeetSettingsView = parakeet.settingsView
        fillerCleanupSettingsView = filler.settingsView
    }
}

@MainActor
final class ServiceContainer: ObservableObject {
    /// The process-wide composition root. AppKit callbacks cannot receive SwiftUI
    /// environment values, so they resolve dependencies through this single owner.
    static let shared = ServiceContainer()

    // Services
    let modelManagerService: ModelManagerService
    let builtInComponents: BuiltInComponents
    let audioFileService: AudioFileService
    let audioRecordingService: AudioRecordingService
    let hotkeyService: HotkeyService
    let textInsertionService: TextInsertionService
    let historyService: HistoryService
    let usageStatisticsService: UsageStatisticsService
    let recentTranscriptionStore: RecentTranscriptionStore
    let textDiffService: TextDiffService
    let profileService: ProfileService
    let audioDuckingService: AudioDuckingService
    let mediaPlaybackService: MediaPlaybackService
    let dictionaryService: DictionaryService
    let soundService: SoundService
    let audioDeviceService: AudioDeviceService
    let termPackRegistryService: TermPackRegistryService
    let appFormatterService: AppFormatterService
    let dictationPunctuationProfileStore: DictationPunctuationProfileStore
    let punctuationRulesLoader: PunctuationRulesLoader
    let punctuationStrategyResolver: PunctuationStrategyResolver
    let punctuationVerificationService: PunctuationVerificationService
    let audioRecorderService: AudioRecorderService
    let accessibilityAnnouncementService: AccessibilityAnnouncementService
    let errorLogService: ErrorLogService

    // Launch view models
    let settingsViewModel: SettingsViewModel
    let dictationViewModel: DictationViewModel
    let homeViewModel: HomeViewModel
    let audioRecorderViewModel: AudioRecorderViewModel

    // Retained feature scopes. Each graph is constructed on first presentation.
    private lazy var fileTranscriptionScope = MemoizedFeature { [unowned self] in
        FileTranscriptionViewModel(
            modelManager: modelManagerService,
            audioFileService: audioFileService
        )
    }
    private lazy var dictationRecoveryScope = MemoizedFeature { [unowned self] in
        DictationRecoveryViewModel(
            audioRecordingService: audioRecordingService,
            modelManager: modelManagerService,
            historyService: historyService,
            audioFileService: audioFileService,
            usageStatisticsRecorder: usageStatisticsService
        )
    }
    private lazy var historyScope = MemoizedFeature { [unowned self] in
        HistoryViewModel(
            historyService: historyService,
            textDiffService: textDiffService,
            dictionaryService: dictionaryService
        )
    }
    private lazy var profilesScope = MemoizedFeature { [unowned self] in
        ProfilesViewModel(
            profileService: profileService,
            historyService: historyService,
            settingsViewModel: settingsViewModel,
            textInsertionService: textInsertionService
        )
    }
    private lazy var dictionaryScope = MemoizedFeature { [unowned self] in
        DictionaryViewModel(
            dictionaryService: dictionaryService,
            termPackRegistryService: termPackRegistryService
        )
    }

    var fileTranscriptionViewModel: FileTranscriptionViewModel { fileTranscriptionScope.value }
    var dictationRecoveryViewModel: DictationRecoveryViewModel { dictationRecoveryScope.value }
    var historyViewModel: HistoryViewModel { historyScope.value }
    var profilesViewModel: ProfilesViewModel { profilesScope.value }
    var dictionaryViewModel: DictionaryViewModel { dictionaryScope.value }

    private var didInitialize = false
    private var maintenanceTask: Task<Void, Never>?

    private init() {
        let performanceToken = PerformanceMilestones.begin(.serviceContainerConstruction)
        defer { PerformanceMilestones.end(performanceToken) }

        // Services
        let inputActivationGuard = AudioInputDeviceActivationGuard()
        builtInComponents = BuiltInComponents()
        modelManagerService = ModelManagerService(engine: builtInComponents.transcriptionEngine)
        audioFileService = AudioFileService()
        audioRecordingService = AudioRecordingService(
            inputActivationGuard: inputActivationGuard
        )
        hotkeyService = HotkeyService()
        let hotkeyToken = PerformanceMilestones.begin(.hotkeyRegistration)
        hotkeyService.setup()
        PerformanceMilestones.end(hotkeyToken)
        PerformanceMilestones.hotkeyReady()
        textInsertionService = TextInsertionService()
        let retainedStoreToken = PerformanceMilestones.begin(.retainedStoreOpening)
        historyService = HistoryService()
        usageStatisticsService = UsageStatisticsService()
        recentTranscriptionStore = RecentTranscriptionStore()
        textDiffService = TextDiffService()
        profileService = ProfileService()
        audioDuckingService = AudioDuckingService()
        mediaPlaybackService = MediaPlaybackService()
        dictionaryService = DictionaryService()
        PerformanceMilestones.end(retainedStoreToken)
        soundService = SoundService()
        audioDeviceService = AudioDeviceService(
            inputActivationGuard: inputActivationGuard
        )
        termPackRegistryService = TermPackRegistryService()
        appFormatterService = AppFormatterService()
        dictationPunctuationProfileStore = DictationPunctuationProfileStore()
        punctuationRulesLoader = PunctuationRulesLoader()
        punctuationStrategyResolver = PunctuationStrategyResolver(profileStore: dictationPunctuationProfileStore)
        punctuationVerificationService = PunctuationVerificationService(rulesLoader: punctuationRulesLoader)
        audioRecorderService = AudioRecorderService(
            inputActivationGuard: inputActivationGuard
        )
        accessibilityAnnouncementService = AccessibilityAnnouncementService()
        errorLogService = ErrorLogService()

        // Launch view models
        settingsViewModel = SettingsViewModel(modelManager: modelManagerService)
        dictationViewModel = DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManagerService,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            appFormatterService: appFormatterService,
            punctuationStrategyResolver: punctuationStrategyResolver,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: punctuationRulesLoader),
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: mediaPlaybackService,
            postProcessors: builtInComponents.postProcessors,
            usageStatisticsRecorder: usageStatisticsService
        )
        audioRecorderViewModel = AudioRecorderViewModel(
            recorderService: audioRecorderService,
            modelManager: modelManagerService,
            dictionaryService: dictionaryService,
            audioDeviceService: audioDeviceService
        )
        homeViewModel = HomeViewModel(
            historyService: historyService,
            usageStatisticsService: usageStatisticsService
        )

    }

    func initialize() async {
        guard !AppConstants.isRunningTests else { return }
        guard !didInitialize else { return }
        didInitialize = true
        let performanceToken = PerformanceMilestones.begin(.serviceContainerInitialization)
        defer { PerformanceMilestones.end(performanceToken) }

        dictationViewModel.registerInitialTriggerHotkeys()

        let selectionToken = PerformanceMilestones.begin(.modelSelectionRestoration)
        modelManagerService.restoreProviderSelection()
        audioRecorderViewModel.reconcileSelectionWithAvailableEngines()
        PerformanceMilestones.end(selectionToken)

        scheduleMaintenance()

        #if DEBUG
        await PerformanceBaselineRunner.runIfRequested(using: self)
        #endif
    }

    private func scheduleMaintenance() {
        guard maintenanceTask == nil else { return }
        maintenanceTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }

            if usageStatisticsService.needsHistoryBackfill {
                await usageStatisticsService.backfillFromHistoryIfNeededInBatches(
                    historyService.records
                )
            }
            guard !Task.isCancelled else { return }

            let retentionDays = UserDefaults.standard.integer(
                forKey: UserDefaultsKeys.historyRetentionDays
            )
            if retentionDays > 0 {
                await historyService.purgeOldRecordsInBatches(retentionDays: retentionDays)
            }
        }
    }
}
