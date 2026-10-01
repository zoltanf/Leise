import XCTest
import os
import LeiseCore
@testable import Leise

/// Exercises the DictationViewModel recording state machine through the same
/// hotkey callbacks the app wires up, with the audio engine faked via the
/// recording service's test overrides.
final class DictationViewModelStateMachineTests: XCTestCase {
    @MainActor
    private struct Harness {
        let viewModel: DictationViewModel
        let hotkeyService: HotkeyService
        let recordingService: AudioRecordingService
        let textInsertionService: TextInsertionService
        let historyService: HistoryService
        let recentTranscriptionStore: RecentTranscriptionStore
        let engine: TestTranscriptionEngine
        let startCallCount: OSAllocatedUnfairLock<Int>
        let stopCallCount: OSAllocatedUnfairLock<Int>
        /// Engine calls in order: "start", "stop-begin", "stop-end".
        let engineEvents: OSAllocatedUnfairLock<[String]>
        let pasteCount: OSAllocatedUnfairLock<Int>

        func fireStartHotkey() {
            hotkeyService.onDictationStart?(DispatchTime.now().uptimeNanoseconds)
        }

        func fireStopHotkey() {
            hotkeyService.onDictationStop?()
        }
    }

    @MainActor
    private func makeHarness(
        engineAvailable: Bool = true,
        microphonePermission: Bool = true,
        startDelay: TimeInterval = 0,
        stopDelay: TimeInterval = 0,
        stopSamples: [Float] = [],
        postProcessors: [any TextPostProcessor] = []
    ) throws -> Harness {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock {
            TestSupport.remove(appSupportDirectory)
        }

        let startCallCount = OSAllocatedUnfairLock(initialState: 0)
        let stopCallCount = OSAllocatedUnfairLock(initialState: 0)
        let engineEvents = OSAllocatedUnfairLock<[String]>(initialState: [])
        let pasteCount = OSAllocatedUnfairLock(initialState: 0)

        let recordingService = AudioRecordingService()
        recordingService.hasMicrophonePermissionOverride = microphonePermission
        recordingService.startRecordingOverride = {
            if startDelay > 0 {
                Thread.sleep(forTimeInterval: startDelay)
            }
            startCallCount.withLock { $0 += 1 }
            engineEvents.withLock { $0.append("start") }
        }
        recordingService.stopRecordingOverride = { _ in
            stopCallCount.withLock { $0 += 1 }
            engineEvents.withLock { $0.append("stop-begin") }
            if stopDelay > 0 {
                try? await Task.sleep(for: .seconds(stopDelay))
            }
            engineEvents.withLock { $0.append("stop-end") }
            return stopSamples
        }

        let engine = TestTranscriptionEngine()
        let modelManager = engineAvailable
            ? ModelManagerService(engine: engine)
            : ModelManagerService()
        let textInsertionService = TextInsertionService()
        // Keep insertion off the user's real clipboard and away from AX.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LeiseTests-\(UUID().uuidString)"))
        textInsertionService.pasteboardProvider = { pasteboard }
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.captureActiveAppOverride = { (name: "Test", bundleId: "com.leise.tests", url: nil) }
        // The user's persisted preserve-clipboard / auto-enter settings must
        // not reach the real focused app: no AX insertion, no synthetic Return.
        textInsertionService.focusedTextElementOverride = { nil }
        textInsertionService.focusedTextFieldOverride = { false }
        textInsertionService.selectedTextOverride = { nil }
        textInsertionService.returnSimulatorOverride = {}
        textInsertionService.pasteSimulatorOverride = { pasteCount.withLock { $0 += 1 } }
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let recentTranscriptionStore = RecentTranscriptionStore()
        let hotkeyService = HotkeyService()
        let punctuationProfileStore = DictationPunctuationProfileStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            storageKey: UUID().uuidString
        )
        let punctuationRulesLoader = PunctuationRulesLoader()

