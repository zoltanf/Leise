import Foundation
import LeiseCore
import SwiftData
import os.log

func preferredAppLanguageCode() -> String {
    if let language = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage),
       !language.isEmpty {
        return language
    }
    return Bundle.main.preferredLocalizations.first
        ?? Locale.current.language.languageCode?.identifier
        ?? "en"
}

func localizedAppLanguageName(for code: String) -> String {
    // Language option names must follow the in-app language immediately (the
    // Locale-based names below do). They cannot go through the string catalog:
    // String(localized:) resolution is effectively fixed for the process
    // lifetime, and the app language can differ from it until relaunch.
    let language = preferredAppLanguageCode()
    if code == "auto" {
        if language.hasPrefix("de") { return "Automatisch erkennen" }
        if language.hasPrefix("ja") { return "自動検出" }
        return "Auto-Detect"
    }
    if code == "multi" {
        if language.hasPrefix("de") { return "Mehrsprachig" }
        if language.hasPrefix("ja") { return "多言語" }
        return "Multilingual"
    }
    return Locale(identifier: language).localizedString(forIdentifier: code) ?? code
}

struct LocalizedAppLanguageOption: Equatable {
    let code: String
    let name: String
}

let defaultSpokenLanguageCodes: [String] = [
    "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
    "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
    "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo", "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
    "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
    "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "vo", "yi", "yo", "yue", "zh",
]

func localizedAppLanguageOptions(for codes: [String]) -> [LocalizedAppLanguageOption] {
    codes.map { LocalizedAppLanguageOption(code: $0, name: localizedAppLanguageName(for: $0)) }
}

func localizedAppLanguageSearchTerms(for code: String, preferredDisplayName: String? = nil) -> [String] {
    var candidates = [preferredDisplayName, code, localizedAppLanguageName(for: code)]
    if code == "multi" {
        candidates.append(contentsOf: ["Multilingual", "Mehrsprachig"])
    }
    candidates.append(Locale(identifier: "en").localizedString(forIdentifier: code))
    candidates.append(Locale.current.localizedString(forIdentifier: code))
    var terms: [String] = []
    for candidate in candidates {
        guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !terms.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
        terms.append(value)
    }
    return terms
}

func localizedAppLanguageBadgeText(for code: String) -> String {
    if code.contains("-") { return code.uppercased() }
    let key = NSLocale.Key.languageCode.rawValue
    return NSLocale.components(fromLocaleIdentifier: code)[key]?.uppercased() ?? code.uppercased()
}

struct LocalizedAppLanguageBadgeDescriptor: Equatable {
    let text: String
    let accessibilityLabel: String
}

func localizedAppLanguageBadgeDescriptor(for code: String) -> LocalizedAppLanguageBadgeDescriptor {
    LocalizedAppLanguageBadgeDescriptor(
        text: localizedAppLanguageBadgeText(for: code),
        accessibilityLabel: localizedAppLanguageName(for: code)
    )
}

func featuredAppLanguageRank(for code: String) -> Int? {
    let key = NSLocale.Key.languageCode.rawValue
    guard let languageCode = NSLocale.components(fromLocaleIdentifier: code)[key]?.lowercased() else { return nil }
    return ["de", "en", "fr", "es", "zh", "hi", "ar", "pt", "ja"].firstIndex(of: languageCode)
}

enum AppConstants {
    enum ReleaseChannel: String, CaseIterable {
        case stable
        case releaseCandidate = "release-candidate"
        case daily

        var sparkleChannels: Set<String> {
            switch self {
            case .stable:
                return []
            case .releaseCandidate:
                return ["release-candidate"]
            case .daily:
                return ["release-candidate", "daily"]
            }
        }

        var selectionDisplayName: String {
            switch self {
            case .stable:
                return String(localized: "Stable")
            case .releaseCandidate:
                return String(localized: "Release Candidate")
            case .daily:
                return String(localized: "Daily")
            }
        }

        var versionDisplayName: String? {
            switch self {
            case .stable:
                return nil
            case .releaseCandidate, .daily:
                return selectionDisplayName
            }
        }

        var updateDescription: String {
            switch self {
            case .stable:
                return String(localized: "Stable gets production releases only.")
            case .releaseCandidate:
                return String(localized: "Release Candidate includes stable and preview builds.")
            case .daily:
                return String(localized: "Daily includes stable, release candidate, and daily builds.")
            }
        }
    }

    nonisolated(unsafe) static var testAppSupportDirectoryOverride: URL?

    static let appSupportDirectoryName = "Leise"

    static let keychainServicePrefix = "com.leise.mac.apikey."

    static let loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "com.leise.mac"

    static var appSupportDirectory: URL {
        if let override = testAppSupportDirectoryOverride {
            return override
        }
        return defaultAppSupportDirectory
    }

    static let defaultAppSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }()

    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    static let buildVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    static func bundledReleaseChannel(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> ReleaseChannel {
        guard let rawValue = infoDictionary?["LeiseReleaseChannel"] as? String,
              let channel = ReleaseChannel(rawValue: rawValue) else {
            return .stable
        }
        return channel
    }

    static func selectedUpdateChannel(
        defaults: UserDefaults = .standard,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> ReleaseChannel {
        guard let rawValue = defaults.string(forKey: UserDefaultsKeys.updateChannel),
              let channel = ReleaseChannel(rawValue: rawValue) else {
            return bundledReleaseChannel(infoDictionary: infoDictionary)
        }
        return channel
    }

    static var releaseChannel: ReleaseChannel {
        bundledReleaseChannel()
    }

    static var effectiveUpdateChannel: ReleaseChannel {
        selectedUpdateChannel()
    }

    static let defaultReleaseChannel: ReleaseChannel = {
        guard let rawValue = Bundle.main.infoDictionary?["LeiseReleaseChannel"] as? String,
              let channel = ReleaseChannel(rawValue: rawValue) else {
            return .stable
        }
        return channel
    }()

    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil {
            return true
        }

        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    static let isDevelopment = false

}

private let factoryLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Leise", category: "SwiftDataStoreFactory")

@MainActor
struct SwiftDataStoreFactory {
    static func create(
        for modelTypes: [any PersistentModel.Type],
        storeName: String,
        in directory: URL
    ) throws -> (ModelContainer, ModelContext) {
        let schema = Schema(modelTypes)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let storeURL = directory.appendingPathComponent("\(storeName).store")
        let config = ModelConfiguration(url: storeURL)

        var container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            factoryLogger.error("Incompatible schema for \(storeName) store. Resetting store.")
            // Incompatible schema — delete old store and retry
            for suffix in ["", "-wal", "-shm"] {
                let url = directory.appendingPathComponent("\(storeName).store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                // If it still fails, there's a fundamental issue
                fatalError("Failed to create \(storeName) ModelContainer after reset: \(error)")
            }
        }

        let context = ModelContext(container)
        context.autosaveEnabled = true
        return (container, context)
    }
}
