import SwiftUI

struct ProfilesSettingsView: View {
    @ObservedObject private var viewModel = ServiceContainer.shared.profilesViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Profiles"))
                        .font(.title2.bold())
                    Text(localizedAppText(
                        "Apply dictation language and insertion behavior for specific apps or websites.",
                        de: "Wendet Diktatsprache und Einfügeverhalten für bestimmte Apps oder Websites an."
                    ))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.prepareNewProfile()
                } label: {
                    Label(String(localized: "New Profile"), systemImage: "plus")
                }
            }
            .padding()

            Divider()

            if viewModel.profiles.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Profiles Yet"),
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text(localizedAppText(
                        "Create a profile for an app, website, or global fallback.",
                        de: "Erstelle ein Profil für eine App, Website oder als globalen Fallback."
                    ))
                )
            } else {
                List(viewModel.profiles) { profile in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { profile.isEnabled },
                            set: { _ in viewModel.toggle(profile) }
                        ))
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(.headline)
                            Text(scopeSummary(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { viewModel.startEditing(profile) } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) { viewModel.delete(profile) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sheet(isPresented: $viewModel.showingEditor) {
            editor
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Profile")) {
                    TextField(String(localized: "Name"), text: $viewModel.editorName)
                    Toggle(String(localized: "Enabled"), isOn: $viewModel.editorEnabled)
                }
                Section(localizedAppText("Matching", de: "Zuordnung")) {
                    TextField(
                        localizedAppText("App bundle identifiers, one per line", de: "App-Bundle-IDs, eine pro Zeile"),
                        text: $viewModel.editorBundleIdentifiers,
                        axis: .vertical
                    )
                    TextField(
                        localizedAppText("Website domains, one per line", de: "Website-Domains, eine pro Zeile"),
                        text: $viewModel.editorURLPatterns,
                        axis: .vertical
                    )
                }
                Section(localizedAppText("Behavior", de: "Verhalten")) {
                    TextField(localizedAppText("Language code (blank inherits global)", de: "Sprachcode (leer übernimmt global)"), text: $viewModel.editorInputLanguage)
                    Picker(localizedAppText("Output format", de: "Ausgabeformat"), selection: $viewModel.editorOutputFormat) {
                        Text(localizedAppText("Automatic", de: "Automatisch")).tag("")
                        Text("Plain Text").tag("plainText")
                        Text("Markdown").tag("markdown")
                    }
                    Toggle(localizedAppText("Press Return after insertion", de: "Nach dem Einfügen Return drücken"), isOn: $viewModel.editorAutoEnterEnabled)
                    HotkeyRecorderView(
                        label: viewModel.editorHotkey.map(HotkeyService.displayName(for:)) ?? String(localized: "Not Set"),
                        onRecord: { viewModel.editorHotkey = $0 },
                        onClear: { viewModel.editorHotkey = nil }
                    )
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { viewModel.showingEditor = false }
                Button(String(localized: "Save")) { viewModel.saveEditor() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.editorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
    }

    private func scopeSummary(_ profile: Profile) -> String {
        let scope = (profile.bundleIdentifiers + profile.urlPatterns).joined(separator: ", ")
        return scope.isEmpty ? localizedAppText("Global fallback", de: "Globaler Fallback") : scope
    }
}
