import AppKit
import XCTest
@testable import codexbar

@MainActor
final class UsageDashboardLayoutTests: CodexBarTestCase {
    func testDashboardKeepsCompleteSnapshotWhileSelectionChanges() {
        let projection = self.fixture()
        let model = UsageDashboardWindowModel(previewProjection: projection, period: .allTime, year: 2026)
        model.period = .thisWeek
        model.scope = .codex
        model.year = 2025
        XCTAssertEqual(model.currentProjection?.aggregate.tokens, projection.aggregate.tokens)
        XCTAssertEqual(model.currentProjection?.period, .allTime)
        XCTAssertEqual(model.currentProjection?.scope, .all)
        XCTAssertEqual(model.currentProjection?.year, 2026)
    }

    func testCompactDashboardRendersAtBothWindowSizes() throws {
        XCTAssertNotEqual(CodexPaths.realHome.path, FileManager.default.homeDirectoryForCurrentUser.path)
        let suiteName = "codexbar.dashboard-layout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ApplicationPreferencesStore(defaults: defaults)
        preferences.update { $0.theme = .dark; $0.fontScale = 1 }
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-dashboard-compact-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in [CGSize(width: 820, height: 620), CGSize(width: 1100, height: 780)] {
            let data = try XCTUnwrap(UsageDashboardPreviewRenderer.png(
                projection: self.fixture(), period: .allTime, year: 2026, size: size, preferences: preferences
            ))
            let image = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertGreaterThan(data.count, 5_000)
            XCTAssertGreaterThanOrEqual(image.pixelsWide, Int(size.width))
            XCTAssertEqual(Double(image.pixelsWide) / Double(image.pixelsHigh), size.width / size.height, accuracy: 0.01)
            try data.write(to: output.appendingPathComponent("dashboard-\(Int(size.width))x\(Int(size.height)).png"))
        }
    }

    private func fixture() -> UsageDashboardProjection {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        var summary = LocalCostSummary.empty
        summary.dailyEntries = (0..<160).compactMap { offset in
            guard !offset.isMultiple(of: 11), let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            return .init(id: "fixture-\(offset)", date: date, costUSD: Double(10 + offset % 23), totalTokens: (10 + offset % 23) * 1_000_000)
        }
        let models = (0..<8).map { index in
            MonitorModelUsage(modelID: ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.5", "gpt-5.4", "fixture-small", "fixture-mini"][index],
                              inputTokens: 200_000_000 / (index + 1), cachedInputTokens: 180_000_000 / (index + 1),
                              outputTokens: 10_000_000 / (index + 1), totalTokens: 210_000_000 / (index + 1),
                              estimatedCostUSD: 400 / Double(index + 1), lastUsedDay: now)
        }
        let tools = Dictionary(uniqueKeysWithValues: ToolUsageClient.allCases.enumerated().map { index, client in
            (client, ToolUsageSnapshot(client: client, availability: .ready,
                                      dailyEntries: [.init(date: now, totalTokens: 30_000_000 / (index + 1), costUSD: 30 / Double(index + 1))]))
        })
        return .build(codex: summary, tools: tools, codexModels: models, period: .allTime, year: 2026, now: now, calendar: calendar)
    }
}
