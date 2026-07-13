import AVFoundation
import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "ErrorLogService")

private struct DiagnosticsReport: Encodable {
    struct AppInfo: Encodable {
        let version: String
        let build: String
        let bundleIdentifier: String
        let isDevelopment: Bool
        let launchTimestamp: Date
        let uptimeSeconds: TimeInterval
    }

    struct SystemInfo: Encodable {
        let macOSVersion: String
        let localeIdentifier: String
        let timeZoneIdentifier: String
        let cpuArchitecture: String
    }

    struct PermissionsInfo: Encodable {
        let microphoneGranted: Bool
        let accessibilityGranted: Bool
    }

    struct ModelInfo: Encodable {
        let selectedProviderId: String?
        let selectedModelId: String?
        let isModelReady: Bool
        let supportsStreaming: Bool
        let supportsLiveTranscriptionSession: Bool
    }

    struct SettingsInfo: Encodable {
        let selectedLanguage: String?
        let historyRetentionDays: Int
        let saveAudioWithHistory: Bool
        let appFormattingEnabled: Bool
        let modelAutoUnloadSeconds: Int
        let indicatorStyle: String
        let soundFeedbackEnabled: Bool
        let showMenuBarIcon: Bool
        let preferredAppLanguage: String?
    }

    struct Counts: Encodable {
        let historyRecords: Int
        let profiles: Int
        let enabledProfiles: Int
        let dictionaryTerms: Int
        let dictionaryCorrections: Int
        let errorEntries: Int
    }

    let schemaVersion: Int
    let exportedAt: Date
    let app: AppInfo
    let system: SystemInfo
    let permissions: PermissionsInfo
    let secureInput: SecureInputDiagnostics
    let model: ModelInfo
    let modelAutoUnload: ModelAutoUnloadDiagnosticsSnapshot
    let audioInput: AudioInputDiagnosticsReport
    let settings: SettingsInfo
    let counts: Counts
    let errors: [ErrorLogEntry]
}

@MainActor
final class ErrorLogService: ObservableObject {
    @Published private(set) var entries: [ErrorLogEntry] = []

    private static let maxEntries = 200
    private let fileURL: URL
    private let launchTimestamp = Date()

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        try? FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        fileURL = appSupportDirectory.appendingPathComponent("error-log.json")
        loadEntries()
    }

    func addEntry(message: String, category: String = "general") {
        entries.insert(ErrorLogEntry(message: message, category: category), at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        saveEntries()
        logger.info("Error logged: [\(category)] \(message)")
    }

    func clearAll() {
        entries.removeAll()
        saveEntries()
    }

    func exportDiagnostics(to url: URL) async throws {
        let report = diagnosticsReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try await Task.detached(priority: .utility) {
            try data.write(to: url, options: .atomic)
        }.value
    }

    private func diagnosticsReport() -> DiagnosticsReport {
        let container = ServiceContainer.shared
        let defaults = UserDefaults.standard
        let modelAutoUnloadSeconds = ModelAutoUnloadPolicy.effectiveSeconds(defaults: defaults)

        return DiagnosticsReport(
            schemaVersion: 1,
            exportedAt: Date(),
            app: .init(
                version: AppConstants.appVersion,
                build: AppConstants.buildVersion,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.leise.mac",
                isDevelopment: AppConstants.isDevelopment,
                launchTimestamp: launchTimestamp,
                uptimeSeconds: Date().timeIntervalSince(launchTimestamp)
            ),
            system: .init(
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                localeIdentifier: Locale.current.identifier,
                timeZoneIdentifier: TimeZone.current.identifier,
                cpuArchitecture: RuntimeArchitecture.current
            ),
            permissions: .init(
                microphoneGranted: AVAudioApplication.shared.recordPermission == .granted,
                accessibilityGranted: container.textInsertionService.isAccessibilityGranted
            ),
            secureInput: SecureInputDiagnosticsProvider.snapshot(),
            model: .init(
                selectedProviderId: container.modelManagerService.selectedProviderId,
                selectedModelId: container.modelManagerService.selectedModelId,
                isModelReady: container.modelManagerService.isModelReady,
                supportsStreaming: container.modelManagerService.supportsStreaming,
                supportsLiveTranscriptionSession: container.modelManagerService.supportsLiveTranscriptionSession()
            ),
            modelAutoUnload: container.modelManagerService.autoUnloadDiagnosticsSnapshot(),
            audioInput: container.audioDeviceService.diagnosticsReport(),
            settings: .init(
                selectedLanguage: defaults.string(forKey: UserDefaultsKeys.selectedLanguage),
                historyRetentionDays: defaults.integer(forKey: UserDefaultsKeys.historyRetentionDays),
                saveAudioWithHistory: defaults.bool(forKey: UserDefaultsKeys.saveAudioWithHistory),
                appFormattingEnabled: defaults.bool(forKey: UserDefaultsKeys.appFormattingEnabled),
                modelAutoUnloadSeconds: modelAutoUnloadSeconds,
                indicatorStyle: DictationViewModel.loadIndicatorStyle(defaults: defaults).rawValue,
                soundFeedbackEnabled: defaults.object(forKey: UserDefaultsKeys.soundFeedbackEnabled) as? Bool ?? true,
                showMenuBarIcon: defaults.object(forKey: UserDefaultsKeys.showMenuBarIcon) as? Bool ?? true,
                preferredAppLanguage: defaults.string(forKey: UserDefaultsKeys.preferredAppLanguage)
            ),
            counts: .init(
                historyRecords: container.historyService.records.count,
                profiles: container.profileService.profiles.count,
                enabledProfiles: container.profileService.profiles.filter(\.isEnabled).count,
                dictionaryTerms: container.dictionaryService.termsCount,
                dictionaryCorrections: container.dictionaryService.correctionsCount,
                errorEntries: entries.count
            ),
            errors: entries
        )
    }

    private func loadEntries() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ErrorLogEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
