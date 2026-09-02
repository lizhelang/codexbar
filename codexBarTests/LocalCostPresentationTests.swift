import XCTest

final class LocalCostPresentationTests: XCTestCase {
    func testEmptyUncomputedSummaryDisplaysUnknownInsteadOfZero() {
        XCTAssertTrue(LocalCostSummaryPresentation.shouldDisplayUnknown(summary: .empty))
    }

    func testComputedZeroSummaryRemainsARealZero() {
        let summary = LocalCostSummary(
            todayCostUSD: 0,
            todayTokens: 0,
            last30DaysCostUSD: 0,
            last30DaysTokens: 0,
            lifetimeCostUSD: 0,
            lifetimeTokens: 0,
            dailyEntries: [],
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertFalse(LocalCostSummaryPresentation.shouldDisplayUnknown(summary: summary))
    }

    func testChartContainsThirtyCalendarDaysIncludingZeroBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 10 * 60 * 60))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 2,
            hour: 10
        )))
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let summary = LocalCostSummary(
            todayCostUSD: 2,
            todayTokens: 20,
            last30DaysCostUSD: 3,
            last30DaysTokens: 30,
            lifetimeCostUSD: 3,
            lifetimeTokens: 30,
            dailyEntries: [
                DailyCostEntry(id: "today", date: today, costUSD: 2, totalTokens: 20),
                DailyCostEntry(id: "yesterday", date: yesterday, costUSD: 1, totalTokens: 10),
            ],
            updatedAt: now
        )

        let entries = LocalCostChartSeries.entries(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(entries.count, 30)
        XCTAssertEqual(entries.first?.date, calendar.date(byAdding: .day, value: -29, to: today))
        XCTAssertEqual(entries.last?.date, today)
        XCTAssertEqual(entries.filter { $0.totalTokens == 0 }.count, 28)
        XCTAssertEqual(entries.suffix(2).map(\.totalTokens), [10, 20])
    }

    func testScanningStatusUsesProgressFraction() {
        let state = LocalCostRefreshState(
            phase: .scanning,
            activeStrength: .incremental,
            progress: .init(processedBytes: 25, totalBytes: 100, completedFiles: 1, totalFiles: 4),
            lastRawSessionScanAt: nil,
            latestUsageEventAt: nil,
            warningCount: 0
        )

        XCTAssertEqual(
            LocalCostSummaryPresentation.statusText(for: state),
            "Scanning local records… 25%"
        )
    }

    func testChartMergesDuplicateEntriesThatNormalizeToSameDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 2)))
        let summary = LocalCostSummary(
            todayCostUSD: 3,
            todayTokens: 30,
            last30DaysCostUSD: 3,
            last30DaysTokens: 30,
            lifetimeCostUSD: 3,
            lifetimeTokens: 30,
            dailyEntries: [
                DailyCostEntry(id: "a", date: day.addingTimeInterval(60), costUSD: 1, totalTokens: 10),
                DailyCostEntry(id: "b", date: day.addingTimeInterval(120), costUSD: 2, totalTokens: 20),
            ],
            updatedAt: day
        )

        let entries = LocalCostChartSeries.entries(summary: summary, now: day, calendar: calendar)

        XCTAssertEqual(entries.last?.totalTokens, 30)
        XCTAssertEqual(entries.last?.costUSD ?? 0, 3, accuracy: 1e-12)
    }
}
