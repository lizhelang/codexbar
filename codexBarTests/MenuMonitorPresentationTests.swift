import XCTest

final class MenuMonitorPresentationTests: XCTestCase {
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
}
