import Foundation
import Combine
import OSLog
import SwiftUI
import FluidAudio
import LeiseCore

private actor AsyncTranscriptionGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

public struct ParakeetComponent: @unchecked Sendable {
    public let engine: any TranscriptionEngine
    public let settingsView: AnyView
}

public enum ParakeetComponentFactory {
    @MainActor
    public static func make(store: any ParakeetStore) -> ParakeetComponent {
        let implementation = ParakeetEngineImplementation(store: store)
        return ParakeetComponent(
            engine: implementation,
            settingsView: AnyView(ParakeetSettingsView(engine: implementation))
        )
    }
}

public enum ParakeetRuntimeRecovery {
    public static func resetNetworkingAfterWake() {
        ParakeetHTTPClient.resetSharedSession(reason: "macOS wake")
    }
}

// MARK: - Engine implementation

final class ParakeetEngineImplementation: TranscriptionEngine, @unchecked Sendable {
    static let vocabularyAssetFileName = "parakeet_vocab.json"
    private static let logger = Logger(subsystem: "com.leise.engine.parakeet", category: "Transcription")
    private static let shortClipConfidenceThreshold: Float = 0.55
    private static let shortClipConfidenceGateDuration: TimeInterval = 1.0
    private static let fluidAudioProgressMinimumSampleCount = 240_000
    typealias VocabularyAssetFetcher = @Sendable (_ url: URL, _ description: String) async throws -> Data

    fileprivate let store: any ParakeetStore
    fileprivate var asrManager: AsrManager?
    fileprivate var loadedAsrModels: AsrModels?
    fileprivate var loadedModelId: String?
    fileprivate var _selectedModelId: String?
    private let stateSubject = PassthroughSubject<Void, Never>()
    var modelState: ParakeetModelState = .notLoaded { didSet { stateSubject.send() } }
    fileprivate var downloadProgress: Double = 0
    fileprivate var selectedVersion: ParakeetVersion = .v3
    fileprivate var _hfToken: String?

    // Vocabulary Boosting
    fileprivate var ctcModels: CtcModels?
    fileprivate var ctcTokenizer: CtcTokenizer?
    fileprivate var ctcSpotter: CtcKeywordSpotter?
    fileprivate var customVocabulary: CustomVocabularyContext?
    fileprivate var vocabularyRescorer: VocabularyRescorer?
    fileprivate var vocabSizeConfig: ContextBiasingConstants.VocabSizeConfig?
    fileprivate var vocabularyBoostingEnabled: Bool = false
    private let transcriptionGate = AsyncTranscriptionGate()
    var ctcModelState: CtcModelState = .notDownloaded
    var lastConfiguredPrompt: String?
    var lastBoostingTermCount: Int = 0

    init(store: any ParakeetStore, restoresPersistedModel: Bool = true) {
        self.store = store
        _selectedModelId = store.userDefault(forKey: "selectedModel") as? String
        _hfToken = HuggingFaceTokenHelper.loadToken(from: store)
        vocabularyBoostingEnabled = store.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool ?? false
        if let versionString = store.userDefault(forKey: "selectedVersion") as? String,
           let version = ParakeetVersion(rawValue: versionString) {
            selectedVersion = version
        }
        if let selectedModelId = _selectedModelId,
           let version = ParakeetVersion.from(modelId: selectedModelId) {
            selectedVersion = version
        } else if let persistedLoadedModel = store.userDefault(forKey: "loadedModel") as? String,
                  !persistedLoadedModel.isEmpty {
            _selectedModelId = persistedLoadedModel
            store.setUserDefault(persistedLoadedModel, forKey: "selectedModel")
            if let version = ParakeetVersion.from(modelId: persistedLoadedModel) {
                selectedVersion = version
            }
        }
        if restoresPersistedModel, store.shouldRestoreLoadedModelsPassively {
            Task { await restoreLoadedModel(allowDownloads: false) }
        }
    }

    // MARK: - TranscriptionEngine

    var id: String { "parakeet" }
    var displayName: String { "Parakeet" }

    var isConfigured: Bool {
        asrManager != nil && loadedModelId != nil
    }

    var canDismissSettingsAfterSetup: Bool {
        if case .ready = modelState {
            return true
        }
        return false
    }

    var models: [TranscriptionModel] {
        ParakeetVersion.allCases.map { version in
            let def = version.modelDef
            return TranscriptionModel(
                id: def.id,
                displayName: def.displayName
            )
        }
    }

    var selectedModelID: String? { _selectedModelId }
    var allowsTranscriptPreviewFallback: Bool { true }
    var supportsStreaming: Bool { true }

