import XCTest
@testable import LeiseCore
@testable import ParakeetEngine

@MainActor
final class ParakeetEngineImplementationTests: XCTestCase {
    private final class TestStore: ParakeetStore, @unchecked Sendable {
        private struct Box: @unchecked Sendable { let value: Any }
        private let lock = NSLock()
        private var defaults: [String: Box]
        private var secrets: [String: String]
        let shouldRestoreLoadedModelsPassively: Bool
        let bundledModelsDirectory: URL?

        init(
            defaults: [String: Any] = [:],
            secrets: [String: String] = [:],
            shouldRestoreLoadedModelsPassively: Bool = true,
            bundledModelsDirectory: URL? = nil
        ) throws {
            self.defaults = defaults.mapValues(Box.init(value:))
            self.secrets = secrets
            self.shouldRestoreLoadedModelsPassively = shouldRestoreLoadedModelsPassively
            self.bundledModelsDirectory = bundledModelsDirectory
        }

        func storeSecret(key: String, value: String) throws {
            lock.withLock { secrets[key] = value }
        }

        func loadSecret(key: String) -> String? {
            lock.withLock { secrets[key] }
        }

        func userDefault(forKey key: String) -> Any? {
            lock.withLock { defaults[key]?.value }
        }

        func setUserDefault(_ value: Any?, forKey key: String) {
            lock.withLock { defaults[key] = value.map(Box.init(value:)) }
        }
    }

    private actor RequestRecorder {
        private var request: URLRequest?

        func set(_ request: URLRequest) {
            self.request = request
        }

        func get() -> URLRequest? {
            request
        }
    }

    private actor VocabularyFetchRecorder {
        private var requests: [(url: URL, description: String)] = []
        private let data: Data?
        private let error: Error?

        init(data: Data) {
            self.data = data
            self.error = nil
        }

        init(error: Error) {
            self.data = nil
            self.error = error
        }

        func fetch(url: URL, description: String) async throws -> Data {
            requests.append((url: url, description: description))
            if let data {
                return data
            }
            throw error ?? URLError(.unknown)
        }

        func requestCount() -> Int {
            requests.count
        }

        func firstRequest() -> (url: URL, description: String)? {
            requests.first
        }
    }

    private func makeEngine(
        store: TestStore? = nil,
        restoresPersistedModel: Bool = false
    ) -> ParakeetEngineImplementation {
        ParakeetEngineImplementation(
            store: store ?? (try! TestStore()),
            restoresPersistedModel: restoresPersistedModel
        )
    }

    private func makeTemporaryDirectory(prefix: String = "ParakeetEngineImplementationTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    func testVocabularyAssetURLsMapToVersionRepositories() {
        XCTAssertEqual(
            ParakeetEngineImplementation.vocabularyAssetURL(for: .v2).absoluteString,
            "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/main/parakeet_vocab.json"
        )
        XCTAssertEqual(
            ParakeetEngineImplementation.vocabularyAssetURL(for: .v3).absoluteString,
            "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/parakeet_vocab.json"
        )
    }

    func testOfflineDistributionUsesBundledAssetsAndLoadingLanguage() throws {
        let directory = try makeTemporaryDirectory(prefix: "OfflineModels")
        let store = try TestStore(bundledModelsDirectory: directory)
        let engine = makeEngine(store: store)

        XCTAssertTrue(engine.isOfflineDistribution)
        engine.modelState = .downloading
        XCTAssertEqual(engine.currentSettingsActivity?.message, "Loading included model")
    }

