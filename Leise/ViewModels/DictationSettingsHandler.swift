import Foundation

@MainActor
final class DictationSettingsHandler {
    private let hotkeyService: HotkeyService
    private let audioRecordingService: AudioRecordingService
    private let textInsertionService: TextInsertionService
    private let profileService: ProfileService
    private var permissionPollTask: Task<Void, Never>?

    var onObjectWillChange: (() -> Void)?
    var onHotkeyLabelsChanged: (() -> Void)?

    init(
        hotkeyService: HotkeyService,
        audioRecordingService: AudioRecordingService,
        textInsertionService: TextInsertionService,
        profileService: ProfileService
    ) {
        self.hotkeyService = hotkeyService
        self.audioRecordingService = audioRecordingService
        self.textInsertionService = textInsertionService
        self.profileService = profileService
    }

    func requestMicPermission() {
        Task {
            _ = await audioRecordingService.requestMicrophonePermission()
            DispatchQueue.main.async { [weak self] in
                self?.onObjectWillChange?()
            }
            pollPermissionStatus()
        }
    }

    func requestAccessibilityPermission() {
        textInsertionService.requestAccessibilityPermission()
        pollPermissionStatus()
    }

    func setHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.updateHotkey(hotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func addHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.appendHotkey(hotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func replaceHotkey(_ existingHotkey: UnifiedHotkey, with newHotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.replaceHotkey(existingHotkey, with: newHotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func removeHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.removeHotkey(hotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func removeConflictingHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.removeConflictingHotkey(hotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func clearHotkey(for slot: HotkeySlotType) {
        hotkeyService.clearHotkey(for: slot)
        onHotkeyLabelsChanged?()
    }

    func hotkeys(for slot: HotkeySlotType) -> [UnifiedHotkey] {
        hotkeyService.hotkeys(for: slot)
    }

    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? {
        hotkeyService.isHotkeyAssigned(hotkey, excluding: excluding)
    }

    static func loadHotkeys(for slotType: HotkeySlotType) -> [UnifiedHotkey] {
        if let data = UserDefaults.standard.data(forKey: slotType.hotkeysDefaultsKey),
           let hotkeys = try? JSONDecoder().decode([UnifiedHotkey].self, from: data) {
            return hotkeys
        }

        guard let data = UserDefaults.standard.data(forKey: slotType.defaultsKey),
              let hotkey = try? JSONDecoder().decode(UnifiedHotkey.self, from: data) else {
            return []
        }
        return [hotkey]
    }

    static func loadHotkeyLabels(for slotType: HotkeySlotType) -> [String] {
        loadHotkeys(for: slotType).map { HotkeyService.displayName(for: $0) }
    }

    static func loadHotkeyLabel(for slotType: HotkeySlotType) -> String {
        loadHotkeyLabels(for: slotType).first ?? ""
    }

    static func loadMenuShortcutDescriptor(for slotType: HotkeySlotType) -> HotkeyService.MenuShortcutDescriptor? {
        loadHotkeys(for: slotType).compactMap { HotkeyService.menuShortcutDescriptor(for: $0) }.first
    }

    func registerInitialTriggerHotkeys() {
        syncProfileHotkeys(profileService.profiles)
    }

    func syncProfileHotkeys(_ profiles: [Profile]) {
        let entries = profiles.compactMap { profile -> (id: UUID, hotkey: UnifiedHotkey)? in
            guard profile.isEnabled, let hotkey = profile.hotkey else { return nil }
            return (profile.id, hotkey)
        }
        hotkeyService.registerProfileHotkeys(entries)
    }

    func pollPermissionStatus() {
        let needsMic = { [weak self] () -> Bool in
            guard let self else { return false }
            return !self.audioRecordingService.hasMicrophonePermission
        }
        let needsAccessibility = { [weak self] () -> Bool in
            guard let self else { return false }
            return !self.textInsertionService.isAccessibilityGranted
        }
        var hasResumedHotkeyMonitoring = !needsAccessibility()
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.onObjectWillChange?()
                    if !hasResumedHotkeyMonitoring, !needsAccessibility() {
                        hasResumedHotkeyMonitoring = true
                        self?.hotkeyService.resumeMonitoring()
                    }
                }
                if !needsMic(), !needsAccessibility() { return }
            }
        }
    }
}
