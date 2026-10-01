import Foundation
import Combine
import LeiseCore
import XCTest
@testable import Leise

enum TestSupport {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let artifactsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LeiseTests-artifacts", isDirectory: true)
    private static let deferredCleanupRoot = artifactsRoot
        .appendingPathComponent(".deferred-cleanup", isDirectory: true)
    private static let staleDirectoryLifetime: TimeInterval = 24 * 60 * 60

    static func makeTemporaryDirectory(prefix: String = "LeiseTests") throws -> URL {
        try ensureArtifactsDirectories()
        cleanupStaleDirectories()

        let directory = artifactsRoot
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remove(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        do {
            try ensureArtifactsDirectories()

            let standardizedDirectory = directory.standardizedFileURL
            let deferredRootPath = deferredCleanupRoot.standardizedFileURL.path
            let artifactsRootPath = artifactsRoot.standardizedFileURL.path

            guard standardizedDirectory.path.hasPrefix(artifactsRootPath),
                  !standardizedDirectory.path.hasPrefix(deferredRootPath) else {
                try FileManager.default.removeItem(at: standardizedDirectory)
                return
            }

            let destination = deferredCleanupRoot
                .appendingPathComponent("\(directory.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: standardizedDirectory, to: destination)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func ensureArtifactsDirectories() throws {
        try FileManager.default.createDirectory(at: artifactsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deferredCleanupRoot, withIntermediateDirectories: true)
    }

    static func localizedCatalogValue(for key: String, language: String) throws -> String {
        let localizations = try catalogLocalizations(for: key)
        let languageEntry = try XCTUnwrap(
            localizations[language] as? [String: Any],
            "Missing \(language) localization for key: \(key)"
        )
        let stringUnit = try XCTUnwrap(
            languageEntry["stringUnit"] as? [String: Any],
            "Missing stringUnit for key: \(key)"
        )
        return try XCTUnwrap(
            stringUnit["value"] as? String,
            "Missing localized value for key: \(key)"
        )
    }

    /// Resolves the way `String(localized:)` does at runtime: the first
    /// preferred language the bundle supports wins, and the catalog's source
    /// language (or a language without an entry) yields the key itself.
    static func localizedCatalogValue(
        for key: String,
        preferredLanguages: [String],
        bundle: Bundle = .main
    ) throws -> String {
        let language = Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: preferredLanguages
        ).first
        return try localizedCatalogValue(for: key, resolvedLanguage: language)
    }

    static func localizedCatalogValueForCurrentLocale(for key: String, bundle: Bundle = .main) throws -> String {
        try localizedCatalogValue(for: key, resolvedLanguage: bundle.preferredLocalizations.first)
    }

    private static func localizedCatalogValue(for key: String, resolvedLanguage: String?) throws -> String {
        let localizations = try catalogLocalizations(for: key)
        guard let resolvedLanguage,
              let languageEntry = localizations[resolvedLanguage] as? [String: Any],
              let stringUnit = languageEntry["stringUnit"] as? [String: Any],
              let value = stringUnit["value"] as? String else {
            return key
        }
        return value
    }

    private static func cleanupStaleDirectories() {
        let cutoff = Date().addingTimeInterval(-staleDirectoryLifetime)
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey]

        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: deferredCleanupRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for directory in directories {
            let values = try? directory.resourceValues(forKeys: resourceKeys)
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            guard modifiedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func catalogLocalizations(for key: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Leise/Resources/Localizable.xcstrings"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing catalog entry for key: \(key)")
        return try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for key: \(key)")
    }
}

@MainActor
final class TestTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (TranscriptionRequest) async throws -> EngineTranscriptionResult

    let id: String
    let displayName: String
    let models: [TranscriptionModel]
    var selectedModelID: String?
    var capabilities: TranscriptionCapabilities
    var isReady: Bool
    var allowsFinalTranscriptionPrecomputation: Bool
    var preparationStatus: ModelPreparationStatus { isReady ? .ready : .idle }
    var stateDidChange: AnyPublisher<Void, Never> { stateSubject.eraseToAnyPublisher() }

    private let stateSubject = PassthroughSubject<Void, Never>()
    private let handler: Handler
    private(set) var requests: [TranscriptionRequest] = []
    private(set) var selectedModelHistory: [String] = []
    private(set) var prepareCallCount = 0
    private(set) var prepareForDictationCallCount = 0
    private(set) var prepareAllowDownloadsHistory: [Bool] = []
    private(set) var unloadCallCount = 0
    private(set) var precomputationRequests: [TranscriptionPrecomputationRequest] = []
    private(set) var discardedPrecomputationSessionIDs: [UUID] = []

    init(
        id: String = "parakeet",
        displayName: String = "Parakeet",
        models: [TranscriptionModel] = [
            TranscriptionModel(id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT v3")
        ],
        selectedModelID: String? = "parakeet-tdt-0.6b-v3",
        capabilities: TranscriptionCapabilities = .init(
            supportedLanguages: ["de", "en"],
            supportsBatchPreview: true,
            allowsBatchPreviewFallback: true,
            dictionaryHints: .available
        ),
        isReady: Bool = true,
        allowsFinalTranscriptionPrecomputation: Bool = false,
        handler: @escaping Handler = { _ in EngineTranscriptionResult(text: "mock transcription") }
    ) {
        self.id = id
        self.displayName = displayName
        self.models = models
        self.selectedModelID = selectedModelID
        self.capabilities = capabilities
        self.isReady = isReady
        self.allowsFinalTranscriptionPrecomputation = allowsFinalTranscriptionPrecomputation
        self.handler = handler
    }

    func selectModel(id: String) {
        selectedModelID = id
        selectedModelHistory.append(id)
        stateSubject.send()
    }

    func prepareModel(id: String?, allowDownloads: Bool) async throws {
        prepareCallCount += 1
        prepareAllowDownloadsHistory.append(allowDownloads)
        if let id { selectModel(id: id) }
        isReady = true
        stateSubject.send()
    }

    func prepareForDictation() async {
        prepareForDictationCallCount += 1
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> EngineTranscriptionResult {
        requests.append(request)
        return try await handler(request)
    }

    func shouldPrecomputeFinalTranscription(dictionaryTermHints: [DictionaryTermHint]) -> Bool {
        allowsFinalTranscriptionPrecomputation && !dictionaryTermHints.isEmpty
    }

    func precomputeFinalTranscription(_ request: TranscriptionPrecomputationRequest) async {
        precomputationRequests.append(request)
    }

    func discardFinalTranscriptionPrecomputation(sessionID: UUID) {
        discardedPrecomputationSessionIDs.append(sessionID)
    }

    func unloadModel(clearPersistence _: Bool) {
        unloadCallCount += 1
        isReady = false
        stateSubject.send()
    }
}

@MainActor
final class MemoizedFeatureTests: XCTestCase {
    func testFactoryIsDeferredAndRunsOnce() {
        var constructionCount = 0
        let feature = MemoizedFeature {
            constructionCount += 1
            return NSObject()
        }

        XCTAssertFalse(feature.isInitialized)
        XCTAssertEqual(constructionCount, 0)

        let first = feature.value
        let second = feature.value

        XCTAssertTrue(feature.isInitialized)
        XCTAssertTrue(first === second)
        XCTAssertEqual(constructionCount, 1)
    }

    func testHotkeyActionsWaitForCompleteDictationBindings() {
        let service = HotkeyService()
        var actions: [String] = []

        service.dispatchDictationStartForTesting(42)
        service.dispatchDictationStopForTesting()
        service.onDictationStart = { actions.append("start:\($0)") }
        service.onDictationStop = { actions.append("stop") }

        XCTAssertTrue(actions.isEmpty)

        service.onProfileDictationStart = { _, _ in actions.append("profile") }

        XCTAssertEqual(actions, ["start:42", "stop"])
    }
}
