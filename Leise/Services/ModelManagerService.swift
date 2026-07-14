import Combine
import Foundation
import LeiseCore

enum TranscriptionEngineError: LocalizedError {
    case modelNotLoaded
    case unsupportedTask(String)
    case transcriptionFailed(String)
    case modelLoadFailed(String)
    case modelDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "No model loaded. Please download and select a model first."
        case .unsupportedTask(let detail):
            "Unsupported task: \(detail)"
        case .transcriptionFailed(let detail):
            "Transcription failed: \(detail)"
        case .modelLoadFailed(let detail):
            "Failed to load model: \(detail)"
        case .modelDownloadFailed(let detail):
            "Failed to download model: \(detail)"
        }
    }
}

struct TranscriptionAuthStatus {
    let isAvailable: Bool
    let unavailableReason: String?

    static let available = TranscriptionAuthStatus(isAvailable: true, unavailableReason: nil)
}

enum ModelAutoUnloadPolicy {
    static let defaultSeconds = 600

    static func effectiveSeconds(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds) != nil else {
            return defaultSeconds
        }
        return defaults.integer(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
    }

    static func shouldRestoreLoadedModelsPassively(defaults: UserDefaults = .standard) -> Bool {
        effectiveSeconds(defaults: defaults) == 0
    }

    static func policyName(seconds: Int) -> String {
        switch seconds {
        case 0: "never"
        case -1: "immediate"
        default: "afterSeconds"
        }
    }
}

struct ModelAutoUnloadDiagnosticsSnapshot: Encodable, Equatable, Sendable {
    struct Entry: Encodable, Equatable, Sendable {
        let engineClassName: String
        let engineObjectIdentifier: String
        let policySeconds: Int
        let scheduledAt: Date?
        let dueAt: Date?
        let lastFiredAt: Date?
        let lastSelectorResponded: Bool?
    }

    let policySeconds: Int
    let policyName: String
    let entries: [Entry]
}

@MainActor
final class ModelManagerService: ObservableObject {
    @Published private(set) var selectedProviderId: String?

    @Published var autoUnloadSeconds: Int {
        didSet {
            UserDefaults.standard.set(autoUnloadSeconds, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            cancelAutoUnloadTimer()
            scheduleAutoUnloadIfNeeded()
        }
    }

    let engine: (any TranscriptionEngine)?
    private var stateCancellable: AnyCancellable?
    private var autoUnloadTask: Task<Void, Never>?
    private var autoUnloadEntry: ModelAutoUnloadDiagnosticsSnapshot.Entry?
    private var dictationPreparationTask: Task<Void, Error>?
    private var dictationPreparationKey: DictationPreparationKey?
    private var dictationPreparationOriginalModelID: String?
    private var dictationPreparationOutcome: DictationPreparationOutcome?
    private var dictationPreparationGeneration = UUID()
    private let providerKey = UserDefaultsKeys.selectedEngine

    private struct DictationPreparationKey: Equatable {
        let engineID: String
        let modelID: String?
    }

    private enum DictationPreparationOutcome: Equatable {
        case inFlight
        case succeeded
        case failed
    }

    init(engine: (any TranscriptionEngine)? = nil) {
        self.engine = engine
        autoUnloadSeconds = ModelAutoUnloadPolicy.effectiveSeconds()
        let persistedProvider = UserDefaults.standard.string(forKey: providerKey)
        selectedProviderId = persistedProvider ?? engine?.id

        stateCancellable = engine?.stateDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.scheduleAutoUnloadIfNeeded()
            }
    }

    var availableEngines: [any TranscriptionEngine] {
        engine.map { [$0] } ?? []
    }

    func engine(for providerId: String?) -> (any TranscriptionEngine)? {
        guard let engine, providerId == nil || providerId == engine.id else { return nil }
        return engine
    }

    func hasEngine(id: String) -> Bool {
        engine?.id == id
    }

    var isModelReady: Bool { selectedEngine?.isReady ?? false }
    var canTranscribe: Bool { selectedEngine != nil }
    var activeEngineName: String? { selectedEngine?.displayName }
    var selectedModelId: String? { selectedEngine?.selectedModelID }
    var supportsStreaming: Bool { selectedEngine?.capabilities.supportsBatchPreview ?? false }

    private var selectedEngine: (any TranscriptionEngine)? {
        engine(for: selectedProviderId)
    }

    func selectedModelId(for providerId: String?) -> String? {
        engine(for: providerId)?.selectedModelID
    }

    func resolvedModelId(engineOverrideId: String? = nil, cloudModelOverride: String? = nil) -> String? {
        cloudModelOverride ?? selectedModelId(for: engineOverrideId ?? selectedProviderId)
    }

    var activeModelName: String? {
        guard let engine = selectedEngine else { return nil }
        return Self.activeModelName(for: engine)
    }

    static func activeModelName(for engine: any TranscriptionEngine) -> String? {
        if let selectedID = engine.selectedModelID,
           let model = engine.models.first(where: { $0.id == selectedID }) {
            return model.displayName
        }
        return engine.isReady ? engine.displayName : nil
    }

