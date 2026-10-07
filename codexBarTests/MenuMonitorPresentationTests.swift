import XCTest

final class MenuMonitorPresentationTests: XCTestCase {
    func testPausedToolCacheAppearsOnlyInSelectedDetail() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let enabled = self.snapshot(client: .cursor, today: 11, yesterday: 13, now: now, calendar: calendar)
        let paused = self.snapshot(client: .openCode, today: 37, yesterday: 17, now: now, calendar: calendar)

        for (period, selectedTokens, enabledTokens) in [(UsagePeriod.today, 37, 11), (.allTime, 54, 24)] {
            let result = MenuMonitorPresentation.build(costSummary: .empty, records: nil,
                toolSnapshots: [.cursor: enabled], selectedToolSnapshot: paused,
                modelUsage: [], runningThreads: .empty,
                period: period, scope: .client(.openCode), codexSessions: [], recentCodexSessions: [],
                recentSessionLimit: 5, now: now, calendar: calendar)
            XCTAssertEqual(result.aggregates[.client(.openCode)]?.tokens, selectedTokens)
            XCTAssertEqual(result.aggregates[.client(.cursor)]?.tokens, enabledTokens)
            XCTAssertEqual(result.aggregates[.all]?.tokens, enabledTokens,
                           "暂停工具的缓存不能进入启用工具的总汇总")
            XCTAssertEqual(result.history.tokens, 24,
                           "无论详情所选期间为何，总历史仍只包含启用工具")
            XCTAssertEqual(result.page.trend.totalTokens, selectedTokens)
            XCTAssertEqual(result.page.models?.reduce(0) { $0 + $1.totalTokens }, selectedTokens)
            XCTAssertEqual(result.page.sessions.reduce(0) { $0 + $1.totalTokens }, selectedTokens)
            XCTAssertEqual(result.page.projects.reduce(0) { $0 + $1.totalTokens }, selectedTokens)
            XCTAssertEqual(Set(result.page.sessions.map(\.sourceID)), [ToolUsageClient.openCode.rawValue])
        }
    }

    func testPausedToolCacheIsIgnoredOutsideItsMatchingScope() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let enabled = self.snapshot(client: .cursor, today: 11, yesterday: 13, now: now, calendar: calendar)
        let paused = self.snapshot(client: .openCode, today: 37, yesterday: 17, now: now, calendar: calendar)

        for scope in [UsageScope.all, .codex, .client(.claudeCode)] {
            let result = MenuMonitorPresentation.build(costSummary: .empty, records: nil,
                toolSnapshots: [.cursor: enabled], selectedToolSnapshot: paused,
                modelUsage: [], runningThreads: .empty,
                period: .today, scope: scope, codexSessions: [], recentCodexSessions: [],
                recentSessionLimit: 5, now: now, calendar: calendar)
            XCTAssertEqual(result.aggregates[.client(.openCode)]?.tokens, 0)
            XCTAssertEqual(result.aggregates[.all]?.tokens, 11)
            XCTAssertEqual(result.history.tokens, 24)
            XCTAssertEqual(result.page.trend.totalTokens, scope == .all ? 11 : 0)
            XCTAssertFalse(result.page.sessions.contains { $0.sourceID == ToolUsageClient.openCode.rawValue })
        }
    }

    func testSelectedCacheDoesNotReplaceOrDuplicateAnEnabledSource() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let enabled = self.snapshot(client: .openCode, today: 37, yesterday: 17, now: now, calendar: calendar)
        let staleCache = self.snapshot(client: .openCode, today: 90, yesterday: 80, now: now, calendar: calendar)
        let result = MenuMonitorPresentation.build(costSummary: .empty, records: nil,
            toolSnapshots: [.openCode: enabled], selectedToolSnapshot: staleCache,
            modelUsage: [], runningThreads: .empty,
            period: .today, scope: .client(.openCode), codexSessions: [], recentCodexSessions: [],
            recentSessionLimit: 5, now: now, calendar: calendar)
        XCTAssertEqual(result.aggregates[.client(.openCode)]?.tokens, 37)
        XCTAssertEqual(result.aggregates[.all]?.tokens, 37)
        XCTAssertEqual(result.history.tokens, 54)
        XCTAssertEqual(result.page.trend.totalTokens, 37)
        XCTAssertEqual(result.page.sessions.reduce(0) { $0 + $1.totalTokens }, 37)
    }

    func testLargeProjectionRunsOffMainAndKeepsPeriodAndSourceTotals() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedCalendar = calendar
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: day)!
        let count = 6_000
        let records = (0..<count).map { index in
            ToolUsageRecord(id: "record-\(index)", timestamp: index.isMultiple(of: 2) ? day : yesterday,
                modelID: "model-\(index % 12)", sessionID: "session-\(index % 300)",
                projectPath: "/fixture/project-\(index % 20)", inputTokens: 10, totalTokens: 10, costUSD: 0.01)
        }
        let snapshot = ToolUsageSnapshot(client: .openCode, availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: day, totalTokens: 30_000, costUSD: 30),
                           ToolUsageDailyEntry(date: yesterday, totalTokens: 30_000, costUSD: 30)],
            usageRecords: records)
        let started = Date()
        let result = await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return MenuMonitorPresentation.build(costSummary: .empty, records: nil,
                toolSnapshots: [.openCode: snapshot], modelUsage: [], runningThreads: .empty,
                period: .today, scope: .client(.openCode), codexSessions: [], recentCodexSessions: [],
                recentSessionLimit: 5, now: now, calendar: fixedCalendar)
        }.value
        print("Menu projection: 6000 records in \(Date().timeIntervalSince(started)) seconds (background)")
        XCTAssertEqual(result.aggregates[.all]?.tokens, 30_000)
        XCTAssertEqual(result.aggregates[.client(.openCode)]?.tokens, 30_000)
        XCTAssertEqual(result.aggregates[.codex]?.tokens, 0)
        XCTAssertEqual(result.history.tokens, 60_000)
        XCTAssertEqual(result.page.sessions.reduce(0) { $0 + $1.totalTokens }, 30_000)
        XCTAssertEqual(result.page.models?.reduce(0) { $0 + $1.totalTokens }, 30_000)
        XCTAssertEqual(result.page.projects.reduce(0) { $0 + $1.totalTokens }, 30_000)
        XCTAssertEqual(result.sessionsByProject.values.reduce(0) { $0 + $1.count }, result.page.sessions.count)
        for project in result.page.projects {
            XCTAssertEqual(result.sessionsByProject[project.cwd]?.reduce(0) { $0 + $1.totalTokens }, project.totalTokens)
        }
    }

    private func snapshot(client: ToolUsageClient, today: Int, yesterday: Int,
                          now: Date, calendar: Calendar) -> ToolUsageSnapshot {
        let day = calendar.startOfDay(for: now)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: day)!
        return ToolUsageSnapshot(client: client, availability: .ready,
            dailyEntries: [ToolUsageDailyEntry(date: day, totalTokens: today, costUSD: 0.01),
                           ToolUsageDailyEntry(date: previousDay, totalTokens: yesterday, costUSD: 0.01)],
            usageRecords: [
                ToolUsageRecord(id: "\(client.rawValue)-today", timestamp: day,
                    modelID: "fixture-model", sessionID: "fixture-session", projectPath: "/fixture/project",
                    inputTokens: today, totalTokens: today, costUSD: 0.01),
                ToolUsageRecord(id: "\(client.rawValue)-yesterday", timestamp: previousDay,
                    modelID: "fixture-model", sessionID: "fixture-session", projectPath: "/fixture/project",
                    inputTokens: yesterday, totalTokens: yesterday, costUSD: 0.01)
            ])
    }
}
