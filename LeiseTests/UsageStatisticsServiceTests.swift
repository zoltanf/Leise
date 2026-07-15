import XCTest
@testable import Leise

final class UsageStatisticsServiceTests: XCTestCase {
    @MainActor
    func testRecordsDailyAggregatesAndSummaries() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatistics")
        defer { TestSupport.remove(directory) }

        let calendar = Self.utcCalendar()
        let service = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        let today = Self.date(year: 2026, month: 7, day: 5, hour: 12, calendar: calendar)
        let yesterday = Self.date(year: 2026, month: 7, day: 4, hour: 9, calendar: calendar)

        service.recordTranscription(timestamp: today, wordsCount: 90, durationSeconds: 60, appBundleIdentifier: "com.example.editor")
        service.recordTranscription(timestamp: today, wordsCount: 45, durationSeconds: 60, appBundleIdentifier: "com.example.editor")
        service.recordTranscription(timestamp: yesterday, wordsCount: 45, durationSeconds: 30, appBundleIdentifier: "com.example.mail")

        let summary = service.summary(from: nil, to: today)
        XCTAssertEqual(summary.transcriptionCount, 3)
        XCTAssertEqual(summary.words, 180)
        XCTAssertEqual(summary.durationSeconds, 150, accuracy: 0.001)
        XCTAssertEqual(summary.appCount, 2)
        XCTAssertEqual(summary.rawWPM, 72, accuracy: 0.001)
        XCTAssertEqual(summary.rawSavedMinutes, 1.5, accuracy: 0.001)