    func selectModel(id modelId: String) {
        guard let version = ParakeetVersion.from(modelId: modelId) else { return }
        _selectedModelId = modelId
        store.setUserDefault(modelId, forKey: "selectedModel")
        if version == selectedVersion && loadedModelId == modelId { return }
        Task {
            unloadModel(clearPersistence: false)
            selectedVersion = version
            _selectedModelId = modelId
            store.setUserDefault(modelId, forKey: "selectedModel")
            store.setUserDefault(version.rawValue, forKey: "selectedVersion")
            await loadModel()
        }
    }

    var dictionaryTermsSupport: DictionaryHintSupport {
        vocabularyBoostingEnabled ? .available : .requiresSetting
    }

    var supportedLanguages: [String] {
        selectedVersion.supportedLanguages
    }

    func transcribe(
        audio: TranscriptionAudio,
        language: String?,
        prompt: String?
    ) async throws -> EngineTranscriptionResult {
        try await transcribe(
            audio: audio,
            language: language,
            prompt: prompt,
            dictionaryTermHints: [],
            onProgress: { _ in true },
            onSourceProgress: { _ in true }
        )
    }

    func transcribe(
        audio: TranscriptionAudio,
        language: String?,
        prompt: String?,
        dictionaryTermHints: [DictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (TranscriptionSourceProgress) -> Bool
    ) async throws -> EngineTranscriptionResult {
        try await transcriptionGate.withLock {
            try await transcribeSerially(
                audio: audio,
                language: language,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                onProgress: onProgress,
                onSourceProgress: onSourceProgress
            )
        }
    }

    private func transcribeSerially(
        audio: TranscriptionAudio,
        language: String?,
        prompt: String?,
        dictionaryTermHints: [DictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (TranscriptionSourceProgress) -> Bool
    ) async throws -> EngineTranscriptionResult {
        guard let asrManager else {
            throw TranscriptionEngineFailure.notReady
        }

        if vocabularyBoostingEnabled {
            await configureBoostingIfNeeded(prompt: prompt, dictionaryTermHints: dictionaryTermHints)
        }

        let normalizedSamples = ParakeetAudioUtilities.paddedSamples(
            audio.samples,
            minimumDuration: 1.0,
            sampleRate: 16_000
        )
        let fluidLanguage = Self.fluidAudioLanguage(for: language)
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let progressTask: Task<Void, Never>? = if Self.shouldObserveSourceProgress(sampleCount: normalizedSamples.count) {
            Task { [asrManager, duration = audio.duration, onSourceProgress] in
                let stream = await asrManager.transcriptionProgressStream
                do {
                    for try await fraction in stream {
                        guard !Task.isCancelled else { break }
                        guard let progress = Self.sourceProgress(fromFraction: fraction, totalDuration: duration) else {
                            continue
                        }
                        if !onSourceProgress(progress) {
                            break
                        }
                    }
                } catch {
                    // The transcription task reports the underlying error; progress is best-effort.
                }
            }
        } else {
            nil
        }
        defer { progressTask?.cancel() }

        let result = try await asrManager.transcribe(
            normalizedSamples,
            decoderState: &decoderState,
            language: fluidLanguage
        )
        let finalResult = await applyVocabularyRescoringIfNeeded(
            to: result,
            audioSamples: normalizedSamples
        )
        let trimmedText = finalResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if audio.duration < Self.shortClipConfidenceGateDuration {
            Self.logger.info(
                "Short clip transcription: rawDuration=\(String(format: "%.3f", audio.duration), privacy: .public)s, confidence=\(String(format: "%.3f", finalResult.confidence), privacy: .public), textLength=\(trimmedText.count, privacy: .public)"
            )
        }

        guard ParakeetAudioUtilities.shouldAcceptShortClipTranscription(
            audioDuration: audio.duration,
            confidence: finalResult.confidence,
            minimumDuration: Self.shortClipConfidenceGateDuration,
            minimumConfidence: Self.shortClipConfidenceThreshold
        ) else {
            Self.logger.info(
                "Discarding low-confidence short clip: rawDuration=\(String(format: "%.3f", audio.duration), privacy: .public)s, confidence=\(String(format: "%.3f", finalResult.confidence), privacy: .public)"
            )
            return EngineTranscriptionResult(text: "", detectedLanguage: nil, segments: [])
        }

        let segments: [EngineTranscriptionSegment]
        if let tokenTimings = finalResult.tokenTimings, !tokenTimings.isEmpty {
            segments = Self.groupTokensIntoSegments(tokenTimings)
        } else {
            segments = []
        }

        _ = onProgress(finalResult.text)
        return EngineTranscriptionResult(text: finalResult.text, detectedLanguage: nil, segments: segments)
    }

    static func sourceProgress(
        fromFraction fraction: Double,
        totalDuration: TimeInterval
    ) -> TranscriptionSourceProgress? {
        guard fraction.isFinite,
              totalDuration.isFinite,
              totalDuration > 0 else {
            return nil
        }
        let clampedFraction = min(max(fraction, 0), 1)
        return TranscriptionSourceProgress(
            processedDuration: totalDuration * clampedFraction,
            totalDuration: totalDuration
        )
    }

    static func shouldObserveSourceProgress(sampleCount: Int) -> Bool {
        sampleCount > fluidAudioProgressMinimumSampleCount
    }

    private static func fluidAudioLanguage(for language: String?) -> Language? {
        guard let language else { return nil }
        let primaryCode = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)

        guard let primaryCode, !primaryCode.isEmpty else { return nil }
        return Language(rawValue: primaryCode)
    }
    // MARK: - Token-to-Segment Grouping

    private static func groupTokensIntoSegments(_ tokenTimings: [TokenTiming]) -> [EngineTranscriptionSegment] {
        // Phase 1: Group sub-word tokens into words
        struct WordTiming {
            let word: String
            let start: Double
            let end: Double
        }

        var words: [WordTiming] = []
        var currentWord = ""
        var wordStart: Double = 0
        var wordEnd: Double = 0

        for timing in tokenTimings {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }

            let startsNewWord = isWordBoundary(token) || currentWord.isEmpty

            if startsNewWord && !currentWord.isEmpty {
                let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    words.append(WordTiming(word: trimmed, start: wordStart, end: wordEnd))
                }
                currentWord = ""
            }

            if startsNewWord {
                currentWord = stripWordBoundaryPrefix(token)
                wordStart = timing.startTime
            } else {
                currentWord += token
            }
            wordEnd = timing.endTime
        }

