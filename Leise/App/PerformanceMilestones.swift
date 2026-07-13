import Foundation

#if DEBUG
import os
import Darwin
#endif

/// Stable Points of Interest used by the performance measurement scripts.
///
/// Release builds intentionally reduce this type to no-op calls. Keep the raw
/// signpost names stable so baseline and final traces remain comparable while
/// implementation types are renamed or removed.
enum PerformanceMilestones {
    enum Interval: Sendable {
        case appInitialization
        case serviceContainerConstruction
        case serviceContainerInitialization
        case hotkeyRegistration
        case builtInComponentConstruction
        case retainedStoreOpening
        case modelSelectionRestoration
        case audioStart
        case modelPreparation
        case liveSessionCreation
        case finalTranscription
        case postProcessing
        case persistence
        case textInsertion
    }

    struct Token: @unchecked Sendable {
        #if DEBUG
        fileprivate let interval: Interval
        fileprivate let state: OSSignpostIntervalState

        fileprivate init(interval: Interval, state: OSSignpostIntervalState) {
            self.interval = interval
            self.state = state
        }
        #else
        fileprivate init() {}
        #endif
    }

    #if DEBUG
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.leise.mac",
        category: "Performance"
    )
    nonisolated(unsafe) private static var processLaunchState: OSSignpostIntervalState?
    #endif

    static func processStarted() {
        #if DEBUG
        guard processLaunchState == nil else { return }
        processLaunchState = signposter.beginInterval("process_to_ui_ready")
        signposter.emitEvent("process_started")
        #endif
    }

    static func uiReady() {
        #if DEBUG
        signposter.emitEvent("ui_ready")
        if let state = processLaunchState {
            signposter.endInterval("process_to_ui_ready", state)
            processLaunchState = nil
        }
        #endif
    }

    static func hotkeyReady() {
        #if DEBUG
        signposter.emitEvent("hotkey_ready")
        #endif
    }

    static func begin(_ interval: Interval) -> Token {
        #if DEBUG
        let state: OSSignpostIntervalState
        switch interval {
        case .appInitialization:
            state = signposter.beginInterval("app_initialization")
        case .serviceContainerConstruction:
            state = signposter.beginInterval("service_container_construction")
        case .serviceContainerInitialization:
            state = signposter.beginInterval("service_container_initialization")
        case .hotkeyRegistration:
            state = signposter.beginInterval("hotkey_registration")
        case .builtInComponentConstruction:
            state = signposter.beginInterval("built_in_component_construction")
        case .retainedStoreOpening:
            state = signposter.beginInterval("retained_store_opening")
        case .modelSelectionRestoration:
            state = signposter.beginInterval("model_selection_restoration")
        case .audioStart:
            state = signposter.beginInterval("audio_start")
        case .modelPreparation:
            state = signposter.beginInterval("model_preparation")
        case .liveSessionCreation:
            state = signposter.beginInterval("live_session_creation")
        case .finalTranscription:
            state = signposter.beginInterval("final_transcription")
        case .postProcessing:
            state = signposter.beginInterval("post_processing")
        case .persistence:
            state = signposter.beginInterval("history_statistics_persistence")
        case .textInsertion:
            state = signposter.beginInterval("text_insertion")
        }
        return Token(interval: interval, state: state)
        #else
        return Token()
        #endif
    }

    static func end(_ token: Token) {
        #if DEBUG
        switch token.interval {
        case .appInitialization:
            signposter.endInterval("app_initialization", token.state)
        case .serviceContainerConstruction:
            signposter.endInterval("service_container_construction", token.state)
        case .serviceContainerInitialization:
            signposter.endInterval("service_container_initialization", token.state)
        case .hotkeyRegistration:
            signposter.endInterval("hotkey_registration", token.state)
        case .builtInComponentConstruction:
            signposter.endInterval("built_in_component_construction", token.state)
        case .retainedStoreOpening:
            signposter.endInterval("retained_store_opening", token.state)
        case .modelSelectionRestoration:
            signposter.endInterval("model_selection_restoration", token.state)
        case .audioStart:
            signposter.endInterval("audio_start", token.state)
        case .modelPreparation:
            signposter.endInterval("model_preparation", token.state)
        case .liveSessionCreation:
            signposter.endInterval("live_session_creation", token.state)
        case .finalTranscription:
            signposter.endInterval("final_transcription", token.state)
        case .postProcessing:
            signposter.endInterval("post_processing", token.state)
        case .persistence:
            signposter.endInterval("history_statistics_persistence", token.state)
        case .textInsertion:
            signposter.endInterval("text_insertion", token.state)
        }
        #endif
    }

    static func measure<T>(
        _ interval: Interval,
        operation: () throws -> T
    ) rethrows -> T {
        let token = begin(interval)
        defer { end(token) }
        return try operation()
    }

    @MainActor
    static func measure<T>(
        _ interval: Interval,
        operation: () async throws -> T
    ) async rethrows -> T {
        let token = begin(interval)
        defer { end(token) }
        return try await operation()
    }
}