        let daily = service.dailyWordCounts(days: 2, endingAt: today)
        XCTAssertEqual(daily.map(\.totalWords), [45, 135])
    }

    @MainActor
    func testRecordsRichApplicationQualityAndHabitAggregates() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsRich")
        defer { TestSupport.remove(directory) }

        let calendar = Self.utcCalendar()
        let service = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        let timestamp = Self.date(year: 2026, month: 7, day: 5, hour: 14, calendar: calendar)

        service.recordTranscription(
            timestamp: timestamp,
            wordsCount: 4,
            durationSeconds: 18,
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari",
            appDomain: "www.example.com",
            language: "en",
            engine: "parakeet",
            model: "TDT v3",
            rawText: "schedule at six PM",
            processedText: "schedule at 6 PM",
            pipelineSteps: ["Number Normalization", "Corrections"]
        )
        service.recordManualCorrection(
            timestamp: timestamp,
            isFirstCorrectionForDictation: true,
            changedWordCount: 1,
            suggestions: [CorrectionSuggestion(original: "teh", replacement: "the")]
        )

        let summary = service.summary(from: nil, to: timestamp)
        XCTAssertEqual(summary.appUsage["com.apple.Safari"]?.label, "Safari")
        XCTAssertEqual(summary.appUsage["com.apple.Safari"]?.transcriptionCount, 1)
        XCTAssertEqual(summary.domainUsage["example.com"]?.transcriptionCount, 1)
        XCTAssertEqual(summary.languageUsage["en"]?.transcriptionCount, 1)
        XCTAssertEqual(summary.engineUsage["parakeet::tdt v3"]?.label, "TDT v3")
        XCTAssertEqual(summary.pipelineStepUsage["Number Normalization"], 1)
        XCTAssertEqual(summary.hourlyUsage["14"], 1)
        XCTAssertEqual(summary.durationBucketUsage["10to30"], 1)
        XCTAssertEqual(summary.postProcessedCount, 1)
        XCTAssertEqual(summary.changedWordCount, 1)
        XCTAssertEqual(summary.dictionaryCorrectionDictationCount, 1)
        XCTAssertEqual(summary.manualCorrectionCount, 1)
        XCTAssertEqual(summary.correctedDictationCount, 1)
        XCTAssertEqual(summary.manuallyChangedWordCount, 1)
        XCTAssertEqual(summary.correctionUsage.values.first?.original, "teh")
        XCTAssertEqual(summary.correctionUsage.values.first?.replacement, "the")
    }

    @MainActor
    func testHistoryBackfillIsIdempotentAndClearDoesNotRebackfill() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsBackfill")
        defer { TestSupport.remove(directory) }

        let historyService = HistoryService(appSupportDirectory: directory)
        historyService.clearAll()
        historyService.addRecord(
            rawText: "Alpha beta gamma",
            finalText: "Alpha beta gamma",
            appName: "Editor",
            appBundleIdentifier: "com.example.editor",
            durationSeconds: 30,
            language: "en",
            engineUsed: "parakeet"
        )
        historyService.addRecord(
            rawText: "Delta epsilon",
            finalText: "Delta epsilon",
            appName: "Mail",
            appBundleIdentifier: "com.example.mail",
            durationSeconds: 20,
            language: "en",
            engineUsed: "parakeet"
        )

        let service = UsageStatisticsService(appSupportDirectory: directory)
        service.backfillFromHistoryIfNeeded(historyService.records)
        service.backfillFromHistoryIfNeeded(historyService.records)

        var summary = service.summary(from: nil)
        XCTAssertEqual(summary.transcriptionCount, 2)
        XCTAssertEqual(summary.words, 5)
        XCTAssertEqual(summary.appCount, 2)
        XCTAssertEqual(summary.appUsage["com.example.editor"]?.label, "Editor")
        XCTAssertEqual(summary.languageUsage["en"]?.transcriptionCount, 2)

        service.clearUsageStatistics()
        service.backfillFromHistoryIfNeeded(historyService.records)

        summary = service.summary(from: nil)
        XCTAssertEqual(summary.transcriptionCount, 0)
        XCTAssertEqual(summary.words, 0)
    }

    @MainActor
    func testHomeUsesUsageStatisticsWhileKeepingRecentHistory() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsDashboard")
        defer { TestSupport.remove(directory) }

        let calendar = Calendar.current
        let now = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date()))!
        let historyService = HistoryService(appSupportDirectory: directory)
        historyService.clearAll()
        historyService.addRecord(
            rawText: "Retained history only",
            finalText: "Retained history only",
            appName: "Notes",
            appBundleIdentifier: "com.example.notes",
            durationSeconds: 10,
            language: "en",
            engineUsed: "parakeet"
        )

        let usageStatisticsService = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        usageStatisticsService.recordTranscription(
            timestamp: now,
            wordsCount: 120,
            durationSeconds: 60,
            appBundleIdentifier: "com.example.aggregate"
        )

        let homeViewModel = HomeViewModel(
            historyService: historyService,
            usageStatisticsService: usageStatisticsService
        )
        homeViewModel.selectedTimePeriod = .week
        homeViewModel.refresh()

        XCTAssertTrue(homeViewModel.hasAnyTranscriptions)
        XCTAssertEqual(homeViewModel.wordsCount, 120)
        XCTAssertEqual(homeViewModel.averageWPM, "120")
        XCTAssertEqual(homeViewModel.appsUsed, 1)
        XCTAssertEqual(homeViewModel.recentTranscriptions.count, 1)
        XCTAssertEqual(homeViewModel.recentTranscriptions.first?.finalText, "Retained history only")
        XCTAssertEqual(homeViewModel.habitHeatmap.count, 42)
        XCTAssertEqual(Set(homeViewModel.habitHeatmap.map(\.weekdayKey)).count, 7)
    }

    @MainActor
    func testHistoryEditsPersistAndAggregateManualCorrections() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsCorrections")
        defer { TestSupport.remove(directory) }

        let historyService = HistoryService(appSupportDirectory: directory)
        historyService.addRecord(
            rawText: "please use teh word",
            finalText: "please use teh word",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 4,
            language: "en",
            engineUsed: "parakeet"
        )
        let usageService = UsageStatisticsService(appSupportDirectory: directory)
        usageService.backfillFromHistoryIfNeeded(historyService.records)
        let dictionaryService = DictionaryService(appSupportDirectory: directory)
        let viewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            usageStatisticsService: usageService
        )
        let record = try XCTUnwrap(historyService.records.first)
        viewModel.selectedRecordIDs = [record.id]
        viewModel.startEditing()
        viewModel.editedText = "please use the word"
        viewModel.saveEditing()

        XCTAssertEqual(record.initialFinalText, "please use teh word")
        XCTAssertEqual(record.finalText, "please use the word")
        XCTAssertEqual(record.manualEditCount, 1)
        XCTAssertEqual(record.manualChangedWordCount, 1)
        XCTAssertNotNil(record.lastManuallyEditedAt)
        XCTAssertEqual(usageService.summary(from: nil).manualCorrectionCount, 1)
        XCTAssertEqual(usageService.summary(from: nil).correctedDictationCount, 1)
        XCTAssertEqual(dictionaryService.corrections.first?.original, "teh")
        XCTAssertEqual(dictionaryService.corrections.first?.replacement, "the")
    }

    @MainActor
    func testAllTimeDashboardUsesAdaptiveMonthlyRollupsForLongHistory() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "UsageStatisticsRollups")
        defer { TestSupport.remove(directory) }

        let calendar = Self.utcCalendar()
        let now = Self.date(year: 2026, month: 7, day: 5, hour: 12, calendar: calendar)
        let old = calendar.date(byAdding: .day, value: -800, to: now)!
        let historyService = HistoryService(appSupportDirectory: directory)
        let usageService = UsageStatisticsService(appSupportDirectory: directory, calendar: calendar)
        usageService.recordTranscription(
            timestamp: old,
            wordsCount: 20,
            durationSeconds: 10,
            appBundleIdentifier: "com.example.old"
        )
        usageService.recordTranscription(
            timestamp: now,
            wordsCount: 30,
            durationSeconds: 15,
            appBundleIdentifier: "com.example.new"
        )

        let viewModel = HomeViewModel(
            historyService: historyService,
            usageStatisticsService: usageService
        )
        viewModel.selectedTimePeriod = .allTime
        viewModel.refresh(now: now)

        XCTAssertEqual(viewModel.chartGranularity, .month)
        XCTAssertEqual(viewModel.chartData.count, 2)
        XCTAssertEqual(viewModel.chartData.reduce(0) { $0 + $1.wordCount }, 50)
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        calendar: Calendar
    ) -> Date {
        DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ).date!
    }
}