        let lastTrimmed = currentWord.trimmingCharacters(in: .whitespaces)
        if !lastTrimmed.isEmpty {
            words.append(WordTiming(word: lastTrimmed, start: wordStart, end: wordEnd))
        }

        guard !words.isEmpty else { return [] }

        // Phase 2: Group words into sentence segments (split at sentence-ending punctuation or pause > 0.8s)
        let sentenceEndings: Set<Character> = [".", "?", "!"]
        let pauseThreshold: Double = 0.8

        var segments: [EngineTranscriptionSegment] = []
        var segmentWords: [String] = []
        var segmentStart: Double = words[0].start
        var segmentEnd: Double = words[0].end

        for i in 0..<words.count {
            let word = words[i]
            segmentWords.append(word.word)
            segmentEnd = word.end

            let isSentenceEnd = word.word.last.map { sentenceEndings.contains($0) } ?? false
            let hasLongPause = i + 1 < words.count && (words[i + 1].start - word.end) > pauseThreshold
            let isLast = i == words.count - 1

            if isSentenceEnd || hasLongPause || isLast {
                let text = segmentWords.joined(separator: " ")
                segments.append(EngineTranscriptionSegment(text: text, start: segmentStart, end: segmentEnd))
                segmentWords = []
                if i + 1 < words.count {
                    segmentStart = words[i + 1].start
                }
            }
        }

