import Foundation
import SwiftData

@Model
final class Profile {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var priority: Int
    var bundleIdentifiers: [String]
    var urlPatterns: [String]
    var inputLanguage: String?
    var engineOverride: String?
    var cloudModelOverride: String?
    var outputFormat: String?
    var hotkeyData: Data?
    var autoEnterEnabled: Bool = false
    var createdAt: Date
    var updatedAt: Date

    var hotkey: UnifiedHotkey? {
        get {
            guard let data = hotkeyData else { return nil }
            return try? JSONDecoder().decode(UnifiedHotkey.self, from: data)
        }
        set {
            hotkeyData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    var inputLanguageSelection: LanguageSelection {
        get {
            LanguageSelection(storedValue: inputLanguage, nilBehavior: .inheritGlobal)
        }
        set {
            inputLanguage = newValue.storedValue(nilBehavior: .inheritGlobal)
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        priority: Int = 0,
        bundleIdentifiers: [String] = [],
        urlPatterns: [String] = [],
        inputLanguage: String? = nil,
        engineOverride: String? = nil,
        cloudModelOverride: String? = nil,
        outputFormat: String? = nil,
        hotkeyData: Data? = nil,
        autoEnterEnabled: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.priority = priority
        self.bundleIdentifiers = bundleIdentifiers
        self.urlPatterns = urlPatterns
        self.inputLanguage = inputLanguage
        self.engineOverride = engineOverride
        self.cloudModelOverride = cloudModelOverride
        self.outputFormat = outputFormat
        self.hotkeyData = hotkeyData
        self.autoEnterEnabled = autoEnterEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
