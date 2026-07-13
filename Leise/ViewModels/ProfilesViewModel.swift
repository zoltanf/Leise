import Combine
import Foundation

@MainActor
final class ProfilesViewModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var showingEditor = false
    @Published var editingProfile: Profile?
    @Published var editorName = ""
    @Published var editorEnabled = true
    @Published var editorBundleIdentifiers = ""
    @Published var editorURLPatterns = ""
    @Published var editorInputLanguage = ""
    @Published var editorOutputFormat = ""
    @Published var editorAutoEnterEnabled = false
    @Published var editorHotkey: UnifiedHotkey?

    private let profileService: ProfileService
    private var cancellables = Set<AnyCancellable>()

    init(
        profileService: ProfileService,
        historyService _: HistoryService,
        settingsViewModel _: SettingsViewModel,
        textInsertionService _: TextInsertionService
    ) {
        self.profileService = profileService
        profiles = profileService.profiles
        profileService.$profiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.profiles = $0 }
            .store(in: &cancellables)
    }

    func prepareNewProfile() {
        editingProfile = nil
        editorName = ""
        editorEnabled = true
        editorBundleIdentifiers = ""
        editorURLPatterns = ""
        editorInputLanguage = ""
        editorOutputFormat = ""
        editorAutoEnterEnabled = false
        editorHotkey = nil
        showingEditor = true
    }

    func startEditing(_ profile: Profile) {
        editingProfile = profile
        editorName = profile.name
        editorEnabled = profile.isEnabled
        editorBundleIdentifiers = profile.bundleIdentifiers.joined(separator: "\n")
        editorURLPatterns = profile.urlPatterns.joined(separator: "\n")
        editorInputLanguage = profile.inputLanguage ?? ""
        editorOutputFormat = profile.outputFormat ?? ""
        editorAutoEnterEnabled = profile.autoEnterEnabled
        editorHotkey = profile.hotkey
        showingEditor = true
    }

    func saveEditor() {
        let name = editorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let bundles = values(from: editorBundleIdentifiers)
        let urls = values(from: editorURLPatterns)
        let language = optionalValue(editorInputLanguage)
        let outputFormat = optionalValue(editorOutputFormat)
        let hotkeyData = editorHotkey.flatMap { try? JSONEncoder().encode($0) }

        if let profile = editingProfile {
            profile.name = name
            profile.isEnabled = editorEnabled
            profile.bundleIdentifiers = bundles
            profile.urlPatterns = urls
            profile.inputLanguage = language
            profile.outputFormat = outputFormat
            profile.autoEnterEnabled = editorAutoEnterEnabled
            profile.hotkeyData = hotkeyData
            profileService.updateProfile(profile)
        } else {
            profileService.addProfile(
                name: name,
                isEnabled: editorEnabled,
                bundleIdentifiers: bundles,
                urlPatterns: urls,
                inputLanguage: language,
                outputFormat: outputFormat,
                hotkeyData: hotkeyData,
                autoEnterEnabled: editorAutoEnterEnabled,
                priority: profileService.nextPriority()
            )
        }
        showingEditor = false
    }

    func toggle(_ profile: Profile) { profileService.toggleProfile(profile) }
    func delete(_ profile: Profile) { profileService.deleteProfile(profile) }

    private func values(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func optionalValue(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