        return segments
    }

    // MARK: - Vocabulary Boosting

    fileprivate func downloadCtcModel() async {
        ctcModelState = .downloading
        do {
            applyHuggingFaceTokenToEnvironment()
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: cacheDir)
            ctcModels = models
            ctcTokenizer = tokenizer
            ctcModelState = .ready
        } catch {
            ctcModelState = .error(error.localizedDescription)
        }
    }

    static func vocabularyHints(
        prompt: String?,
        dictionaryTermHints: [DictionaryTermHint]
    ) -> [DictionaryTermHint] {
        if !dictionaryTermHints.isEmpty {
            return DictionaryTerms.normalizedHints(from: dictionaryTermHints)
        }
        return DictionaryTerms.hints(fromPrompt: prompt)
    }

    static func vocabularySignature(from hints: [DictionaryTermHint]) -> String? {
        guard !hints.isEmpty else { return nil }
        return hints.map {
            let threshold = $0.ctcMinSimilarity.map { String(format: "%.4f", Double($0)) } ?? "auto"
            return "\($0.text)|\(threshold)"
        }.joined(separator: "\u{1F}")
    }

    private func configureBoostingIfNeeded(
        prompt: String?,
        dictionaryTermHints: [DictionaryTermHint] = []
    ) async {
        guard vocabularyBoostingEnabled else { return }

        let termHints = Self.vocabularyHints(prompt: prompt, dictionaryTermHints: dictionaryTermHints)
        let signature = Self.vocabularySignature(from: termHints)
        if signature == lastConfiguredPrompt && (signature != nil || customVocabulary == nil) { return }
        lastConfiguredPrompt = signature

        guard !termHints.isEmpty else {
            clearConfiguredVocabulary()
            return
        }

        if ctcModels == nil {
            await downloadCtcModel()
        }
        guard let ctcModels, let ctcTokenizer else {
            lastConfiguredPrompt = nil
            return
        }

        // FluidAudio currently exposes only vocabulary-level minSimilarity; per-term
        // thresholds are preserved in structured hints until the upstream API exists.
        let terms = termHints.compactMap { hint -> CustomVocabularyTerm? in
            let text = hint.text
            let ids = ctcTokenizer.encode(text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(text: text, weight: 10.0, ctcTokenIds: ids)
        }

        guard !terms.isEmpty else {
            clearConfiguredVocabulary()
            return
        }

        let cappedTerms = Array(terms.prefix(256))
        let vocab = CustomVocabularyContext(terms: cappedTerms)
        let blankId = ctcModels.vocabulary.count
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
        let ctcModelDir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        do {
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: vocab,
                ctcModelDirectory: ctcModelDir
            )
            customVocabulary = vocab
            ctcSpotter = spotter
            vocabularyRescorer = rescorer
            vocabSizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: cappedTerms.count)
            lastBoostingTermCount = cappedTerms.count
        } catch {
            clearConfiguredVocabulary()
            lastBoostingTermCount = 0
            lastConfiguredPrompt = nil
        }
    }

    private func applyVocabularyRescoringIfNeeded(
        to result: ASRResult,
        audioSamples: [Float]
    ) async -> ASRResult {
        guard vocabularyBoostingEnabled,
              let spotter = ctcSpotter,
              let rescorer = vocabularyRescorer,
              let vocab = customVocabulary,
              let tokenTimings = result.tokenTimings,
              !tokenTimings.isEmpty
        else {
            return result
        }

        do {
            let spotResult = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: audioSamples,
                customVocabulary: vocab,
                minScore: nil
            )
            guard !spotResult.logProbs.isEmpty else { return result }

            let vocabConfig = vocabSizeConfig
                ?? ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
            let rescoreOutput = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: tokenTimings,
                logProbs: spotResult.logProbs,
                frameDuration: spotResult.frameDuration,
                cbw: vocabConfig.cbw,
                marginSeconds: 0.5,
                minSimilarity: max(vocabConfig.minSimilarity, vocab.minSimilarity)
            )

            guard rescoreOutput.wasModified else { return result }

            let detectedTerms = spotResult.detections.map(\.term.text)
            let appliedTerms = rescoreOutput.replacements.compactMap { replacement in
                replacement.shouldReplace ? replacement.replacementWord : nil
            }
            Self.logger.info(
                "Vocabulary rescoring applied \(rescoreOutput.replacements.count) replacement(s)"
            )
            return result.withRescoring(
                text: rescoreOutput.text,
                detected: detectedTerms,
                applied: appliedTerms
            )
        } catch {
            Self.logger.warning("Vocabulary rescoring failed: \(error.localizedDescription)")
            return result
        }
    }

    func setBoostingEnabled(_ enabled: Bool) {
        guard vocabularyBoostingEnabled != enabled else { return }
        vocabularyBoostingEnabled = enabled
        store.setUserDefault(enabled, forKey: "vocabularyBoostingEnabled")
        if !enabled {
            clearConfiguredVocabulary()
        }
    }

    private func clearConfiguredVocabulary() {
        ctcSpotter = nil
        customVocabulary = nil
        vocabularyRescorer = nil
        vocabSizeConfig = nil
        lastConfiguredPrompt = nil
        lastBoostingTermCount = 0
    }

    private func clearVocabularyBoostingState(resetModelState: Bool = false) {
        clearConfiguredVocabulary()
        ctcModels = nil
        ctcTokenizer = nil
        if resetModelState {
            ctcModelState = .notDownloaded
        }
    }

    // MARK: - Model Management

    fileprivate func loadModel() async {
        modelState = .downloading
        downloadProgress = 0.1

        do {
            applyHuggingFaceTokenToEnvironment()
            try await ensureVocabularyAsset(for: selectedVersion)
            let models = try await AsrModels.downloadAndLoad(version: selectedVersion.asrModelVersion)
            downloadProgress = 0.7

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            downloadProgress = 1.0

            asrManager = manager
            loadedAsrModels = models
            loadedModelId = selectedVersion.modelDef.id
            _selectedModelId = selectedVersion.modelDef.id
            modelState = .ready

            store.setUserDefault(selectedVersion.modelDef.id, forKey: "selectedModel")
            store.setUserDefault(selectedVersion.modelDef.id, forKey: "loadedModel")
            store.setUserDefault(selectedVersion.rawValue, forKey: "selectedVersion")

            if vocabularyBoostingEnabled {
                let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
                if CtcModels.modelsExist(at: cacheDir) {
                    await downloadCtcModel()
                }
            }
        } catch {
            modelState = .error(error.localizedDescription)
            downloadProgress = 0
        }
    }

    static func vocabularyAssetURL(for version: ParakeetVersion) -> URL {
        let repo: String
        switch version {
        case .v2:
            repo = "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        case .v3:
            repo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(vocabularyAssetFileName)")!
    }

    static func vocabularyAssetDirectory(for version: ParakeetVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version.asrModelVersion)
    }

    func ensureVocabularyAsset(
        for version: ParakeetVersion,
        targetDirectory: URL? = nil,
        fetcher: VocabularyAssetFetcher = { url, description in
            try await ParakeetEngineImplementation.downloadVocabularyAsset(from: url, description: description)
        }
    ) async throws {
        let directory = targetDirectory ?? Self.vocabularyAssetDirectory(for: version)
        let targetURL = directory.appendingPathComponent(Self.vocabularyAssetFileName, isDirectory: false)
        guard !Self.vocabularyAssetExists(at: targetURL) else { return }

        let vocabularyURL = Self.vocabularyAssetURL(for: version)
        let description = "\(version.modelDef.displayName) vocabulary"
        let data: Data
        do {
            data = try await fetcher(vocabularyURL, description)
        } catch {
            throw ParakeetVocabularyAssetError.downloadFailed(version: version, underlying: error)
        }
        guard !data.isEmpty else {
            throw ParakeetVocabularyAssetError.emptyDownload(version: version)
        }

        let fileManager = FileManager.default
        var installFailureURL = directory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporaryURL = directory.appendingPathComponent(
                ".\(Self.vocabularyAssetFileName).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            installFailureURL = temporaryURL
            do {
                try data.write(to: temporaryURL, options: .atomic)
                if Self.vocabularyAssetExists(at: targetURL) {
                    try? fileManager.removeItem(at: temporaryURL)
                    return
                }
                installFailureURL = targetURL
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: targetURL)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        } catch {
            throw ParakeetVocabularyAssetError.installFailed(
                version: version,
                path: installFailureURL,
                underlying: error
            )
        }
    }

    private static func vocabularyAssetExists(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private static func downloadVocabularyAsset(from url: URL, description: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 600
        if let token = currentHuggingFaceToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await ParakeetHTTPClient.data(for: request, resourceTimeout: 600)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ParakeetVocabularyAssetHTTPError(description: description, statusCode: nil)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ParakeetVocabularyAssetHTTPError(
                description: description,
                statusCode: httpResponse.statusCode
            )
        }
        return data
    }

    private static func currentHuggingFaceToken() -> String? {
        for key in HuggingFaceTokenHelper.environmentKeys {
            if let token = HuggingFaceTokenHelper.normalizedToken(ProcessInfo.processInfo.environment[key]) {
                return token
            }
        }
        return nil
    }

    func unloadModel(clearPersistence: Bool = true) {
        clearVocabularyBoostingState(resetModelState: true)
        asrManager = nil
        loadedAsrModels = nil
        loadedModelId = nil
        modelState = .notLoaded
        downloadProgress = 0
        if clearPersistence {
            store.setUserDefault(nil, forKey: "loadedModel")
        }
    }

    func restoreLoadedModel(allowDownloads: Bool = true) async {
        guard let savedModelId = store.userDefault(forKey: "loadedModel") as? String else {
            return
        }
        if _selectedModelId == nil {
            _selectedModelId = savedModelId
            store.setUserDefault(savedModelId, forKey: "selectedModel")
        }
        // Infer version from persisted model ID for backwards compatibility
        if let version = ParakeetVersion.from(modelId: savedModelId) {
            selectedVersion = version
        }
        guard allowDownloads || isModelDownloaded(version: selectedVersion) else { return }
        await loadModel()
    }

    private func isModelDownloaded(version: ParakeetVersion) -> Bool {
        let cacheDir = AsrModels.defaultCacheDirectory(for: version.asrModelVersion)
        return AsrModels.modelsExist(at: cacheDir, version: version.asrModelVersion)
    }

    // MARK: - Settings View

    var currentSettingsActivity: ParakeetSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            break
        case .downloading:
            return ParakeetSettingsActivity(
                message: "Downloading model",
                progress: downloadProgress
            )
        case .error(let message):
            return ParakeetSettingsActivity(message: message, isError: true)
        }

        guard vocabularyBoostingEnabled else { return nil }

        switch ctcModelState {
        case .notDownloaded, .ready:
            return nil
        case .downloading:
            return ParakeetSettingsActivity(message: "Downloading vocabulary model")
        case .error(let message):
            return ParakeetSettingsActivity(message: message, isError: true)
        }
    }

    var settingsView: AnyView? {
        AnyView(ParakeetSettingsView(engine: self))
    }

    var huggingFaceToken: String? { _hfToken }

    func setHuggingFaceToken(_ token: String) {
        _hfToken = HuggingFaceTokenHelper.saveToken(token, to: store)
    }

    func clearHuggingFaceToken() {
        _hfToken = nil
        HuggingFaceTokenHelper.clearToken(from: store)
    }

    func validateHuggingFaceToken(
        _ token: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = ParakeetHTTPClient.data
    ) async -> Bool {
        await HuggingFaceTokenHelper.validateToken(token, dataFetcher: dataFetcher)
    }

    func applyHuggingFaceTokenToEnvironment() {
        HuggingFaceTokenHelper.applyTokenToEnvironment(_hfToken)
    }
}

