import SwiftUI
import AppKit

enum SettingsTab: Hashable {
    case home, general, appearance, recording, hotkeys, recorder
    case dictationRecovery, fileTranscription, history, dictionary, profiles, parakeet, fillerWords, advanced, about
}

private struct SettingsDestination: Identifiable, Hashable {
    let tab: SettingsTab
    let title: String
    let systemImage: String
    let badge: Int?

    var id: SettingsTab { tab }
}

private struct SettingsDestinationSection: Identifiable {
    let id: String
    let destinations: [SettingsDestination]
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home
    @ObservedObject private var fileTranscription = ServiceContainer.shared.fileTranscriptionViewModel
    @ObservedObject private var dictationRecovery = ServiceContainer.shared.dictationRecoveryViewModel
    @ObservedObject private var homeViewModel = ServiceContainer.shared.homeViewModel
    @ObservedObject private var settingsNavigation = SettingsNavigationCoordinator.shared

    private var destinations: [SettingsDestination] {
        [
            SettingsDestination(tab: .home, title: String(localized: "Home"), systemImage: "house", badge: nil),
            SettingsDestination(tab: .general, title: String(localized: "General"), systemImage: "gear", badge: nil),
            SettingsDestination(tab: .appearance, title: String(localized: "Appearance"), systemImage: "paintbrush", badge: nil),
            SettingsDestination(tab: .hotkeys, title: String(localized: "Hotkeys"), systemImage: "keyboard", badge: nil),
            SettingsDestination(
                tab: .recorder,
                title: String(localized: "settings.tab.recorder"),
                systemImage: "waveform.circle",
                badge: nil
            ),
            SettingsDestination(
                tab: .dictationRecovery,
                title: localizedAppText("Recovery", de: "Wiederherstellung"),
                systemImage: "waveform",
                badge: nil
            ),
            SettingsDestination(tab: .fileTranscription, title: String(localized: "File Transcription"), systemImage: "doc.text", badge: nil),
            SettingsDestination(tab: .history, title: String(localized: "History"), systemImage: "clock.arrow.circlepath", badge: nil),
            SettingsDestination(tab: .dictionary, title: String(localized: "Dictionary"), systemImage: "book.closed", badge: nil),
            SettingsDestination(tab: .profiles, title: String(localized: "Profiles"), systemImage: "person.crop.circle", badge: nil),
            SettingsDestination(
                tab: .parakeet,
                title: String(localized: "Processing"),
                systemImage: "cpu",
                badge: nil
            ),
            SettingsDestination(
                tab: .fillerWords,
                title: String(localized: "Filler Word Cleanup"),
                systemImage: "text.badge.minus",
                badge: nil
            ),
            SettingsDestination(tab: .advanced, title: String(localized: "Advanced"), systemImage: "gearshape.2", badge: nil),
            SettingsDestination(tab: .about, title: String(localized: "About"), systemImage: "info.circle", badge: nil)
        ].compactMap { $0 }
    }

    private var destinationSections: [SettingsDestinationSection] {
        settingsDestinationSections(destinations)
    }

