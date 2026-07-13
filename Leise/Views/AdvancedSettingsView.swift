import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsView: View {
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var dictation = ServiceContainer.shared.dictationViewModel
    @ObservedObject private var errorLogService = ServiceContainer.shared.errorLogService

    @State private var showClearUsageStatisticsConfirmation = false
    @State private var showDiagnosticsExportError = false
    @State private var diagnosticsExportErrorMessage = ""

    @AppStorage(UserDefaultsKeys.historyEnabled) private var historyEnabled = true
    @AppStorage(UserDefaultsKeys.historyRetentionDays) private var historyRetentionDays = 0
    @AppStorage(UserDefaultsKeys.saveAudioWithHistory) private var saveAudioWithHistory = false

    var body: some View {
        Form {
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
                    Text(String(localized: "This will permanently delete aggregate word, app, time-saved, and activity statistics. Transcription history entries are unchanged."))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .alert(localizedAppText("Export Failed", de: "Export fehlgeschlagen"), isPresented: $showDiagnosticsExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticsExportErrorMessage)
        }
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
                    diagnosticsExportErrorMessage = error.localizedDescription
                    showDiagnosticsExportError = true
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