    func selectProvider(_ providerId: String) {
        guard hasEngine(id: providerId) else { return }
        if selectedProviderId != providerId {
            cancelDictationPreparation()
        }
        selectedProviderId = providerId
        UserDefaults.standard.set(providerId, forKey: providerKey)
    }

    func clearProviderSelection() {
        cancelDictationPreparation()
        selectedProviderId = nil
        UserDefaults.standard.removeObject(forKey: providerKey)
    }

    func selectModel(_ providerId: String, modelId: String) {
        guard let engine = engine(for: providerId) else { return }
        cancelDictationPreparation()
        selectProvider(providerId)
        engine.selectModel(id: modelId)
    }

    /// Loads an already-downloaded model while the user is speaking. The normal
    /// transcription path awaits this same task, avoiding duplicate model loads
    /// when a recording is stopped quickly. A hotkey press never starts a download.
    func prepareForDictation(
        engineOverrideId: String? = nil,
        modelOverrideId: String? = nil
    ) {
        guard autoUnloadSeconds != -1 else { return }
        guard let engine = engine(for: engineOverrideId ?? selectedProviderId) else { return }

        let modelID = modelOverrideId ?? engine.selectedModelID
        let key = DictationPreparationKey(engineID: engine.id, modelID: modelID)
        guard !engine.isReady || engine.selectedModelID != modelID else { return }
        guard dictationPreparationKey != key || dictationPreparationTask == nil else { return }

        cancelDictationPreparation()
        let generation = UUID()
        dictationPreparationGeneration = generation
        dictationPreparationKey = key
        dictationPreparationOriginalModelID = engine.selectedModelID
        dictationPreparationOutcome = .inFlight
        let task = Task { @MainActor in
            try await engine.prepareModel(id: modelID, allowDownloads: false)
        }
        dictationPreparationTask = task

        Task { @MainActor [weak self] in
            let result = await task.result
            guard let self, self.dictationPreparationGeneration == generation else { return }
            self.dictationPreparationTask = nil
            self.dictationPreparationOutcome = switch result {
            case .success: .succeeded
            case .failure: .failed
            }
        }
    }

    private func cancelDictationPreparation() {
        dictationPreparationTask?.cancel()
        dictationPreparationTask = nil
        dictationPreparationKey = nil
        dictationPreparationOriginalModelID = nil
        dictationPreparationOutcome = nil
        dictationPreparationGeneration = UUID()
    }

    func restoreProviderSelection() {
        guard let engine else {
            clearProviderSelection()
            return
        }
        selectProvider(engine.id)
    }

    func supportsLiveTranscriptionSession(engineOverrideId: String? = nil) -> Bool { false }
    func allowsTranscriptPreviewFallback(
        engineOverrideId: String? = nil,
        selectedProviderId: String? = nil
    ) -> Bool {
        engine(for: engineOverrideId ?? selectedProviderId ?? self.selectedProviderId)?
            .capabilities.allowsBatchPreviewFallback ?? false
    }

    func transcriptionAuthStatus(for engine: any TranscriptionEngine) -> TranscriptionAuthStatus { .available }

    func transcriptionAuthStatus(for providerId: String?) -> TranscriptionAuthStatus? {
        engine(for: providerId).map { _ in .available }
    }

    func canUseForTranscription(_ engine: any TranscriptionEngine) -> Bool { true }
    func canPrepareForTranscription(_ engine: any TranscriptionEngine) -> Bool { engine.isReady }

    func resolvedModelDisplayName(
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil
    ) -> String? {
        guard let engine = engine(for: engineOverrideId ?? selectedProviderId) else { return nil }
        let modelID = cloudModelOverride ?? engine.selectedModelID
        return modelID.flatMap { id in engine.models.first(where: { $0.id == id })?.displayName }
            ?? engine.displayName
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [DictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            normalizeNumbers: normalizeNumbers,
            onProgress: onProgress
        )
    }

    func transcribe(
        audioSamples: [Float],
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [DictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil,
        onProgress: @Sendable @escaping (String) -> Bool = { _ in true }
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: languageSelection,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            normalizeNumbers: normalizeNumbers,
            onProgress: onProgress,
            onSourceProgress: { _ in true }
        )
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [DictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (TranscriptionSourceProgress) -> Bool
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            normalizeNumbers: normalizeNumbers,
            onProgress: onProgress,
            onSourceProgress: onSourceProgress
        )
    }

