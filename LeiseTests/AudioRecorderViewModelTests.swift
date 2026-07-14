import AudioToolbox
import LeiseCore
import XCTest
@testable import Leise

@MainActor
final class AudioRecorderViewModelTests: XCTestCase {
    func testRecorderSelectionPersistsSeparatelyFromGlobalDefault() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let engine = makeEngine()
        UserDefaults.standard.set(engine.id, forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults, engine: engine)
        viewModel.selectedEngine = engine.id
        viewModel.selectedModel = "parakeet-v2"

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine), engine.id)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel), "parakeet-v2")
        XCTAssertEqual(viewModel.effectiveProviderId, engine.id)
        XCTAssertEqual(viewModel.effectiveModelId, "parakeet-v2")
    }

    func testRecorderSelectionFallsBackToGlobalDefaultWhenUnset() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let engine = makeEngine()
        UserDefaults.standard.set(engine.id, forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults, engine: engine)

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertEqual(viewModel.effectiveProviderId, engine.id)
        XCTAssertEqual(viewModel.effectiveModelId, engine.selectedModelID)
        XCTAssertEqual(viewModel.resolvedEngine?.id, engine.id)
    }

    func testRecorderSelectionClearsMissingSavedEngineAndModel() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        defaults.set("missing-engine", forKey: UserDefaultsKeys.recorderTranscriptionEngine)
        defaults.set("old-model", forKey: UserDefaultsKeys.recorderTranscriptionModel)
        let engine = makeEngine()
        UserDefaults.standard.set(engine.id, forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults, engine: engine)
        viewModel.reconcileSelectionWithAvailableEngines()

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine))
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel))
        XCTAssertEqual(viewModel.effectiveProviderId, engine.id)
    }

    func testRecorderLivePreviewDefaultsOffAndPersistsSeparately() throws {
        let defaults = try makeDefaults()
        let viewModel = makeViewModel(defaults: defaults, engine: makeEngine())

        XCTAssertFalse(viewModel.livePreviewEnabled)
        viewModel.livePreviewEnabled = true
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.recorderLivePreviewEnabled))
    }

    func testRecorderOutputDirectoryPersistsAndRestores() throws {
        let defaults = try makeDefaults()
        let customDirectory = makeTemporaryDirectory()
        let firstService = AudioRecorderService()
        let firstViewModel = makeViewModel(
            defaults: defaults,
            engine: makeEngine(),
            recorderService: firstService
        )

        firstViewModel.setOutputDirectory(customDirectory)

        XCTAssertEqual(firstViewModel.selectedOutputDirectory, customDirectory.standardizedFileURL)
        XCTAssertEqual(firstService.recordingsDirectory, customDirectory.standardizedFileURL)
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.recorderOutputDirectory),
            customDirectory.standardizedFileURL.path
        )

        let restoredService = AudioRecorderService()
        let restoredViewModel = makeViewModel(
            defaults: defaults,
            engine: makeEngine(),
            recorderService: restoredService
        )

        XCTAssertEqual(restoredViewModel.selectedOutputDirectory, customDirectory.standardizedFileURL)
        XCTAssertEqual(restoredService.recordingsDirectory, customDirectory.standardizedFileURL)
    }

    func testRecorderOutputDirectoryCanReturnToDefault() throws {
        let defaults = try makeDefaults()
        let customDirectory = makeTemporaryDirectory()
        defaults.set(customDirectory.path, forKey: UserDefaultsKeys.recorderOutputDirectory)
        let recorderService = AudioRecorderService()
        let isolatedDefaultDirectory = makeTemporaryDirectory()
        recorderService.recordingsDirectoryOverride = isolatedDefaultDirectory
        let viewModel = makeViewModel(
            defaults: defaults,
            engine: makeEngine(),
            recorderService: recorderService
        )

        viewModel.useDefaultOutputDirectory()

        XCTAssertNil(viewModel.selectedOutputDirectory)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderOutputDirectory))
        recorderService.recordingsDirectoryOverride = nil
        XCTAssertEqual(recorderService.recordingsDirectory, AudioRecorderService.defaultRecordingsDirectory)
    }

    func testLivePreviewStartsOnlyWhenTranscriptAndPreviewAreEnabled() async throws {
        try preserveStandardDefaults()

        let disabledCount = try await livePreviewStartCount(transcriptionEnabled: false, livePreviewEnabled: true)
        let transcriptionOnlyCount = try await livePreviewStartCount(transcriptionEnabled: true, livePreviewEnabled: false)
        let previewCount = try await livePreviewStartCount(transcriptionEnabled: true, livePreviewEnabled: true)
        XCTAssertEqual(disabledCount, 0)
        XCTAssertEqual(transcriptionOnlyCount, 0)
        XCTAssertEqual(previewCount, 1)
    }

    func testRecorderStartPassesResolvedMicrophonePrioritySelection() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let usbDeviceID = AudioDeviceID(620)
        let usbDevice = AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
        let audioDeviceService = AudioDeviceService(
            initialInputDevices: [usbDevice],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )
        audioDeviceService.audioDeviceIDResolverOverride = { $0 == "usb-input" ? usbDeviceID : nil }
        audioDeviceService.addInputDeviceToPriorityList(usbDevice)

        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        var capturedSelection: ResolvedRecordingInputSelection?
        recorderService.startRecordingOverride = { _, _, _, outputURL, microphoneSelection in
            capturedSelection = microphoneSelection
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }

        let viewModel = makeViewModel(
            defaults: defaults,
            engine: makeEngine(),
            recorderService: recorderService,
            audioDeviceService: audioDeviceService
        )
        try await viewModel.startRecordingForTesting(micEnabled: true, systemAudioEnabled: false)

        XCTAssertEqual(capturedSelection?.deviceUID, "usb-input")
        XCTAssertEqual(capturedSelection?.deviceID, usbDeviceID)
        XCTAssertTrue(capturedSelection?.hasExplicitDeviceSelection == true)
    }

    func testRecorderStartIgnoresMicrophonePriorityWhenMicDisabled() async throws {
        let defaults = try makeDefaults()
        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = makeTemporaryDirectory()
        var capturedSelection: ResolvedRecordingInputSelection?
        recorderService.startRecordingOverride = { _, _, _, outputURL, microphoneSelection in
            capturedSelection = microphoneSelection
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        let viewModel = makeViewModel(defaults: defaults, engine: makeEngine(), recorderService: recorderService)

        try await viewModel.startRecordingForTesting(micEnabled: false, systemAudioEnabled: true)

        XCTAssertNil(capturedSelection?.deviceUID)
        XCTAssertNil(capturedSelection?.deviceID)
        XCTAssertFalse(capturedSelection?.hasExplicitDeviceSelection == true)
    }

    func testRecorderTranscriptionFailureAlertSummaryIncludesPhaseAndProviderError() throws {
        let defaults = try makeDefaults()
        let viewModel = makeViewModel(defaults: defaults, engine: makeEngine())
        let failure = AudioRecorderViewModel.RecordingTranscriptionFailure(
            phase: .emptyResult,
            providerError: "Final transcription returned no text.",
            engineName: "Parakeet",
            modelName: "Parakeet TDT v3",
            failedAt: Date()
        )

        let summary = viewModel.recorderTranscriptionFailureAlertSummary(failure)

        XCTAssertTrue(summary.contains(failure.phase.displayName))
        XCTAssertTrue(summary.contains(failure.providerError))
    }

    private func makeEngine() -> TestTranscriptionEngine {
        TestTranscriptionEngine(
            models: [
                TranscriptionModel(id: "parakeet-v3", displayName: "Parakeet v3"),
                TranscriptionModel(id: "parakeet-v2", displayName: "Parakeet v2")
            ],
            selectedModelID: "parakeet-v3"
        )
    }

    private func makeViewModel(
        defaults: UserDefaults,
        engine: TestTranscriptionEngine,
        recorderService: AudioRecorderService? = nil,
        audioDeviceService: AudioDeviceService = AudioDeviceService(initialInputDevices: [], monitorDeviceChanges: false),
        livePreviewStartObserver: (() -> Void)? = nil
    ) -> AudioRecorderViewModel {
        let resolvedRecorderService = recorderService ?? {
            let service = AudioRecorderService()
            service.recordingsDirectoryOverride = makeTemporaryDirectory()
            return service
        }()
        return AudioRecorderViewModel(
            recorderService: resolvedRecorderService,
            modelManager: ModelManagerService(engine: engine),
            dictionaryService: DictionaryService(appSupportDirectory: makeTemporaryDirectory()),
            audioDeviceService: audioDeviceService,
            defaults: defaults,
            livePreviewStartObserver: livePreviewStartObserver
        )
    }

    private func livePreviewStartCount(
        transcriptionEnabled: Bool,
        livePreviewEnabled: Bool
    ) async throws -> Int {
        let defaults = try makeDefaults()
        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = makeTemporaryDirectory()
        recorderService.startRecordingOverride = { _, _, _, outputURL, _ in
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        let engine = makeEngine()
        UserDefaults.standard.set(engine.id, forKey: UserDefaultsKeys.selectedEngine)
        var startCount = 0
        let viewModel = makeViewModel(
            defaults: defaults,
            engine: engine,
            recorderService: recorderService,
            livePreviewStartObserver: { startCount += 1 }
        )
        viewModel.transcriptionEnabled = transcriptionEnabled
        viewModel.livePreviewEnabled = livePreviewEnabled

        try await viewModel.startRecordingForTesting(micEnabled: true, systemAudioEnabled: false)
        return startCount
    }

    private func preserveStandardDefaults() throws {
        let keys = [
            UserDefaultsKeys.selectedEngine,
            UserDefaultsKeys.selectedModelId,
            UserDefaultsKeys.selectedInputDeviceUID,
            UserDefaultsKeys.inputDevicePriorityList
        ]
        let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        addTeardownBlock {
            for key in keys {
                if let value = originals[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "AudioRecorderViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecorderViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