extension ParakeetEngineImplementation {
    var capabilities: TranscriptionCapabilities {
        TranscriptionCapabilities(
            supportedLanguages: supportedLanguages,
            supportsBatchPreview: supportsStreaming,
            allowsBatchPreviewFallback: allowsTranscriptPreviewFallback,
            dictionaryHints: dictionaryTermsSupport
        )
    }
    var isReady: Bool { isConfigured }
    var preparationStatus: ModelPreparationStatus {
        switch currentSettingsActivity {
        case .none:
            isConfigured ? .ready : .idle
        case .some(let activity) where activity.isError:
            .failed(message: activity.message)
        case .some(let activity):
            .preparing(message: activity.message, progress: activity.progress)
        }
    }
    var stateDidChange: AnyPublisher<Void, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    func prepareModel(id: String?, allowDownloads: Bool) async throws {
        if let id, id != selectedModelID {
            guard let version = ParakeetVersion.from(modelId: id) else {
                throw TranscriptionEngineFailure.failed("Unknown Parakeet model: \(id)")
            }
            unloadModel(clearPersistence: false)
            selectedVersion = version
            _selectedModelId = id
            store.setUserDefault(id, forKey: "selectedModel")
            store.setUserDefault(version.rawValue, forKey: "selectedVersion")
        }

        if isConfigured { return }
        if !allowDownloads, !isModelDownloaded(version: selectedVersion) {
            throw TranscriptionEngineFailure.notReady
        }
        await loadModel()
        guard isConfigured else {
            if case .error(let message) = modelState {
                throw TranscriptionEngineFailure.failed(message)
            }
            throw TranscriptionEngineFailure.notReady
        }
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> EngineTranscriptionResult {
        if request.isCancelled() { throw TranscriptionEngineFailure.cancelled }
        let result = try await transcribe(
            audio: TranscriptionAudio(
                samples: request.audio.samples,
                duration: request.audio.duration
            ),
            language: request.language,
            prompt: request.prompt,
            dictionaryTermHints: request.dictionaryTermHints,
            onProgress: request.onTextProgress,
            onSourceProgress: { progress in
                request.onSourceProgress(TranscriptionSourceProgress(
                    processedDuration: progress.processedDuration,
                    totalDuration: progress.totalDuration
                ))
            }
        )
        return result
    }
}

// MARK: - Model Version

enum ParakeetVersion: String, CaseIterable {
    case v2
    case v3

