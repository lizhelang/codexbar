import Foundation

nonisolated struct UsageDashboardToolRow: Identifiable, Sendable {
    let scope: UsageScope
    let usage: UsageAggregate
    var id: String { self.scope.id }
}

nonisolated struct UsageDashboardHeatmapDay: Identifiable, Sendable {
    let date: Date
    let usage: UsageChartEntry
    let isInYear: Bool
    var id: Date { self.date }
}

nonisolated struct UsageDashboardProjection: Sendable {
    let period: UsagePeriod
    let scope: UsageScope
    let year: Int
    let aggregate: UsageAggregate
    let chartEntries: [UsageChartEntry]
    let chartIsLastYearOnly: Bool
    let tools: [UsageDashboardToolRow]
    let models: [MonitorModelUsage]
    let modelsAvailable: Bool
    let activeDayCount: Int
    let longestStreakDays: Int
    let peakDay: UsageChartEntry?
    let annualWeeks: [[UsageDashboardHeatmapDay]]
    let annualActiveDays: Int
    let availableYears: [Int]
    let projectedAt: Date

    func matches(period: UsagePeriod, scope: UsageScope, year: Int) -> Bool {
        self.period == period && self.scope == scope && self.year == year
    }

    static func build(
        codex: LocalCostSummary,
        tools: [ToolUsageClient: ToolUsageSnapshot],
        codexModels: [MonitorModelUsage]?,
        period: UsagePeriod,
        scope: UsageScope = .all,
        year: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> Self {
        let presentation = MenuMonitorPresentation.build(
            costSummary: codex, records: nil, toolSnapshots: tools,
            modelUsage: codexModels, runningThreads: .empty, period: period, scope: scope,
            codexSessions: nil, recentCodexSessions: nil, recentSessionLimit: 1,
            now: now, calendar: calendar
        )
        let aggregate = Self.accountingForSelectedSources(presentation.aggregates[scope] ?? .empty, scope: scope, tools: tools)
        let history = Self.accountingForSelectedSources(scope == .all ? presentation.history : UsagePresentation.aggregate(
            codex: codex, external: tools, scope: scope, period: .allTime, now: now, calendar: calendar
        ), scope: scope, tools: tools)
        let active = aggregate.dailyEntries.filter { $0.tokens > 0 }
        let today = calendar.startOfDay(for: now)
        let first = period.firstDay(now: now, calendar: calendar) ?? aggregate.dailyEntries.first?.date ?? today
        let span = max(1, (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1)
        let chartCount = min(366, span)
        let chart = UsagePresentation.chartEntries(dailyEntries: aggregate.dailyEntries, numberOfDays: chartCount, now: now, calendar: calendar)
        let toolRows: [UsageDashboardToolRow] = ([UsageScope.codex] + ToolUsageClient.allCases.map(UsageScope.client))
            .compactMap { scope in
                guard let usage = presentation.aggregates[scope], usage.tokens > 0 || usage.knownCostUSD > 0 else { return nil }
                return UsageDashboardToolRow(scope: scope, usage: usage)
            }
            .filter { scope == .all || $0.scope == scope }
            .sorted { $0.usage.tokens > $1.usage.tokens }
        var annualCalendar = calendar
        annualCalendar.firstWeekday = 2
        let start = annualCalendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
        let end = annualCalendar.date(byAdding: .year, value: 1, to: start) ?? today
        let gridStart = annualCalendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        let byDay = Dictionary(uniqueKeysWithValues: history.dailyEntries.map { ($0.date, $0) })
        let weekCount = ((annualCalendar.dateComponents([.day], from: gridStart, to: end).day ?? 365) + 6) / 7
        let weeks = (0..<weekCount).map { week in
            (0..<7).compactMap { offset -> UsageDashboardHeatmapDay? in
                guard let date = annualCalendar.date(byAdding: .day, value: week * 7 + offset, to: gridStart) else { return nil }
                return UsageDashboardHeatmapDay(
                    date: date,
                    usage: byDay[date] ?? UsageChartEntry(date: date, tokens: 0, knownCostUSD: 0, costIsComplete: true),
                    isInYear: date >= start && date < end && date <= today
                )
            }
        }
        let activeAnnual = history.dailyEntries.filter { $0.date >= start && $0.date < end && $0.tokens > 0 }.count
        let years = Set(history.dailyEntries.map { calendar.component(.year, from: $0.date) })
            .union([calendar.component(.year, from: now), year]).sorted(by: >)
        return Self(
            period: period, scope: scope, year: year,
            aggregate: aggregate, chartEntries: chart, chartIsLastYearOnly: span > 366,
            tools: toolRows, models: presentation.page.models ?? [], modelsAvailable: presentation.page.models != nil,
            activeDayCount: active.count, longestStreakDays: presentation.page.trend.longestStreakDays,
            peakDay: active.max { $0.tokens < $1.tokens }, annualWeeks: weeks,
            annualActiveDays: activeAnnual, availableYears: years, projectedAt: now
        )
    }

    private static func accountingForSelectedSources(_ aggregate: UsageAggregate, scope: UsageScope, tools: [ToolUsageClient: ToolUsageSnapshot]) -> UsageAggregate {
        guard scope == .all else { return aggregate }
        // The caller removes explicitly disabled tools. Their absence must not turn known cost into an estimate.
        let complete = aggregate.dailyEntries.allSatisfy(\.costIsComplete) && tools.values.allSatisfy { $0.availability == .ready }
        return UsageAggregate(tokens: aggregate.tokens, knownCostUSD: aggregate.knownCostUSD,
                              costIsComplete: complete, dailyEntries: aggregate.dailyEntries, latestUsageAt: aggregate.latestUsageAt)
    }
}

/// Reads the existing compact index only; no transcript or RecordsSnapshot loading is permitted here.
actor UsageDashboardProjectionWorker {
    func project(
        codex: LocalCostSummary,
        tools: [ToolUsageClient: ToolUsageSnapshot],
        indexURL: URL?,
        pricing: [String: CodexBarModelPricing],
        period: UsagePeriod,
        scope: UsageScope = .all,
        year: Int,
        now: Date
    ) throws -> UsageDashboardProjection {
        try Task.checkCancellation()
        let models: [MonitorModelUsage]?
        if scope == .all || scope == .codex, let indexURL, FileManager.default.fileExists(atPath: indexURL.path) {
            models = try? LocalCostIndexStore(databaseURL: indexURL).modelUsage(period: period, now: now, modelPricingOverrides: pricing)
        } else { models = nil }
        try Task.checkCancellation()
        return UsageDashboardProjection.build(codex: codex, tools: tools, codexModels: models, period: period, scope: scope, year: year, now: now)
    }
}