    func transcribe(
        audioSamples: [Float],
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [DictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (TranscriptionSourceProgress) -> Bool
    ) async throws -> TranscriptionResult {
        guard task == .transcribe else {
            throw TranscriptionEngineError.unsupportedTask(task.rawValue)
        }
        guard let engine = engine(for: engineOverrideId ?? selectedProviderId) else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let observedModelID = engine.selectedModelID
        let requestedModelID = cloudModelOverride ?? observedModelID
        let preparationKey = DictationPreparationKey(
            engineID: engine.id,
            modelID: requestedModelID
        )
        let hasMatchingWarmup = dictationPreparationKey == preparationKey
        let modelIDToRestore = hasMatchingWarmup
            ? dictationPreparationOriginalModelID
            : observedModelID
        let requiresModelSwitch = requestedModelID != observedModelID
        if requiresModelSwitch, !hasMatchingWarmup, let requestedModelID {
            engine.selectModel(id: requestedModelID)
        }
        defer {
            if let modelIDToRestore, modelIDToRestore != requestedModelID {
                engine.selectModel(id: modelIDToRestore)
            }
        }

        do {
            let preparationToken = PerformanceMilestones.begin(.modelPreparation)
            defer { PerformanceMilestones.end(preparationToken) }
            var warmupPreparedModel = false
            if hasMatchingWarmup, let dictationPreparationTask {
                if case .success = await dictationPreparationTask.result {
                    warmupPreparedModel = engine.isReady && engine.selectedModelID == requestedModelID
                }
            } else if hasMatchingWarmup, dictationPreparationOutcome == .succeeded {
                warmupPreparedModel = engine.isReady && engine.selectedModelID == requestedModelID
            }
            if !warmupPreparedModel && (!engine.isReady || requiresModelSwitch) {
                try await engine.prepareModel(id: requestedModelID, allowDownloads: true)
            }
        } catch {
            throw TranscriptionEngineError.modelLoadFailed(error.localizedDescription)
        }

        let language = resolvedLanguage(from: languageSelection, supported: engine.capabilities.supportedLanguages)
        let normalizationCandidates = languageSelection.selectedCodes.filter {
            engine.capabilities.supportedLanguages.isEmpty || engine.capabilities.supportedLanguages.contains($0)
        }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let result: EngineTranscriptionResult
        do {
            result = try await engine.transcribe(TranscriptionRequest(
                audio: TranscriptionAudio(samples: audioSamples),
                language: language,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                onTextProgress: onProgress,
                onSourceProgress: onSourceProgress
            ))
        } catch {
            throw TranscriptionEngineError.transcriptionFailed(error.localizedDescription)
        }

        scheduleAutoUnloadIfNeeded()
        return TranscriptionNormalizationService.normalizeResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            configuredLanguage: language,
            configuredLanguageCandidates: normalizationCandidates,
            duration: Double(audioSamples.count) / 16_000,
            processingTime: CFAbsoluteTimeGetCurrent() - startedAt,
            engineUsed: engine.id,
            segments: result.segments.map {
                TranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
            },
            task: task,
            normalizeNumbers: normalizeNumbers
        )
    }

    private func resolvedLanguage(from selection: LanguageSelection, supported: [String]) -> String? {
        let supportedSet = Set(supported)
        switch selection {
        case .exact(let code):
            return supportedSet.isEmpty || supportedSet.contains(code) ? code : nil
        case .hints(let codes):
            return codes.first { supportedSet.isEmpty || supportedSet.contains($0) }
        case .auto, .inheritGlobal:
            return nil
        }
    }

    func scheduleAutoUnloadIfNeeded() {
        autoUnloadTask?.cancel()
        autoUnloadTask = nil
        guard let engine, engine.isReady, autoUnloadSeconds != 0 else {
            autoUnloadEntry = nil
            return
        }

        let seconds = autoUnloadSeconds
        let scheduledAt = Date()
        let dueAt = scheduledAt.addingTimeInterval(seconds == -1 ? 0.1 : TimeInterval(seconds))
        autoUnloadEntry = .init(
            engineClassName: String(describing: type(of: engine)),
            engineObjectIdentifier: String(describing: ObjectIdentifier(engine)),
            policySeconds: seconds,
            scheduledAt: scheduledAt,
            dueAt: dueAt,
            lastFiredAt: nil,
            lastSelectorResponded: nil
        )
        autoUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: seconds == -1 ? .milliseconds(100) : .seconds(seconds))
            guard !Task.isCancelled, let self, let engine = self.engine else { return }
            engine.unloadModel(clearPersistence: false)
            self.autoUnloadEntry = .init(
                engineClassName: String(describing: type(of: engine)),
                engineObjectIdentifier: String(describing: ObjectIdentifier(engine)),
                policySeconds: seconds,
                scheduledAt: nil,
                dueAt: nil,
                lastFiredAt: Date(),
                lastSelectorResponded: true
            )
            self.autoUnloadTask = nil
        }
    }

    func cancelAutoUnloadTimer() {
        autoUnloadTask?.cancel()
        autoUnloadTask = nil
        autoUnloadEntry = nil
    }

    func autoUnloadDiagnosticsSnapshot() -> ModelAutoUnloadDiagnosticsSnapshot {
        .init(
            policySeconds: autoUnloadSeconds,
            policyName: ModelAutoUnloadPolicy.policyName(seconds: autoUnloadSeconds),
            entries: autoUnloadEntry.map { [$0] } ?? []
        )
    }
}
