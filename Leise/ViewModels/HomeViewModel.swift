import Combine
import Foundation

enum TimePeriod: String, CaseIterable {
    case week
    case month
    case allTime

    var displayName: String {
        switch self {
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        case .allTime: String(localized: "All Time")
        }
    }

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .allTime: nil
        }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case apps
    case quality

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .apps: String(localized: "Apps")
        case .quality: String(localized: "Quality")
        }
    }
}

enum AppUsageMetric: String, CaseIterable, Identifiable {
    case dictations
    case words
    case time

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .dictations: String(localized: "Dictations")
        case .words: String(localized: "Words")
        case .time: String(localized: "Time")
        }
    }
}

enum ActivityGranularity: Equatable {
    case day
    case week
    case month
}

struct ActivityDataPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let wordCount: Int
    let transcriptionCount: Int
    let postProcessedCount: Int
    let manualCorrectionCount: Int
}

struct RankedUsageItem: Identifiable, Equatable {
    let id: String
    let label: String
    let transcriptionCount: Int
    let words: Int
    let durationSeconds: Double

    func value(for metric: AppUsageMetric) -> Double {
        switch metric {
        case .dictations: Double(transcriptionCount)
        case .words: Double(words)
        case .time: durationSeconds / 60
        }
    }
}

struct RankedCountItem: Identifiable, Equatable {
    let id: String
    let label: String
    let count: Int
}

struct HabitHeatmapPoint: Identifiable {
    var id: String { "\(weekdayIndex)-\(hourBucket)" }
    var weekdayKey: String { String(weekdayIndex) }
    let weekdayIndex: Int
    let weekdayLabel: String
    let hourBucket: Int
    let hourLabel: String
    let count: Int
}

struct DurationBucketPoint: Identifiable {
    let id: String
    let label: String
    let order: Int
    let count: Int
}

struct CorrectionUsageItem: Identifiable {
    let id: String
    let original: String
    let replacement: String
    let count: Int
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var selectedTimePeriod: TimePeriod = .week
    @Published var selectedSection: DashboardSection = .overview
    @Published var selectedAppMetric: AppUsageMetric = .dictations
    @Published var wordsCount = 0
    @Published var dictationCount = 0
    @Published var averageWPM = "—"
    @Published var appsUsed = 0
    @Published var timeSaved = "—"
    @Published var chartData: [ActivityDataPoint] = []
    @Published var chartGranularity: ActivityGranularity = .day
    @Published var wordsTrend: Double?
    @Published var dictationsTrend: Double?
    @Published var wpmTrend: Double?
    @Published var appsTrend: Double?
    @Published var timeSavedTrend: Double?
    @Published var recentTranscriptions: [TranscriptionRecord] = []
    @Published var navigateToHistory = false
    @Published var pendingHistoryAppBundleIdentifier: String?
    @Published var pendingHistoryTimeRange: HistoryTimeRange = .all
    /// When set, History opens with this record selected (tapping a specific
    /// recent transcription should show that record, not an unfiltered list).
    @Published var pendingHistoryRecordID: UUID?
    @Published var hasAnyTranscriptions = false

    @Published var appUsage: [RankedUsageItem] = []
    @Published var domainUsage: [RankedUsageItem] = []
    @Published var topAppLabel = "—"
    @Published var topAppShare = "—"

    @Published var postProcessedCount = 0
    @Published var enhancementRate = "—"
    @Published var changedWordCount = 0
    @Published var manualCorrectionCount = 0
    @Published var correctedDictationCount = 0
    @Published var manuallyChangedWordCount = 0
    @Published var dictionaryCorrectionDictationCount = 0
    @Published var pipelineUsage: [RankedCountItem] = []
    @Published var languageUsage: [RankedUsageItem] = []
    @Published var engineUsage: [RankedUsageItem] = []
    @Published var correctionUsage: [CorrectionUsageItem] = []

    @Published var activeDays = 0
    @Published var currentStreak = 0
    @Published var averageDictationDuration = "—"
    @Published var averageWordsPerDictation = "—"
    @Published var habitHeatmap: [HabitHeatmapPoint] = []
    @Published var durationBuckets: [DurationBucketPoint] = []

