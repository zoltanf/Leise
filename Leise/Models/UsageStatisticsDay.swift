import Foundation
import SwiftData

struct UsageCategoryAggregate: Codable, Equatable, Sendable {
    var label: String
    var transcriptionCount: Int
    var words: Int
    var durationSeconds: Double

    init(
        label: String,
        transcriptionCount: Int = 0,
        words: Int = 0,
        durationSeconds: Double = 0
    ) {
        self.label = label
        self.transcriptionCount = transcriptionCount
        self.words = words
        self.durationSeconds = durationSeconds
    }

    mutating func add(words: Int, durationSeconds: Double) {
        transcriptionCount += 1
        self.words += words
        self.durationSeconds += durationSeconds
    }

    mutating func merge(_ other: UsageCategoryAggregate) {
        if label.isEmpty { label = other.label }
        transcriptionCount += other.transcriptionCount
        words += other.words
        durationSeconds += other.durationSeconds
    }
}

struct UsageCorrectionAggregate: Codable, Equatable, Sendable {
    var original: String
    var replacement: String
    var count: Int
}

@Model
final class UsageStatisticsDay {
    @Attribute(.unique)
    var day: Date
    var transcriptionCount: Int
    var totalWords: Int
    var totalDurationSeconds: Double
    var appBundleIdentifiersJSON: String?
    var appUsageJSON: String?
    var domainUsageJSON: String?
    var languageUsageJSON: String?
    var engineUsageJSON: String?
    var pipelineStepUsageJSON: String?
    var hourlyUsageJSON: String?
    var durationBucketUsageJSON: String?
    var correctionUsageJSON: String?
    var postProcessedCount: Int = 0
    var changedWordCount: Int = 0
    var manualCorrectionCount: Int = 0
    var correctedDictationCount: Int = 0
    var manuallyChangedWordCount: Int = 0
    var dictionaryCorrectionDictationCount: Int = 0

    init(
        day: Date,
        transcriptionCount: Int = 0,
        totalWords: Int = 0,
        totalDurationSeconds: Double = 0,
        appBundleIdentifiers: Set<String> = []
    ) {
        self.day = day
        self.transcriptionCount = transcriptionCount
        self.totalWords = totalWords
        self.totalDurationSeconds = totalDurationSeconds
        self.appBundleIdentifiersJSON = Self.encode(appBundleIdentifiers)
    }

    var appBundleIdentifiers: Set<String> {
        get { Self.decode(appBundleIdentifiersJSON) }
        set { appBundleIdentifiersJSON = Self.encode(newValue) }
    }

    var appUsage: [String: UsageCategoryAggregate] {
        get { Self.decodeDictionary(appUsageJSON) }
        set { appUsageJSON = Self.encodeDictionary(newValue) }
    }

    var domainUsage: [String: UsageCategoryAggregate] {
        get { Self.decodeDictionary(domainUsageJSON) }
        set { domainUsageJSON = Self.encodeDictionary(newValue) }
    }

    var languageUsage: [String: UsageCategoryAggregate] {
        get { Self.decodeDictionary(languageUsageJSON) }
        set { languageUsageJSON = Self.encodeDictionary(newValue) }
    }

    var engineUsage: [String: UsageCategoryAggregate] {
        get { Self.decodeDictionary(engineUsageJSON) }
        set { engineUsageJSON = Self.encodeDictionary(newValue) }
    }

    var pipelineStepUsage: [String: Int] {
        get { Self.decodeDictionary(pipelineStepUsageJSON) }
        set { pipelineStepUsageJSON = Self.encodeDictionary(newValue) }
    }

    var hourlyUsage: [String: Int] {
        get { Self.decodeDictionary(hourlyUsageJSON) }
        set { hourlyUsageJSON = Self.encodeDictionary(newValue) }
    }

    var durationBucketUsage: [String: Int] {
        get { Self.decodeDictionary(durationBucketUsageJSON) }
        set { durationBucketUsageJSON = Self.encodeDictionary(newValue) }
    }

    var correctionUsage: [String: UsageCorrectionAggregate] {
        get { Self.decodeDictionary(correctionUsageJSON) }
        set { correctionUsageJSON = Self.encodeDictionary(newValue) }
    }

    func add(wordsCount: Int, durationSeconds: Double, appBundleIdentifier: String?) {
        transcriptionCount += 1
        totalWords += wordsCount
        totalDurationSeconds += durationSeconds

        guard let appBundleIdentifier = appBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appBundleIdentifier.isEmpty else {
            return
        }
        var identifiers = appBundleIdentifiers
        identifiers.insert(appBundleIdentifier)
        appBundleIdentifiers = identifiers
    }

    private static func encode(_ identifiers: Set<String>) -> String? {
        let values = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func decode(_ value: String?) -> Set<String> {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private static func encodeDictionary<Value: Encodable>(_ value: [String: Value]) -> String? {
        guard !value.isEmpty,
              let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func decodeDictionary<Value: Decodable>(_ value: String?) -> [String: Value] {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Value].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
