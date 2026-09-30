import AppKit
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
        let historyService: HistoryService
        let recentTranscriptionStore: RecentTranscriptionStore
        let startCallCount: OSAllocatedUnfairLock<Int>
        let stopCallCount: OSAllocatedUnfairLock<Int>
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
        recordedSamples: [Float] = [],
        postProcessors: [any TextPostProcessor] = []
    ) throws -> Harness {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock {
            TestSupport.remove(appSupportDirectory)
        }

        let startCallCount = OSAllocatedUnfairLock(initialState: 0)
        let stopCallCount = OSAllocatedUnfairLock(initialState: 0)
        let pasteCount = OSAllocatedUnfairLock(initialState: 0)

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
            return recordedSamples
        }

        // Never touch the real pasteboard, focused app, or keyboard.
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock {
            pasteboard.releaseGlobally()
        }
        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.pasteboardProvider = { pasteboard }
        textInsertionService.focusedTextFieldOverride = { false }
        textInsertionService.focusedTextElementOverride = { nil }
        textInsertionService.captureActiveAppOverride = { (name: "TextEdit", bundleId: "com.apple.TextEdit", url: nil) }
        textInsertionService.pasteSimulatorOverride = { pasteCount.withLock { $0 += 1 } }
        textInsertionService.returnSimulatorOverride = {}

        let modelManager = engineAvailable
            ? ModelManagerService(engine: TestTranscriptionEngine())
            : ModelManagerService()
        let hotkeyService = HotkeyService()
        let punctuationProfileStore = DictationPunctuationProfileStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            storageKey: UUID().uuidString
        )
        let punctuationRulesLoader = PunctuationRulesLoader()
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let recentTranscriptionStore = RecentTranscriptionStore()

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
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            startCallCount: startCallCount,
            stopCallCount: stopCallCount,
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

    // MARK: - Cancel during processing

    /// Half a second of audio loud enough to pass the short-speech gate.
    private static let speechSamples = [Float](
        repeating: 0.1,
        count: Int(AudioRecordingService.targetSampleRate / 2)
    )

    @MainActor
    func testCompletedDictationInsertsPostProcessedText() async throws {
        let harness = try makeHarness(recordedSamples: Self.speechSamples)

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
            recordedSamples: Self.speechSamples,
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