    var asrModelVersion: AsrModelVersion {
        switch self {
        case .v2: return .v2
        case .v3: return .v3
        }
    }

    var modelDef: ParakeetModelDef {
        switch self {
        case .v2:
            return ParakeetModelDef(
                id: "parakeet-tdt-0.6b-v2",
                displayName: "Parakeet TDT v2",
                sizeDescription: "~600 MB",
                ramRequirement: "8 GB+"
            )
        case .v3:
            return ParakeetModelDef(
                id: "parakeet-tdt-0.6b-v3",
                displayName: "Parakeet TDT v3",
                sizeDescription: "~600 MB",
                ramRequirement: "8 GB+"
            )
        }
    }

    var supportedLanguages: [String] {
        switch self {
        case .v2:
            return ["en"]
        case .v3:
            return ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
        }
    }

    func settingsDescription(bundle: Bundle) -> String {
        switch self {
        case .v2:
            return String(localized: "NVIDIA Parakeet TDT V2 - extremely fast on Apple Silicon. English only, highest recall. No API key required.", bundle: bundle)
        case .v3:
            return String(localized: "NVIDIA Parakeet TDT - extremely fast on Apple Silicon. 25 European languages, no API key required.", bundle: bundle)
        }
    }

    static func from(modelId: String) -> ParakeetVersion? {
        allCases.first { $0.modelDef.id == modelId }
    }
}

// MARK: - Model Types

struct ParakeetModelDef {
    let id: String
    let displayName: String
    let sizeDescription: String
    let ramRequirement: String
}

enum ParakeetModelState: Equatable {
    case notLoaded
    case downloading
    case ready
    case error(String)
}

enum CtcModelState: Equatable {
    case notDownloaded
    case downloading
    case ready
    case error(String)
}

private struct ParakeetVocabularyAssetHTTPError: LocalizedError, Sendable {
    let description: String
    let statusCode: Int?

