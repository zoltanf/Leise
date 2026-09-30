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
        let startCallCount: OSAllocatedUnfairLock<Int>
        let stopCallCount: OSAllocatedUnfairLock<Int>
        /// Engine calls in order: "start", "stop-begin", "stop-end".
        let engineEvents: OSAllocatedUnfairLock<[String]>

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
        stopDelay: TimeInterval = 0
    ) throws -> Harness {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock {
            TestSupport.remove(appSupportDirectory)
        }

        let startCallCount = OSAllocatedUnfairLock(initialState: 0)
        let stopCallCount = OSAllocatedUnfairLock(initialState: 0)
        let engineEvents = OSAllocatedUnfairLock<[String]>(initialState: [])

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
            return []
        }

        let modelManager = engineAvailable
            ? ModelManagerService(engine: TestTranscriptionEngine())
            : ModelManagerService()
        let hotkeyService = HotkeyService()
        let punctuationProfileStore = DictationPunctuationProfileStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            storageKey: UUID().uuidString
        )
        let punctuationRulesLoader = PunctuationRulesLoader()

        let viewModel = DictationViewModel(
            audioRecordingService: recordingService,
            textInsertionService: TextInsertionService(),
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: SettingsViewModel(modelManager: modelManager),
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: RecentTranscriptionStore(),
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
            mediaPlaybackService: MediaPlaybackService(startListening: false)
        )

        return Harness(
            viewModel: viewModel,
            hotkeyService: hotkeyService,
            recordingService: recordingService,
            startCallCount: startCallCount,
            stopCallCount: stopCallCount,
            engineEvents: engineEvents
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
}
