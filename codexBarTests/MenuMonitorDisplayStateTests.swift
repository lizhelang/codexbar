import XCTest

final class MenuMonitorDisplayStateTests: XCTestCase {
    func testSelectionKeepsCompleteDisplayedSnapshotWhileLoading() throws {
        var state = MenuMonitorDisplayState()
        XCTAssertTrue(state.publish(self.presentation(period: .today)))

        state.select(period: .thisWeek, scope: .all)

        XCTAssertEqual(state.requestedPeriod, .thisWeek)
        XCTAssertEqual(state.displayedPeriod, .today)
        let displayed = try XCTUnwrap(state.presentation)
        XCTAssertEqual(displayed.aggregates[.all]?.tokens, 10)
        XCTAssertEqual(displayed.page.models?.count, 1)
        XCTAssertEqual(displayed.page.sessions.count, 1)
        XCTAssertEqual(displayed.page.projects.count, 1)
        XCTAssertEqual(displayed.sessionsByProject.count, 1)
    }

    func testRapidPeriodChangesRejectResultsForEarlierSelections() throws {
        var state = MenuMonitorDisplayState()
        XCTAssertTrue(state.publish(self.presentation(period: .today)))
        state.select(period: .thisWeek, scope: .all)
        state.select(period: .thisMonth, scope: .all)
        state.select(period: .allTime, scope: .all)

        for period in [UsagePeriod.thisMonth, .today, .thisWeek] {
            XCTAssertFalse(state.publish(self.presentation(period: period)))
            XCTAssertEqual(state.displayedPeriod, .today)
            XCTAssertEqual(state.presentation?.aggregates[.all]?.tokens, 10)
        }

        XCTAssertTrue(state.publish(self.presentation(period: .allTime)))
        XCTAssertEqual(state.displayedPeriod, .allTime)
        XCTAssertEqual(try XCTUnwrap(state.presentation).aggregates[.all]?.tokens, 100)
        XCTAssertFalse(state.publish(self.presentation(period: .thisWeek)))
        XCTAssertEqual(state.presentation?.aggregates[.all]?.tokens, 100)
    }

    func testPublicationReplacesTotalsModelsSessionsAndProjectsTogether() throws {
        var state = MenuMonitorDisplayState()
        state.publish(self.presentation(period: .today))
        state.select(period: .thisWeek, scope: .all)

        XCTAssertTrue(state.publish(self.presentation(period: .thisWeek)))

        let displayed = try XCTUnwrap(state.presentation)
        XCTAssertEqual(state.displayedPeriod, .thisWeek)
        XCTAssertEqual(displayed.aggregates[.all]?.tokens, 30)
        XCTAssertEqual(displayed.page.models?.count, 2)
        XCTAssertEqual(displayed.page.models?.reduce(0) { $0 + $1.totalTokens }, 30)
        XCTAssertEqual(displayed.page.sessions.count, 2)
        XCTAssertEqual(displayed.page.sessions.reduce(0) { $0 + $1.totalTokens }, 30)
        XCTAssertEqual(displayed.page.projects.count, 2)
        XCTAssertEqual(displayed.page.projects.reduce(0) { $0 + $1.totalTokens }, 30)
        XCTAssertEqual(displayed.sessionsByProject.values.flatMap { $0 }.reduce(0) { $0 + $1.totalTokens }, 30)
    }

    func testScopeChangesRejectStaleResultsAndAcceptGenuinelyEmptyData() throws {
        var state = MenuMonitorDisplayState(period: .allTime)
        state.publish(self.presentation(period: .allTime))
        state.select(period: .allTime, scope: .client(.openCode))
        state.select(period: .allTime, scope: .codex)

        XCTAssertEqual(state.displayedScope, .all)
        XCTAssertFalse(state.publish(self.presentation(period: .allTime, scope: .client(.openCode))))
        XCTAssertFalse(state.publish(self.presentation(period: .allTime, scope: .all)))
        XCTAssertEqual(state.presentation?.page.sessions.count, 3)
        XCTAssertTrue(state.publish(self.presentation(period: .allTime, scope: .codex)))

        let displayed = try XCTUnwrap(state.presentation)
        XCTAssertEqual(state.displayedScope, .codex)
        XCTAssertEqual(displayed.aggregates[.codex]?.tokens, 0)
        XCTAssertEqual(displayed.page.models, [])
        XCTAssertTrue(displayed.page.sessions.isEmpty)
        XCTAssertTrue(displayed.page.projects.isEmpty)
        XCTAssertTrue(displayed.sessionsByProject.isEmpty)
    }

    func testInitialDisplayUsesRequestedPeriodAndScopeWithoutInventingData() {
        var state = MenuMonitorDisplayState(period: .thisWeek, scope: .codex)
        XCTAssertNil(state.presentation)
        XCTAssertEqual(state.displayedPeriod, .thisWeek)
        XCTAssertEqual(state.displayedScope, .codex)

        state.select(period: .thisMonth, scope: .client(.openCode))
        XCTAssertNil(state.presentation)
        XCTAssertEqual(state.displayedPeriod, .thisMonth)
        XCTAssertEqual(state.displayedScope, .client(.openCode))
    }

    private func presentation(period: UsagePeriod, scope: UsageScope = .all) -> MenuMonitorPresentation {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let entries = [("today", today, 10), ("yesterday", yesterday, 20), ("earlier", earlier, 70)]
        let records = entries.map { name, date, tokens in
            ToolUsageRecord(id: name, timestamp: date, modelID: "model-\(name)",
                sessionID: "session-\(name)", projectPath: "/fixture/\(name)",
                inputTokens: tokens, totalTokens: tokens, costUSD: Double(tokens) / 100)
        }
        let snapshot = ToolUsageSnapshot(client: .openCode, availability: .ready,
            dailyEntries: entries.map { _, date, tokens in
                ToolUsageDailyEntry(date: date, totalTokens: tokens, costUSD: Double(tokens) / 100)
            }, usageRecords: records)
        return MenuMonitorPresentation.build(costSummary: .empty, records: nil,
            toolSnapshots: [.openCode: snapshot], modelUsage: [], runningThreads: .empty,
            period: period, scope: scope, codexSessions: [], recentCodexSessions: [],
            recentSessionLimit: 5, now: now, calendar: calendar)
    }
}