    var errorDescription: String? {
        guard let statusCode else {
            return "Invalid HTTP response while downloading \(description)"
        }
        return "HTTP \(statusCode) while downloading \(description)"
    }
}

private enum ParakeetVocabularyAssetError: LocalizedError {
    case downloadFailed(version: ParakeetVersion, underlying: Error)
    case emptyDownload(version: ParakeetVersion)
    case installFailed(version: ParakeetVersion, path: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let version, let underlying):
            return "Failed to download Parakeet vocabulary file for \(version.modelDef.displayName): \(underlying.localizedDescription)"
        case .emptyDownload(let version):
            return "Failed to download Parakeet vocabulary file for \(version.modelDef.displayName): downloaded file was empty"
        case .installFailed(let version, let path, let underlying):
            return "Failed to install Parakeet vocabulary file for \(version.modelDef.displayName) at \(path.path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Settings View

private struct ParakeetSettingsView: View {
    let engine: ParakeetEngineImplementation
    private let bundle = Bundle(for: ParakeetEngineImplementation.self)
    @Environment(\.dismiss) private var dismiss
    @State private var selectedVersion: ParakeetVersion = .v3
    @State private var modelState: ParakeetModelState = .notLoaded
    @State private var downloadProgress: Double = 0
    @State private var isPolling = false
    @State private var hfTokenInput = ""
    @State private var showHfToken = false
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?
    @State private var boostingEnabled: Bool = false
    @State private var ctcModelState: CtcModelState = .notDownloaded
    @State private var boostingTermCount: Int = 0

    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var trimmedHfTokenInput: String {
        hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var storedHfToken: String {
        engine._hfToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var hasStoredHfToken: Bool {
        !storedHfToken.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Parakeet")
                    .font(.headline)

                Text(selectedVersion.settingsDescription(bundle: bundle))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Hugging Face Token", bundle: bundle)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("Optional. Increases download rate limits. Free at huggingface.co/settings/tokens", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        if showHfToken {
                            TextField("hf_...", text: $hfTokenInput)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("hf_...", text: $hfTokenInput)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showHfToken.toggle()
                        } label: {
                            Image(systemName: showHfToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)

                        if hasStoredHfToken {
                            Button(String(localized: "Remove", bundle: bundle)) {
                                hfTokenInput = ""
                                tokenValidationResult = nil
                                isValidatingToken = false
                                engine.clearHuggingFaceToken()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button(String(localized: "Save", bundle: bundle)) {
                            validateAndSaveHuggingFaceToken()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(trimmedHfTokenInput.isEmpty || isValidatingToken)
                    }

                    if isValidatingToken {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Validating token...", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let tokenValidationResult {
                        HStack(spacing: 4) {
                            Image(systemName: tokenValidationResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(tokenValidationResult ? .green : .red)
                            Text(
                                tokenValidationResult
                                    ? String(localized: "Valid Hugging Face Token", bundle: bundle)
                                    : String(localized: "Invalid Hugging Face Token", bundle: bundle)
                            )
                            .font(.caption)
                            .foregroundStyle(tokenValidationResult ? .green : .red)
                        }
                    }
                }

                Divider()

                // Model version picker
                HStack {
                    Text("Model Version", bundle: bundle)
                    Spacer()
                    Picker("", selection: $selectedVersion) {
                        ForEach(ParakeetVersion.allCases, id: \.self) { version in
                            Text(version.modelDef.displayName).tag(version)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(modelState == .downloading)
                }

                // Model info and action
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedVersion.modelDef.displayName)
                            .font(.body)
                        Text("\(selectedVersion.modelDef.sizeDescription) - RAM: \(selectedVersion.modelDef.ramRequirement)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    switch modelState {
                    case .notLoaded:
                        Button(String(localized: "Download & Load", bundle: bundle)) {
                            modelState = .downloading
                            downloadProgress = 0.05
                            isPolling = true
                            Task {
                                await engine.loadModel()
                                isPolling = false
                                modelState = engine.modelState
                                downloadProgress = engine.downloadProgress
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    case .downloading:
                        HStack(spacing: 8) {
                            ProgressView(value: downloadProgress)
                                .frame(width: 80)
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                        }

                    case .ready:
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button(String(localized: "Unload", bundle: bundle)) {
                                engine.unloadModel()
                                modelState = engine.modelState
                                ctcModelState = engine.ctcModelState
                                boostingTermCount = 0
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                    case .error(let message):
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Button(String(localized: "Retry", bundle: bundle)) {
                                modelState = .downloading
                                isPolling = true
                                Task {
                                    await engine.loadModel()
                                    isPolling = false
                                    modelState = engine.modelState
                                    downloadProgress = engine.downloadProgress
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(.vertical, 4)

                if case .ready = modelState {
                    Divider()
                    vocabularyBoostingSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            if engine.canDismissSettingsAfterSetup {
                Divider()

                HStack {
                    Spacer()

                    Button(String(localized: "Done", bundle: bundle)) {
                        finishSetupAndClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
                .background(.bar)
            }
        }
        .onAppear {
            selectedVersion = engine.selectedVersion
            modelState = engine.modelState
            downloadProgress = engine.downloadProgress
            boostingEnabled = engine.vocabularyBoostingEnabled
            ctcModelState = engine.ctcModelState
            boostingTermCount = engine.lastBoostingTermCount
            if let token = engine._hfToken, !token.isEmpty {
                hfTokenInput = token
            }
            if case .downloading = engine.modelState { isPolling = true }
        }
        .onChange(of: selectedVersion) { _, newVersion in
            guard newVersion != engine.selectedVersion else { return }
            engine.selectedVersion = newVersion
            engine.store.setUserDefault(newVersion.rawValue, forKey: "selectedVersion")
            if engine.loadedModelId != nil {
                // Reload with new version
                modelState = .downloading
                downloadProgress = 0.05
                isPolling = true
                Task {
                    engine.unloadModel(clearPersistence: false)
                    await engine.loadModel()
                    isPolling = false
                    modelState = engine.modelState
                    downloadProgress = engine.downloadProgress
                }
            }
        }
        .onReceive(pollTimer) { _ in
            guard isPolling else { return }
            downloadProgress = engine.downloadProgress
            let engineState = engine.modelState
            if engineState != .notLoaded {
                modelState = engineState
            }
            ctcModelState = engine.ctcModelState
            boostingTermCount = engine.lastBoostingTermCount
            if case .ready = engineState { isPolling = false }
            else if case .error = engineState { isPolling = false }
        }
        .onChange(of: hfTokenInput) { _, newValue in
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue != storedHfToken {
                tokenValidationResult = nil
            }
        }
    }

    @ViewBuilder
    private var vocabularyBoostingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vocabulary Boosting", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Improves recognition of custom terms from your Dictionary using a secondary CTC model.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: $boostingEnabled) {
                Text("Enable Vocabulary Boosting", bundle: bundle)
            }
            .onChange(of: boostingEnabled) { _, newValue in
                engine.setBoostingEnabled(newValue)
                ctcModelState = engine.ctcModelState
            }

            if boostingEnabled {
                HStack(spacing: 6) {
                    switch ctcModelState {
                    case .notDownloaded:
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("CTC model (~100 MB) - downloads automatically on first use, or:", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Download Now", bundle: bundle)) {
                            isPolling = true
                            Task {
                                await engine.downloadCtcModel()
                                ctcModelState = engine.ctcModelState
                                isPolling = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                    case .downloading:
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading CTC model...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .ready:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        if boostingTermCount > 0 {
                            Text("Ready - \(boostingTermCount) terms loaded", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Ready - add terms in Dictionary settings", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                    case .error(let message):
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button(String(localized: "Retry", bundle: bundle)) {
                            isPolling = true
                            Task {
                                await engine.downloadCtcModel()
                                ctcModelState = engine.ctcModelState
                                isPolling = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }

    private func validateAndSaveHuggingFaceToken() {
        let trimmedToken = trimmedHfTokenInput
        guard !trimmedToken.isEmpty else { return }

        isValidatingToken = true
        tokenValidationResult = nil

        Task {
            let isValid = await engine.validateHuggingFaceToken(trimmedToken)
            await MainActor.run {
                isValidatingToken = false
                tokenValidationResult = isValid
                if isValid {
                    engine.setHuggingFaceToken(trimmedToken)
                    hfTokenInput = trimmedToken
                }
            }
        }
    }

    private func finishSetupAndClose() {
        dismiss()
    }
}
