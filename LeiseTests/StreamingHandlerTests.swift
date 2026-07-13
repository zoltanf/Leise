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