    var body: some View {
        Group {
            if #available(macOS 15, *) {
                SettingsModernShell(
                    selectedTab: $selectedTab,
                    sections: destinationSections,
                    detail: { tab in AnyView(settingsDetail(for: tab)) }
                )
            } else {
                SettingsSidebarShell(
                    selectedTab: $selectedTab,
                    sections: destinationSections,
                    detail: settingsDetail(for:)
                )
            }
        }
        .frame(minWidth: 950, idealWidth: 1050, minHeight: 550, idealHeight: 600)
        .onAppear {
            navigateToFileTranscriptionIfNeeded()
        }
        .onChange(of: fileTranscription.showFilePickerFromMenu) { _, _ in
            navigateToFileTranscriptionIfNeeded()
        }
        .onChange(of: homeViewModel.navigateToHistory) { _, navigate in
            if navigate {
                selectedTab = .history
                homeViewModel.navigateToHistory = false
            }
        }
        .onReceive(settingsNavigation.$request.compactMap { $0 }) { request in
            selectedTab = Self.availableTab(request.tab)
        }
    }

    static func availableTab(_ tab: SettingsTab) -> SettingsTab {
        switch tab {
        case .recording:
            return .general
        default:
            return tab
        }
    }

    private func navigateToFileTranscriptionIfNeeded() {
        if fileTranscription.showFilePickerFromMenu {
            selectedTab = .fileTranscription
        }
    }

    @ViewBuilder
    private func settingsDetail(for tab: SettingsTab) -> some View {
        switch tab {
        case .home:
            HomeSettingsView()
        case .general:
            GeneralSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .recording:
            GeneralSettingsView()
        case .hotkeys:
            HotkeySettingsView()
        case .recorder:
            AudioRecorderView(viewModel: ServiceContainer.shared.audioRecorderViewModel)
        case .dictationRecovery:
            DictationRecoveryView()
        case .fileTranscription:
            FileTranscriptionView()
        case .history:
            HistoryView()
        case .dictionary:
            DictionarySettingsView()
        case .profiles:
            ProfilesSettingsView()
        case .parakeet:
            ParakeetSettingsPage()
        case .fillerWords:
            FillerWordCleanupSettingsPage()
        case .advanced:
            AdvancedSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

@available(macOS 15, *)
private struct SettingsModernShell: View {
    @Binding var selectedTab: SettingsTab
    let sections: [SettingsDestinationSection]
    let detail: (SettingsTab) -> AnyView

    @State private var sidebarSearchText = ""

    private var filteredSections: [SettingsDestinationSection] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }

        return sections
            .map { section in
                SettingsDestinationSection(
                    id: section.id,
                    destinations: section.destinations.filter { destination in
                        destination.title.localizedCaseInsensitiveContains(query)
                    }
                )
            }
            .filter { !$0.destinations.isEmpty }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(filteredSections) { section in
                    Section {
                        ForEach(section.destinations) { destination in
                            SettingsSidebarRow(destination: destination)
                                .tag(destination.tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(
                text: $sidebarSearchText,
                placement: .sidebar,
                prompt: Text(localizedAppText("Search Settings", de: "Einstellungen durchsuchen"))
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            detail(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private func settingsDestination(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> SettingsDestination {
    destinations.first(where: { $0.tab == tab })!
}

private func settingsDestinationSections(_ destinations: [SettingsDestination]) -> [SettingsDestinationSection] {
    let libraryDestinations = [
        settingsDestination(destinations, .home),
        settingsDestination(destinations, .history),
        settingsDestination(destinations, .dictationRecovery),
        settingsDestination(destinations, .dictionary)
    ]

    let preferencesDestinations = [
        settingsDestination(destinations, .general),
        settingsDestination(destinations, .appearance),
        settingsDestination(destinations, .parakeet),
        settingsDestination(destinations, .fillerWords),
        settingsDestination(destinations, .hotkeys),
        settingsDestination(destinations, .advanced)
    ]

    let recordingDestinations = [
        settingsDestination(destinations, .recorder),
        settingsDestination(destinations, .fileTranscription)
    ]

    return [
        SettingsDestinationSection(
            id: "library",
            destinations: libraryDestinations
        ),
        SettingsDestinationSection(
            id: "recording",
            destinations: recordingDestinations
        ),
        SettingsDestinationSection(
            id: "preferences",
            destinations: preferencesDestinations
        ),
        SettingsDestinationSection(
            id: "about",
            destinations: [
                settingsDestination(destinations, .about)
            ]
        )
    ]
}

private struct SettingsSidebarShell<DetailContent: View>: View {
    @Binding var selectedTab: SettingsTab
    let sections: [SettingsDestinationSection]
    let detail: (SettingsTab) -> DetailContent

    @State private var isSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                List(selection: $selectedTab) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.destinations) { destination in
                                SettingsSidebarRow(destination: destination)
                                    .tag(destination.tab)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 240)

                Divider()
            }

            detail(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // macOS 14 glitches when the default NavigationSplitView sidebar reveal animates.
        // Use a custom zero-duration toggle instead.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.leading")
                }
                .help(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
                .accessibilityLabel(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
            }
        }
    }

    private func toggleSidebar() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            withAnimation(nil) {
                isSidebarVisible.toggle()
            }
        }
    }
}

private struct SettingsSidebarRow: View {
    let destination: SettingsDestination

    var body: some View {
        HStack(spacing: 10) {
            Label(destination.title, systemImage: destination.systemImage)

            Spacer(minLength: 8)

            if let badge = destination.badge {
                SettingsSidebarBadge(title: destination.title, count: badge)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct SettingsSidebarBadge: View {
    let title: String
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tertiary, in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(title), \(count) updates")
    }
}

struct RecordingSettingsView: View {
    @ObservedObject private var dictation = ServiceContainer.shared.dictationViewModel
    @ObservedObject private var audioDevice = ServiceContainer.shared.audioDeviceService
    @State private var customSounds: [String] = SoundChoice.installedCustomSounds()
    @State private var draggedInputDevicePriorityItem: AudioInputDevicePriorityItem?
    private let soundService = ServiceContainer.shared.soundService

    private var needsPermissions: Bool {
        dictation.needsMicPermission || dictation.needsAccessibilityPermission
    }

    private var inputDeviceSelectionBinding: Binding<String?> {
        Binding(
            get: { audioDevice.selectedDeviceUID },
            set: { newValue in
                if let newValue {
                    audioDevice.selectInputDeviceAsPrimary(newValue)
                } else {
                    audioDevice.clearInputDevicePriorityList()
                }
            }
        )
    }

    @ViewBuilder
    private var microphonePriorityEditor: some View {
        if shouldShowMicrophonePriorityList {
            LabeledContent(String(localized: "Microphone Priority")) {
                VStack(alignment: .trailing, spacing: 6) {
                    microphonePriorityList
                        .frame(maxWidth: 560, alignment: .leading)

                    microphonePriorityAddMenu
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack {
                Spacer()
                microphonePriorityAddMenu
            }
        }
    }

    private var shouldShowMicrophonePriorityList: Bool {
        let priorityList = audioDevice.inputDevicePriorityList
        guard priorityList.count == 1, let item = priorityList.first else {
            return priorityList.count > 1
        }

        return !audioDevice.isInputDevicePriorityItemAvailable(item)
    }

    @ViewBuilder
    private var microphonePriorityList: some View {
        if !audioDevice.inputDevicePriorityList.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(audioDevice.inputDevicePriorityList.enumerated()), id: \.element.id) { index, item in
                    microphonePriorityRow(index: index, item: item)
                        .onDrag {
                            draggedInputDevicePriorityItem = item
                            return NSItemProvider(object: item.uid as NSString)
                        }
                        .onDrop(
                            of: ["public.text"],
                            delegate: MicrophonePriorityDropDelegate(
                                item: item,
                                audioDevice: audioDevice,
                                draggedItem: $draggedInputDevicePriorityItem
                            )
                        )

                    if index < audioDevice.inputDevicePriorityList.count - 1 {
                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }
        }
    }

    private var microphonePriorityAddMenu: some View {
        Menu {
            if audioDevice.inputDevicePriorityCandidates.isEmpty {
                Text(String(localized: "No more microphones"))
            } else {
                ForEach(audioDevice.inputDevicePriorityCandidates) { device in
                    Button(audioDevice.displayName(for: device)) {
                        audioDevice.addInputDeviceToPriorityList(device)
                    }
                }
            }
        } label: {
            Label(String(localized: "Add Microphone"), systemImage: "plus")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help(String(localized: "Add Microphone"))
    }

    private func microphonePriorityRow(index: Int, item: AudioInputDevicePriorityItem) -> some View {
        let isAvailable = audioDevice.isInputDevicePriorityItemAvailable(item)
        let canMoveUp = index > 0
        let canMoveDown = index < audioDevice.inputDevicePriorityList.count - 1

        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 12)

            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            Text(audioDevice.displayName(for: item))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            if !isAvailable {
                Text(String(localized: "Disconnected"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            Button {
                audioDevice.removeInputDevicePriorityItem(item)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 13))
            .help(String(localized: "Remove microphone"))
        }
        .padding(.vertical, 3)
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                moveMicrophonePriorityItemUp(item)
            } label: {
                Label(String(localized: "Move Up"), systemImage: "chevron.up")
            }
            .disabled(!canMoveUp)

            Button {
                moveMicrophonePriorityItemDown(item)
            } label: {
                Label(String(localized: "Move Down"), systemImage: "chevron.down")
            }
            .disabled(!canMoveDown)
        }
        .modifier(MicrophonePriorityAccessibilityActions(
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            moveUp: { moveMicrophonePriorityItemUp(item) },
            moveDown: { moveMicrophonePriorityItemDown(item) }
        ))
    }

    private func moveMicrophonePriorityItemUp(_ item: AudioInputDevicePriorityItem) {
        guard let index = audioDevice.inputDevicePriorityList.firstIndex(of: item),
              index > 0 else { return }

        audioDevice.moveInputDevicePriorityItems(from: IndexSet(integer: index), to: index - 1)
    }

    private func moveMicrophonePriorityItemDown(_ item: AudioInputDevicePriorityItem) {
        guard let index = audioDevice.inputDevicePriorityList.firstIndex(of: item),
              index < audioDevice.inputDevicePriorityList.count - 1 else { return }

        audioDevice.moveInputDevicePriorityItems(from: IndexSet(integer: index), to: index + 2)
    }

    var body: some View {
        Form {
            settingsSections
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            customSounds = SoundChoice.installedCustomSounds()
        }
    }

    @ViewBuilder
    var settingsSections: some View {
            if needsPermissions {
                PermissionsBanner(dictation: dictation)
            }

            Section(String(localized: "Microphone")) {
                Picker(String(localized: "Input Device"), selection: inputDeviceSelectionBinding) {
                    Text(String(localized: "System Default")).tag(nil as String?)
                    Divider()
                    ForEach(audioDevice.inputDevices) { device in
                        Text(audioDevice.displayName(for: device)).tag(device.uid as String?)
                    }
                }

                microphonePriorityEditor

                if let message = audioDevice.selectedDeviceStatusMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                if audioDevice.isPreviewActive {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        AudioWaveformView(
                            audioLevel: audioDevice.previewAudioLevel,
                            isSetup: false,
                            compact: true
                        )
                        .foregroundStyle(.green)
                    }
                    .padding(.vertical, 4)
                }

                Button(audioDevice.isPreviewActive
                    ? String(localized: "Stop Preview")
                    : String(localized: "Test Microphone")
                ) {
                    if audioDevice.isPreviewActive {
                        audioDevice.stopPreview()
                    } else {
                        audioDevice.startPreview()
                    }
                }
                .disabled(!audioDevice.isPreviewActive && dictation.needsMicPermission)

                if let error = audioDevice.previewError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if let name = audioDevice.disconnectedDeviceName {
                    Label(
                        String(localized: "Microphone disconnected. Falling back to system default."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if audioDevice.disconnectedDeviceName == name {
                                audioDevice.disconnectedDeviceName = nil
                            }
                        }
                    }
                }
            }

            Section(String(localized: "Sound")) {
                Toggle(String(localized: "Play sound feedback"), isOn: $dictation.soundFeedbackEnabled)

                if dictation.soundFeedbackEnabled {
                    SoundEventPicker(event: .recordingStarted, soundService: soundService, customSounds: $customSounds)
                    SoundEventPicker(event: .transcriptionSuccess, soundService: soundService, customSounds: $customSounds)
                    SoundEventPicker(event: .error, soundService: soundService, customSounds: $customSounds)
                }

                Text(String(localized: "Plays a sound when recording starts and when transcription completes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

            Section(String(localized: "Clipboard")) {
                Toggle(String(localized: "Preserve clipboard content"), isOn: $dictation.preserveClipboard)

                Text(String(localized: "Restores your clipboard after text insertion. Without this, your clipboard contains the transcribed text after dictation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Output Formatting")) {
                Toggle(String(localized: "App-aware formatting"), isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.appFormattingEnabled) },
                    set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.appFormattingEnabled) }
                ))

                Text(String(localized: "When enabled, Leise uses target-app rules and available cursor context for smarter insertion. Profile output format settings still choose the inserted format for each profile."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(String(localized: "Normalize spoken numbers to digits"), isOn: Binding(
                    get: { TranscriptionNormalizationService.numberNormalizationEnabled() },
                    set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled) }
                ))

                Text(String(localized: "Converts spoken numbers in supported languages into digits before insertion and export."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Audio Ducking")) {
                Toggle(String(localized: "Reduce system volume during recording"), isOn: $dictation.audioDuckingEnabled)

                if dictation.audioDuckingEnabled {
                    HStack {
                        Image(systemName: "speaker.slash")
                            .foregroundStyle(.secondary)
                        Slider(value: $dictation.audioDuckingLevel, in: 0...0.5, step: 0.05)
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(.secondary)
                    }

                    Text(String(localized: "Percentage of your current volume to use during recording. 0% mutes completely."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "Media Pause")) {
                Toggle(String(localized: "Pause media playback during recording"), isOn: $dictation.mediaPauseEnabled)

                Text(String(localized: "Automatically pauses music and videos while recording and resumes when done. Uses macOS system media controls - may not work with all apps."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if needsPermissions {
                Section(String(localized: "Permissions")) {
                    if dictation.needsMicPermission {
                        HStack {
                            Label(
                                String(localized: "Microphone"),
                                systemImage: "mic.slash"
                            )
                            .foregroundStyle(.orange)

                            Spacer()

                            Button(String(localized: "Grant Access")) {
                                dictation.requestMicPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if dictation.needsAccessibilityPermission {
                        HStack {
                            Label(
                                String(localized: "Accessibility"),
                                systemImage: "lock.shield"
                            )
                            .foregroundStyle(.orange)

                            Spacer()

                            Button(String(localized: "Grant Access")) {
                                dictation.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
    }

}

// MARK: - Sound Event Picker

private struct SoundEventPicker: View {
    let event: SoundEvent
    let soundService: SoundService
    @Binding var customSounds: [String]
    @State private var selection: String

    init(event: SoundEvent, soundService: SoundService, customSounds: Binding<[String]>) {
        self.event = event
        self.soundService = soundService
        self._customSounds = customSounds
        self._selection = State(initialValue: soundService.choice(for: event).storageKey)
    }

    var body: some View {
        HStack {
            Picker(event.displayName, selection: $selection) {
                Text(String(localized: "Default")).tag(event.defaultChoice.storageKey)

                Divider()

                ForEach(SoundChoice.bundledSounds, id: \.name) { sound in
                    Text(sound.displayName).tag(SoundChoice.bundled(sound.name).storageKey)
                }

                if !customSounds.isEmpty {
                    Divider()
                    ForEach(customSounds, id: \.self) { name in
                        Text(name).tag(SoundChoice.custom(name).storageKey)
                    }
                }

                Divider()

                ForEach(SoundChoice.systemSounds, id: \.self) { name in
                    Text(name).tag(SoundChoice.system(name).storageKey)
                }

                Divider()

                Text(String(localized: "None")).tag(SoundChoice.none.storageKey)
            }
            .onChange(of: selection) { _, newValue in
                let choice = SoundChoice(storageKey: newValue)
                soundService.updateChoice(for: event, choice: choice)
                soundService.preview(choice)
            }

            Button {
                soundService.preview(SoundChoice(storageKey: selection))
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Preview sound"))

            Button {
                importCustomSound()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Add custom sound"))
        }
    }

    private func importCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SoundChoice.allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a sound file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let filename = try soundService.importCustomSound(from: url)
            customSounds = SoundChoice.installedCustomSounds()
            selection = SoundChoice.custom(filename).storageKey
        } catch {
            // File copy failed - silently ignore
        }
    }
}

private struct MicrophonePriorityAccessibilityActions: ViewModifier {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveUp && canMoveDown {
            content
                .accessibilityAction(named: Text(String(localized: "Move Up")), moveUp)
                .accessibilityAction(named: Text(String(localized: "Move Down")), moveDown)
        } else if canMoveUp {
            content
                .accessibilityAction(named: Text(String(localized: "Move Up")), moveUp)
        } else if canMoveDown {
            content
                .accessibilityAction(named: Text(String(localized: "Move Down")), moveDown)
        } else {
            content
        }
    }
}

private struct MicrophonePriorityDropDelegate: DropDelegate {
    let item: AudioInputDevicePriorityItem
    let audioDevice: AudioDeviceService
    @Binding var draggedItem: AudioInputDevicePriorityItem?

    func dropEntered(info: DropInfo) {
        guard let draggedItem,
              draggedItem != item,
              let fromIndex = audioDevice.inputDevicePriorityList.firstIndex(of: draggedItem),
              let toIndex = audioDevice.inputDevicePriorityList.firstIndex(of: item) else { return }

        let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
        audioDevice.moveInputDevicePriorityItems(from: IndexSet(integer: fromIndex), to: destination)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}

// MARK: - Permissions Banner

struct PermissionsBanner: View {
    @ObservedObject var dictation: DictationViewModel

    var body: some View {
        Section {
            if dictation.needsMicPermission {
                HStack {
                    Label(
                        String(localized: "Microphone access required"),
                        systemImage: "mic.slash"
                    )
                    .foregroundStyle(.red)

                    Spacer()

                    Button(String(localized: "Grant Access")) {
                        dictation.requestMicPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if dictation.needsAccessibilityPermission {
                HStack {
                    Label(
                        String(localized: "Accessibility access required"),
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.red)

                    Spacer()

                    Button(String(localized: "Grant Access")) {
                        dictation.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}
