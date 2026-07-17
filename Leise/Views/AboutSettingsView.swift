import SwiftUI

struct AboutSettingsView: View {
    @AppStorage(UserDefaultsKeys.updateChannel) private var selectedUpdateChannelRawValue = AppConstants.defaultReleaseChannel.rawValue

    private var selectedUpdateChannel: AppConstants.ReleaseChannel {
        AppConstants.ReleaseChannel(rawValue: selectedUpdateChannelRawValue) ?? AppConstants.defaultReleaseChannel
    }

    private var updateChannelBinding: Binding<AppConstants.ReleaseChannel> {
        Binding(
            get: { selectedUpdateChannel },
            set: { newChannel in
                guard selectedUpdateChannel != newChannel else { return }
                selectedUpdateChannelRawValue = newChannel.rawValue
                UpdateChecker.shared?.resetUpdateCycleAfterSettingsChange()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)

                    Text("Leise")
                        .font(.title)
                        .fontWeight(.semibold)

                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    let channelSuffix = AppConstants.releaseChannel.versionDisplayName.map { " - \($0)" } ?? ""
                    Text("Version \(version) (\(build))\(channelSuffix)")
                        .foregroundStyle(.secondary)

                    Text(String(localized: "Fast, private speech-to-text for your Mac. Transcribe with local or cloud engines, process text with AI prompts, and insert directly into any app."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Picker(String(localized: "Update Channel"), selection: updateChannelBinding) {
                    ForEach(AppConstants.ReleaseChannel.allCases, id: \.self) { channel in
                        Text(channel.selectionDisplayName)
                            .tag(channel)
                    }
                }
                .pickerStyle(.menu)

                Text(selectedUpdateChannel.updateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button(String(localized: "Check for Updates...")) {
                        UpdateChecker.shared?.checkForUpdates()
                    }
                    .disabled(UpdateChecker.shared?.canCheckForUpdates() != true)
                    Spacer()
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        openSetupWizard()
                    } label: {
                        Label(
                            String(localized: "Open Setup Wizard"),
                            systemImage: "sparkles"
                        )
                    }
                    Spacer()
                }

                Text(String(localized: "Run the first-time setup flow again without changing your saved settings."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let devBuildSource = DevBuildSource.current {
                Section(String(localized: "Development Build")) {
                    LabeledContent(String(localized: "Built"), value: devBuildSource.builtAtUTC)
                    LabeledContent(String(localized: "Source"), value: devBuildSource.source)

                    Text(devBuildSource.repository)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                VStack(spacing: 4) {
                    Text(String(localized: "\u{00A9} 2024-2026 Leise Contributors"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(localized: "Licensed under the GNU General Public License v3.0"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }

    private func openSetupWizard() {
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.setupWizardCurrentStep)
        NotificationCenter.default.post(name: .resetSetupWizardWindow, object: nil)
        ManagedAppWindowOpener.shared.open(id: "setup")
    }
}

private struct DevBuildSource {
    let repository: String
    let branch: String
    let commit: String
    let builtAtUTC: String

    var source: String {
        "\(branch) @ \(commit)"
    }

    static var current: DevBuildSource? {
        guard let url = Bundle.main.url(forResource: "DevBuildSource", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let values = Dictionary(
            uniqueKeysWithValues: contents
                .split(whereSeparator: \Character.isNewline)
                .compactMap { line -> (String, String)? in
                    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
        )

        guard values["app"] == "Leise",
              let repository = values["repo"],
              let branch = values["branch"],
              let commit = values["commit"],
              let builtAtUTC = values["built_at_utc"] else {
            return nil
        }

        return DevBuildSource(
            repository: repository,
            branch: branch,
            commit: commit,
            builtAtUTC: builtAtUTC
        )
    }
}
