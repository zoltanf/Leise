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
            Section(localizedAppText("Backup & Restore", de: "Sichern & Wiederherstellen")) {
                Text(localizedAppText(
                    "Export preferences, dictionary entries, profiles, and transcription history to one JSON file, or restore them from a previous backup.",
                    de: "Exportiert Einstellungen, Wörterbucheinträge, Profile und den Transkriptionsverlauf in eine JSON-Datei oder stellt sie aus einer früheren Sicherung wieder her."
                ))
                .foregroundStyle(.secondary)

                HStack {
                    Button(action: exportUserData) {
                        Label(
                            localizedAppText("Export Backup", de: "Sicherung exportieren"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    Button(action: chooseBackupToImport) {
                        Label(
                            localizedAppText("Import Backup", de: "Sicherung importieren"),
                            systemImage: "square.and.arrow.down"
                        )
                    }
                }

                Text(localizedAppText(
                    "API keys, downloaded models, caches, audio recordings, and custom sound files are not included.",
                    de: "API-Schlüssel, heruntergeladene Modelle, Caches, Audioaufnahmen und eigene Sounddateien sind nicht enthalten."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(localizedAppText("Support Diagnostics", de: "Support-Diagnose")) {
                HStack {
                    Button(action: exportDiagnostics) {
                        Label(
                            localizedAppText("Export Diagnostics", de: "Diagnose exportieren"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    SettingsInfoButton(text: localizedAppText(
                        "Creates a JSON support report with app, system, permission, settings, and audio-device diagnostics.",
                        de: "Erstellt einen JSON-Supportbericht mit App-, System-, Berechtigungs-, Einstellungs- und Audiogeräte-Diagnose."
                    ))
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
                        info: String(localized: "Automatically unloads local models from memory after inactivity. It reloads when needed. Does not affect cloud engines.")
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
                        title: localizedAppText("Whisper Mode (AGC)", de: "Whisper-Modus (AGC)"),
                        info: localizedAppText(
                            "Automatically raises quiet microphone input before transcription. Useful for low-gain microphones, but very noisy rooms may sound louder too.",
                            de: "Hebt leise Mikrofoneingaben vor der Transkription automatisch an. Hilft bei Mikrofonen mit niedrigem Pegel, kann in lauten Räumen aber auch Störgeräusche verstärken."
                        )
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
            localizedAppText("Import Backup?", de: "Sicherung importieren?"),
            isPresented: $showImportConfirmation
        ) {
            Button(localizedAppText("Replace Current Data", de: "Aktuelle Daten ersetzen"), role: .destructive) {
                importPendingBackup()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingImportURL = nil
                pendingImportSummary = nil
            }
        } message: {
            if let summary = pendingImportSummary {
                Text(localizedAppText(
                    "This replaces current settings and user data with \(summary.dictionaryEntryCount) dictionary entries, \(summary.profileCount) profiles, and \(summary.historyRecordCount) history records. This cannot be undone unless you export a backup first.",
                    de: "Dabei werden die aktuellen Einstellungen und Benutzerdaten durch \(summary.dictionaryEntryCount) Wörterbucheinträge, \(summary.profileCount) Profile und \(summary.historyRecordCount) Verlaufseinträge ersetzt. Dies kann nur rückgängig gemacht werden, wenn zuvor eine Sicherung exportiert wurde."
                ))
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
        panel.title = localizedAppText("Export Backup", de: "Sicherung exportieren")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = backupFilename()

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let summary = try backupService.exportBackup(to: url)
                notice = SettingsNotice(
                    title: localizedAppText("Backup Exported", de: "Sicherung exportiert"),
                    message: localizedAppText(
                        "Exported \(summary.preferenceCount) settings, \(summary.dictionaryEntryCount) dictionary entries, \(summary.profileCount) profiles, and \(summary.historyRecordCount) history records.",
                        de: "\(summary.preferenceCount) Einstellungen, \(summary.dictionaryEntryCount) Wörterbucheinträge, \(summary.profileCount) Profile und \(summary.historyRecordCount) Verlaufseinträge wurden exportiert."
                    )
                )
            } catch {
                notice = SettingsNotice(
                    title: localizedAppText("Export Failed", de: "Export fehlgeschlagen"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.title = localizedAppText("Import Backup", de: "Sicherung importieren")
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
                    title: localizedAppText("Invalid Backup", de: "Ungültige Sicherung"),
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
                title: localizedAppText("Backup Imported", de: "Sicherung importiert"),
                message: localizedAppText(
                    "Restored \(summary.preferenceCount) settings, \(summary.dictionaryEntryCount) dictionary entries, \(summary.profileCount) profiles, and \(summary.historyRecordCount) history records. Quit and reopen Leise to apply every restored setting.",
                    de: "\(summary.preferenceCount) Einstellungen, \(summary.dictionaryEntryCount) Wörterbucheinträge, \(summary.profileCount) Profile und \(summary.historyRecordCount) Verlaufseinträge wurden wiederhergestellt. Beenden und öffnen Sie Leise erneut, um alle Einstellungen anzuwenden."
                )
            )
        } catch {
            notice = SettingsNotice(
                title: localizedAppText("Import Failed", de: "Import fehlgeschlagen"),
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
            title: localizedAppText("Export Failed", de: "Export fehlgeschlagen"),
            message: error.localizedDescription
        )
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = localizedAppText("Export Diagnostics", de: "Diagnose exportieren")
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
