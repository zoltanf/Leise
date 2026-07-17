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
        startDelay: TimeInterval = 0
    ) throws -> Harness {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock {
            TestSupport.remove(appSupportDirectory)
        }

        let startCallCount = OSAllocatedUnfairLock(initialState: 0)
        let stopCallCount = OSAllocatedUnfairLock(initialState: 0)

        let recordingService = AudioRecordingService()
        recordingService.hasMicrophonePermissionOverride = microphonePermission
        recordingService.startRecordingOverride = {
            if startDelay > 0 {
                Thread.sleep(forTimeInterval: startDelay)
            }
            startCallCount.withLock { $0 += 1 }
        }
        recordingService.stopRecordingOverride = { _ in
            stopCallCount.withLock { $0 += 1 }
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
            stopCallCount: stopCallCount
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

        await waitUntil { harness.viewModel.state != .recording }
        XCTAssertNotEqual(harness.viewModel.state, .recording)
    }
}
