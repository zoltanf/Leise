import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsView: View {
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var dictation = ServiceContainer.shared.dictationViewModel
    @ObservedObject private var errorLogService = ServiceContainer.shared.errorLogService
    private let backupService = ServiceContainer.shared.userDataBackupService

    @State private var showClearUsageStatisticsConfirmation = false
    @State private var showImportConfirmation = false
    @State private var pendingImportURL: URL?
    @State private var pendingImportSummary: UserDataBackupSummary?
    @State private var notice: SettingsNotice?

    @AppStorage(UserDefaultsKeys.historyEnabled) private var historyEnabled = true
    @AppStorage(UserDefaultsKeys.historyRetentionDays) private var historyRetentionDays = 0
    @AppStorage(UserDefaultsKeys.saveAudioWithHistory) private var saveAudioWithHistory = false

    var body: some View {
        Form {
            Section(String(localized: "Backup & Restore")) {
                Text(String(localized: "Export preferences, dictionary entries, profiles, and transcription history to one JSON file, or restore them from a previous backup."))
                .foregroundStyle(.secondary)

                HStack {
                    Button(action: exportUserData) {
                        Label(
                            String(localized: "Export Backup"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    Button(action: chooseBackupToImport) {
                        Label(
                            String(localized: "Import Backup"),
                            systemImage: "square.and.arrow.down"
                        )
                    }
                }

                Text(String(localized: "API keys, downloaded models, caches, audio recordings, and custom sound files are not included."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "Support Diagnostics")) {
                HStack {
                    Button(action: exportDiagnostics) {
                        Label(
                            String(localized: "Export Diagnostics"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    SettingsInfoButton(text: String(localized: "Creates a JSON support report with app, system, permission, settings, and audio-device diagnostics."))
                }
            }

            Section(String(localized: "Recording")) {
                Picker(selection: Binding(
                    get: { modelManager.autoUnloadSeconds },
                    set: { modelManager.autoUnloadSeconds = $0 }
                )) {
                    Text(String(localized: "Never")).tag(0)
                    Divider()
                    Text(String(localized: "Immediate")).tag(-1)
                    Text(String(localized: "After 2 minutes")).tag(120)
                    Text(String(localized: "After 5 minutes")).tag(300)
                    Text(String(localized: "After 10 minutes")).tag(600)
                    Text(String(localized: "After 30 minutes")).tag(1800)
                    Text(String(localized: "After 1 hour")).tag(3600)
                } label: {
                    SettingsInfoLabel(
                        title: String(localized: "Auto-unload model"),
                        info: String(localized: "Keeps local models in memory by default for fast dictation. If auto-unload is enabled, Leise starts reloading the model when recording begins. Does not affect cloud engines.")
                    )
                }

                Toggle(isOn: $dictation.transcribeShortQuietClipsAggressively) {
                    SettingsInfoLabel(
                        title: String(localized: "Transcribe short / quiet clips more aggressively"),
                        info: String(localized: "Still discards accidental ultra-short taps, but keeps more very short or quiet recordings instead of classifying them as no speech.")
                    )
                }

                Toggle(isOn: $dictation.microphoneBoostEnabled) {
                    SettingsInfoLabel(
                        title: String(localized: "Whisper Mode (AGC)"),
                        info: String(localized: "Automatically raises quiet microphone input before transcription. Useful for low-gain microphones, but very noisy rooms may sound louder too.")
                    )
                }
            }

            SpokenPunctuationSettingsSection()

            Section(String(localized: "History")) {
                Toggle(isOn: $historyEnabled) {
                    SettingsInfoLabel(
                        title: String(localized: "Save history"),
                        info: String(localized: "Saves transcriptions to the history tab.")
                    )
                }

                if historyEnabled {
                    Toggle(isOn: $saveAudioWithHistory) {
                        SettingsInfoLabel(
                            title: String(localized: "Save audio with transcriptions"),
                            info: String(localized: "Stores a WAV recording alongside each transcription. Uses approximately 1 MB per 30 seconds.")
                        )
                    }

                    Picker(selection: $historyRetentionDays) {
                        Text(String(localized: "Unlimited")).tag(0)
                        Text(String(localized: "30 days")).tag(30)
                        Text(String(localized: "60 days")).tag(60)
                        Text(String(localized: "90 days")).tag(90)
                        Text(String(localized: "180 days")).tag(180)
                    } label: {
                        SettingsInfoLabel(
                            title: String(localized: "Auto-delete after"),
                            info: String(localized: "Older entries are automatically removed at app launch.")
                        )
                    }
                }

                Button(role: .destructive) {
                    showClearUsageStatisticsConfirmation = true
                } label: {
                    Label(String(localized: "Clear Usage Statistics"), systemImage: "trash")
                }
                .confirmationDialog(
                    String(localized: "Clear Usage Statistics?"),
                    isPresented: $showClearUsageStatisticsConfirmation
                ) {
                    Button(String(localized: "Clear Statistics"), role: .destructive) {
                        ServiceContainer.shared.usageStatisticsService.clearUsageStatistics()
                    }
                } message: {
                    Text(String(localized: "This will permanently delete all aggregate activity, application, habit, and quality statistics. Transcription history entries are unchanged."))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .confirmationDialog(
            String(localized: "Import Backup?"),
            isPresented: $showImportConfirmation
        ) {
            Button(String(localized: "Replace Current Data"), role: .destructive) {
                importPendingBackup()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingImportURL = nil
                pendingImportSummary = nil
            }
        } message: {
            if let summary = pendingImportSummary {
                Text(String(localized: "This replaces current settings and user data with \(summary.dictionaryEntryCount) dictionary entries, \(summary.profileCount) profiles, and \(summary.historyRecordCount) history records. This cannot be undone unless you export a backup first."))
            }
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func exportUserData() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Backup")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = backupFilename()

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let summary = try backupService.exportBackup(to: url)
                notice = SettingsNotice(
                    title: String(localized: "Backup Exported"),
                    message: String(localized: "Exported \(summary.preferenceCount) settings, \(summary.dictionaryEntryCount) dictionary entries, \(summary.profileCount) profiles, and \(summary.historyRecordCount) history records.")
                )
            } catch {
                notice = SettingsNotice(
                    title: String(localized: "Export Failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Backup")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                pendingImportSummary = try backupService.inspectBackup(at: url)
                pendingImportURL = url
                showImportConfirmation = true
            } catch {
                notice = SettingsNotice(
                    title: String(localized: "Invalid Backup"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func importPendingBackup() {
        guard let url = pendingImportURL else { return }
        defer {
            pendingImportURL = nil
            pendingImportSummary = nil
        }

        do {
            let summary = try backupService.importBackup(from: url)
            notice = SettingsNotice(
                title: String(localized: "Backup Imported"),
                message: String(localized: "Restored \(summary.preferenceCount) settings, \(summary.dictionaryEntryCount) dictionary entries, \(summary.profileCount) profiles, and \(summary.historyRecordCount) history records. Quit and reopen Leise to apply every restored setting.")
            )
        } catch {
            notice = SettingsNotice(
                title: String(localized: "Import Failed"),
                message: error.localizedDescription
            )
        }
    }

    private func backupFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "leise-backup-\(formatter.string(from: Date())).json"
    }

    private struct SettingsNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private func showDiagnosticsExportFailure(_ error: Error) {
        notice = SettingsNotice(
            title: String(localized: "Export Failed"),
            message: error.localizedDescription
        )
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Diagnostics")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = diagnosticsFilename()

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await errorLogService.exportDiagnostics(to: url)
                } catch {
                    showDiagnosticsExportFailure(error)
                }
            }
        }
    }

    private func diagnosticsFilename() -> String {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "leise-diagnostics-\(timestamp).json"
    }
}

struct SettingsInfoLabel: View {
    let title: String
    let info: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            SettingsInfoButton(text: info)
        }
    }
}

struct SettingsInfoButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel(String(localized: "More information"))
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 300, alignment: .leading)
        }
    }
}