    @Published var showSetupWizard: Bool {
        didSet { UserDefaults.standard.set(!showSetupWizard, forKey: UserDefaultsKeys.setupWizardCompleted) }
    }

    private let historyService: HistoryService
    private let usageStatisticsService: UsageStatisticsService
    private var cancellables = Set<AnyCancellable>()
    private var refreshWorkItem: DispatchWorkItem?

    init(historyService: HistoryService, usageStatisticsService: UsageStatisticsService) {
        self.historyService = historyService
        self.usageStatisticsService = usageStatisticsService
        self.showSetupWizard = !UserDefaults.standard.bool(forKey: UserDefaultsKeys.setupWizardCompleted)
        setupBindings()
        refresh()
    }

    private func setupBindings() {
        historyService.$records
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        usageStatisticsService.$days
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        $selectedTimePeriod
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func refresh(now: Date = Date()) {
        let allRecords = historyService.records
        hasAnyTranscriptions = usageStatisticsService.hasAnyStatistics || !allRecords.isEmpty

        let summary = currentSummary(now: now)
        let stats = computeStats(for: summary)
        wordsCount = stats.words
        dictationCount = summary.transcriptionCount
        averageWPM = stats.wpm
        appsUsed = stats.apps
        timeSaved = stats.timeSaved

        if let days = selectedTimePeriod.days {
            let previous = usageStatisticsService.previousPeriodSummary(days: days, endingAt: now)
            let previousStats = computeStats(for: previous)
            wordsTrend = Self.trendPercent(current: Double(stats.words), previous: Double(previousStats.words))
            dictationsTrend = Self.trendPercent(
                current: Double(summary.transcriptionCount),
                previous: Double(previous.transcriptionCount)
            )
            appsTrend = Self.trendPercent(current: Double(stats.apps), previous: Double(previousStats.apps))
            wpmTrend = Self.trendPercent(current: stats.rawWPM, previous: previousStats.rawWPM)
            timeSavedTrend = Self.trendPercent(
                current: stats.rawSavedMinutes,
                previous: previousStats.rawSavedMinutes
            )
        } else {
            wordsTrend = nil
            dictationsTrend = nil
            wpmTrend = nil
            appsTrend = nil
            timeSavedTrend = nil
        }

        let snapshots = currentSnapshots(now: now)
        chartGranularity = granularity(for: snapshots, now: now)
        chartData = buildChartData(snapshots: snapshots, granularity: chartGranularity)
        recentTranscriptions = Array(allRecords.prefix(3))

        appUsage = rankedUsage(summary.appUsage)
        domainUsage = rankedUsage(summary.domainUsage)
        languageUsage = rankedUsage(summary.languageUsage)
        engineUsage = rankedUsage(summary.engineUsage)
        if let top = appUsage.first, summary.transcriptionCount > 0 {
            let tied = appUsage.prefix { $0.transcriptionCount == top.transcriptionCount }
            topAppLabel = tied.map(\.label).joined(separator: " · ")
            topAppShare = "\(Int((Double(top.transcriptionCount) / Double(summary.transcriptionCount) * 100).rounded()))%"
        } else {
            topAppLabel = "—"
            topAppShare = "—"
        }

        postProcessedCount = summary.postProcessedCount
        enhancementRate = summary.transcriptionCount > 0
            ? "\(Int((Double(summary.postProcessedCount) / Double(summary.transcriptionCount) * 100).rounded()))%"
            : "—"
        changedWordCount = summary.changedWordCount
        manualCorrectionCount = summary.manualCorrectionCount
        correctedDictationCount = summary.correctedDictationCount
        manuallyChangedWordCount = summary.manuallyChangedWordCount
        dictionaryCorrectionDictationCount = summary.dictionaryCorrectionDictationCount
        pipelineUsage = summary.pipelineStepUsage
            .map { RankedCountItem(id: $0.key, label: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.label < $1.label : $0.count > $1.count }
        correctionUsage = summary.correctionUsage
            .map { CorrectionUsageItem(
                id: $0.key,
                original: $0.value.original,
                replacement: $0.value.replacement,
                count: $0.value.count
            ) }
            .sorted { $0.count == $1.count ? $0.original < $1.original : $0.count > $1.count }

        activeDays = snapshots.filter { $0.transcriptionCount > 0 }.count
        currentStreak = Self.streak(in: snapshots, endingAt: now, calendar: .current)
        averageDictationDuration = summary.transcriptionCount > 0
            ? Self.formatDuration(summary.durationSeconds / Double(summary.transcriptionCount))
            : "—"
        averageWordsPerDictation = summary.transcriptionCount > 0
            ? "\(Int((Double(summary.words) / Double(summary.transcriptionCount)).rounded()))"
            : "—"
        habitHeatmap = buildHeatmap(snapshots)
        durationBuckets = Self.durationBucketDefinitions.map { definition in
            DurationBucketPoint(
                id: definition.key,
                label: definition.label,
                order: definition.order,
                count: summary.durationBucketUsage[definition.key, default: 0]
            )
        }
    }

    func requestHistory(forAppBundleIdentifier bundleIdentifier: String) {
        pendingHistoryAppBundleIdentifier = bundleIdentifier
        pendingHistoryTimeRange = switch selectedTimePeriod {
        case .week: .sevenDays
        case .month: .thirtyDays
        case .allTime: .all
        }
        navigateToHistory = true
    }

    func clearPendingHistoryNavigation() {
        pendingHistoryAppBundleIdentifier = nil
        pendingHistoryTimeRange = .all
        pendingHistoryRecordID = nil
    }

    private struct PeriodStats {
        let words: Int
        let wpm: String
        let rawWPM: Double
        let apps: Int
        let timeSaved: String
        let rawSavedMinutes: Double
    }

    private func currentSummary(now: Date) -> UsageStatisticsSummary {
        guard let days = selectedTimePeriod.days else {
            return usageStatisticsService.summary(from: nil, to: now)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let endDay = calendar.date(byAdding: .day, value: 1, to: today) else {
            return .empty
        }
        return usageStatisticsService.summary(startDay: startDay, endDayExclusive: endDay)
    }

    private func currentSnapshots(now: Date) -> [UsageStatisticsDaySnapshot] {
        if let days = selectedTimePeriod.days {
            return usageStatisticsService.dailyWordCounts(days: days, endingAt: now)
        }
        return usageStatisticsService.days.filter { $0.day <= now }.sorted { $0.day < $1.day }
    }

    private func computeStats(for summary: UsageStatisticsSummary) -> PeriodStats {
        let rawWPM = summary.rawWPM
        let wpm = rawWPM > 0 ? "\(Int(rawWPM.rounded()))" : "—"
        let rawSavedMinutes = summary.rawSavedMinutes
        let timeSaved = rawSavedMinutes > 0 ? Self.formatMinutes(rawSavedMinutes) : "—"
        return PeriodStats(
            words: summary.words,
            wpm: wpm,
            rawWPM: rawWPM,
            apps: summary.appCount,
            timeSaved: timeSaved,
            rawSavedMinutes: rawSavedMinutes
        )
    }

    nonisolated static func trendPercent(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return ((current - previous) / previous) * 100
    }

    private func granularity(
        for snapshots: [UsageStatisticsDaySnapshot],
        now: Date
    ) -> ActivityGranularity {
        guard selectedTimePeriod == .allTime,
              let oldest = snapshots.map(\.day).min() else {
            return .day
        }
        let span = Calendar.current.dateComponents([.day], from: oldest, to: now).day ?? 0
        if span <= 90 { return .day }
        if span <= 730 { return .week }
        return .month
    }

    private func buildChartData(
        snapshots: [UsageStatisticsDaySnapshot],
        granularity: ActivityGranularity
    ) -> [ActivityDataPoint] {
        let calendar = Calendar.current
        var grouped: [Date: ActivityDataPoint] = [:]
        for snapshot in snapshots {
            let bucket: Date
            switch granularity {
            case .day:
                bucket = calendar.startOfDay(for: snapshot.day)
            case .week:
                bucket = calendar.dateInterval(of: .weekOfYear, for: snapshot.day)?.start ?? snapshot.day
            case .month:
                bucket = calendar.dateInterval(of: .month, for: snapshot.day)?.start ?? snapshot.day
            }
            let current = grouped[bucket] ?? ActivityDataPoint(
                date: bucket,
                wordCount: 0,
                transcriptionCount: 0,
                postProcessedCount: 0,
                manualCorrectionCount: 0
            )
            grouped[bucket] = ActivityDataPoint(
                date: bucket,
                wordCount: current.wordCount + snapshot.totalWords,
                transcriptionCount: current.transcriptionCount + snapshot.transcriptionCount,
                postProcessedCount: current.postProcessedCount + snapshot.postProcessedCount,
                manualCorrectionCount: current.manualCorrectionCount + snapshot.manualCorrectionCount
            )
        }
        return grouped.values.sorted { $0.date < $1.date }
    }

    private func rankedUsage(_ values: [String: UsageCategoryAggregate]) -> [RankedUsageItem] {
        values.map {
            RankedUsageItem(
                id: $0.key,
                label: $0.value.label,
                transcriptionCount: $0.value.transcriptionCount,
                words: $0.value.words,
                durationSeconds: $0.value.durationSeconds
            )
        }
        .sorted {
            if $0.transcriptionCount == $1.transcriptionCount { return $0.label < $1.label }
            return $0.transcriptionCount > $1.transcriptionCount
        }
    }

    private func buildHeatmap(_ snapshots: [UsageStatisticsDaySnapshot]) -> [HabitHeatmapPoint] {
        let calendar = Calendar.current
        let symbols = calendar.shortStandaloneWeekdaySymbols
        var counts: [String: Int] = [:]
        for snapshot in snapshots {
            let weekday = calendar.component(.weekday, from: snapshot.day)
            let mondayIndex = (weekday + 5) % 7
            for (hour, count) in snapshot.hourlyUsage {
                guard let hourValue = Int(hour) else { continue }
                let bucket = (hourValue / 4) * 4
                counts["\(mondayIndex)-\(bucket)", default: 0] += count
            }
        }

        return (0..<7).flatMap { weekdayIndex in
            (0..<6).map { bucketIndex in
                let hour = bucketIndex * 4
                let calendarWeekday = ((weekdayIndex + 1) % 7) + 1
                return HabitHeatmapPoint(
                    weekdayIndex: weekdayIndex,
                    weekdayLabel: symbols[calendarWeekday - 1],
                    hourBucket: hour,
                    hourLabel: String(format: "%02d", hour),
                    count: counts["\(weekdayIndex)-\(hour)", default: 0]
                )
            }
        }
    }

    private nonisolated static func streak(
        in snapshots: [UsageStatisticsDaySnapshot],
        endingAt now: Date,
        calendar: Calendar
    ) -> Int {
        let activeDays = Set(snapshots.filter { $0.transcriptionCount > 0 }.map { calendar.startOfDay(for: $0.day) })
        guard !activeDays.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var cursor = activeDays.contains(today) ? today : yesterday
        guard activeDays.contains(cursor) else { return 0 }
        var result = 0
        while activeDays.contains(cursor) {
            result += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return result
    }

    private static let durationBucketDefinitions: [(key: String, label: String, order: Int)] = [
        ("under10", "<10s", 0),
        ("10to30", "10–30s", 1),
        ("30to60", "30–60s", 2),
        ("60to120", "1–2m", 3),
        ("over120", "2m+", 4),
    ]

    private static func formatMinutes(_ minutes: Double) -> String {
        let totalMinutes = Int(minutes.rounded())
        if totalMinutes >= 60 { return "\(totalMinutes / 60)h \(totalMinutes % 60)m" }
        return "\(totalMinutes)m"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded < 60 { return "\(rounded)s" }
        return "\(rounded / 60)m \(rounded % 60)s"
    }

    func completeSetupWizard() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.setupWizardCurrentStep)
        showSetupWizard = false
    }
}
