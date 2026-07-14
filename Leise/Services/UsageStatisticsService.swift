import Combine
import Foundation
import SwiftData
import os.log

private let usageStatisticsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Leise",
    category: "UsageStatisticsService"
)

struct UsageTranscriptionSample: Sendable {
    let timestamp: Date
    let wordsCount: Int
    let durationSeconds: Double
    let appName: String?
    let appBundleIdentifier: String?
    let appDomain: String?
    let language: String?
    let engine: String?
    let model: String?
    let rawText: String?
    let processedText: String?
    let pipelineSteps: [String]
    let manualEditCount: Int
    let manualChangedWordCount: Int
    let manualCorrections: [UsageCorrectionAggregate]
}

@MainActor
protocol UsageStatisticsRecording: AnyObject {
    func recordTranscription(_ sample: UsageTranscriptionSample)
}

extension UsageStatisticsRecording {
    func recordTranscription(
        timestamp: Date = Date(),
        wordsCount: Int,
        durationSeconds: Double,
        appName: String? = nil,
        appBundleIdentifier: String?,
        appDomain: String? = nil,
        language: String? = nil,
        engine: String? = nil,
        model: String? = nil,
        rawText: String? = nil,
        processedText: String? = nil,
        pipelineSteps: [String] = []
    ) {
        recordTranscription(UsageTranscriptionSample(
            timestamp: timestamp,
            wordsCount: wordsCount,
            durationSeconds: durationSeconds,
            appName: appName,
            appBundleIdentifier: appBundleIdentifier,
            appDomain: appDomain,
            language: language,
            engine: engine,
            model: model,
            rawText: rawText,
            processedText: processedText,
            pipelineSteps: pipelineSteps,
            manualEditCount: 0,
            manualChangedWordCount: 0,
            manualCorrections: []
        ))
    }
}

struct UsageStatisticsDaySnapshot: Equatable, Sendable {
    let day: Date
    let transcriptionCount: Int
    let totalWords: Int
    let totalDurationSeconds: Double
    let appBundleIdentifiers: Set<String>
    let appUsage: [String: UsageCategoryAggregate]
    let domainUsage: [String: UsageCategoryAggregate]
    let languageUsage: [String: UsageCategoryAggregate]
    let engineUsage: [String: UsageCategoryAggregate]
    let pipelineStepUsage: [String: Int]
    let hourlyUsage: [String: Int]
    let durationBucketUsage: [String: Int]
    let correctionUsage: [String: UsageCorrectionAggregate]
    let postProcessedCount: Int
    let changedWordCount: Int
    let manualCorrectionCount: Int
    let correctedDictationCount: Int
    let manuallyChangedWordCount: Int
    let dictionaryCorrectionDictationCount: Int

    static func empty(day: Date) -> UsageStatisticsDaySnapshot {
        UsageStatisticsDaySnapshot(
            day: day,
            transcriptionCount: 0,
            totalWords: 0,
            totalDurationSeconds: 0,
            appBundleIdentifiers: [],
            appUsage: [:],
            domainUsage: [:],
            languageUsage: [:],
            engineUsage: [:],
            pipelineStepUsage: [:],
            hourlyUsage: [:],
            durationBucketUsage: [:],
            correctionUsage: [:],
            postProcessedCount: 0,
            changedWordCount: 0,
            manualCorrectionCount: 0,
            correctedDictationCount: 0,
            manuallyChangedWordCount: 0,
            dictionaryCorrectionDictationCount: 0
        )
    }
}

struct UsageStatisticsSummary: Equatable {
    let transcriptionCount: Int
    let words: Int
    let durationSeconds: Double
    let appBundleIdentifiers: Set<String>
    let appUsage: [String: UsageCategoryAggregate]
    let domainUsage: [String: UsageCategoryAggregate]
    let languageUsage: [String: UsageCategoryAggregate]
    let engineUsage: [String: UsageCategoryAggregate]
    let pipelineStepUsage: [String: Int]
    let hourlyUsage: [String: Int]
    let durationBucketUsage: [String: Int]
    let correctionUsage: [String: UsageCorrectionAggregate]
    let postProcessedCount: Int
    let changedWordCount: Int
    let manualCorrectionCount: Int
    let correctedDictationCount: Int
    let manuallyChangedWordCount: Int
    let dictionaryCorrectionDictationCount: Int

