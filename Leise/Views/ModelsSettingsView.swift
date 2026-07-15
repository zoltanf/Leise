import SwiftUI

struct ParakeetSettingsPage: View {
    var body: some View {
        BuiltInSettingsPage(
            title: String(localized: "Processing"),
            description: String(localized: "Choose a Parakeet model, set the spoken language, and configure local transcription and vocabulary boosting."),
            systemImage: "cpu",
            settingsView: ServiceContainer.shared.builtInComponents.parakeetSettingsView
        )
    }
}

struct SpokenLanguageSettingsSection: View {
    @ObservedObject private var settings = ServiceContainer.shared.settingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Spoken Language"))
                .font(.subheadline)
                .fontWeight(.medium)

            LanguageSelectionEditor(
                selection: $settings.languageSelection,
                availableLanguages: settings.availableLanguages,
                hintBehavior: LanguageSelectionHintBehavior(engine: settings.activeTranscriptionEngine)
            )

            Text(String(localized: "Controls dictation and profiles that inherit the global spoken language. Recorder and Recovery have separate language settings."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BuiltInSettingsPage: View {
    let title: String
    let description: String
    let systemImage: String
    let settingsView: AnyView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.accent)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.accentColor.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsView
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.secondary.opacity(0.055))
                    )
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .topLeading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
