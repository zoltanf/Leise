import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at Login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }

                Text(String(localized: "Leise will start automatically when you log in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            RecordingSettingsView(embeddedInParentForm: true)

        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert toggle on failure
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct AppearanceSettingsView: View {
    private enum AppVisibilityMode: String, CaseIterable {
        case menuBar
        case dock
        case dockWhileWindowOpen
    }

    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden) private var dockIconBehaviorRawValue = DockIconBehavior.keepVisible.rawValue
    @State private var appLanguage: String = AppearanceSettingsView.currentAppLanguage
    @State private var showRestartAlert = false
    @ObservedObject private var dictation = ServiceContainer.shared.dictationViewModel

    private static var currentAppLanguage: String {
        if let language = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage) {
            return language
        }
        let preferredLanguage = Locale.preferredLanguages.first
        if preferredLanguage?.hasPrefix("ja") == true { return "ja" }
        return preferredLanguage?.hasPrefix("de") == true ? "de" : "en"
    }

    private var supportsTranscriptPreview: Bool {
        dictation.indicatorStyle.supportsTranscriptPreview
    }

    private var supportsPositionSelection: Bool {
        dictation.indicatorStyle == .overlay || dictation.indicatorStyle == .minimal
    }

    private var dockIconBehavior: DockIconBehavior {
        get { DockIconBehavior(rawValue: dockIconBehaviorRawValue) ?? .keepVisible }
        nonmutating set { dockIconBehaviorRawValue = newValue.rawValue }
    }

    private var appVisibilityMode: AppVisibilityMode {
        get {
            if showMenuBarIcon { return .menuBar }
            return dockIconBehavior == .keepVisible ? .dock : .dockWhileWindowOpen
        }
        nonmutating set {
            switch newValue {
            case .menuBar:
                showMenuBarIcon = true
                dockIconBehavior = .keepVisible
            case .dock:
                showMenuBarIcon = false
                dockIconBehavior = .keepVisible
            case .dockWhileWindowOpen:
                showMenuBarIcon = false
                dockIconBehavior = .onlyWhileWindowOpen
            }
        }
    }

    private var appVisibilityDescription: LocalizedStringKey {
        switch appVisibilityMode {
        case .menuBar:
            "Leise stays in the menu bar and hides its Dock icon while no window is open."
        case .dock:
            "Leise stays accessible via the Dock icon."
        case .dockWhileWindowOpen:
            "Leise hides both icons until a window opens. To reopen Settings later, launch Leise from Spotlight or the Applications folder."
        }
    }

    private var transcriptPreviewSize: Binding<Double> {
        Binding(
            get: { Double(dictation.indicatorTranscriptPreviewFontSizeOffset) },
            set: { dictation.indicatorTranscriptPreviewFontSizeOffset = Int($0.rounded()) }
        )
    }

    var body: some View {
        Form {
            Section(String(localized: "Language")) {
                Picker(String(localized: "App Language"), selection: $appLanguage) {
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                    Text("日本語").tag("ja")
                }
                .onChange(of: appLanguage) {
                    UserDefaults.standard.set(appLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
                    UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
                    showRestartAlert = true
                }
            }

            Section(String(localized: "App Appearance")) {
                Picker(String(localized: "App visibility"), selection: Binding(
                    get: { appVisibilityMode },
                    set: { appVisibilityMode = $0 }
                )) {
                    Text(String(localized: "Menu bar icon")).tag(AppVisibilityMode.menuBar)
                    Text(String(localized: "Dock icon")).tag(AppVisibilityMode.dock)
                    Text(String(localized: "Dock icon only while a window is open")).tag(AppVisibilityMode.dockWhileWindowOpen)
                }

                Text(appVisibilityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Indicator")) {
                IndicatorPreviewView()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                IndicatorStylePicker()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                if supportsTranscriptPreview {
                    Toggle(String(localized: "Show live transcript preview"), isOn: $dictation.indicatorTranscriptPreviewEnabled)

                    LabeledContent(String(localized: "Live transcript size")) {
                        HStack(spacing: 12) {
                            Slider(value: transcriptPreviewSize, in: 0...8, step: 1)
                                .frame(width: 180)
                            Text(verbatim: "\(Int(dictation.indicatorTranscriptPreviewFontSize(for: dictation.indicatorStyle))) pt")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                        }
                    }
                    .disabled(!dictation.indicatorTranscriptPreviewEnabled)

                    if !dictation.indicatorTranscriptPreviewEnabled {
                        Text(String(localized: "When disabled, Leise skips live transcript requests for the indicator and only runs the final transcription after you stop recording."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker(String(localized: "Visibility"), selection: $dictation.notchIndicatorVisibility) {
                    Text(String(localized: "Always visible")).tag(NotchIndicatorVisibility.always)
                    Text(String(localized: "Only during activity")).tag(NotchIndicatorVisibility.duringActivity)
                    Text(String(localized: "Never")).tag(NotchIndicatorVisibility.never)
                }

                Picker(String(localized: "Display"), selection: $dictation.notchIndicatorDisplay) {
                    Text(String(localized: "Active Screen")).tag(NotchIndicatorDisplay.activeScreen)
                    Text(String(localized: "Primary Screen")).tag(NotchIndicatorDisplay.primaryScreen)
                    Text(String(localized: "Built-in Display")).tag(NotchIndicatorDisplay.builtInScreen)
                }

                if supportsPositionSelection {
                    Picker(String(localized: "Position"), selection: $dictation.overlayPosition) {
                        Text(String(localized: "Top")).tag(OverlayPosition.top)
                        Text(String(localized: "Bottom")).tag(OverlayPosition.bottom)
                    }
                }

                if dictation.indicatorStyle != .minimal {
                    Picker(String(localized: "Left Side"), selection: $dictation.notchIndicatorLeftContent) {
                        indicatorContentOptions
                    }
                }

                Picker(String(localized: "Right Side"), selection: $dictation.notchIndicatorRightContent) {
                    indicatorContentOptions
                }

                Text(indicatorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .alert(String(localized: "Restart Required"), isPresented: $showRestartAlert) {
            Button(String(localized: "Restart Now")) {
                restartApp()
            }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "The language change will take effect after restarting Leise."))
        }
    }

    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var indicatorDescription: LocalizedStringKey {
        switch dictation.indicatorStyle {
        case .notch:
            "The notch indicator extends the MacBook notch area to show recording status."
        case .minimal:
            "The indicator style is a compact power-user indicator that only shows status, errors, and action feedback."
        default:
            "The overlay indicator appears as a floating pill on the screen."
        }
    }

    @ViewBuilder
    private var indicatorContentOptions: some View {
        Text(String(localized: "Recording Indicator")).tag(NotchIndicatorContent.indicator)
        Text(String(localized: "Timer")).tag(NotchIndicatorContent.timer)
        Text(String(localized: "Waveform")).tag(NotchIndicatorContent.waveform)
        Text(String(localized: "Profile")).tag(NotchIndicatorContent.profile)
        Text(String(localized: "None")).tag(NotchIndicatorContent.none)
    }
}