    func testIncompleteOfflineModelFailsWithoutInstallingCacheFiles() async throws {
        let directory = try makeTemporaryDirectory(prefix: "OfflineModels")
        let store = try TestStore(bundledModelsDirectory: directory)
        let engine = makeEngine(store: store)

        await engine.loadModel()

        guard case .error(let message) = engine.modelState else {
            return XCTFail("Expected an incomplete offline package error")
        }
        XCTAssertTrue(message.contains("Reinstall the offline edition"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            []
        )
    }

    func testIncompleteOfflineVocabularyModelFailsWithoutDownloading() async throws {
        let directory = try makeTemporaryDirectory(prefix: "OfflineModels")
        let store = try TestStore(bundledModelsDirectory: directory)
        let engine = makeEngine(store: store)

        await engine.downloadCtcModel()

        guard case .error(let message) = engine.ctcModelState else {
            return XCTFail("Expected an incomplete offline vocabulary model error")
        }
        XCTAssertTrue(message.contains("Reinstall the offline edition"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            []
        )
    }

    func testEnsureVocabularyAssetSkipsExistingFile() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetEngineImplementation.vocabularyAssetFileName)
        let existingData = Data(#"{"0":"existing"}"#.utf8)
        try existingData.write(to: targetURL)
        let recorder = VocabularyFetchRecorder(data: Data(#"{"0":"downloaded"}"#.utf8))
        let engine = makeEngine()

        try await engine.ensureVocabularyAsset(
            for: .v3,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(try Data(contentsOf: targetURL), existingData)
    }

    func testEnsureVocabularyAssetRepairsEmptyExistingFile() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetEngineImplementation.vocabularyAssetFileName)
        try Data().write(to: targetURL)
        let downloadedData = Data(#"{"0":"downloaded"}"#.utf8)
        let recorder = VocabularyFetchRecorder(data: downloadedData)
        let engine = makeEngine()

        try await engine.ensureVocabularyAsset(
            for: .v3,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        XCTAssertEqual(try Data(contentsOf: targetURL), downloadedData)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testEnsureVocabularyAssetDownloadsMissingFile() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetEngineImplementation.vocabularyAssetFileName)
        let downloadedData = Data(#"{"0":"<blank>"}"#.utf8)
        let recorder = VocabularyFetchRecorder(data: downloadedData)
        let engine = makeEngine()

        try await engine.ensureVocabularyAsset(
            for: .v3,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        XCTAssertEqual(try Data(contentsOf: targetURL), downloadedData)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
        let recordedRequest = await recorder.firstRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url, ParakeetEngineImplementation.vocabularyAssetURL(for: .v3))
        XCTAssertEqual(request.description, "Parakeet TDT v3 vocabulary")
    }

    func testEnsureVocabularyAssetCreatesMissingTargetDirectory() async throws {
        let parentDirectory = try makeTemporaryDirectory()
        let directory = parentDirectory.appendingPathComponent("missing-cache", isDirectory: true)
        let targetURL = directory.appendingPathComponent(ParakeetEngineImplementation.vocabularyAssetFileName)
        let downloadedData = Data(#"{"0":"created-directory"}"#.utf8)
        let recorder = VocabularyFetchRecorder(data: downloadedData)
        let engine = makeEngine()

        try await engine.ensureVocabularyAsset(
            for: .v2,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: targetURL), downloadedData)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
        let recordedRequest = await recorder.firstRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url, ParakeetEngineImplementation.vocabularyAssetURL(for: .v2))
    }

    func testEnsureVocabularyAssetSurfacesFailedFetch() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetEngineImplementation.vocabularyAssetFileName)
        let recorder = VocabularyFetchRecorder(
            error: NSError(
                domain: "ParakeetVocabularyAssetTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "network unavailable"]
            )
        )
        let engine = makeEngine()

        do {
            try await engine.ensureVocabularyAsset(
                for: .v2,
                targetDirectory: directory,
                fetcher: { url, description in
                    try await recorder.fetch(url: url, description: description)
                }
            )
            XCTFail("Expected vocabulary download to fail")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "Failed to download Parakeet vocabulary file for Parakeet TDT v2"
                )
            )
            XCTAssertTrue(error.localizedDescription.contains("network unavailable"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testInitializationPromotesPersistedLoadedModelToSelectedModelWhenSelectionMissing() throws {
        let host = try TestStore(defaults: [
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let engine = makeEngine(store: host)

        XCTAssertEqual(engine.selectedModelID, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertFalse(engine.isConfigured)
    }

    func testInitializationKeepsPersistedSelectedModelVisibleBeforeRestoreCompletes() throws {
        let host = try TestStore(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v2",
            "loadedModel": "parakeet-tdt-0.6b-v2",
        ])
        let engine = makeEngine(store: host)

        XCTAssertEqual(engine.selectedModelID, "parakeet-tdt-0.6b-v2")
        XCTAssertFalse(engine.isConfigured)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v2")
    }

    func testInitializationDoesNotMarkEngineReadyBeforeRestoreSucceeds() throws {
        let host = try TestStore(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v3",
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let engine = makeEngine(store: host)

        XCTAssertFalse(engine.isConfigured)
        XCTAssertEqual(engine.selectedModelID, "parakeet-tdt-0.6b-v3")
    }

    func testUnloadWithoutClearingPersistenceKeepsSelectedAndLoadedModelMarkers() throws {
        let host = try TestStore(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v3",
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let engine = makeEngine(store: host)

        engine.unloadModel(clearPersistence: false)

        XCTAssertFalse(engine.isConfigured)
        XCTAssertEqual(engine.selectedModelID, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v3")
    }

    func testUnloadClearingPersistenceKeepsSelectedModelAndRemovesLoadedModelMarker() throws {
        let host = try TestStore(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v3",
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let engine = makeEngine(store: host)

        engine.unloadModel(clearPersistence: true)

        XCTAssertFalse(engine.isConfigured)
        XCTAssertEqual(engine.selectedModelID, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
    }

    func testInitializationLoadsStoredHuggingFaceToken() throws {
        let host = try TestStore(secrets: ["hf-token": "hf_parakeet_saved"])
        let engine = makeEngine(store: host)

        XCTAssertEqual(engine.huggingFaceToken, "hf_parakeet_saved")
    }

    func testAllowsTranscriptPreviewFallback() throws {
        XCTAssertTrue(makeEngine().capabilities.allowsBatchPreviewFallback)
    }

    func testUsesBatchFallbackForLivePreview() throws {
        let engine = makeEngine()

        XCTAssertTrue(engine.supportsStreaming)
        XCTAssertTrue(engine.capabilities.supportsBatchPreview)
        XCTAssertTrue(engine.capabilities.allowsBatchPreviewFallback)
    }

    func testSourceProgressMapsProgressFractionToAudioDuration() {
        let progress = ParakeetEngineImplementation.sourceProgress(fromFraction: 0.25, totalDuration: 240)

        XCTAssertEqual(progress?.processedDuration, 60)
        XCTAssertEqual(progress?.totalDuration, 240)
        XCTAssertEqual(progress?.fractionCompleted, 0.25)
    }

    func testSourceProgressClampsAndRejectsInvalidDurations() {
        XCTAssertEqual(
            ParakeetEngineImplementation.sourceProgress(fromFraction: 1.5, totalDuration: 10)?.processedDuration,
            10
        )
        XCTAssertEqual(
            ParakeetEngineImplementation.sourceProgress(fromFraction: -0.5, totalDuration: 10)?.processedDuration,
            0
        )
        XCTAssertNil(ParakeetEngineImplementation.sourceProgress(fromFraction: .nan, totalDuration: 10))
        XCTAssertNil(ParakeetEngineImplementation.sourceProgress(fromFraction: 0.5, totalDuration: 0))
    }

    func testSourceProgressObservationOnlyStartsForFluidAudioProgressRange() {
        XCTAssertFalse(ParakeetEngineImplementation.shouldObserveSourceProgress(sampleCount: 160_000))
        XCTAssertFalse(ParakeetEngineImplementation.shouldObserveSourceProgress(sampleCount: 240_000))
        XCTAssertTrue(ParakeetEngineImplementation.shouldObserveSourceProgress(sampleCount: 240_001))
    }

    func testDictionaryTermsSupportReflectsStoredBoostingPreference() throws {
        let defaultHost = try TestStore()
        let defaultEngine = makeEngine(store: defaultHost)
        XCTAssertEqual(defaultEngine.dictionaryTermsSupport, .requiresSetting)

        let enabledHost = try TestStore(defaults: ["vocabularyBoostingEnabled": true])
        let enabledEngine = makeEngine(store: enabledHost)
        XCTAssertEqual(enabledEngine.dictionaryTermsSupport, .available)
    }

    func testVocabularyHintsPreferStructuredHintsOverPrompt() throws {
        let hints = ParakeetEngineImplementation.vocabularyHints(
            prompt: "PromptTerm",
            dictionaryTermHints: [
                DictionaryTermHint(text: " Caivex ", ctcMinSimilarity: 0.5),
                DictionaryTermHint(text: "caivex", ctcMinSimilarity: 0.8),
                DictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
            ]
        )

        XCTAssertEqual(hints, [
            DictionaryTermHint(text: "Caivex", ctcMinSimilarity: 0.5),
            DictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
        ])
    }

    func testVocabularyHintsFallbackToPromptAndEncodeThresholdSignature() throws {
        XCTAssertEqual(
            ParakeetEngineImplementation.vocabularyHints(prompt: " Alpha, Beta, alpha ", dictionaryTermHints: []),
            [
                DictionaryTermHint(text: "Alpha", ctcMinSimilarity: nil),
                DictionaryTermHint(text: "Beta", ctcMinSimilarity: nil),
            ]
        )

        let signature = ParakeetEngineImplementation.vocabularySignature(from: [
            DictionaryTermHint(text: "Alpha", ctcMinSimilarity: nil),
            DictionaryTermHint(text: "Beta", ctcMinSimilarity: 0.65),
        ])

        XCTAssertEqual(signature, "Alpha|auto\u{1F}Beta|0.6500")
    }

    func testSettingsDismissalRequiresOnlyBaseModelReadiness() throws {
        let host = try TestStore(defaults: ["vocabularyBoostingEnabled": true])
        let engine = makeEngine(store: host)

        XCTAssertFalse(engine.canDismissSettingsAfterSetup)

        engine.ctcModelState = .ready
        XCTAssertFalse(engine.canDismissSettingsAfterSetup)

        engine.modelState = .ready
        engine.ctcModelState = .downloading
        XCTAssertTrue(engine.canDismissSettingsAfterSetup)
    }

    func testEnablingVocabularyBoostingPersistsAndNotifiesCapabilityChange() throws {
        let host = try TestStore()
        let engine = makeEngine(store: host)

        engine.setBoostingEnabled(true)

        XCTAssertEqual(host.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool, true)
        XCTAssertEqual(engine.dictionaryTermsSupport, .available)

        engine.setBoostingEnabled(true)

    }

    func testDisablingVocabularyBoostingPersistsClearsVocabularyAndHidesCtcActivity() throws {
        let host = try TestStore(defaults: ["vocabularyBoostingEnabled": true])
        let engine = makeEngine(store: host)
        engine.lastConfiguredPrompt = "Leise Madison"
        engine.lastBoostingTermCount = 2
        engine.ctcModelState = .downloading
        XCTAssertEqual(engine.currentSettingsActivity?.message, "Downloading vocabulary model")

        engine.setBoostingEnabled(false)

        XCTAssertEqual(host.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool, false)
        XCTAssertEqual(engine.dictionaryTermsSupport, .requiresSetting)
        XCTAssertNil(engine.lastConfiguredPrompt)
        XCTAssertEqual(engine.lastBoostingTermCount, 0)
        XCTAssertNil(engine.currentSettingsActivity)
        engine.ctcModelState = .error("Vocabulary model failed")
        XCTAssertNil(engine.currentSettingsActivity)

        engine.setBoostingEnabled(false)

    }

    func testStoresAndClearsHuggingFaceTokenSecret() throws {
        let host = try TestStore()
        let engine = makeEngine(store: host)

        engine.setHuggingFaceToken("  hf_parakeet_saved  ")
        XCTAssertEqual(engine.huggingFaceToken, "hf_parakeet_saved")
        XCTAssertEqual(host.loadSecret(key: "hf-token"), "hf_parakeet_saved")

        engine.clearHuggingFaceToken()
        XCTAssertNil(engine.huggingFaceToken)
        XCTAssertEqual(host.loadSecret(key: "hf-token"), "")
    }

    func testValidatesHuggingFaceTokenAgainstWhoAmIEndpoint() async throws {
        let engine = makeEngine()
        let requestRecorder = RequestRecorder()

        let isValid = await engine.validateHuggingFaceToken("hf_parakeet_test") { request in
            await requestRecorder.set(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"{"name":"leise","type":"user"}"#.utf8)
            return (data, response)
        }

        XCTAssertTrue(isValid)
        let maybeRequest = await requestRecorder.get()
        let request = try XCTUnwrap(maybeRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://huggingface.co/api/whoami-v2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_parakeet_test")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testAppliesStoredHuggingFaceTokenToEnvironment() throws {
        let envKeys = [
            "HF_TOKEN",
            "HUGGING_FACE_HUB_TOKEN",
            "HUGGINGFACEHUB_API_TOKEN",
        ]
        let originalTokens = Dictionary(
            uniqueKeysWithValues: envKeys.map { key in
                (key, getenv(key).map { String(cString: $0) })
            }
        )
        defer {
            for key in envKeys {
                if let originalToken = originalTokens[key] ?? nil {
                    setenv(key, originalToken, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let host = try TestStore()
        let engine = makeEngine(store: host)
        engine.setHuggingFaceToken("hf_env_parakeet")

        engine.applyHuggingFaceTokenToEnvironment()

        for key in envKeys {
            XCTAssertEqual(getenv(key).map { String(cString: $0) }, "hf_env_parakeet")
        }
    }

    func testCtcChunkRangesMatchFluidAudioWindowing() {
        let sampleCount = 60 * 16_000
        let completed = ParakeetEngineImplementation.ctcChunkRanges(
            sampleCount: sampleCount,
            includeIncompleteTail: false
        )
        let final = ParakeetEngineImplementation.ctcChunkRanges(
            sampleCount: sampleCount,
            includeIncompleteTail: true
        )

        XCTAssertEqual(completed, [
            0..<240_000,
            208_000..<448_000,
            416_000..<656_000,
            624_000..<864_000,
        ])
        XCTAssertEqual(final, completed + [832_000..<960_000])
    }

    func testCtcChunkMergeMatchesFluidAudioLogSpaceOverlapAverage() {
        let first = ParakeetEngineImplementation.CtcLogProbabilityChunk(
            startSample: 0,
            endSample: 240_000,
            logProbs: [
                [logf(0.9), logf(0.1)],
                [logf(0.8), logf(0.2)],
            ],
            frameDuration: 2
        )
        let second = ParakeetEngineImplementation.CtcLogProbabilityChunk(
            startSample: 208_000,
            endSample: 448_000,
            logProbs: [
                [logf(0.2), logf(0.8)],
                [logf(0.1), logf(0.9)],
            ],
            frameDuration: 2
        )

        let merged = ParakeetEngineImplementation.mergeCtcLogProbabilityChunks([first, second])

        XCTAssertEqual(merged.logProbs.count, 3)
        XCTAssertEqual(expf(merged.logProbs[1][0]), 0.4, accuracy: 0.0001)
        XCTAssertEqual(expf(merged.logProbs[1][1]), 0.4, accuracy: 0.0001)
    }
}
