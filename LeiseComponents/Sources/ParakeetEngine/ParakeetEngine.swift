import Foundation
import Combine
import OSLog
import SwiftUI
import FluidAudio
import LeiseCore

enum TranscriptionPriority: Int, Sendable {
    case final = 0
    case preview = 1
}

actor AsyncTranscriptionGate {
    private struct Waiter {
        let id: UUID
        let priority: TranscriptionPriority
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    func withLock<T: Sendable>(
        priority: TranscriptionPriority,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(priority: priority)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(priority: TranscriptionPriority) async throws {
        guard isLocked else {
            try Task.checkCancellation()
            isLocked = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        let nextIndex = waiters.indices.min { lhs, rhs in
            waiters[lhs].priority.rawValue < waiters[rhs].priority.rawValue
        } ?? waiters.startIndex
        let next = waiters.remove(at: nextIndex)
        next.continuation.resume()
    }
}

public struct ParakeetComponent: @unchecked Sendable {
    public let engine: any TranscriptionEngine
    public let settingsView: AnyView
}

public enum ParakeetComponentFactory {
    @MainActor
    public static func make(
        store: any ParakeetStore,
        modelSupplementaryView: @escaping @MainActor () -> AnyView = { AnyView(EmptyView()) }
    ) -> ParakeetComponent {
        let implementation = ParakeetEngineImplementation(store: store)
        return ParakeetComponent(
            engine: implementation,
            settingsView: AnyView(ParakeetSettingsView(
                engine: implementation,
                modelSupplementaryView: modelSupplementaryView
            ))
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
    static let v2BundledFolderName = "parakeet-tdt-0.6b-v2"
    static let v3BundledFolderName = "parakeet-tdt-0.6b-v3"
    static let ctcBundledFolderName = "parakeet-ctc-110m-coreml"
    private static let logger = Logger(subsystem: "com.leise.engine.parakeet", category: "Transcription")
    private static let shortClipConfidenceThreshold: Float = 0.55
    private static let shortClipConfidenceGateDuration: TimeInterval = 1.0
    private static let fluidAudioProgressMinimumSampleCount = 240_000
    private static let modelWarmupSampleCount = 16_000
    static let ctcChunkSampleCount = ASRConstants.maxModelSamples
    static let ctcChunkOverlapSampleCount = 32_000
    static var ctcChunkStrideSampleCount: Int {
        ctcChunkSampleCount - ctcChunkOverlapSampleCount
    }
    typealias VocabularyAssetFetcher = @Sendable (_ url: URL, _ description: String) async throws -> Data

    fileprivate let store: any ParakeetStore
    fileprivate var asrManager: AsrManager?
    fileprivate var loadedAsrModels: AsrModels?
    fileprivate var loadedModelId: String?
    fileprivate var _selectedModelId: String?
    private let stateSubject = PassthroughSubject<Void, Never>()
    var modelState: ParakeetModelState = .notLoaded { didSet { stateSubject.send() } }
    private var modelLoadTask: Task<Void, Never>?
    private var modelLoadGeneration = UUID()
    fileprivate var downloadProgress: Double = 0
    fileprivate var selectedVersion: ParakeetVersion = .v2
    fileprivate var _hfToken: String?

    // Vocabulary Boosting
    fileprivate var ctcModels: CtcModels?
    private var ctcModelLoadTask: Task<Void, Never>?
    private var ctcModelLoadGeneration = UUID()
    fileprivate var ctcModelDirectory: URL?
    fileprivate var ctcTokenizer: CtcTokenizer?
    fileprivate var ctcSpotter: CtcKeywordSpotter?
    fileprivate var customVocabulary: CustomVocabularyContext?
    fileprivate var vocabularyRescorer: VocabularyRescorer?
    fileprivate var vocabSizeConfig: ContextBiasingConstants.VocabSizeConfig?
    fileprivate var vocabularyBoostingEnabled: Bool = false
    struct CtcLogProbabilityChunk: Sendable {
        let startSample: Int
        let endSample: Int
        let logProbs: [[Float]]
        let frameDuration: Double
    }
    private struct VocabularyPrecomputationSession: Sendable {
        let id: UUID
        let vocabularySignature: String
        let modelID: String
        var chunksByStartSample: [Int: CtcLogProbabilityChunk]
    }
    private var vocabularyPrecomputationSession: VocabularyPrecomputationSession?
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
    var isOfflineDistribution: Bool { store.bundledModelsDirectory != nil }
    var usesBundledModels: Bool { isOfflineDistribution }
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
        prompt: String?,
        purpose: TranscriptionRequestPurpose = .final,
        sessionID: UUID? = nil
    ) async throws -> EngineTranscriptionResult {
        try await transcribe(
            audio: audio,
            language: language,
            prompt: prompt,
            dictionaryTermHints: [],
            purpose: purpose,
            sessionID: sessionID,
            onProgress: { _ in true },
            onSourceProgress: { _ in true }
        )
    }

    func transcribe(
        audio: TranscriptionAudio,
        language: String?,
        prompt: String?,
        dictionaryTermHints: [DictionaryTermHint],
        purpose: TranscriptionRequestPurpose = .final,
        sessionID: UUID? = nil,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (TranscriptionSourceProgress) -> Bool
    ) async throws -> EngineTranscriptionResult {
        let priority: TranscriptionPriority = purpose == .final ? .final : .preview
        return try await transcriptionGate.withLock(priority: priority) {
            try await transcribeSerially(
                audio: audio,
                language: language,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                purpose: purpose,
                sessionID: sessionID,
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
        purpose: TranscriptionRequestPurpose,
        sessionID: UUID?,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (TranscriptionSourceProgress) -> Bool
    ) async throws -> EngineTranscriptionResult {
        guard let asrManager else {
            throw TranscriptionEngineFailure.notReady
        }

        if vocabularyBoostingEnabled, purpose == .final {
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

        let baseTranscriptionStart = ContinuousClock.now
        let result = try await asrManager.transcribe(
            normalizedSamples,
            decoderState: &decoderState,
            language: fluidLanguage
        )
        Self.logger.info(
            "Base TDT transcription finished in \(ContinuousClock.now - baseTranscriptionStart), purpose=\(String(describing: purpose), privacy: .public), audioSeconds=\(String(format: "%.1f", audio.duration), privacy: .public)"
        )
        let finalResult = if purpose == .final {
            await applyVocabularyRescoringIfNeeded(
                to: result,
                audioSamples: normalizedSamples,
                sessionID: sessionID
            )
        } else {
            result
        }
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

        let segments = Self.transcriptionSegments(
            from: finalResult.tokenTimings,
            purpose: purpose
        )

        _ = onProgress(finalResult.text)
        return EngineTranscriptionResult(text: finalResult.text, detectedLanguage: nil, segments: segments)
    }

    static func transcriptionSegments(
        from tokenTimings: [TokenTiming]?,
        purpose: TranscriptionRequestPurpose
    ) -> [EngineTranscriptionSegment] {
        guard shouldBuildTranscriptionSegments(for: purpose),
              let tokenTimings,
              !tokenTimings.isEmpty else {
            return []
        }
        return groupTokensIntoSegments(tokenTimings)
    }

    static func shouldBuildTranscriptionSegments(for purpose: TranscriptionRequestPurpose) -> Bool {
        purpose == .final
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

    func downloadCtcModel() async {
        if ctcModels != nil, ctcTokenizer != nil {
            ctcModelState = .ready
            return
        }
        if let ctcModelLoadTask {
            await ctcModelLoadTask.value
            return
        }

        let generation = UUID()
        ctcModelLoadGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCtcModelLoad(generation: generation)
        }
        ctcModelLoadTask = task
        await task.value
        if ctcModelLoadGeneration == generation {
            ctcModelLoadTask = nil
        }
    }

    private func performCtcModelLoad(generation: UUID) async {
        ctcModelState = .downloading
        do {
            let directory: URL
            let models: CtcModels
            if let bundledDirectory = bundledCtcModelDirectory {
                disableFluidAudioNetwork(for: bundledDirectory)
                try validateBundledCtcModel(at: bundledDirectory)
                directory = bundledDirectory
                models = try await CtcModels.loadDirect(from: bundledDirectory, variant: .ctc110m)
            } else {
                applyHuggingFaceTokenToEnvironment()
                models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
            }
            let tokenizer = try await CtcTokenizer.load(from: directory)
            guard !Task.isCancelled, ctcModelLoadGeneration == generation else { return }
            ctcModels = models
            ctcModelDirectory = directory
            ctcTokenizer = tokenizer
            ctcModelState = .ready
        } catch where Task.isCancelled || ctcModelLoadGeneration != generation {
            return
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

    func shouldPrecomputeFinalTranscription(dictionaryTermHints: [DictionaryTermHint]) -> Bool {
        vocabularyBoostingEnabled && !dictionaryTermHints.isEmpty && isConfigured
    }

    func precomputeFinalTranscription(_ request: TranscriptionPrecomputationRequest) async {
        guard shouldPrecomputeFinalTranscription(dictionaryTermHints: request.dictionaryTermHints) else {
            return
        }

        await configureBoostingIfNeeded(
            prompt: request.prompt,
            dictionaryTermHints: request.dictionaryTermHints
        )
        guard let spotter = ctcSpotter,
              let vocabulary = customVocabulary,
              let vocabularySignature = lastConfiguredPrompt,
              let modelID = loadedModelId else {
            return
        }

        if vocabularyPrecomputationSession?.id != request.sessionID
            || vocabularyPrecomputationSession?.vocabularySignature != vocabularySignature
            || vocabularyPrecomputationSession?.modelID != modelID {
            vocabularyPrecomputationSession = VocabularyPrecomputationSession(
                id: request.sessionID,
                vocabularySignature: vocabularySignature,
                modelID: modelID,
                chunksByStartSample: [:]
            )
        }

        let inferenceVocabulary = Self.inferenceOnlyVocabulary(from: vocabulary)
        let ranges = Self.ctcChunkRanges(
            sampleCount: request.audio.samples.count,
            includeIncompleteTail: false
        )

        for range in ranges {
            guard !Task.isCancelled else { return }
            guard vocabularyPrecomputationSession?.chunksByStartSample[range.lowerBound] == nil else {
                continue
            }

            let startedAt = ContinuousClock.now
            do {
                let spotResult = try await spotter.spotKeywordsWithLogProbs(
                    audioSamples: Array(request.audio.samples[range]),
                    customVocabulary: inferenceVocabulary,
                    minScore: nil
                )
                guard vocabularyPrecomputationSession?.id == request.sessionID,
                      vocabularyPrecomputationSession?.vocabularySignature == vocabularySignature,
                      vocabularyPrecomputationSession?.modelID == modelID else {
                    return
                }
                vocabularyPrecomputationSession?.chunksByStartSample[range.lowerBound] = CtcLogProbabilityChunk(
                    startSample: range.lowerBound,
                    endSample: range.upperBound,
                    logProbs: spotResult.logProbs,
                    frameDuration: spotResult.frameDuration
                )
                Self.logger.info(
                    "Precomputed vocabulary CTC window in \(ContinuousClock.now - startedAt), startSeconds=\(String(format: "%.1f", Double(range.lowerBound) / 16_000), privacy: .public)"
                )
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.warning("Vocabulary CTC precomputation failed: \(error.localizedDescription)")
                return
            }
        }
    }

    func discardFinalTranscriptionPrecomputation(sessionID: UUID) {
        guard vocabularyPrecomputationSession?.id == sessionID else { return }
        vocabularyPrecomputationSession = nil
    }

    static func ctcChunkRanges(
        sampleCount: Int,
        includeIncompleteTail: Bool
    ) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + ctcChunkSampleCount, sampleCount)
            guard includeIncompleteTail || end - start == ctcChunkSampleCount else { break }
            ranges.append(start..<end)
            if end >= sampleCount { break }
            start += ctcChunkStrideSampleCount
        }
        return ranges
    }

    static func mergeCtcLogProbabilityChunks(
        _ chunks: [CtcLogProbabilityChunk]
    ) -> (logProbs: [[Float]], frameDuration: Double) {
        guard let first = chunks.first, first.frameDuration > 0 else {
            return ([], 0)
        }

        let frameDuration = first.frameDuration
        let overlapFrames = Int(
            Double(ctcChunkOverlapSampleCount) / 16_000.0 / frameDuration
        )
        var merged: [[Float]] = []

        for (index, chunk) in chunks.enumerated() where !chunk.logProbs.isEmpty {
            if index == 0 {
                merged.append(contentsOf: chunk.logProbs)
                continue
            }

            let overlapCount = min(overlapFrames, merged.count, chunk.logProbs.count)
            if overlapCount > 0 {
                let existingStart = merged.count - overlapCount
                for overlapIndex in 0..<overlapCount {
                    merged[existingStart + overlapIndex] = mergeCtcOverlapFrame(
                        existing: merged[existingStart + overlapIndex],
                        incoming: chunk.logProbs[overlapIndex]
                    )
                }
            }
            if overlapCount < chunk.logProbs.count {
                merged.append(contentsOf: chunk.logProbs.suffix(from: overlapCount))
            }
        }

        return (merged, frameDuration)
    }

    private static func mergeCtcOverlapFrame(existing: [Float], incoming: [Float]) -> [Float] {
        let count = min(existing.count, incoming.count)
        guard count > 0 else { return existing }

        var averaged = [Float](repeating: 0, count: count)
        for index in 0..<count {
            averaged[index] = (existing[index] + incoming[index]) / 2
        }
        return averaged
    }

    private static func inferenceOnlyVocabulary(
        from vocabulary: CustomVocabularyContext
    ) -> CustomVocabularyContext {
        CustomVocabularyContext(
            terms: Array(vocabulary.terms.prefix(1)),
            alpha: vocabulary.alpha,
            minCtcScore: vocabulary.minCtcScore,
            minSimilarity: vocabulary.minSimilarity,
            minCombinedConfidence: vocabulary.minCombinedConfidence,
            minTermLength: vocabulary.minTermLength
        )
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
        let ctcModelDir = ctcModelDirectory ?? CtcModels.defaultCacheDirectory(for: ctcModels.variant)
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
        audioSamples: [Float],
        sessionID: UUID?
    ) async -> ASRResult {
        defer {
            if let sessionID {
                discardFinalTranscriptionPrecomputation(sessionID: sessionID)
            }
        }
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
            let ctcStartedAt = ContinuousClock.now
            let cachedSession = sessionID.flatMap { id -> VocabularyPrecomputationSession? in
                guard let session = vocabularyPrecomputationSession,
                      session.id == id,
                      session.vocabularySignature == lastConfiguredPrompt,
                      session.modelID == loadedModelId,
                      !session.chunksByStartSample.isEmpty else {
                    return nil
                }
                return session
            }
            let spotResult: CtcKeywordSpotter.SpotKeywordsResult
            let reusedChunkCount: Int
            if let cachedSession {
                let ranges = Self.ctcChunkRanges(
                    sampleCount: audioSamples.count,
                    includeIncompleteTail: true
                )
                var chunks: [CtcLogProbabilityChunk] = []
                var reuseCount = 0
                let inferenceVocabulary = Self.inferenceOnlyVocabulary(from: vocab)

                for range in ranges {
                    if let cached = cachedSession.chunksByStartSample[range.lowerBound],
                       cached.endSample == range.upperBound {
                        chunks.append(cached)
                        reuseCount += 1
                        continue
                    }

                    let computed = try await spotter.spotKeywordsWithLogProbs(
                        audioSamples: Array(audioSamples[range]),
                        customVocabulary: inferenceVocabulary,
                        minScore: nil
                    )
                    chunks.append(CtcLogProbabilityChunk(
                        startSample: range.lowerBound,
                        endSample: range.upperBound,
                        logProbs: computed.logProbs,
                        frameDuration: computed.frameDuration
                    ))
                }

                let merged = Self.mergeCtcLogProbabilityChunks(chunks)
                spotResult = spotter.spotKeywordsFromLogProbs(
                    logProbs: merged.logProbs,
                    frameDuration: merged.frameDuration,
                    customVocabulary: vocab,
                    minScore: nil
                )
                reusedChunkCount = reuseCount
            } else {
                spotResult = try await spotter.spotKeywordsWithLogProbs(
                    audioSamples: audioSamples,
                    customVocabulary: vocab,
                    minScore: nil
                )
                reusedChunkCount = 0
            }
            Self.logger.info(
                "Vocabulary CTC inference and spotting finished in \(ContinuousClock.now - ctcStartedAt), reusedChunks=\(reusedChunkCount, privacy: .public)"
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
        vocabularyPrecomputationSession = nil
    }

    private func clearVocabularyBoostingState(resetModelState: Bool = false) {
        ctcModelLoadGeneration = UUID()
        ctcModelLoadTask?.cancel()
        ctcModelLoadTask = nil
        clearConfiguredVocabulary()
        ctcModels = nil
        ctcModelDirectory = nil
        ctcTokenizer = nil
        if resetModelState {
            ctcModelState = .notDownloaded
        }
    }

    // MARK: - Model Management

    func loadModel() async {
        if let modelLoadTask {
            await modelLoadTask.value
            return
        }

        let generation = UUID()
        modelLoadGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performModelLoad(generation: generation)
        }
        modelLoadTask = task
        await task.value
        if modelLoadGeneration == generation {
            modelLoadTask = nil
        }
    }

    private func performModelLoad(generation: UUID) async {
        let loadingVersion = selectedVersion
        modelState = .downloading
        downloadProgress = 0.1

        do {
            let models: AsrModels
            if let bundledDirectory = bundledAsrModelDirectory(for: loadingVersion) {
                disableFluidAudioNetwork(for: bundledDirectory)
                try validateBundledAsrModel(at: bundledDirectory, version: loadingVersion)
                models = try await AsrModels.load(
                    from: bundledDirectory,
                    version: loadingVersion.asrModelVersion
                )
            } else {
                applyHuggingFaceTokenToEnvironment()
                try await ensureVocabularyAsset(for: loadingVersion)
                models = try await AsrModels.downloadAndLoad(version: loadingVersion.asrModelVersion)
            }
            guard !Task.isCancelled,
                  modelLoadGeneration == generation,
                  selectedVersion == loadingVersion else { return }
            downloadProgress = 0.7

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            await warmUpModel(manager, version: loadingVersion)
            guard !Task.isCancelled,
                  modelLoadGeneration == generation,
                  selectedVersion == loadingVersion else { return }
            downloadProgress = 1.0

            asrManager = manager
            loadedAsrModels = models
            loadedModelId = loadingVersion.modelDef.id
            _selectedModelId = loadingVersion.modelDef.id
            modelState = .ready

            store.setUserDefault(loadingVersion.modelDef.id, forKey: "selectedModel")
            store.setUserDefault(loadingVersion.modelDef.id, forKey: "loadedModel")
            store.setUserDefault(loadingVersion.rawValue, forKey: "selectedVersion")

            if vocabularyBoostingEnabled {
                let ctcDirectory = bundledCtcModelDirectory
                    ?? CtcModels.defaultCacheDirectory(for: .ctc110m)
                if CtcModels.modelsExist(at: ctcDirectory) {
                    await downloadCtcModel()
                }
            }
        } catch where Task.isCancelled || modelLoadGeneration != generation {
            return
        } catch {
            modelState = .error(error.localizedDescription)
            downloadProgress = 0
        }
    }

    private func warmUpModel(_ manager: AsrManager, version: ParakeetVersion) async {
        guard !Task.isCancelled else { return }

        let startedAt = ContinuousClock.now
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        do {
            _ = try await manager.transcribe(
                Array(repeating: Float.zero, count: Self.modelWarmupSampleCount),
                decoderState: &decoderState
            )
            Self.logger.info(
                "Core ML warmup finished in \(ContinuousClock.now - startedAt), model=\(version.rawValue, privacy: .public)"
            )
        } catch is CancellationError {
            return
        } catch {
            // Priming is an optimization. Keep the successfully loaded model available
            // and let a real transcription surface any persistent inference failure.
            Self.logger.warning(
                "Core ML warmup failed for model=\(version.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
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
        modelLoadGeneration = UUID()
        modelLoadTask?.cancel()
        modelLoadTask = nil
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
        if let directory = bundledAsrModelDirectory(for: version) {
            return AsrModels.modelsExist(at: directory, version: version.asrModelVersion)
        }
        let cacheDir = AsrModels.defaultCacheDirectory(for: version.asrModelVersion)
        return AsrModels.modelsExist(at: cacheDir, version: version.asrModelVersion)
    }

    private func bundledAsrModelDirectory(for version: ParakeetVersion) -> URL? {
        guard let root = store.bundledModelsDirectory else { return nil }
        let folderName = switch version {
        case .v2: Self.v2BundledFolderName
        case .v3: Self.v3BundledFolderName
        }
        return root.appendingPathComponent(folderName, isDirectory: true)
    }

    private var bundledCtcModelDirectory: URL? {
        store.bundledModelsDirectory?.appendingPathComponent(
            Self.ctcBundledFolderName,
            isDirectory: true
        )
    }

    private func validateBundledAsrModel(at directory: URL, version: ParakeetVersion) throws {
        guard AsrModels.modelsExist(at: directory, version: version.asrModelVersion) else {
            throw ParakeetBundledModelError.incomplete(version.modelDef.displayName, directory)
        }
    }

    private func validateBundledCtcModel(at directory: URL) throws {
        guard CtcModels.modelsExist(at: directory),
              FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("tokenizer.json").path
              ) else {
            throw ParakeetBundledModelError.incomplete("Parakeet CTC 110M", directory)
        }
    }

    private func disableFluidAudioNetwork(for bundledDirectory: URL) {
        // The offline edition must never fall back to Hugging Face if a packaged
        // Core ML bundle is damaged. Point FluidAudio's model registry at the
        // local, read-only bundle before invoking any of its loaders.
        ModelRegistry.baseURL = bundledDirectory.absoluteString
    }

    // MARK: - Settings View

    var currentSettingsActivity: ParakeetSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            break
        case .downloading:
            return ParakeetSettingsActivity(
                message: isOfflineDistribution ? "Loading included model" : "Downloading model",
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
            return ParakeetSettingsActivity(
                message: isOfflineDistribution
                    ? "Loading included vocabulary model"
                    : "Downloading vocabulary model"
            )
        case .error(let message):
            return ParakeetSettingsActivity(message: message, isError: true)
        }
    }

    var settingsView: AnyView? {
        AnyView(ParakeetSettingsView(
            engine: self,
            modelSupplementaryView: { AnyView(EmptyView()) }
        ))
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

    func prepareForDictation() async {
        guard vocabularyBoostingEnabled,
              ctcModels == nil || ctcTokenizer == nil else {
            return
        }

        let directory = bundledCtcModelDirectory
            ?? CtcModels.defaultCacheDirectory(for: .ctc110m)
        guard CtcModels.modelsExist(at: directory) else { return }
        await downloadCtcModel()
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
            purpose: request.purpose,
            sessionID: request.sessionID,
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
                sizeDescription: "~440 MB",
                ramRequirement: "8 GB+"
            )
        case .v3:
            return ParakeetModelDef(
                id: "parakeet-tdt-0.6b-v3",
                displayName: "Parakeet TDT v3",
                sizeDescription: "~460 MB",
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
            return String(localized: "English only. Usually the best choice for English dictation, with higher English recall than v3.", bundle: bundle)
        case .v3:
            return String(localized: "Supports 25 European languages, including English, German, French, Spanish, and Italian. Choose v3 for non-English dictation.", bundle: bundle)
        }
    }

    func settingsTitle(bundle: Bundle) -> String {
        switch self {
        case .v2:
            return String(localized: "Best for English", bundle: bundle)
        case .v3:
            return String(localized: "Multilingual", bundle: bundle)
        }
    }

    func settingsBadge(bundle: Bundle) -> String {
        switch self {
        case .v2:
            return String(localized: "Default", bundle: bundle)
        case .v3:
            return String(localized: "25 languages", bundle: bundle)
        }
    }

    var settingsSymbolName: String {
        switch self {
        case .v2: return "textformat.abc"
        case .v3: return "globe.europe.africa.fill"
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

private enum ParakeetBundledModelError: LocalizedError {
    case incomplete(String, URL)

    var errorDescription: String? {
        switch self {
        case .incomplete(let modelName, let directory):
            return "The offline edition is missing required files for \(modelName) at \(directory.path). Reinstall the offline edition."
        }
    }
}

// MARK: - Settings View

private struct ParakeetSettingsView: View {
    let engine: ParakeetEngineImplementation
    let modelSupplementaryView: @MainActor () -> AnyView
    private let bundle = Bundle(for: ParakeetEngineImplementation.self)
    @State private var selectedVersion: ParakeetVersion = .v2
    @State private var modelState: ParakeetModelState = .notLoaded
    @State private var downloadProgress: Double = 0
    @State private var isPolling = false
    @State private var boostingEnabled: Bool = false
    @State private var ctcModelState: CtcModelState = .notDownloaded
    @State private var boostingTermCount: Int = 0

    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(
                engine.isOfflineDistribution
                    ? String(localized: "Offline edition: both transcription models and the vocabulary model are included. No model downloads or API key are required.", bundle: bundle)
                    : String(localized: "Both models run privately on your Mac with similar speed, download size, and memory use. No account or API key is required.", bundle: bundle)
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            modelSelectionSection

            Divider()
            modelSupplementaryView()

            Divider()
            vocabularyBoostingSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .onAppear {
            selectedVersion = engine.selectedVersion
            modelState = engine.modelState
            downloadProgress = engine.downloadProgress
            boostingEnabled = engine.vocabularyBoostingEnabled
            ctcModelState = engine.ctcModelState
            boostingTermCount = engine.lastBoostingTermCount
            if case .downloading = engine.modelState { isPolling = true }
        }
        .onChange(of: selectedVersion) { _, newVersion in
            guard newVersion != engine.selectedVersion else { return }
            engine.selectedVersion = newVersion
            engine.store.setUserDefault(newVersion.rawValue, forKey: "selectedVersion")
            if engine.loadedModelId != nil {
                loadSelectedModel(replacingLoadedModel: true)
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
    }

    private var modelSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose your transcription model", bundle: bundle)
                    .font(.subheadline.weight(.semibold))
                Text("Use v2 for English. Choose v3 when you need another supported language.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(ParakeetVersion.allCases, id: \.self) { version in
                    modelSelectionCard(for: version)
                }
            }

            modelStatusRow
        }
    }

    private func modelSelectionCard(for version: ParakeetVersion) -> some View {
        let isSelected = selectedVersion == version

        return Button {
            selectedVersion = version
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: version.settingsSymbolName)
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.09))
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(version.modelDef.displayName)
                            .font(.headline)
                        Text(version.settingsTitle(bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Text(version.settingsBadge(bundle: bundle))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.09))
                        )
                }

                Text(version.settingsDescription(bundle: bundle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack(spacing: 14) {
                    Label(version.modelDef.sizeDescription, systemImage: "arrow.down.circle")
                    Label("RAM: \(version.modelDef.ramRequirement)", systemImage: "memorychip")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.22),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(modelState == .downloading)
        .accessibilityValue(isSelected ? String(localized: "Selected", bundle: bundle) : "")
    }

    private var modelStatusRow: some View {
        HStack(spacing: 12) {
            switch modelState {
            case .notLoaded:
                Label(
                    String(localized: "Ready to load \(selectedVersion.modelDef.displayName)", bundle: bundle),
                    systemImage: "arrow.down.circle"
                )
                .foregroundStyle(.secondary)

                Spacer()

                Button(
                    engine.isOfflineDistribution
                        ? String(localized: "Load Model", bundle: bundle)
                        : String(localized: "Download & Load", bundle: bundle)
                ) {
                    loadSelectedModel()
                }
                .buttonStyle(.borderedProminent)

            case .downloading:
                Label(
                    engine.isOfflineDistribution
                        ? String(localized: "Loading \(selectedVersion.modelDef.displayName)…", bundle: bundle)
                        : String(localized: "Downloading and loading \(selectedVersion.modelDef.displayName)…", bundle: bundle),
                    systemImage: "arrow.down.circle.fill"
                )

                Spacer()

                ProgressView(value: downloadProgress)
                    .frame(width: 110)
                Text("\(Int(downloadProgress * 100))%")
                    .font(.caption)
                    .monospacedDigit()

            case .ready:
                Label(
                    String(localized: "\(selectedVersion.modelDef.displayName) is loaded and ready", bundle: bundle),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

                Spacer()

                Button(String(localized: "Unload", bundle: bundle)) {
                    engine.unloadModel()
                    modelState = engine.modelState
                    ctcModelState = engine.ctcModelState
                    boostingTermCount = 0
                }
                .buttonStyle(.bordered)

            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)

                Spacer()

                Button(String(localized: "Retry", bundle: bundle)) {
                    loadSelectedModel()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .font(.callout)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func loadSelectedModel(replacingLoadedModel: Bool = false) {
        modelState = .downloading
        downloadProgress = 0.05
        isPolling = true
        Task {
            if replacingLoadedModel {
                engine.unloadModel(clearPersistence: false)
            }
            await engine.loadModel()
            isPolling = false
            modelState = engine.modelState
            downloadProgress = engine.downloadProgress
        }
    }

    @ViewBuilder
    private var vocabularyBoostingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vocabulary Boosting", bundle: bundle)
                        .font(.subheadline.weight(.semibold))
                    Text("Works with both Parakeet v2 and v3.", bundle: bundle)
                        .font(.caption.weight(.medium))
                    Text("Improves names and technical terms from your Dictionary by running an additional small speech model locally. It can add processing time to long dictations.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Toggle(isOn: $boostingEnabled) {
                    Text("Enable Vocabulary Boosting", bundle: bundle)
                }
                .labelsHidden()
                .accessibilityLabel(String(localized: "Enable Vocabulary Boosting", bundle: bundle))
            }
            .onChange(of: boostingEnabled) { _, newValue in
                engine.setBoostingEnabled(newValue)
                ctcModelState = engine.ctcModelState
            }

            if boostingEnabled {
                HStack(spacing: 6) {
                    switch ctcModelState {
                    case .notDownloaded:
                        Image(systemName: engine.isOfflineDistribution ? "shippingbox.fill" : "arrow.down.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(
                            engine.isOfflineDistribution
                                ? String(localized: "Vocabulary model included — it loads automatically on first use.", bundle: bundle)
                                : String(localized: "Vocabulary model (~100 MB) — downloads automatically on first use.", bundle: bundle)
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(
                            engine.isOfflineDistribution
                                ? String(localized: "Load Now", bundle: bundle)
                                : String(localized: "Download Now", bundle: bundle)
                        ) {
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
                        Text(
                            engine.isOfflineDistribution
                                ? String(localized: "Loading the included vocabulary model…", bundle: bundle)
                                : String(localized: "Downloading the vocabulary model…", bundle: bundle)
                        )
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
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.primary.opacity(0.035))
                )
            }
        }
    }
}
