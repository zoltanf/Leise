import LeiseCore
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

        let result = await handler.finish()

        XCTAssertNil(result)
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
        let handler = StreamingHandler(
            modelManager: ModelManagerService(engine: engine),
            recentBufferProvider: { _ in [] },
            fullBufferProvider: { samples },
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
        XCTAssertEqual(engine.discardedPrecomputationSessionIDs, [])

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

        _ = try await modelManager.transcribe(
            audioSamples: Array(repeating: 0.1, count: 16_000),
            languageSelection: .auto,
            task: .transcribe
        )

        XCTAssertEqual(engine.prepareCallCount, 1)
        XCTAssertEqual(engine.requests.count, 1)
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

    func testStablePreviewReplacesShortUnrelatedFinalTail() {
        let result = TranscriptionResult(
            text: "tail",
            detectedLanguage: "en",
            duration: 2,
            processingTime: 0.1,
            engineUsed: "parakeet",
            segments: []
        )

        let stabilized = StreamingHandler.resultPreferringStablePreviewIfNeeded(
            result,
            stablePreview: "This is the meaningful preview"
        )

        XCTAssertEqual(stabilized.text, "This is the meaningful preview")
    }

    func testProviderFinalWinsWhenPreviewIsNotSubstantive() {
        let result = TranscriptionResult(
            text: "final result",
            detectedLanguage: "en",
            duration: 2,
            processingTime: 0.1,
            engineUsed: "parakeet",
            segments: []
        )

        XCTAssertEqual(
            StreamingHandler.resultPreferringStablePreviewIfNeeded(result, stablePreview: "yeah").text,
            "final result"
        )
    }

    private func makeHandler(engine: TestTranscriptionEngine? = TestTranscriptionEngine()) -> StreamingHandler {
        StreamingHandler(
            modelManager: ModelManagerService(engine: engine),
            recentBufferProvider: { _ in [] }
        )
    }
}
