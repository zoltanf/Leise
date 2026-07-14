import Combine
import Foundation

public struct TranscriptionAudio: Sendable {
    public let samples: [Float]
    public let duration: TimeInterval

    public init(samples: [Float], duration: TimeInterval? = nil) {
        self.samples = samples
        self.duration = duration ?? Double(samples.count) / 16_000
    }
}

public struct TranscriptionModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct DictionaryTermHint: Equatable, Codable, Sendable {
    public let text: String
    public let ctcMinSimilarity: Float?

    public init(text: String, ctcMinSimilarity: Float? = nil) {
        self.text = text
        self.ctcMinSimilarity = ctcMinSimilarity
    }
}

public struct TranscriptionSourceProgress: Equatable, Sendable {
    public let processedDuration: TimeInterval
    public let totalDuration: TimeInterval

    public init(processedDuration: TimeInterval, totalDuration: TimeInterval) {
        self.processedDuration = processedDuration
        self.totalDuration = totalDuration
    }

    public var fractionCompleted: Double {
        guard totalDuration > 0 else { return 0 }
        return min(max(processedDuration / totalDuration, 0), 1)
    }
}

public enum TranscriptionRequestPurpose: Equatable, Sendable {
    case final
    case preview
}

public struct TranscriptionPrecomputationRequest: Sendable {
    public let sessionID: UUID
    public let audio: TranscriptionAudio
    public let prompt: String?
    public let dictionaryTermHints: [DictionaryTermHint]

    public init(
        sessionID: UUID,
        audio: TranscriptionAudio,
        prompt: String? = nil,
        dictionaryTermHints: [DictionaryTermHint] = []
    ) {
        self.sessionID = sessionID
        self.audio = audio
        self.prompt = prompt
        self.dictionaryTermHints = dictionaryTermHints
    }
}

public struct EngineTranscriptionSegment: Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct EngineTranscriptionResult: Equatable, Sendable {
    public let text: String
    public let detectedLanguage: String?
    public let segments: [EngineTranscriptionSegment]

    public init(
        text: String,
        detectedLanguage: String? = nil,
        segments: [EngineTranscriptionSegment] = []
    ) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.segments = segments
    }
}

public enum DictionaryHintSupport: Equatable, Sendable {
    case unavailable
    case requiresSetting
    case available
}

public struct TranscriptionCapabilities: Equatable, Sendable {
    public let supportedLanguages: [String]
    public let supportsBatchPreview: Bool
    public let allowsBatchPreviewFallback: Bool
    public let dictionaryHints: DictionaryHintSupport

    public init(
        supportedLanguages: [String],
        supportsBatchPreview: Bool,
        allowsBatchPreviewFallback: Bool,
        dictionaryHints: DictionaryHintSupport
    ) {
        self.supportedLanguages = supportedLanguages
        self.supportsBatchPreview = supportsBatchPreview
        self.allowsBatchPreviewFallback = allowsBatchPreviewFallback
        self.dictionaryHints = dictionaryHints
    }
}

public struct TranscriptionRequest: Sendable {
    public typealias TextProgress = @Sendable (String) -> Bool
    public typealias SourceProgress = @Sendable (TranscriptionSourceProgress) -> Bool
    public typealias CancellationCheck = @Sendable () -> Bool

    public let audio: TranscriptionAudio
    public let language: String?
    public let prompt: String?
    public let dictionaryTermHints: [DictionaryTermHint]
    public let purpose: TranscriptionRequestPurpose
    public let sessionID: UUID?
    public let onTextProgress: TextProgress
    public let onSourceProgress: SourceProgress
    public let isCancelled: CancellationCheck

    public init(
        audio: TranscriptionAudio,
        language: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [DictionaryTermHint] = [],
        purpose: TranscriptionRequestPurpose = .final,
        sessionID: UUID? = nil,
        onTextProgress: @escaping TextProgress = { _ in true },
        onSourceProgress: @escaping SourceProgress = { _ in true },
        isCancelled: @escaping CancellationCheck = { Task.isCancelled }
    ) {
        self.audio = audio
        self.language = language
        self.prompt = prompt
        self.dictionaryTermHints = dictionaryTermHints
        self.purpose = purpose
        self.sessionID = sessionID
        self.onTextProgress = onTextProgress
        self.onSourceProgress = onSourceProgress
        self.isCancelled = isCancelled
    }
}

public enum ModelPreparationStatus: Equatable, Sendable {
    case idle
    case preparing(message: String, progress: Double?)
    case ready
    case failed(message: String)
}

@MainActor
public protocol TranscriptionEngine: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var models: [TranscriptionModel] { get }
    var selectedModelID: String? { get }
    var capabilities: TranscriptionCapabilities { get }
    var isReady: Bool { get }
    var preparationStatus: ModelPreparationStatus { get }
    var stateDidChange: AnyPublisher<Void, Never> { get }

    func selectModel(id: String)
    func prepareModel(id: String?, allowDownloads: Bool) async throws
    func shouldPrecomputeFinalTranscription(dictionaryTermHints: [DictionaryTermHint]) -> Bool
    func precomputeFinalTranscription(_ request: TranscriptionPrecomputationRequest) async
    func discardFinalTranscriptionPrecomputation(sessionID: UUID)
    func transcribe(_ request: TranscriptionRequest) async throws -> EngineTranscriptionResult
    func unloadModel(clearPersistence: Bool)
}

public extension TranscriptionEngine {
    func shouldPrecomputeFinalTranscription(dictionaryTermHints _: [DictionaryTermHint]) -> Bool {
        false
    }

    func precomputeFinalTranscription(_: TranscriptionPrecomputationRequest) async {}

    func discardFinalTranscriptionPrecomputation(sessionID _: UUID) {}

    func prepareModel(id: String? = nil) async throws {
        try await prepareModel(id: id, allowDownloads: true)
    }

    func unloadModel() {
        unloadModel(clearPersistence: true)
    }
}

public enum TranscriptionEngineFailure: LocalizedError, Sendable {
    case notReady
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notReady:
            "The transcription model is not ready."
        case .cancelled:
            "Transcription was cancelled."
        case .failed(let message):
            message
        }
    }
}