        let viewModel = DictationViewModel(
            audioRecordingService: recordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: SettingsViewModel(modelManager: modelManager),
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: ProfileService(appSupportDirectory: appSupportDirectory),
            audioDuckingService: AudioDuckingService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            soundService: SoundService(),
            audioDeviceService: AudioDeviceService(
                initialInputDevices: [],
                monitorDeviceChanges: false,
                probeCompatibilities: false
            ),
            appFormatterService: AppFormatterService(),
            punctuationStrategyResolver: PunctuationStrategyResolver(profileStore: punctuationProfileStore),
            speechPunctuationService: SpeechPunctuationService(rulesLoader: punctuationRulesLoader),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            errorLogService: ErrorLogService(appSupportDirectory: appSupportDirectory),
            mediaPlaybackService: MediaPlaybackService(startListening: false),
            postProcessors: postProcessors
        )

        return Harness(
            viewModel: viewModel,
            hotkeyService: hotkeyService,
            recordingService: recordingService,
            textInsertionService: textInsertionService,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            engine: engine,
            startCallCount: startCallCount,
            stopCallCount: stopCallCount,
            engineEvents: engineEvents,
            pasteCount: pasteCount
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Start rejection

    @MainActor
    func testStartIsRejectedWhenEngineCannotTranscribe() async throws {
        let harness = try makeHarness(engineAvailable: false)

        harness.fireStartHotkey()
        await waitUntil(timeout: 0.3) { harness.startCallCount.withLock { $0 } > 0 }

        // A rejected start surfaces error feedback (which uses the .inserting
        // feedback state) but must never start the engine or begin recording.
        XCTAssertNotEqual(harness.viewModel.state, .recording)
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 0)
    }

