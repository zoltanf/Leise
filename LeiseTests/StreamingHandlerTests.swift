import LeiseCore
import os
import XCTest
@testable import Leise

@MainActor
final class StreamingHandlerTests: XCTestCase {
    func testDisabledPreviewDoesNotEnterStreamingState() {
        let handler = makeHandler()
        var states: [Bool] = []
        handler.onStreamingStateChange = { states.append($0) }

        handler.start(
            streamPrompt: "",
            engineOverrideId: "parakeet",
            selectedProviderId: "parakeet",
            languageSelection: .auto,
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: false,
            stateCheck: { true }
        )

        XCTAssertEqual(states, [false])
    }

    func testMissingEngineDoesNotEnterStreamingState() {
        let handler = makeHandler(engine: nil)
        var states: [Bool] = []
        handler.onStreamingStateChange = { states.append($0) }

        handler.start(
            streamPrompt: "",
            engineOverrideId: "missing",
            selectedProviderId: nil,
            languageSelection: .auto,
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        XCTAssertEqual(states, [false])
    }

    func testFinishStopsPreviewAndDefersToFinalBatchTranscription() async {
        let handler = makeHandler()
        var states: [Bool] = []
        handler.onStreamingStateChange = { states.append($0) }
        handler.start(
            streamPrompt: "",
            engineOverrideId: "parakeet",
            selectedProviderId: "parakeet",
            languageSelection: .auto,
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        await handler.finish()

        XCTAssertEqual(states, [false, true, false])
    }

    func testInitialFallbackCanPublishBeforeRegularPollInterval() async {
        let engine = TestTranscriptionEngine()
        let sessionID = UUID()
        let handler = StreamingHandler(
            modelManager: ModelManagerService(engine: engine),
            recentBufferProvider: { _ in Array(repeating: 0.1, count: 16_000) },
            initialFallbackDelay: .milliseconds(10),
            fallbackPollInterval: .seconds(10)
        )
        let preview = expectation(description: "initial preview")
        handler.onPartialTextUpdate = { text in
            if text == "mock transcription" {
                preview.fulfill()
            }
        }

        handler.start(
            streamPrompt: "",
            engineOverrideId: "parakeet",
            selectedProviderId: "parakeet",
            languageSelection: .auto,
            task: .transcribe,
            cloudModelOverride: nil,
            sessionID: sessionID,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        await fulfillment(of: [preview], timeout: 1)
        handler.stop()
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(engine.requests.first?.purpose, .preview)
        XCTAssertEqual(engine.requests.first?.sessionID, sessionID)
    }

    func testFinalPrecomputationRunsWhilePreviewIsDisabledAndSurvivesFinish() async {
        let engine = TestTranscriptionEngine(allowsFinalTranscriptionPrecomputation: true)
        let sessionID = UUID()
        let samples = Array(repeating: Float(0.1), count: 15 * 16_000)
        let deltaCalls = OSAllocatedUnfairLock(initialState: [Int]())
        let fullBufferReadCount = OSAllocatedUnfairLock(initialState: 0)
        let handler = StreamingHandler(
            modelManager: ModelManagerService(engine: engine),
            recentBufferProvider: { _ in [] },
            bufferDeltaProvider: { sampleOffset in
                deltaCalls.withLock { $0.append(sampleOffset) }
                let start = min(max(0, sampleOffset), samples.count)
                return (Array(samples.dropFirst(start)), samples.count)
            },
            fullBufferProvider: {
                fullBufferReadCount.withLock { $0 += 1 }
                return samples
            },
            bufferDurationProvider: { 15 },
            initialFallbackDelay: .seconds(10),
            fallbackPollInterval: .seconds(10)
        )

        handler.start(
            streamPrompt: "Leise",
            dictionaryTermHints: [DictionaryTermHint(text: "Leise")],
            engineOverrideId: "parakeet",
            selectedProviderId: "parakeet",
            languageSelection: .auto,
            task: .transcribe,
            cloudModelOverride: nil,
            sessionID: sessionID,
            allowLiveTranscription: false,
            stateCheck: { true }
        )

        for _ in 0..<20 where engine.precomputationRequests.isEmpty {
            await Task.yield()
        }
        _ = await handler.finish()

        XCTAssertEqual(engine.requests.count, 0)
        XCTAssertEqual(engine.precomputationRequests.count, 1)
        XCTAssertEqual(engine.precomputationRequests.first?.sessionID, sessionID)
        XCTAssertEqual(engine.precomputationRequests.first?.audio.samples.count, samples.count)
        XCTAssertEqual(engine.discardedPrecomputationSessionIDs, [])
        XCTAssertEqual(fullBufferReadCount.withLock { $0 }, 0)
        XCTAssertEqual(deltaCalls.withLock { $0.first }, 0)

        handler.discardFinalPrecomputation()
        XCTAssertEqual(engine.discardedPrecomputationSessionIDs, [sessionID])
    }

    func testDictationWarmupUsesDownloadedModelAndAvoidsSecondPreparation() async throws {
        let engine = TestTranscriptionEngine(isReady: false)
        let modelManager = ModelManagerService(engine: engine)

        modelManager.prepareForDictation()
        for _ in 0..<20 where !engine.isReady {
            await Task.yield()
        }

        XCTAssertTrue(engine.isReady)
        XCTAssertEqual(engine.prepareCallCount, 1)
        XCTAssertEqual(engine.prepareAllowDownloadsHistory, [false])
        XCTAssertEqual(engine.prepareForDictationCallCount, 1)

        _ = try await modelManager.transcribe(
            audioSamples: Array(repeating: 0.1, count: 16_000),
            languageSelection: .auto,
            task: .transcribe
        )

        XCTAssertEqual(engine.prepareCallCount, 1)
        XCTAssertEqual(engine.requests.count, 1)
    }

    func testReadyModelStillPreparesCachedDictationResources() async throws {
        let engine = TestTranscriptionEngine(isReady: true)
        let modelManager = ModelManagerService(engine: engine)

        modelManager.prepareForDictation()
        for _ in 0..<20 where engine.prepareForDictationCallCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(engine.prepareCallCount, 0)
        XCTAssertEqual(engine.prepareForDictationCallCount, 1)

        _ = try await modelManager.transcribe(
            audioSamples: Array(repeating: 0.1, count: 16_000),
            languageSelection: .auto,
            task: .transcribe
        )

        XCTAssertEqual(engine.prepareCallCount, 0)
        XCTAssertEqual(engine.prepareForDictationCallCount, 1)
    }

    func testOverrideWarmupRestoresPreviouslySelectedModelAfterTranscription() async throws {
        let originalModelID = "parakeet-tdt-0.6b-v3"
        let overrideModelID = "parakeet-tdt-0.6b-v2"
        let engine = TestTranscriptionEngine(
            models: [
                TranscriptionModel(id: originalModelID, displayName: "Parakeet TDT v3"),
                TranscriptionModel(id: overrideModelID, displayName: "Parakeet TDT v2")
            ],
            selectedModelID: originalModelID
        )
        let modelManager = ModelManagerService(engine: engine)

        modelManager.prepareForDictation(modelOverrideId: overrideModelID)
        for _ in 0..<20 where engine.prepareCallCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(engine.selectedModelID, overrideModelID)

        _ = try await modelManager.transcribe(
            audioSamples: Array(repeating: 0.1, count: 16_000),
            languageSelection: .auto,
            task: .transcribe,
            cloudModelOverride: overrideModelID
        )

        XCTAssertEqual(engine.prepareCallCount, 1)
        XCTAssertEqual(engine.selectedModelID, originalModelID)
    }

    func testStabilizeTextAppendsDisjointPreviewWindows() {
        XCTAssertEqual(
            StreamingHandler.stabilizeText(confirmed: "First sentence.", new: "Second sentence."),
            "First sentence. Second sentence."
        )
    }

    func testStabilizeTextMergesOverlappingPreviewWindows() {
        XCTAssertEqual(
            StreamingHandler.stabilizeText(
                confirmed: "First sentence. Second sentence.",
                new: "Second sentence. Third sentence."
            ),
            "First sentence. Second sentence. Third sentence."
        )
    }

    func testStabilizeTextKeepsLongerConfirmedPrefix() {
        XCTAssertEqual(
            StreamingHandler.stabilizeText(confirmed: "One two three", new: "One two"),
            "One two three"
        )
    }

    func testStabilizeTextAcceptsProviderCorrection() {
        XCTAssertEqual(
            StreamingHandler.stabilizeText(confirmed: "Ich bin an Köln.", new: "Ich bin an Koeln."),
            "Ich bin an Koeln."
        )
    }

    private func makeHandler(engine: TestTranscriptionEngine? = TestTranscriptionEngine()) -> StreamingHandler {
        StreamingHandler(
            modelManager: ModelManagerService(engine: engine),
            recentBufferProvider: { _ in [] }
        )
    }
}

@MainActor
final class ModelManagerAutoUnloadTests: XCTestCase {
    private var originalAutoUnloadValue: Any?

    override func setUp() {
        super.setUp()
        originalAutoUnloadValue = UserDefaults.standard.object(
            forKey: UserDefaultsKeys.modelAutoUnloadSeconds
        )
    }

    override func tearDown() {
        if let originalAutoUnloadValue {
            UserDefaults.standard.set(
                originalAutoUnloadValue,
                forKey: UserDefaultsKeys.modelAutoUnloadSeconds
            )
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        }
        super.tearDown()
    }

    func testAutoUnloadDefaultsToNever() throws {
        let suiteName = "ModelManagerAutoUnloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ModelAutoUnloadPolicy.effectiveSeconds(defaults: defaults), 0)
        XCTAssertTrue(ModelAutoUnloadPolicy.shouldRestoreLoadedModelsPassively(defaults: defaults))
    }

    func testDictationPreloadsImmediatePolicyAndPreventsMidSessionUnload() async throws {
        UserDefaults.standard.set(-1, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        let engine = TestTranscriptionEngine(isReady: false)
        let manager = ModelManagerService(engine: engine)

        manager.beginDictationActivity()
        manager.prepareForDictation()
        for _ in 0..<20 where !engine.isReady {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(engine.isReady)
        XCTAssertEqual(engine.prepareCallCount, 1)
        XCTAssertEqual(engine.prepareAllowDownloadsHistory, [false])
        XCTAssertEqual(engine.unloadCallCount, 0)

        manager.endDictationActivity()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(engine.unloadCallCount, 1)
        XCTAssertFalse(engine.isReady)
    }
}