#if DEBUG
@MainActor
enum PerformanceBaselineRunner {
    private struct Record: Encodable {
        let scenario: String
        let instance: Int
        let run: Int
        let modelID: String
        let fixturePath: String
        let audioDurationSeconds: Double
        let elapsedMilliseconds: Double
        let inferenceMilliseconds: Double
        let text: String
        let detectedLanguage: String?
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static func prepareDefaultsIfRequested() {
        guard environment["LEISE_PERFORMANCE_FIXTURE"] != nil else { return }
        let modelID = environment["LEISE_PERFORMANCE_MODEL"] ?? "parakeet-tdt-0.6b-v3"
        let version = modelID.hasSuffix("-v2") ? "v2" : "v3"
        let defaults = UserDefaults.standard
        defaults.set("parakeet", forKey: UserDefaultsKeys.selectedEngine)
        defaults.set(modelID, forKey: "component.parakeet.selectedModel")
        defaults.set(modelID, forKey: "component.parakeet.loadedModel")
        defaults.set(version, forKey: "component.parakeet.selectedVersion")
        defaults.set(false, forKey: "component.parakeet.vocabularyBoostingEnabled")
        defaults.set(ModelAutoUnloadPolicy.defaultSeconds, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defaults.set(true, forKey: UserDefaultsKeys.setupWizardCompleted)
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        defaults.set(false, forKey: UserDefaultsKeys.soundFeedbackEnabled)
    }

    static func runIfRequested(using container: ServiceContainer) async {
        guard let fixturePath = environment["LEISE_PERFORMANCE_FIXTURE"] else { return }

        let scenario = environment["LEISE_PERFORMANCE_SCENARIO"] ?? "fixture"
        let instance = max(1, Int(environment["LEISE_PERFORMANCE_INSTANCE"] ?? "1") ?? 1)
        let modelID = environment["LEISE_PERFORMANCE_MODEL"] ?? "parakeet-tdt-0.6b-v3"
        let runs = max(1, Int(environment["LEISE_PERFORMANCE_RUNS"] ?? "1") ?? 1)
        let settleSeconds = max(
            0,
            Double(environment["LEISE_PERFORMANCE_SETTLE_SECONDS"] ?? "0") ?? 0
        )
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let fixtureName = fixtureURL.lastPathComponent

        do {
            let samples = try await container.audioFileService.loadAudioSamples(
                from: fixtureURL
            )
            let audioDuration = Double(samples.count) / 16_000.0

            for run in 1...runs {
                let start = CFAbsoluteTimeGetCurrent()
                let result = try await PerformanceMilestones.measure(.finalTranscription) {
                    try await container.modelManagerService.transcribe(
                        audioSamples: samples,
                        languageSelection: .exact("en"),
                        task: .transcribe,
                        engineOverrideId: "parakeet",
                        normalizeNumbers: false
                    )
                }
                let record = Record(
                    scenario: scenario,
                    instance: instance,
                    run: run,
                    modelID: modelID,
                    fixturePath: fixtureName,
                    audioDurationSeconds: audioDuration,
                    elapsedMilliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1_000,
                    inferenceMilliseconds: result.processingTime * 1_000,
                    text: result.text,
                    detectedLanguage: result.detectedLanguage
                )
                write(record, to: .standardOutput)
            }
            if settleSeconds > 0 {
                try await Task.sleep(for: .seconds(settleSeconds))
            }
            exit(EXIT_SUCCESS)
        } catch {
            let payload = [
                "scenario": scenario,
                "modelID": modelID,
                "fixturePath": fixtureName,
                "error": error.localizedDescription,
            ]
            write(payload, to: .standardError)
            exit(EXIT_FAILURE)
        }
    }

    private static func write<T: Encodable>(_ value: T, to handle: FileHandle) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }
}
#endif