    @MainActor
    func testStartIsRejectedWithoutMicrophonePermission() async throws {
        let harness = try makeHarness(microphonePermission: false)

        harness.fireStartHotkey()
        await waitUntil(timeout: 0.3) { harness.startCallCount.withLock { $0 } > 0 }

        XCTAssertNotEqual(harness.viewModel.state, .recording)
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 0)
    }

    // MARK: - Successful start

    @MainActor
    func testSuccessfulStartEntersRecording() async throws {
        let harness = try makeHarness()

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }

        XCTAssertEqual(harness.viewModel.state, .recording)
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 1)
    }

    @MainActor
    func testDuplicateStartIsIgnoredWhileStartIsInFlight() async throws {
        let harness = try makeHarness(startDelay: 0.15)

        harness.fireStartHotkey()
        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }

        XCTAssertEqual(harness.viewModel.state, .recording)
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 1)
    }

    // MARK: - Stop

    @MainActor
    func testStopIsANoOpWhileIdle() async throws {
        let harness = try makeHarness()

        harness.fireStopHotkey()
        await waitUntil(timeout: 0.3) { harness.stopCallCount.withLock { $0 } > 0 }

        XCTAssertEqual(harness.viewModel.state, .idle)
        XCTAssertEqual(harness.stopCallCount.withLock { $0 }, 0)
    }

    @MainActor
    func testStopDuringInFlightStartRunsAfterStartCompletes() async throws {
        let harness = try makeHarness(startDelay: 0.15)

        harness.fireStartHotkey()
        // The engine is still starting; state is .idle and the stop must be
        // queued rather than dropped.
        harness.fireStopHotkey()

        await waitUntil { harness.stopCallCount.withLock { $0 } > 0 }

        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 1)
        XCTAssertEqual(harness.stopCallCount.withLock { $0 }, 1)
        await waitUntil { harness.viewModel.state != .recording }
        XCTAssertNotEqual(harness.viewModel.state, .recording)
    }

    @MainActor
    func testSecondStopIsIgnoredWhileStopIsInFlight() async throws {
        let harness = try makeHarness()

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }

        harness.fireStopHotkey()
        harness.fireStopHotkey()
        await waitUntil { harness.stopCallCount.withLock { $0 } > 0 }
        // Give a queued (incorrect) second stop a chance to surface.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(harness.stopCallCount.withLock { $0 }, 1)
    }

    // MARK: - Cancel

    @MainActor
    func testCancelHotkeyAbortsRecordingAfterWarningConfirmation() async throws {
        let harness = try makeHarness()

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }

        // First press arms the warning; the second press within the window cancels.
        harness.viewModel.handleCancelHotkey()
        XCTAssertEqual(harness.viewModel.state, .recording)
        harness.viewModel.handleCancelHotkey()

        await waitUntil { harness.stopCallCount.withLock { $0 } > 0 }
        XCTAssertEqual(harness.stopCallCount.withLock { $0 }, 1, "cancel must actually stop the engine")
        await waitUntil { harness.viewModel.state != .recording }
        XCTAssertNotEqual(harness.viewModel.state, .recording)
    }

    @MainActor
    func testCancelDuringInFlightStartAbortsWithoutRecording() async throws {
        let harness = try makeHarness(startDelay: 0.15)

        harness.fireStartHotkey()
        // The engine is still starting; a single Esc must cancel (no warning:
        // nothing has been recorded yet) and stop the engine once it is up.
        harness.viewModel.handleCancelHotkey()

        await waitUntil { harness.stopCallCount.withLock { $0 } > 0 }
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 1)
        XCTAssertEqual(harness.stopCallCount.withLock { $0 }, 1)
        await waitUntil { harness.viewModel.state != .recording }
        XCTAssertNotEqual(harness.viewModel.state, .recording)
    }

    // MARK: - Restart after a dictation

    @MainActor
    func testStartDuringFeedbackDisplayStartsNewRecording() async throws {
        let harness = try makeHarness()

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }
        // The fake engine returns no samples, so the stop ends in the 1.8 s
        // "Too short" feedback display (.inserting).
        harness.fireStopHotkey()
        await waitUntil { harness.viewModel.state == .inserting }
        XCTAssertEqual(harness.viewModel.state, .inserting)

        harness.fireStartHotkey()
        // Well inside the feedback display: the start must not wait for it.
        await waitUntil(timeout: 1.0) { harness.viewModel.state == .recording }

        XCTAssertEqual(harness.viewModel.state, .recording)
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 2)
    }

    @MainActor
    func testStartDuringProcessingRunsOnceProcessingEnds() async throws {
        let harness = try makeHarness(stopDelay: 0.5)

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }
        harness.fireStopHotkey()
        XCTAssertEqual(harness.viewModel.state, .processing)

        harness.fireStartHotkey()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.viewModel.state, .processing)
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 1, "the start must wait for processing to end")

        await waitUntil { harness.viewModel.state == .recording }
        XCTAssertEqual(harness.viewModel.state, .recording)
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 2)
    }

    @MainActor
    func testReleaseBeforeQueuedStartRunsDropsIt() async throws {
        let harness = try makeHarness(stopDelay: 0.3)

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }
        harness.fireStopHotkey()
        harness.fireStartHotkey()
        // Push-to-talk released while the previous dictation is still processing.
        harness.fireStopHotkey()

        await waitUntil { harness.viewModel.state == .inserting }
        // Give an incorrectly retained queued start a chance to surface.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNotEqual(harness.viewModel.state, .recording)
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 1)
        XCTAssertEqual(harness.stopCallCount.withLock { $0 }, 1)
    }

    @MainActor
    func testCancelDuringProcessingDropsQueuedStart() async throws {
        let harness = try makeHarness(stopDelay: 0.3)

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }
        harness.fireStopHotkey()
        harness.fireStartHotkey()
        // First press arms the warning; the second cancels processing.
        harness.viewModel.handleCancelHotkey()
        harness.viewModel.handleCancelHotkey()

        await waitUntil { harness.viewModel.state == .inserting }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNotEqual(harness.viewModel.state, .recording)
        XCTAssertEqual(harness.startCallCount.withLock { $0 }, 1)
    }

    @MainActor
    func testStartRightAfterAbortWaitsForEngineTeardown() async throws {
        let harness = try makeHarness(stopDelay: 0.3)

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }
        // Esc twice aborts; the engine stop keeps running in the background
        // while the "Cancelled" feedback shows.
        harness.viewModel.handleCancelHotkey()
        harness.viewModel.handleCancelHotkey()
        XCTAssertEqual(harness.viewModel.state, .inserting)

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }

        XCTAssertEqual(harness.viewModel.state, .recording)
        XCTAssertEqual(
            harness.engineEvents.withLock { $0 },
            ["start", "stop-begin", "stop-end", "start"],
            "the new engine start must wait for the aborted session's stop"
        )
    }

    /// 1.5 s of audio loud enough to be transcribed rather than discarded.
    private static let speechSamples = [Float](repeating: 0.1, count: 24_000)

    @MainActor
    func testCancelDuringInsertionDoesNotClobberNextRecording() async throws {
        let harness = try makeHarness(stopSamples: Self.speechSamples)
        var pasted = false
        harness.textInsertionService.pasteSimulatorOverride = {
            pasted = true
            // Esc twice while dictation A is mid-insert, then start B at once.
            harness.viewModel.handleCancelHotkey()
            harness.viewModel.handleCancelHotkey()
            harness.fireStartHotkey()
        }

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }
        harness.fireStopHotkey()
        await waitUntil(timeout: 5) {
            pasted && harness.startCallCount.withLock { $0 } == 2 && harness.viewModel.state == .recording
        }
        XCTAssertEqual(harness.viewModel.state, .recording)

        // Outlast A's 1.5 s feedback reset, which must never have been armed.
        try? await Task.sleep(for: .seconds(2))
        XCTAssertEqual(harness.viewModel.state, .recording, "cancelled dictation A reset dictation B")
    }

    @MainActor
    func testExtraKeyWhileStartWaitsForTeardownDiscardsRecording() async throws {
        let harness = try makeHarness(stopDelay: 0.3, stopSamples: Self.speechSamples)

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }
        harness.viewModel.handleCancelHotkey()
        harness.viewModel.handleCancelHotkey()
        // B waits for A's engine teardown; an extra key during that wait
        // makes the hold a shortcut, not a dictation.
        harness.fireStartHotkey()
        harness.hotkeyService.onPushToTalkInterruption?()
        await waitUntil { harness.viewModel.state == .recording }
        harness.fireStopHotkey()
        await waitUntil { harness.viewModel.state == .inserting }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(harness.engine.requests.isEmpty, "the interrupted hold must not be transcribed")
    }

    // MARK: - Cancel during processing

    @MainActor
    func testCompletedDictationInsertsPostProcessedText() async throws {
        let harness = try makeHarness(stopSamples: Self.speechSamples)

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }
        harness.fireStopHotkey()

        await waitUntil { harness.pasteCount.withLock { $0 } > 0 }
        XCTAssertEqual(harness.pasteCount.withLock { $0 }, 1)
        XCTAssertEqual(harness.recentTranscriptionStore.sessionEntries.count, 1)
    }

    @MainActor
    func testCancelDuringPostProcessingDoesNotInsertText() async throws {
        let processor = SuspendingPostProcessor()
        let harness = try makeHarness(
            stopSamples: Self.speechSamples,
            postProcessors: [processor]
        )

        harness.fireStartHotkey()
        await waitUntil { harness.viewModel.state == .recording }
        harness.fireStopHotkey()
        await waitUntil { processor.hasStarted }
        XCTAssertEqual(harness.viewModel.state, .processing)

        // Esc twice: arm the warning, then cancel. The processor's sleep throws
        // CancellationError, which the pipeline swallows and returns normally.
        harness.viewModel.handleCancelHotkey()
        harness.viewModel.handleCancelHotkey()
        await waitUntil { processor.hasFinished }
        XCTAssertTrue(processor.hasFinished, "cancellation must reach the post-processor")

        // Give an (incorrect) insertion a chance to surface.
        await waitUntil(timeout: 0.5) { harness.pasteCount.withLock { $0 } > 0 }
        XCTAssertEqual(harness.pasteCount.withLock { $0 }, 0, "a cancelled dictation must not paste")
        XCTAssertTrue(harness.recentTranscriptionStore.sessionEntries.isEmpty)
        XCTAssertTrue(harness.historyService.records.isEmpty)
    }
}

/// Suspends in `process` until the surrounding task is cancelled, the way a
/// slow post-processor would be interrupted by Esc.
private final class SuspendingPostProcessor: TextPostProcessor, Sendable {
    let id = "test.suspending"
    let displayName = "Suspending"
    let priority = 300

    private let state = OSAllocatedUnfairLock(initialState: (started: false, finished: false))

    var hasStarted: Bool { state.withLock { $0.started } }
    var hasFinished: Bool { state.withLock { $0.finished } }

    func process(_ text: String, context: PostProcessingContext) async throws -> String {
        state.withLock { $0.started = true }
        defer { state.withLock { $0.finished = true } }
        try await Task.sleep(for: .seconds(10))
        return text
    }
}
