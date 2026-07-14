import CoreFoundation
import Foundation

struct LeiseUserDataBackup: Codable {
    static let formatIdentifier = "com.leise.user-data-backup"
    static let currentSchemaVersion = 1

    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let appBuild: String
    let preferences: [String: BackupPreferenceValue]
    let dictionaryEntries: [BackupDictionaryEntry]
    let profiles: [BackupProfile]
    let history: [BackupHistoryRecord]
}

enum BackupPreferenceValue: Codable, Equatable {
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case array([BackupPreferenceValue])
    case dictionary([String: BackupPreferenceValue])

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum ValueType: String, Codable {
        case bool, integer, double, string, data, date, array, dictionary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
        case .double: self = .double(try container.decode(Double.self, forKey: .value))
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .data: self = .data(try container.decode(Data.self, forKey: .value))
        case .date: self = .date(try container.decode(Date.self, forKey: .value))
        case .array: self = .array(try container.decode([BackupPreferenceValue].self, forKey: .value))
        case .dictionary:
            self = .dictionary(try container.decode([String: BackupPreferenceValue].self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case .integer(let value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .data(let value):
            try container.encode(ValueType.data, forKey: .type)
            try container.encode(value, forKey: .value)
        case .date(let value):
            try container.encode(ValueType.date, forKey: .type)
            try container.encode(value, forKey: .value)
        case .array(let value):
            try container.encode(ValueType.array, forKey: .type)
            try container.encode(value, forKey: .value)
        case .dictionary(let value):
            try container.encode(ValueType.dictionary, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    init?(propertyListValue value: Any) {
        switch value {
        case let value as Date:
            self = .date(value)
        case let value as Data:
            self = .data(value)
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if CFNumberIsFloatType(value) {
                let double = value.doubleValue
                guard double.isFinite else { return nil }
                self = .double(double)
            } else {
                self = .integer(value.int64Value)
            }
        case let value as [Any]:
            let converted = value.compactMap(Self.init(propertyListValue:))
            guard converted.count == value.count else { return nil }
            self = .array(converted)
        case let value as [String: Any]:
            var converted: [String: BackupPreferenceValue] = [:]
            for (key, item) in value {
                guard let item = Self(propertyListValue: item) else { return nil }
                converted[key] = item
            }
            self = .dictionary(converted)
        default:
            return nil
        }
    }

    var propertyListValue: Any {
        switch self {
        case .bool(let value): value
        case .integer(let value): NSNumber(value: value)
        case .double(let value): value
        case .string(let value): value
        case .data(let value): value
        case .date(let value): value
        case .array(let value): value.map(\.propertyListValue)
        case .dictionary(let value): value.mapValues(\.propertyListValue)
        }
    }
}

struct BackupDictionaryEntry: Codable, Equatable {
    let id: UUID
    let type: DictionaryEntryType
    let original: String
    let replacement: String?
    let caseSensitive: Bool
    let isEnabled: Bool
    let ctcMinSimilarity: Float?
    let source: DictionaryEntrySource
    let createdAt: Date
    let updatedAt: Date?
    let usageCount: Int

    init(_ entry: DictionaryEntry) {
        id = entry.id
        type = entry.type
        original = entry.original
        replacement = entry.replacement
        caseSensitive = entry.caseSensitive
        isEnabled = entry.isEnabled
        ctcMinSimilarity = entry.ctcMinSimilarity
        source = entry.source
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        usageCount = entry.usageCount
    }
}

struct BackupProfile: Codable, Equatable {
    let id: UUID
    let name: String
    let isEnabled: Bool
    let priority: Int
    let bundleIdentifiers: [String]
    let urlPatterns: [String]
    let inputLanguage: String?
    let engineOverride: String?
    let cloudModelOverride: String?
    let outputFormat: String?
    let hotkeyData: Data?
    let autoEnterEnabled: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ profile: Profile) {
        id = profile.id
        name = profile.name
        isEnabled = profile.isEnabled
        priority = profile.priority
        bundleIdentifiers = profile.bundleIdentifiers
        urlPatterns = profile.urlPatterns
        inputLanguage = profile.inputLanguage
        engineOverride = profile.engineOverride
        cloudModelOverride = profile.cloudModelOverride
        outputFormat = profile.outputFormat
        hotkeyData = profile.hotkeyData
        autoEnterEnabled = profile.autoEnterEnabled
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
    }
}

struct BackupHistoryRecord: Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let rawText: String
    let finalText: String
    let appName: String?
    let appBundleIdentifier: String?
    let appURL: String?
    let durationSeconds: Double
    let language: String?
    let engineUsed: String
    let modelUsed: String?
    let wordsCount: Int
    let audioFileName: String?
    let pipelineSteps: [String]

    init(_ record: TranscriptionRecord) {
        id = record.id
        timestamp = record.timestamp
        rawText = record.rawText
        finalText = record.finalText
        appName = record.appName
        appBundleIdentifier = record.appBundleIdentifier
        appURL = record.appURL
        durationSeconds = record.durationSeconds
        language = record.language
        engineUsed = record.engineUsed
        modelUsed = record.modelUsed
        wordsCount = record.wordsCount
        audioFileName = record.audioFileName
        pipelineSteps = record.pipelineStepList
    }
}

struct UserDataBackupSummary: Equatable {
    let preferenceCount: Int
    let dictionaryEntryCount: Int
    let profileCount: Int
    let historyRecordCount: Int
}

enum UserDataBackupError: LocalizedError {
    case fileTooLarge
    case unsupportedFormat
    case unsupportedVersion(Int)
    case invalidData(String)
    case unsupportedPreference(String)
    case restoreFailed(Error)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "The backup is larger than the supported 256 MB limit."
        case .unsupportedFormat:
            "This is not a Leise user-data backup."
        case .unsupportedVersion(let version):
            "This backup uses unsupported schema version \(version)."
        case .invalidData(let reason):
            "The backup is invalid: \(reason)"
        case .unsupportedPreference(let key):
            "The setting ‘\(key)’ uses an unsupported value type."
        case .restoreFailed(let error):
            "The backup could not be restored: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class UserDataBackupService {
    private static let maximumBackupSize = 256 * 1_024 * 1_024

    private let defaults: UserDefaults
    private let defaultsDomain: String
    private let historyService: HistoryService
    private let dictionaryService: DictionaryService
    private let profileService: ProfileService
    private let usageStatisticsService: UsageStatisticsService
    private let bundle: Bundle

    init(
        defaults: UserDefaults = .standard,
        defaultsDomain: String = Bundle.main.bundleIdentifier ?? "com.leise.mac",
        historyService: HistoryService,
        dictionaryService: DictionaryService,
        profileService: ProfileService,
        usageStatisticsService: UsageStatisticsService,
        bundle: Bundle = .main
    ) {
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
        self.historyService = historyService
        self.dictionaryService = dictionaryService
        self.profileService = profileService
        self.usageStatisticsService = usageStatisticsService
        self.bundle = bundle
    }

    func exportBackup(to url: URL) throws -> UserDataBackupSummary {
        let backup = try makeBackup()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backup).write(to: url, options: .atomic)
        return summary(for: backup)
    }

    func inspectBackup(at url: URL) throws -> UserDataBackupSummary {
        summary(for: try readBackup(from: url))
    }

    func importBackup(from url: URL) throws -> UserDataBackupSummary {
        let incoming = try readBackup(from: url)
        let previous = try makeBackup()

        do {
            try apply(incoming)
        } catch {
            // Each store operation is atomic. If a later store fails, restore the
            // complete pre-import snapshot so the user is never left half-imported.
            try? apply(previous)
            throw UserDataBackupError.restoreFailed(error)
        }
        return summary(for: incoming)
    }

    func makeBackup() throws -> LeiseUserDataBackup {
        let domain = defaults.persistentDomain(forName: defaultsDomain) ?? [:]
        var preferences: [String: BackupPreferenceValue] = [:]
        for (key, value) in domain {
            guard let converted = BackupPreferenceValue(propertyListValue: value) else {
                throw UserDataBackupError.unsupportedPreference(key)
            }
            preferences[key] = converted
        }

        return LeiseUserDataBackup(
            format: LeiseUserDataBackup.formatIdentifier,
            schemaVersion: LeiseUserDataBackup.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            preferences: preferences,
            dictionaryEntries: dictionaryService.entries.map(BackupDictionaryEntry.init),
            profiles: profileService.profiles.map(BackupProfile.init),
            history: historyService.records.map(BackupHistoryRecord.init)
        )
    }

    private func readBackup(from url: URL) throws -> LeiseUserDataBackup {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile == true else {
            throw UserDataBackupError.invalidData("the selected item is not a file")
        }
        guard (resourceValues.fileSize ?? 0) <= Self.maximumBackupSize else {
            throw UserDataBackupError.fileTooLarge
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LeiseUserDataBackup.self, from: Data(contentsOf: url))
        try validate(backup)
        return backup
    }

    private func validate(_ backup: LeiseUserDataBackup) throws {
        guard backup.format == LeiseUserDataBackup.formatIdentifier else {
            throw UserDataBackupError.unsupportedFormat
        }
        guard backup.schemaVersion == LeiseUserDataBackup.currentSchemaVersion else {
            throw UserDataBackupError.unsupportedVersion(backup.schemaVersion)
        }
        try validateUniqueIDs(backup.dictionaryEntries.map(\.id), label: "dictionary entries")
        try validateUniqueIDs(backup.profiles.map(\.id), label: "profiles")
        try validateUniqueIDs(backup.history.map(\.id), label: "history records")

        for entry in backup.dictionaryEntries {
            guard !entry.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UserDataBackupError.invalidData("a dictionary entry has no original text")
            }
            guard entry.usageCount >= 0 else {
                throw UserDataBackupError.invalidData("a dictionary entry has a negative usage count")
            }
            if let threshold = entry.ctcMinSimilarity,
               !threshold.isFinite || threshold < 0 || threshold > 1 {
                throw UserDataBackupError.invalidData("a dictionary similarity threshold is outside 0...1")
            }
        }

        for profile in backup.profiles {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UserDataBackupError.invalidData("a profile has no name")
            }
            if let hotkeyData = profile.hotkeyData {
                guard (try? JSONDecoder().decode(UnifiedHotkey.self, from: hotkeyData)) != nil else {
                    throw UserDataBackupError.invalidData("profile ‘\(profile.name)’ has invalid hotkey data")
                }
            }
        }

        for record in backup.history {
            guard !record.rawText.isEmpty, !record.finalText.isEmpty else {
                throw UserDataBackupError.invalidData("a history record has empty text")
            }
            guard record.durationSeconds.isFinite, record.durationSeconds >= 0 else {
                throw UserDataBackupError.invalidData("a history record has an invalid duration")
            }
            guard !record.engineUsed.isEmpty, record.wordsCount >= 0 else {
                throw UserDataBackupError.invalidData("a history record has invalid metadata")
            }
            if let fileName = record.audioFileName,
               fileName.isEmpty || fileName != URL(fileURLWithPath: fileName).lastPathComponent || fileName.contains("\\") {
                throw UserDataBackupError.invalidData("a history record has an unsafe audio filename")
            }
        }
    }

    private func validateUniqueIDs(_ ids: [UUID], label: String) throws {
        guard Set(ids).count == ids.count else {
            throw UserDataBackupError.invalidData("duplicate IDs were found in \(label)")
        }
    }

    private func apply(_ backup: LeiseUserDataBackup) throws {
        try dictionaryService.replaceAll(with: backup.dictionaryEntries)
        try profileService.replaceAll(with: backup.profiles)
        try historyService.replaceAll(with: backup.history)
        try usageStatisticsService.rebuildFromHistory(historyService.records)
        defaults.setPersistentDomain(
            backup.preferences.mapValues(\.propertyListValue),
            forName: defaultsDomain
        )
        defaults.synchronize()
    }

    private func summary(for backup: LeiseUserDataBackup) -> UserDataBackupSummary {
        UserDataBackupSummary(
            preferenceCount: backup.preferences.count,
            dictionaryEntryCount: backup.dictionaryEntries.count,
            profileCount: backup.profiles.count,
            historyRecordCount: backup.history.count
        )
    }
}
