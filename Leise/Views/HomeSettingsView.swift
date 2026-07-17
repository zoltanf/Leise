import AppKit
import Charts
import SwiftUI

struct HomeSettingsView: View {
    @ObservedObject private var viewModel = ServiceContainer.shared.homeViewModel
    @ObservedObject private var dictation = ServiceContainer.shared.dictationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dictation.needsMicPermission || dictation.needsAccessibilityPermission {
                permissionsBanner
                    .padding(.horizontal)
                    .padding(.top)
            }

            HStack {
                Text(String(localized: "Dashboard"))
                    .font(.title2)
                    .fontWeight(.semibold)

                if viewModel.hasAnyTranscriptions {
                    Picker(String(localized: "Dashboard section"), selection: $viewModel.selectedSection) {
                        ForEach(DashboardSection.allCases) { section in
                            Text(section.displayName).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }

                Spacer()
                timePeriodPicker
                #if DEBUG
                dashboardActionsMenu
                #endif
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.hasAnyTranscriptions {
                        switch viewModel.selectedSection {
                        case .overview: overviewDashboard
                        case .apps: appsDashboard
                        case .quality: qualityDashboard
                        }
                    } else {
                        gettingStartedCard
                        activitySection
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Overview

    private var overviewDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                StatCard(
                    title: String(localized: "Dictations"),
                    value: "\(viewModel.dictationCount)",
                    systemImage: "waveform",
                    trend: viewModel.dictationsTrend
                )
                StatCard(
                    title: String(localized: "Words"),
                    value: "\(viewModel.wordsCount)",
                    systemImage: "text.word.spacing",
                    trend: viewModel.wordsTrend
                )
                StatCard(
                    title: String(localized: "Avg. WPM"),
                    value: viewModel.averageWPM,
                    systemImage: "speedometer",
                    trend: viewModel.wpmTrend
                )
                StatCard(
                    title: String(localized: "Time Saved"),
                    value: viewModel.timeSaved,
                    systemImage: "clock.badge.checkmark",
                    trend: viewModel.timeSavedTrend,
                    subtitle: String(localized: "vs. 45 WPM typing")
                )
            }

            activitySection
            habitSummary
            habitsHeatmapSection
            durationDistributionSection
            recentTranscriptionsSection
        }
    }

    private var activitySection: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(localized: "Activity"))
                        .font(.headline)
                    Spacer()
                    Text(activityGranularityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.chartData.isEmpty || viewModel.chartData.allSatisfy({ $0.wordCount == 0 }) {
                    Text(viewModel.hasAnyTranscriptions
                        ? String(localized: "No activity in this period.")
                        : String(localized: "Your activity will appear here after your first transcription."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    Chart(viewModel.chartData) { point in
                        BarMark(
                            x: .value(
                                String(localized: "Date"),
                                point.date,
                                unit: activityCalendarComponent
                            ),
                            y: .value(String(localized: "Words"), point.wordCount),
                            width: .ratio(0.68)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(4)
                        .accessibilityLabel(activityLabel(point.date))
                        .accessibilityValue("\(point.wordCount) \(String(localized: "words")), \(point.transcriptionCount) \(String(localized: "dictations"))")
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 7)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(activityLabel(date))
                                }
                            }
                        }
                    }
                    .chartXScale(
                        range: .plotDimension(
                            startPadding: activityChartEdgePadding,
                            endPadding: activityChartEdgePadding
                        )
                    )
                    .frame(height: 220)
                    .accessibilityLabel(String(localized: "Words dictated over time"))
                }
            }
        }
    }

    private var habitSummary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            StatCard(
                title: String(localized: "Active Days"),
                value: "\(viewModel.activeDays)",
                systemImage: "calendar.badge.checkmark"
            )
            StatCard(
                title: String(localized: "Current Streak"),
                value: "\(viewModel.currentStreak)",
                systemImage: "flame",
                subtitle: String(localized: "days")
            )
            StatCard(
                title: String(localized: "Avg. Duration"),
                value: viewModel.averageDictationDuration,
                systemImage: "timer"
            )
            StatCard(
                title: String(localized: "Words / Dictation"),
                value: viewModel.averageWordsPerDictation,
                systemImage: "textformat.abc"
            )
        }
    }

    private var habitsHeatmapSection: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Dictation Habits"))
                    .font(.headline)
                Text(String(localized: "When you dictate most"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Chart(viewModel.habitHeatmap) { point in
                    RectangleMark(
                        x: .value(String(localized: "Weekday"), point.weekdayKey),
                        y: .value(String(localized: "Time"), point.hourLabel)
                    )
                    .foregroundStyle(heatmapColor(for: point.count))
                    .cornerRadius(3)
                    .accessibilityLabel("\(point.weekdayLabel), \(point.hourLabel):00")
                    .accessibilityValue("\(point.count) \(String(localized: "dictations"))")
                }
                .chartXScale(domain: heatmapWeekdayDomain)
                .chartXAxis {
                    AxisMarks(values: heatmapWeekdayDomain) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let key = value.as(String.self),
                               let label = heatmapWeekdayLabel(for: key) {
                                Text(label)
                            }
                        }
                    }
                }
                .chartYScale(domain: heatmapHourDomain)
                .frame(height: 210)
                .accessibilityLabel(String(localized: "Dictations by weekday and time of day"))
            }
        }
    }

    private var durationDistributionSection: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Dictation Length"))
                    .font(.headline)
                Text(String(localized: "Distribution by speaking duration"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Chart(viewModel.durationBuckets) { bucket in
                    BarMark(
                        x: .value(String(localized: "Duration"), bucket.label),
                        y: .value(String(localized: "Dictations"), bucket.count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        if bucket.count > 0 {
                            Text("\(bucket.count)")
                                .font(.caption2)
                                .monospacedDigit()
                        }
                    }
                    .accessibilityLabel(bucket.label)
                    .accessibilityValue("\(bucket.count) \(String(localized: "dictations"))")
                }
                .chartXScale(domain: viewModel.durationBuckets.sorted { $0.order < $1.order }.map(\.label))
                .frame(height: 180)
                .accessibilityLabel(String(localized: "Distribution of dictation duration"))
            }
        }
    }

    // MARK: - Apps

    private var appsDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                StatCard(
                    title: String(localized: "Top App"),
                    value: viewModel.topAppLabel,
                    systemImage: "app.badge"
                )
                StatCard(
                    title: String(localized: "Apps Used"),
                    value: "\(viewModel.appsUsed)",
                    systemImage: "square.grid.2x2"
                )
                StatCard(
                    title: String(localized: "Top-App Share"),
                    value: viewModel.topAppShare,
                    systemImage: "chart.bar.fill"
                )
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "Usage by Application"))
                            .font(.headline)
                        Spacer()
                        Picker(String(localized: "Application metric"), selection: $viewModel.selectedAppMetric) {
                            ForEach(AppUsageMetric.allCases) { metric in
                                Text(metric.displayName).tag(metric)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }

                    if viewModel.appUsage.isEmpty {
                        emptyAnalyticsMessage(String(localized: "Application details will appear after your next dictation."))
                    } else {
                        let maximum = viewModel.appUsage.map { $0.value(for: viewModel.selectedAppMetric) }.max() ?? 1
                        VStack(spacing: 10) {
                            ForEach(viewModel.appUsage.prefix(12)) { item in
                                UsageBarRow(
                                    label: item.label,
                                    value: appValueLabel(item),
                                    fraction: maximum > 0 ? item.value(for: viewModel.selectedAppMetric) / maximum : 0,
                                    accessibilityValue: "\(item.transcriptionCount) \(String(localized: "dictations")), \(item.words) \(String(localized: "words"))"
                                ) {
                                    viewModel.requestHistory(forAppBundleIdentifier: item.id)
                                }
                            }
                        }
                    }
                }
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Browser Domains"))
                        .font(.headline)
                    Text(String(localized: "Stored locally from browser context"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if viewModel.domainUsage.isEmpty {
                        emptyAnalyticsMessage(String(localized: "No browser-domain activity in this period."))
                    } else {
                        let maximum = viewModel.domainUsage.map(\.transcriptionCount).max() ?? 1
                        VStack(spacing: 10) {
                            ForEach(viewModel.domainUsage.prefix(10)) { item in
                                UsageBarRow(
                                    label: item.label,
                                    value: "\(item.transcriptionCount)",
                                    fraction: Double(item.transcriptionCount) / Double(maximum),
                                    accessibilityValue: "\(item.transcriptionCount) \(String(localized: "dictations"))"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Quality

    private var qualityDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                StatCard(
                    title: String(localized: "Auto-Enhanced"),
                    value: "\(viewModel.postProcessedCount)",
                    systemImage: "sparkles",
                    subtitle: viewModel.enhancementRate
                )
                StatCard(
                    title: String(localized: "Words Enhanced"),
                    value: "\(viewModel.changedWordCount)",
                    systemImage: "wand.and.stars"
                )
                StatCard(
                    title: String(localized: "Manual Edits"),
                    value: "\(viewModel.manualCorrectionCount)",
                    systemImage: "pencil.and.outline",
                    subtitle: "\(viewModel.manuallyChangedWordCount) \(String(localized: "words changed"))"
                )
                StatCard(
                    title: String(localized: "Dictionary Fixes"),
                    value: "\(viewModel.dictionaryCorrectionDictationCount)",
                    systemImage: "book.badge.checkmark",
                    subtitle: String(localized: "dictations improved")
                )
            }

            postProcessingCoverageSection
            correctionTrendSection
            processingBreakdownSection
            languageAndEngineSection
            learnedCorrectionsSection
        }
    }

    private var postProcessingCoverageSection: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Post-Processing Coverage"))
                    .font(.headline)

                if viewModel.dictationCount == 0 {
                    emptyAnalyticsMessage(String(localized: "No quality data in this period."))
                } else {
                    Chart {
                        BarMark(
                            x: .value(String(localized: "Dictations"), viewModel.postProcessedCount),
                            y: .value(String(localized: "Category"), String(localized: "All dictations"))
                        )
                        .foregroundStyle(by: .value(String(localized: "Result"), String(localized: "Auto-enhanced")))

                        BarMark(
                            x: .value(String(localized: "Dictations"), max(0, viewModel.dictationCount - viewModel.postProcessedCount)),
                            y: .value(String(localized: "Category"), String(localized: "All dictations"))
                        )
                        .foregroundStyle(by: .value(String(localized: "Result"), String(localized: "Unchanged")))
                    }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 105)
                    .accessibilityLabel(String(localized: "Share of auto-enhanced and unchanged dictations"))
                }
            }
        }
    }

    private var correctionTrendSection: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Manual Corrections Over Time"))
                    .font(.headline)

                if viewModel.chartData.allSatisfy({ $0.manualCorrectionCount == 0 }) {
                    emptyAnalyticsMessage(String(localized: "Manual edits made from now on will appear here."))
                } else {
                    Chart(viewModel.chartData) { point in
                        LineMark(
                            x: .value(String(localized: "Date"), point.date),
                            y: .value(String(localized: "Manual Edits"), point.manualCorrectionCount)
                        )
                        .foregroundStyle(Color.accentColor)
                        .symbol(.circle)
                        .interpolationMethod(.catmullRom)
                        .accessibilityLabel(activityLabel(point.date))
                        .accessibilityValue("\(point.manualCorrectionCount) \(String(localized: "manual edits"))")
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 7)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let date = value.as(Date.self) { Text(activityLabel(date)) }
                            }
                        }
                    }
                    .frame(height: 180)
                    .accessibilityLabel(String(localized: "Manual corrections over time"))
                }
            }
        }
    }

    private var processingBreakdownSection: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Processing Contributions"))
                    .font(.headline)

                if viewModel.pipelineUsage.isEmpty {
                    emptyAnalyticsMessage(String(localized: "No processing steps changed text in this period."))
                } else {
                    let maximum = viewModel.pipelineUsage.map(\.count).max() ?? 1
                    VStack(spacing: 10) {
                        ForEach(viewModel.pipelineUsage.prefix(10)) { item in
                            UsageBarRow(
                                label: item.label,
                                value: "\(item.count)",
                                fraction: Double(item.count) / Double(maximum),
                                accessibilityValue: "\(item.count) \(String(localized: "dictations"))"
                            )
                        }
                    }
                }
            }
        }
    }

    private var languageAndEngineSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            categoryUsageSection(title: String(localized: "Languages"), items: viewModel.languageUsage)
            categoryUsageSection(title: String(localized: "Engines & Models"), items: viewModel.engineUsage)
        }
    }

    private func categoryUsageSection(title: String, items: [RankedUsageItem]) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                if items.isEmpty {
                    emptyAnalyticsMessage(String(localized: "No data in this period."))
                } else {
                    let maximum = items.map(\.transcriptionCount).max() ?? 1
                    VStack(spacing: 10) {
                        ForEach(items.prefix(10)) { item in
                            UsageBarRow(
                                label: item.label.uppercased(),
                                value: "\(item.transcriptionCount)",
                                fraction: Double(item.transcriptionCount) / Double(maximum),
                                accessibilityValue: "\(item.transcriptionCount) \(String(localized: "dictations"))"
                            )
                        }
                    }
                }
            }
        }
    }

    private var learnedCorrectionsSection: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Learned Corrections"))
                    .font(.headline)

                if viewModel.correctionUsage.isEmpty {
                    emptyAnalyticsMessage(String(localized: "Corrections learned from History edits will appear here."))
                } else {
                    ForEach(Array(viewModel.correctionUsage.prefix(10).enumerated()), id: \.element.id) { index, correction in
                        HStack(spacing: 8) {
                            Text(correction.original)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(correction.replacement)
                                .fontWeight(.medium)
                            Spacer()
                            Text("×\(correction.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        if index < min(viewModel.correctionUsage.count, 10) - 1 { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - Recent Transcriptions

    private var recentTranscriptionsSection: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Recent Transcriptions"))
                    .font(.headline)

                if viewModel.recentTranscriptions.isEmpty {
                    Text(String(localized: "Press \(primaryHotkeyLabel) in any app to get started."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    VStack(spacing: 0) {
                        ForEach(viewModel.recentTranscriptions, id: \.id) { record in
                            Button {
                                viewModel.pendingHistoryAppBundleIdentifier = nil
                                viewModel.pendingHistoryTimeRange = .all
                                viewModel.pendingHistoryRecordID = record.id
                                viewModel.navigateToHistory = true
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.preview)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        HStack(spacing: 4) {
                                            Text(record.timestamp, format: .relative(presentation: .named))
                                            if let appName = record.appName { Text("– \(appName)") }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if record.id != viewModel.recentTranscriptions.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Dashboard Controls

    private var timePeriodPicker: some View {
        HStack(spacing: 2) {
            ForEach(TimePeriod.allCases, id: \.self) { period in
                periodButton(period)
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func periodButton(_ period: TimePeriod) -> some View {
        let isSelected = viewModel.selectedTimePeriod == period
        return Button(period.displayName) {
            viewModel.selectedTimePeriod = period
        }
        .buttonStyle(.plain)
        .font(.caption)
        .fontWeight(isSelected ? .semibold : .regular)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor : Color.clear)
        .foregroundStyle(isSelected ? .white : .secondary)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
    }

    #if DEBUG
    @State private var showClearAllDataConfirmation = false

    private var dashboardActionsMenu: some View {
        Menu {
            Button("Seed Demo Data", action: seedDemoData)
            Divider()
            Button("Clear All Data", role: .destructive) {
                showClearAllDataConfirmation = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Dashboard Actions")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Dashboard Actions")
        .confirmationDialog("Clear All Data?", isPresented: $showClearAllDataConfirmation) {
            Button("Clear All Data", role: .destructive, action: clearAllData)
        } message: {
            Text("This will permanently delete all transcription history and usage statistics.")
        }
    }

    private func seedDemoData() {
        let historyService = ServiceContainer.shared.historyService
        historyService.seedDemoData()
        ServiceContainer.shared.usageStatisticsService.replaceWithHistoryRecords(historyService.records)
    }

    private func clearAllData() {
        ServiceContainer.shared.historyService.clearAll()
        ServiceContainer.shared.usageStatisticsService.clearUsageStatistics()
    }
    #endif

    // MARK: - Empty State and Permissions

    private var primaryHotkeyLabel: String {
        if !DictationSettingsHandler.loadHotkeys(for: .hybrid).isEmpty { return dictation.hybridHotkeyLabel }
        if !DictationSettingsHandler.loadHotkeys(for: .pushToTalk).isEmpty { return dictation.pttHotkeyLabel }
        if !DictationSettingsHandler.loadHotkeys(for: .toggle).isEmpty { return dictation.toggleHotkeyLabel }
        return dictation.hybridHotkeyLabel
    }

    private var gettingStartedCard: some View {
        DashboardCard {
            VStack(spacing: 12) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text(String(localized: "Ready to start dictating?"))
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(String(localized: "Press"))
                    Text(primaryHotkeyLabel)
                        .fontWeight(.medium)
                    Text(String(localized: "in any app to begin."))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var permissionsBanner: some View {
        VStack(spacing: 8) {
            if dictation.needsMicPermission {
                HStack {
                    Label(String(localized: "Microphone access required"), systemImage: "mic.slash")
                    Spacer()
                    Button(String(localized: "Grant Access")) { dictation.requestMicPermission() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if dictation.needsAccessibilityPermission {
                HStack {
                    Label(String(localized: "Accessibility access required"), systemImage: "lock.shield")
                    Spacer()
                    Button(String(localized: "Grant Access")) { dictation.requestAccessibilityPermission() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .foregroundStyle(.red)
        .padding()
        .background(.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Formatting

    private var activityGranularityLabel: String {
        switch viewModel.chartGranularity {
        case .day: String(localized: "Daily")
        case .week: String(localized: "Weekly")
        case .month: String(localized: "Monthly")
        }
    }

    private var activityCalendarComponent: Calendar.Component {
        switch viewModel.chartGranularity {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    private var activityChartEdgePadding: CGFloat {
        viewModel.selectedTimePeriod == .allTime ? 16 : 0
    }

    private func activityLabel(_ date: Date) -> String {
        switch viewModel.chartGranularity {
        case .day: date.formatted(.dateTime.month(.abbreviated).day())
        case .week: String(localized: "Week of \(date.formatted(.dateTime.month(.abbreviated).day()))")
        case .month: date.formatted(.dateTime.month(.abbreviated).year())
        }
    }

    private var heatmapWeekdayDomain: [String] {
        (0..<7).compactMap { index in
            viewModel.habitHeatmap.first(where: { $0.weekdayIndex == index })?.weekdayKey
        }
    }

    private func heatmapWeekdayLabel(for key: String) -> String? {
        viewModel.habitHeatmap.first(where: { $0.weekdayKey == key })?.weekdayLabel
    }

    private var heatmapHourDomain: [String] {
        stride(from: 0, through: 20, by: 4).map { String(format: "%02d", $0) }
    }

    private func heatmapColor(for count: Int) -> Color {
        let maximum = max(viewModel.habitHeatmap.map(\.count).max() ?? 0, 1)
        guard count > 0 else { return Color.secondary.opacity(0.08) }
        return Color.accentColor.opacity(0.2 + 0.8 * Double(count) / Double(maximum))
    }

    private func appValueLabel(_ item: RankedUsageItem) -> String {
        switch viewModel.selectedAppMetric {
        case .dictations: "\(item.transcriptionCount)"
        case .words: "\(item.words)"
        case .time: formatDuration(item.durationSeconds)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        if value < 60 { return "\(value)s" }
        return "\(value / 60)m \(value % 60)s"
    }

    private func emptyAnalyticsMessage(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
    }
}

private struct DashboardCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding()
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct UsageBarRow: View {
    let label: String
    let value: String
    let fraction: Double
    let accessibilityValue: String
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Text(label)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
            .frame(height: 16)
            Text(value)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 48, alignment: .trailing)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    var trend: Double?
    var subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if let trend { trendLabel(trend) }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .top)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(value)"))
    }

    private func trendLabel(_ percent: Double) -> some View {
        let isPositive = percent >= 0
        return HStack(spacing: 2) {
            Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
            Text("\(Int(abs(percent)))%")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(isPositive ? .green : .red)
    }
}