    static let empty = UsageStatisticsSummary(
        transcriptionCount: 0,
        words: 0,
        durationSeconds: 0,
        appBundleIdentifiers: [],
        appUsage: [:],
        domainUsage: [:],
        languageUsage: [:],
        engineUsage: [:],
        pipelineStepUsage: [:],
        hourlyUsage: [:],
        durationBucketUsage: [:],
        correctionUsage: [:],
        postProcessedCount: 0,
        changedWordCount: 0,
        manualCorrectionCount: 0,
        correctedDictationCount: 0,
        manuallyChangedWordCount: 0,
        dictionaryCorrectionDictationCount: 0
    )

    var rawWPM: Double {
        let minutes = durationSeconds / 60.0
        guard minutes > 0, words > 0 else { return 0 }
        return Double(words) / minutes
    }

    var rawSavedMinutes: Double {
        Double(words) / 45.0 - (durationSeconds / 60.0)
    }

    var appCount: Int { appBundleIdentifiers.count }
}

@MainActor
final class UsageStatisticsService: ObservableObject, UsageStatisticsRecording {
    @Published private(set) var days: [UsageStatisticsDaySnapshot] = []

    private static let historyBackfillCompletedKey = "historyBackfillCompleted"
    private static let historyDetailBackfillCompletedKey = "historyDetailBackfillCompletedV2"

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private var calendar: Calendar

    init(
        appSupportDirectory: URL = AppConstants.appSupportDirectory,
        calendar: Calendar = .current
    ) {
        self.calendar = calendar

        do {
            let (container, context) = try SwiftDataStoreFactory.create(
                for: [UsageStatisticsDay.self, UsageStatisticsMetadata.self],
                storeName: "usage-statistics",
                in: appSupportDirectory
            )
            modelContainer = container
            modelContext = context
        } catch {
            fatalError("Failed to initialize usage statistics store: \(error)")
        }

        fetchDays()
    }

    var hasAnyStatistics: Bool {
        days.contains {
            $0.transcriptionCount > 0 || $0.totalWords > 0 || $0.totalDurationSeconds > 0
                || $0.manualCorrectionCount > 0
        }
    }

    /// The detail migration enriches retained history without duplicating the
    /// existing all-time word and duration aggregates.
    var needsHistoryBackfill: Bool {
        !historyBackfillCompleted || !historyDetailBackfillCompleted
    }

    func recordTranscription(_ sample: UsageTranscriptionSample) {
        guard sample.wordsCount > 0 else {
            usageStatisticsLogger.warning("Skipping usage statistics entry: empty word count")
            return
        }
        guard sample.durationSeconds.isFinite, sample.durationSeconds >= 0 else {
            usageStatisticsLogger.warning("Skipping usage statistics entry: invalid duration \(sample.durationSeconds)")
            return
        }

        do {
            let statisticsDay = try statisticsDay(for: sample.timestamp)
            apply(sample, to: statisticsDay, includeTotals: true, includeDetails: true)
            save()
            fetchDays()
        } catch {
            usageStatisticsLogger.error("Failed to record usage statistics: \(error.localizedDescription)")
        }
    }

    func recordManualCorrection(
        timestamp: Date,
        isFirstCorrectionForDictation: Bool,
        changedWordCount: Int,
        suggestions: [CorrectionSuggestion]
    ) {
        do {
            let statisticsDay = try statisticsDay(for: timestamp)
            statisticsDay.manualCorrectionCount += 1
            if isFirstCorrectionForDictation {
                statisticsDay.correctedDictationCount += 1
            }
            statisticsDay.manuallyChangedWordCount += max(changedWordCount, 0)

            var corrections = statisticsDay.correctionUsage
            for suggestion in suggestions {
                let original = suggestion.original.trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = suggestion.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !original.isEmpty, !replacement.isEmpty else { continue }
                let key = "\(original.lowercased())\u{1F}\(replacement.lowercased())"
                var aggregate = corrections[key] ?? UsageCorrectionAggregate(
                    original: original,
                    replacement: replacement,
                    count: 0
                )
                aggregate.count += 1
                corrections[key] = aggregate
            }
            statisticsDay.correctionUsage = corrections
            save()
            fetchDays()
        } catch {
            usageStatisticsLogger.error("Failed to record manual correction: \(error.localizedDescription)")
        }
    }

