import Foundation
import XCTest
@testable import codexbar

@MainActor
final class UsageDashboardDataTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value + "T12:00:00Z")! }

    private func fixture(period: UsagePeriod = .thisMonth, scope: UsageScope = .all) -> UsageDashboardProjection {
        let current = self.date("2026-10-01")
        var codex = LocalCostSummary.empty
        codex.updatedAt = self.date("2026-10-02")
        codex.dailyEntries = [
            .init(id: "old", date: self.date("2025-12-31"), costUSD: 1, totalTokens: 100),
            .init(id: "current", date: current, costUSD: 2, totalTokens: 200)
        ]
        let model = MonitorModelUsage(modelID: "gpt-fixture", inputTokens: 150, cachedInputTokens: 0, outputTokens: 50, totalTokens: 200, estimatedCostUSD: 2, lastUsedDay: current)
        let tools: [ToolUsageClient: ToolUsageSnapshot] = [.openCode: ToolUsageSnapshot(
            client: .openCode, availability: .ready,
            dailyEntries: [.init(date: self.date("2026-09-30"), totalTokens: 300, costUSD: 3), .init(date: current, totalTokens: 400, costUSD: 4)],
            usageRecords: [.init(id: "prior", timestamp: self.date("2026-09-30"), modelID: "claude-fixture", totalTokens: 300, costUSD: 3),
                           .init(id: "now", timestamp: current, modelID: "deepseek-fixture", totalTokens: 400, costUSD: 4)]
        )]
        return .build(codex: codex, tools: tools, codexModels: [model], period: period, scope: scope, year: 2026, now: self.date("2026-10-02"), calendar: self.calendar)
    }

    func testSelectedPeriodAndToolFilterDoNotMixOtherHistoryIntoRankings() {
        let all = self.fixture()
        XCTAssertEqual(all.aggregate.tokens, 600)
        XCTAssertTrue(all.aggregate.costIsComplete, "Explicitly disabled tools are outside the selected aggregate")
        XCTAssertEqual(Set(all.models.map(\.modelID)), Set(["gpt-fixture", "deepseek-fixture"]))
        XCTAssertEqual(all.activeDayCount, 1)
        XCTAssertEqual(all.annualActiveDays, 2, "Annual activity remains visible when the month changes")
        XCTAssertEqual(all.availableYears, [2026, 2025])
        XCTAssertEqual(all.chartEntries.count, 2)
        let openCode = self.fixture(scope: .client(.openCode))
        XCTAssertEqual(openCode.aggregate.tokens, 400)
        XCTAssertTrue(openCode.aggregate.costIsComplete, "Known single-tool cost must not depend on unrelated tools")
        XCTAssertEqual(openCode.aggregate.knownCostUSD, 4)
        XCTAssertEqual(openCode.models.map(\.modelID), ["deepseek-fixture"])
        XCTAssertEqual(openCode.tools.map(\.scope), [.client(.openCode)])
    }

    func testProjectionIdentityPreventsOldStatisticsBeingRelabeledAfterSelectionChanges() {
        let projection = self.fixture()
        XCTAssertTrue(projection.matches(period: .thisMonth, scope: .all, year: 2026))
        XCTAssertFalse(projection.matches(period: .allTime, scope: .all, year: 2026))
        XCTAssertFalse(projection.matches(period: .thisMonth, scope: .codex, year: 2026))
        XCTAssertFalse(projection.matches(period: .thisMonth, scope: .all, year: 2025))
    }

    func testAnnualHeatmapIncludesLeapDayAndExcludesNeighborYearCells() {
        let now = self.date("2024-12-31")
        var summary = LocalCostSummary.empty
        summary.dailyEntries = [.init(id: "leap", date: self.date("2024-02-29"), costUSD: 1, totalTokens: 500)]
        let projection = UsageDashboardProjection.build(codex: summary, tools: [:], codexModels: [], period: .allTime, year: 2024, now: now, calendar: self.calendar)
        let valid = projection.annualWeeks.flatMap { $0 }.filter(\.isInYear)
        XCTAssertEqual(valid.count, 366)
        XCTAssertEqual(valid.first { self.calendar.component(.month, from: $0.date) == 2 && self.calendar.component(.day, from: $0.date) == 29 }?.usage.tokens, 500)
        XCTAssertEqual(projection.annualActiveDays, 1)
    }

    func testMissingIndexDoesNotCreateDatabaseOrScanSessionFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projection = try await UsageDashboardProjectionWorker().project(codex: .empty, tools: [:], indexURL: root.appendingPathComponent("index.sqlite"), pricing: [:], period: .last7Days, year: 2026, now: self.date("2026-10-02"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(projection.aggregate.tokens, 0)
        XCTAssertEqual(projection.chartEntries.count, 7)
    }

    func testRenderSyntheticDashboardPreviews() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/codexbar-dashboard-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for trends in [false, true] {
            let data = try XCTUnwrap(UsageDashboardPreviewRenderer.png(projection: self.fixture(), period: .thisMonth, year: 2026, trends: trends))
            try data.write(to: directory.appendingPathComponent(trends ? "dashboard-trends.png" : "dashboard-overview.png"))
        }
        let compact = try XCTUnwrap(UsageDashboardPreviewRenderer.png(projection: self.fixture(), period: .thisMonth, year: 2026, size: CGSize(width: 820, height: 620)))
        try compact.write(to: directory.appendingPathComponent("dashboard-minimum.png"))
    }
}
