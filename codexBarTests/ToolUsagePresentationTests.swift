import Foundation
import XCTest
@testable import codexbar

final class ToolUsagePresentationTests: XCTestCase {
    func testPartialExternalDayRetainsKnownCostWithoutClaimingCompleteTotal() {
        let now = Date()
        let day = calendar.startOfDay(for: now)
        let snapshot = ToolUsageSnapshot(client: .openCode, availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: day, totalTokens: 100, knownCostUSD: 2.5)])
        let result = UsagePresentation.aggregate(codex: .empty, external: [.openCode: snapshot],
            scope: .client(.openCode), period: .today, now: now, calendar: calendar)
        XCTAssertEqual(result.tokens, 100)
        XCTAssertEqual(result.knownCostUSD, 2.5)
        XCTAssertFalse(result.costIsComplete)
        XCTAssertEqual(result.dailyEntries.first?.knownCostUSD, 2.5)
    }

    func testActivityTrendFillsUnusedCalendarDaysWithoutLosingKnownCost() {
        let today = Date(timeIntervalSince1970: 1_790_812_800)
        let yesterday = self.calendar.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = self.calendar.date(byAdding: .day, value: -2, to: today)!
        let entries = UsagePresentation.chartEntries(
            dailyEntries: [
                UsageChartEntry(date: twoDaysAgo, tokens: 20, knownCostUSD: 0.5, costIsComplete: false),
                UsageChartEntry(date: today, tokens: 30, knownCostUSD: 1, costIsComplete: true),
            ], numberOfDays: 45, now: today, calendar: self.calendar
        )
        XCTAssertEqual(entries.count, 45)
        XCTAssertEqual(entries.first(where: { $0.date == yesterday })?.tokens, 0)
        XCTAssertEqual(entries.first(where: { $0.date == twoDaysAgo })?.knownCostUSD, 0.5)
        XCTAssertEqual(entries.first(where: { $0.date == twoDaysAgo })?.costIsComplete, false)
        XCTAssertEqual(entries.last?.tokens, 30)
    }

    func testMonthBoundaryUsesLocalDayAndRetainsIncompleteCodexCost() {
        var calendar = self.calendar
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 4))!
        let october = calendar.startOfDay(for: now)
        let september = calendar.date(byAdding: .day, value: -1, to: october)!
        let codex = LocalCostSummary(
            todayCostUSD: 1, todayTokens: 30, last30DaysCostUSD: 3, last30DaysTokens: 100,
            lifetimeCostUSD: 3, lifetimeTokens: 100,
            dailyEntries: [
                DailyCostEntry(id: "sep", date: september, costUSD: 2, totalTokens: 70),
                DailyCostEntry(id: "oct", date: october, costUSD: 1, totalTokens: 30, costIsComplete: false),
            ], updatedAt: now
        )
        let month = UsagePresentation.aggregate(codex: codex, external: [:], scope: .codex, period: .thisMonth, now: now, calendar: calendar)
        XCTAssertEqual(month.tokens, 30)
        XCTAssertEqual(month.knownCostUSD, 1)
        XCTAssertFalse(month.costIsComplete)
        let all = UsagePresentation.aggregate(codex: codex, external: [:], scope: .codex, period: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(all.tokens, 100)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testThisWeekUsesCalendarWeekRatherThanRollingSevenDays() {
        var calendar = self.calendar
        calendar.firstWeekday = 2
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))!
        let codex = LocalCostSummary(
            todayCostUSD: 0, todayTokens: 0,
            last30DaysCostUSD: 0, last30DaysTokens: 0,
            lifetimeCostUSD: 0, lifetimeTokens: 0,
            dailyEntries: [
                DailyCostEntry(id: "monday", date: monday, costUSD: 0, totalTokens: 20),
                DailyCostEntry(id: "sunday", date: sunday, costUSD: 0, totalTokens: 70),
            ],
            updatedAt: now
        )

        let result = UsagePresentation.aggregate(
            codex: codex, external: [:], scope: .codex,
            period: .thisWeek, now: now, calendar: calendar
        )
        XCTAssertEqual(result.tokens, 20)
        XCTAssertEqual(UsagePeriod.thisWeek.chartDayCount(now: now, calendar: calendar), 3)
    }

    func testIntervalAverageSwitchesUnitsWithoutClaimingRealtimeSpeed() {
        let now = self.calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 1))!
        let aggregate = UsageAggregate(
            tokens: 120,
            knownCostUSD: 0,
            costIsComplete: true,
            dailyEntries: [UsageChartEntry(date: self.calendar.startOfDay(for: now), tokens: 120, knownCostUSD: 0, costIsComplete: true)],
            latestUsageAt: now
        )
        let perSecond = UsageRatePresentation.intervalAverage(
            aggregate: aggregate, period: .today, unit: .perSecond,
            now: now, calendar: self.calendar
        )
        let perMinute = UsageRatePresentation.intervalAverage(
            aggregate: aggregate, period: .today, unit: .perMinute,
            now: now, calendar: self.calendar
        )
        XCTAssertEqual(perSecond ?? 0, 120.0 / 3600.0, accuracy: 0.0001)
        XCTAssertEqual(perMinute ?? 0, 2.0, accuracy: 0.0001)
    }

    func testPeriodAndSourceSwitchesPreserveUnknownCost() {
        let now = self.calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
        let today = self.calendar.startOfDay(for: now)
        let sixDaysAgo = self.calendar.date(byAdding: .day, value: -6, to: today)!
        let sevenDaysAgo = self.calendar.date(byAdding: .day, value: -7, to: today)!
        let codex = LocalCostSummary(
            todayCostUSD: 1,
            todayTokens: 100,
            last30DaysCostUSD: 3,
            last30DaysTokens: 300,
            lifetimeCostUSD: 3,
            lifetimeTokens: 300,
            dailyEntries: [
                DailyCostEntry(id: "today", date: today, costUSD: 1, totalTokens: 100),
                DailyCostEntry(id: "week-before", date: sevenDaysAgo, costUSD: 2, totalTokens: 200),
            ],
            updatedAt: now
        )
        let claude = ToolUsageSnapshot(
            client: .claudeCode,
            availability: .ready,
            dailyEntries: [
                ToolUsageDailyEntry(date: sixDaysAgo, totalTokens: 50),
            ],
            latestUsageAt: sixDaysAgo,
            refreshedAt: now
        )
        let external: [ToolUsageClient: ToolUsageSnapshot] = [.claudeCode: claude]

        let week = UsagePresentation.aggregate(
            codex: codex, external: external, scope: .all,
            period: .last7Days, now: now, calendar: self.calendar
        )
        XCTAssertEqual(week.tokens, 150)
        XCTAssertEqual(week.knownCostUSD, 1)
        XCTAssertFalse(week.costIsComplete)

        let month = UsagePresentation.aggregate(
            codex: codex, external: external, scope: .all,
            period: .last30Days, now: now, calendar: self.calendar
        )
        XCTAssertEqual(month.tokens, 350)
        XCTAssertEqual(month.knownCostUSD, 3)
        XCTAssertFalse(month.costIsComplete)

        let codexOnly = UsagePresentation.aggregate(
            codex: codex, external: external, scope: .codex,
            period: .last30Days, now: now, calendar: self.calendar
        )
        XCTAssertEqual(codexOnly.tokens, 300)
        XCTAssertTrue(codexOnly.costIsComplete)
        XCTAssertEqual(UsagePresentation.chartEntries(
            aggregate: week, period: .last7Days, now: now, calendar: self.calendar
        ).count, 7)
        XCTAssertEqual(UsagePresentation.chartEntries(
            aggregate: month, period: .last30Days, now: now, calendar: self.calendar
        ).count, 30)
    }

    func testFutureUsageIsExcluded() {
        let now = self.calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
        let tomorrow = self.calendar.date(byAdding: .day, value: 1, to: now)!
        let external: [ToolUsageClient: ToolUsageSnapshot] = [
            .openCode: ToolUsageSnapshot(
                client: .openCode,
                availability: .ready,
                dailyEntries: [ToolUsageDailyEntry(date: tomorrow, totalTokens: 99, costUSD: 1)]
            ),
        ]
        let total = UsagePresentation.aggregate(
            codex: .empty, external: external, scope: .all,
            period: .allTime, now: now, calendar: self.calendar
        )
        XCTAssertEqual(total.tokens, 0)
        XCTAssertTrue(total.dailyEntries.isEmpty)
    }

    func testTodayAndCalendarMonthUseTheirActualDateBoundaries() {
        let now = self.calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
        let august31 = self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let september1 = self.calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let september30 = self.calendar.startOfDay(for: now)
        let external: [ToolUsageClient: ToolUsageSnapshot] = [
            .cursor: ToolUsageSnapshot(
                client: .cursor,
                availability: .ready,
                dailyEntries: [
                    ToolUsageDailyEntry(date: august31, totalTokens: 200, costUSD: 2),
                    ToolUsageDailyEntry(date: september1, totalTokens: 50, costUSD: 0.5),
                    ToolUsageDailyEntry(date: september30, totalTokens: 100, costUSD: 1),
                ]
            ),
        ]

        let today = UsagePresentation.aggregate(
            codex: .empty, external: external, scope: .client(.cursor),
            period: .today, now: now, calendar: self.calendar
        )
        let month = UsagePresentation.aggregate(
            codex: .empty, external: external, scope: .client(.cursor),
            period: .thisMonth, now: now, calendar: self.calendar
        )
        let allTime = UsagePresentation.aggregate(
            codex: .empty, external: external, scope: .client(.cursor),
            period: .allTime, now: now, calendar: self.calendar
        )

        XCTAssertEqual(today.tokens, 100)
        XCTAssertEqual(month.tokens, 150)
        XCTAssertEqual(allTime.tokens, 350)
        XCTAssertEqual(UsagePresentation.chartEntries(
            aggregate: today, period: .today, now: now, calendar: self.calendar
        ).count, 1)
        XCTAssertEqual(UsagePresentation.chartEntries(
            aggregate: month, period: .thisMonth, now: now, calendar: self.calendar
        ).count, 30)
    }

    func testAggregateSaturatesInsteadOfOverflowing() {
        let now = self.calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
        let day = self.calendar.startOfDay(for: now)
        let first = ToolUsageSnapshot(
            client: .claudeCode, availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: day, totalTokens: Int.max)]
        )
        let second = ToolUsageSnapshot(
            client: .openCode, availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: day, totalTokens: 1)]
        )
        let aggregate = UsagePresentation.aggregate(
            codex: .empty, external: [.claudeCode: first, .openCode: second], scope: .all,
            period: .last7Days, now: now, calendar: self.calendar
        )
        XCTAssertEqual(aggregate.tokens, Int.max)
    }
}