    func backfillFromHistoryIfNeeded(_ records: [TranscriptionRecord]) {
        guard needsHistoryBackfill else { return }
        let includeTotals = !historyBackfillCompleted
        let includeDetails = !historyDetailBackfillCompleted

        do {
            for record in records {
                guard let sample = Self.sample(from: record) else { continue }
                let statisticsDay = try statisticsDay(for: sample.timestamp)
                apply(sample, to: statisticsDay, includeTotals: includeTotals, includeDetails: includeDetails)
            }
            try setHistoryBackfillCompleted(true)
            try setHistoryDetailBackfillCompleted(true)
            save()
            fetchDays()
        } catch {
            usageStatisticsLogger.error("Failed to backfill usage statistics: \(error.localizedDescription)")
        }
    }

    func backfillFromHistoryIfNeededInBatches(
        _ records: [TranscriptionRecord],
        batchSize: Int = 250
    ) async {
        guard needsHistoryBackfill else { return }
        let includeTotals = !historyBackfillCompleted
        let includeDetails = !historyDetailBackfillCompleted
        let samples = records.compactMap(Self.sample(from:))
        let calendar = calendar
        let boundedBatchSize = max(batchSize, 1)

        let groupedSamples = await Task.detached(priority: .utility) {
            var result: [Date: [UsageTranscriptionSample]] = [:]
            for start in stride(from: 0, to: samples.count, by: boundedBatchSize) {
                guard !Task.isCancelled else { return [Date: [UsageTranscriptionSample]]() }
                let end = min(start + boundedBatchSize, samples.count)
                for sample in samples[start..<end] {
                    result[calendar.startOfDay(for: sample.timestamp), default: []].append(sample)
                }
            }
            return result
        }.value

        guard !Task.isCancelled else { return }

        do {
            for (day, samples) in groupedSamples {
                let statisticsDay = try statisticsDay(for: day)
                for sample in samples {
                    apply(sample, to: statisticsDay, includeTotals: includeTotals, includeDetails: includeDetails)
                }
            }
            try setHistoryBackfillCompleted(true)
            try setHistoryDetailBackfillCompleted(true)
            try modelContext.save()
            fetchDays()
        } catch {
            modelContext.rollback()
            usageStatisticsLogger.error("Failed to backfill usage statistics: \(error.localizedDescription)")
        }
    }

    func summary(from start: Date?, to end: Date = Date()) -> UsageStatisticsSummary {
        let startDay = start.map { calendar.startOfDay(for: $0) }
        let endDay = calendar.startOfDay(for: end)
        return summarize(days.filter { snapshot in
            if let startDay, snapshot.day < startDay { return false }
            return snapshot.day <= endDay
        })
    }

    func summary(startDay: Date, endDayExclusive: Date) -> UsageStatisticsSummary {
        summarize(snapshots(startDay: startDay, endDayExclusive: endDayExclusive))
    }

    func snapshots(startDay: Date, endDayExclusive: Date) -> [UsageStatisticsDaySnapshot] {
        let normalizedStart = calendar.startOfDay(for: startDay)
        return days.filter { $0.day >= normalizedStart && $0.day < endDayExclusive }
    }

    func dailyWordCounts(days count: Int?, endingAt now: Date = Date()) -> [UsageStatisticsDaySnapshot] {
        let today = calendar.startOfDay(for: now)
        let requestedDays: Int
        if let count {
            requestedDays = max(count, 1)
        } else if let oldest = days.map(\.day).min() {
            requestedDays = max(1, (calendar.dateComponents([.day], from: oldest, to: today).day ?? 0) + 1)
        } else {
            requestedDays = 30
        }

        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        return (0..<requestedDays).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return byDay[day] ?? .empty(day: day)
        }
    }

    func previousPeriodSummary(days count: Int, endingAt now: Date = Date()) -> UsageStatisticsSummary {
        let today = calendar.startOfDay(for: now)
        guard let currentStart = calendar.date(byAdding: .day, value: -(max(count, 1) - 1), to: today),
              let previousStart = calendar.date(byAdding: .day, value: -max(count, 1), to: currentStart) else {
            return .empty
        }
        return summary(startDay: previousStart, endDayExclusive: currentStart)
    }

    func clearUsageStatistics() {
        do {
            for day in try modelContext.fetch(FetchDescriptor<UsageStatisticsDay>()) {
                modelContext.delete(day)
            }
            try setHistoryBackfillCompleted(true)
            try setHistoryDetailBackfillCompleted(true)
            save()
            fetchDays()
        } catch {
            usageStatisticsLogger.error("Failed to clear usage statistics: \(error.localizedDescription)")
        }
    }

    func rebuildFromHistory(_ records: [TranscriptionRecord]) throws {
        do {
            for day in try modelContext.fetch(FetchDescriptor<UsageStatisticsDay>()) {
                modelContext.delete(day)
            }

            for record in records {
                guard let sample = Self.sample(from: record) else { continue }
                let statisticsDay = try statisticsDay(for: sample.timestamp)
                apply(sample, to: statisticsDay, includeTotals: true, includeDetails: true)
            }

            try setHistoryBackfillCompleted(true)
            try setHistoryDetailBackfillCompleted(true)
            try modelContext.save()
            fetchDays()
        } catch {
            modelContext.rollback()
            fetchDays()
            throw error
        }
    }

    #if DEBUG
    func replaceWithHistoryRecords(_ records: [TranscriptionRecord]) {
        do {
            try rebuildFromHistory(records)
        } catch {
            usageStatisticsLogger.error("Failed to rebuild usage statistics: \(error.localizedDescription)")
        }
    }
    #endif

    nonisolated static func changedWordCount(original: String, edited: String) -> Int {
        let originalWords = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let editedWords = edited.split(whereSeparator: \.isWhitespace).map(String.init)
        let difference = editedWords.difference(from: originalWords)
        var removals = 0
        var insertions = 0
        for change in difference {
            switch change {
            case .remove: removals += 1
            case .insert: insertions += 1
            }
        }
        return max(removals, insertions)
    }

    private static func sample(from record: TranscriptionRecord) -> UsageTranscriptionSample? {
        let wordsCount = record.wordsCount > 0
            ? record.wordsCount
            : record.finalText.split(separator: " ").count
        guard wordsCount > 0,
              record.durationSeconds.isFinite,
              record.durationSeconds >= 0 else {
            return nil
        }
        let manualCorrections: [UsageCorrectionAggregate]
        if record.manualEditCount > 0 {
            manualCorrections = TextDiffService().extractCorrections(
                original: record.initialFinalText ?? record.finalText,
                edited: record.finalText
            ).map {
                UsageCorrectionAggregate(original: $0.original, replacement: $0.replacement, count: 1)
            }
        } else {
            manualCorrections = []
        }

        return UsageTranscriptionSample(
            timestamp: record.timestamp,
            wordsCount: wordsCount,
            durationSeconds: record.durationSeconds,
            appName: record.appName,
            appBundleIdentifier: record.appBundleIdentifier,
            appDomain: record.appDomain,
            language: record.language,
            engine: record.engineUsed,
            model: record.modelUsed,
            rawText: record.rawText,
            processedText: record.initialFinalText ?? record.finalText,
            pipelineSteps: record.pipelineStepList,
            manualEditCount: record.manualEditCount,
            manualChangedWordCount: record.manualChangedWordCount,
            manualCorrections: manualCorrections
        )
    }

    private func apply(
        _ sample: UsageTranscriptionSample,
        to statisticsDay: UsageStatisticsDay,
        includeTotals: Bool,
        includeDetails: Bool
    ) {
        if includeTotals {
            statisticsDay.add(
                wordsCount: sample.wordsCount,
                durationSeconds: sample.durationSeconds,
                appBundleIdentifier: sample.appBundleIdentifier
            )
        }

        guard includeDetails else { return }

        if let bundleIdentifier = normalized(sample.appBundleIdentifier) {
            addCategory(
                key: bundleIdentifier,
                label: normalized(sample.appName) ?? bundleIdentifier,
                words: sample.wordsCount,
                durationSeconds: sample.durationSeconds,
                to: &statisticsDay.appUsage
            )
        }
        if let domain = normalizedDomain(sample.appDomain) {
            addCategory(
                key: domain.lowercased(),
                label: domain,
                words: sample.wordsCount,
                durationSeconds: sample.durationSeconds,
                to: &statisticsDay.domainUsage
            )
        }
        if let language = normalized(sample.language) {
            addCategory(
                key: language.lowercased(),
                label: language,
                words: sample.wordsCount,
                durationSeconds: sample.durationSeconds,
                to: &statisticsDay.languageUsage
            )
        }
        if let engine = normalized(sample.engine) {
            let model = normalized(sample.model)
            addCategory(
                key: "\(engine.lowercased())::\((model ?? "").lowercased())",
                label: model ?? engine,
                words: sample.wordsCount,
                durationSeconds: sample.durationSeconds,
                to: &statisticsDay.engineUsage
            )
        }

        var steps = statisticsDay.pipelineStepUsage
        for step in Set(sample.pipelineSteps.compactMap(normalized)) {
            steps[step, default: 0] += 1
        }
        statisticsDay.pipelineStepUsage = steps
        if sample.pipelineSteps.contains(where: { $0.caseInsensitiveCompare("Corrections") == .orderedSame }) {
            statisticsDay.dictionaryCorrectionDictationCount += 1
        }

        var hours = statisticsDay.hourlyUsage
        hours[String(calendar.component(.hour, from: sample.timestamp)), default: 0] += 1
        statisticsDay.hourlyUsage = hours

        var durations = statisticsDay.durationBucketUsage
        durations[Self.durationBucket(for: sample.durationSeconds), default: 0] += 1
        statisticsDay.durationBucketUsage = durations

        if let rawText = sample.rawText,
           let processedText = sample.processedText,
           rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            != processedText.trimmingCharacters(in: .whitespacesAndNewlines) {
            statisticsDay.postProcessedCount += 1
            statisticsDay.changedWordCount += Self.changedWordCount(original: rawText, edited: processedText)
        }

        if sample.manualEditCount > 0 {
            statisticsDay.manualCorrectionCount += sample.manualEditCount
            statisticsDay.correctedDictationCount += 1
            statisticsDay.manuallyChangedWordCount += sample.manualChangedWordCount

            var corrections = statisticsDay.correctionUsage
            for value in sample.manualCorrections {
                let key = "\(value.original.lowercased())\u{1F}\(value.replacement.lowercased())"
                var aggregate = corrections[key] ?? UsageCorrectionAggregate(
                    original: value.original,
                    replacement: value.replacement,
                    count: 0
                )
                aggregate.count += value.count
                corrections[key] = aggregate
            }
            statisticsDay.correctionUsage = corrections
        }
    }

    private func addCategory(
        key: String,
        label: String,
        words: Int,
        durationSeconds: Double,
        to dictionary: inout [String: UsageCategoryAggregate]
    ) {
        var aggregate = dictionary[key] ?? UsageCategoryAggregate(label: label)
        aggregate.label = label
        aggregate.add(words: words, durationSeconds: durationSeconds)
        dictionary[key] = aggregate
    }

    private func summarize(_ snapshots: [UsageStatisticsDaySnapshot]) -> UsageStatisticsSummary {
        snapshots.reduce(.empty) { partial, snapshot in
            UsageStatisticsSummary(
                transcriptionCount: partial.transcriptionCount + snapshot.transcriptionCount,
                words: partial.words + snapshot.totalWords,
                durationSeconds: partial.durationSeconds + snapshot.totalDurationSeconds,
                appBundleIdentifiers: partial.appBundleIdentifiers.union(snapshot.appBundleIdentifiers),
                appUsage: mergeCategories(partial.appUsage, snapshot.appUsage),
                domainUsage: mergeCategories(partial.domainUsage, snapshot.domainUsage),
                languageUsage: mergeCategories(partial.languageUsage, snapshot.languageUsage),
                engineUsage: mergeCategories(partial.engineUsage, snapshot.engineUsage),
                pipelineStepUsage: mergeCounts(partial.pipelineStepUsage, snapshot.pipelineStepUsage),
                hourlyUsage: mergeCounts(partial.hourlyUsage, snapshot.hourlyUsage),
                durationBucketUsage: mergeCounts(partial.durationBucketUsage, snapshot.durationBucketUsage),
                correctionUsage: mergeCorrections(partial.correctionUsage, snapshot.correctionUsage),
                postProcessedCount: partial.postProcessedCount + snapshot.postProcessedCount,
                changedWordCount: partial.changedWordCount + snapshot.changedWordCount,
                manualCorrectionCount: partial.manualCorrectionCount + snapshot.manualCorrectionCount,
                correctedDictationCount: partial.correctedDictationCount + snapshot.correctedDictationCount,
                manuallyChangedWordCount: partial.manuallyChangedWordCount + snapshot.manuallyChangedWordCount,
                dictionaryCorrectionDictationCount: partial.dictionaryCorrectionDictationCount
                    + snapshot.dictionaryCorrectionDictationCount
            )
        }
    }

    private func mergeCategories(
        _ lhs: [String: UsageCategoryAggregate],
        _ rhs: [String: UsageCategoryAggregate]
    ) -> [String: UsageCategoryAggregate] {
        var result = lhs
        for (key, value) in rhs {
            var aggregate = result[key] ?? UsageCategoryAggregate(label: value.label)
            aggregate.merge(value)
            result[key] = aggregate
        }
        return result
    }

    private func mergeCounts(_ lhs: [String: Int], _ rhs: [String: Int]) -> [String: Int] {
        var result = lhs
        for (key, value) in rhs { result[key, default: 0] += value }
        return result
    }

    private func mergeCorrections(
        _ lhs: [String: UsageCorrectionAggregate],
        _ rhs: [String: UsageCorrectionAggregate]
    ) -> [String: UsageCorrectionAggregate] {
        var result = lhs
        for (key, value) in rhs {
            var aggregate = result[key] ?? value
            if result[key] != nil { aggregate.count += value.count }
            result[key] = aggregate
        }
        return result
    }

    private static func durationBucket(for seconds: Double) -> String {
        switch seconds {
        case ..<10: "under10"
        case ..<30: "10to30"
        case ..<60: "30to60"
        case ..<120: "60to120"
        default: "over120"
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func normalizedDomain(_ value: String?) -> String? {
        guard var value = normalized(value) else { return nil }
        if value.lowercased().hasPrefix("www.") { value.removeFirst(4) }
        return value
    }

    private var historyBackfillCompleted: Bool {
        metadataFlag(for: Self.historyBackfillCompletedKey)
    }

    private var historyDetailBackfillCompleted: Bool {
        metadataFlag(for: Self.historyDetailBackfillCompletedKey)
    }

    private func metadataFlag(for key: String) -> Bool {
        do {
            return try metadataValue(for: key) == "true"
        } catch {
            usageStatisticsLogger.error("Failed to read usage statistics metadata: \(error.localizedDescription)")
            return true
        }
    }

    private func statisticsDay(for timestamp: Date) throws -> UsageStatisticsDay {
        let dayStart = calendar.startOfDay(for: timestamp)
        if let existingDay = try findDay(dayStart) { return existingDay }
        let day = UsageStatisticsDay(day: dayStart)
        modelContext.insert(day)
        return day
    }

    private func findDay(_ day: Date) throws -> UsageStatisticsDay? {
        let existing = try modelContext.fetch(FetchDescriptor<UsageStatisticsDay>())
        return existing.first { $0.day == day }
    }

    private func fetchDays() {
        let descriptor = FetchDescriptor<UsageStatisticsDay>(
            sortBy: [SortDescriptor(\.day, order: .reverse)]
        )
        do {
            days = try modelContext.fetch(descriptor).map {
                UsageStatisticsDaySnapshot(
                    day: $0.day,
                    transcriptionCount: $0.transcriptionCount,
                    totalWords: $0.totalWords,
                    totalDurationSeconds: $0.totalDurationSeconds,
                    appBundleIdentifiers: $0.appBundleIdentifiers,
                    appUsage: $0.appUsage,
                    domainUsage: $0.domainUsage,
                    languageUsage: $0.languageUsage,
                    engineUsage: $0.engineUsage,
                    pipelineStepUsage: $0.pipelineStepUsage,
                    hourlyUsage: $0.hourlyUsage,
                    durationBucketUsage: $0.durationBucketUsage,
                    correctionUsage: $0.correctionUsage,
                    postProcessedCount: $0.postProcessedCount,
                    changedWordCount: $0.changedWordCount,
                    manualCorrectionCount: $0.manualCorrectionCount,
                    correctedDictationCount: $0.correctedDictationCount,
                    manuallyChangedWordCount: $0.manuallyChangedWordCount,
                    dictionaryCorrectionDictationCount: $0.dictionaryCorrectionDictationCount
                )
            }
        } catch {
            usageStatisticsLogger.error("Failed to fetch usage statistics days: \(error.localizedDescription)")
            days = []
        }
    }

    private func metadataValue(for key: String) throws -> String? {
        let metadata = try modelContext.fetch(FetchDescriptor<UsageStatisticsMetadata>())
        return metadata.first { $0.key == key }?.value
    }

    private func setHistoryBackfillCompleted(_ completed: Bool) throws {
        try setMetadataFlag(completed, for: Self.historyBackfillCompletedKey)
    }

    private func setHistoryDetailBackfillCompleted(_ completed: Bool) throws {
        try setMetadataFlag(completed, for: Self.historyDetailBackfillCompletedKey)
    }

    private func setMetadataFlag(_ completed: Bool, for key: String) throws {
        let value = completed ? "true" : "false"
        if let existing = try modelContext.fetch(FetchDescriptor<UsageStatisticsMetadata>())
            .first(where: { $0.key == key }) {
            existing.value = value
        } else {
            modelContext.insert(UsageStatisticsMetadata(key: key, value: value))
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            usageStatisticsLogger.error("Save failed: \(error.localizedDescription)")
        }
    }
}
