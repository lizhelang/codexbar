import Foundation
import XCTest

final class LocalCostSummaryServiceTests: CodexBarTestCase {
    func testLoadAggregatesSessionsAcrossFastAndSlowPaths() throws {
        let home = try self.makeCodexHome()
        let store = SessionLogStore(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            persistedCacheURL: home.appendingPathComponent(".codexbar/test-cost-session-cache.json")
        )
        let service = LocalCostSummaryService(
            sessionLogStore: store,
            calendar: self.utcCalendar()
        )

        try self.writeFastSession(
            directory: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            fileName: "today-fast.jsonl",
            id: "today-fast",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 50
        )
        try self.writeSlowSession(
            directory: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            fileName: "recent-slow.jsonl",
            id: "recent-slow",
            timestamp: "2026-04-03T09:00:00Z",
            model: "gpt-5-mini",
            inputTokens: 200,
            cachedInputTokens: 50,
            outputTokens: 40
        )
        try self.writeFastSession(
            directory: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            fileName: "unsupported.jsonl",
            id: "unsupported",
            timestamp: "2026-03-01T09:00:00Z",
            model: "unknown-model",
            inputTokens: 999,
            cachedInputTokens: 0,
            outputTokens: 999
        )

        let summary = service.load(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.todayTokens, 150)
        XCTAssertEqual(summary.last30DaysTokens, 390)
        XCTAssertEqual(summary.lifetimeTokens, 390)
        XCTAssertEqual(summary.dailyEntries.count, 2)

        XCTAssertEqual(summary.todayCostUSD, 0.000955, accuracy: 1e-12)
        XCTAssertEqual(summary.last30DaysCostUSD, 0.00107375, accuracy: 1e-12)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.00107375, accuracy: 1e-12)

        XCTAssertEqual(summary.dailyEntries[0].date, self.date("2026-04-05T00:00:00Z"))
        XCTAssertEqual(summary.dailyEntries[0].totalTokens, 150)
        XCTAssertEqual(summary.dailyEntries[0].costUSD, 0.000955, accuracy: 1e-12)

        XCTAssertEqual(summary.dailyEntries[1].date, self.date("2026-04-03T00:00:00Z"))
        XCTAssertEqual(summary.dailyEntries[1].totalTokens, 240)
        XCTAssertEqual(summary.dailyEntries[1].costUSD, 0.00011875, accuracy: 1e-12)
    }

    func testLoadRefreshesChangedSessionFileInsteadOfServingStaleCache() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sessionDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let cacheURL = home.appendingPathComponent(".codexbar/test-cost-session-cache.json")
        let store = SessionLogStore(codexRootURL: codexRoot, persistedCacheURL: cacheURL)
        let service = LocalCostSummaryService(
            sessionLogStore: store,
            calendar: self.utcCalendar()
        )

        try self.writeFastSession(
            directory: sessionDirectory,
            fileName: "mutable.jsonl",
            id: "mutable",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4-mini",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 20
        )

        let initialSummary = service.load(now: self.date("2026-04-05T12:00:00Z"))
        XCTAssertEqual(initialSummary.todayTokens, 120)
        XCTAssertEqual(initialSummary.todayCostUSD, 0.00015825, accuracy: 1e-12)

        try self.writeFastSession(
            directory: sessionDirectory,
            fileName: "mutable.jsonl",
            id: "mutable",
            timestamp: "2026-04-05T08:00:00Z",
            model: "gpt-5.4-mini",
            inputTokens: 200,
            cachedInputTokens: 10,
            outputTokens: 50
        )

        let updatedSummary = service.load(now: self.date("2026-04-05T12:00:00Z"))
        XCTAssertEqual(updatedSummary.todayTokens, 250)
        XCTAssertEqual(updatedSummary.todayCostUSD, 0.00036825, accuracy: 1e-12)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    private func makeCodexHome() throws -> URL {
        let home = try XCTUnwrap(self.temporaryHomeURL())
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func temporaryHomeURL() -> URL? {
        let home = ProcessInfo.processInfo.environment["CODEXBAR_HOME"]
        guard let home, home.isEmpty == false else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
    }

    private func writeFastSession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) throws {
        let content = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
            #"{"payload":{"type":"turn_context","model":"\#(model)"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":\#(inputTokens),"cached_input_tokens":\#(cachedInputTokens),"output_tokens":\#(outputTokens)}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(
            to: directory.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeSlowSession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) throws {
        let content = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
            #"{"payload":{"type":"turn_context","model":"\#(model)"}}"#,
            #"{"wrapper":{"type":"event_msg"},"payload":{"type":"token_count","kind":"token_count","info":{"total_token_usage": {"input_tokens": \#(inputTokens), "cached_input_tokens": \#(cachedInputTokens), "output_tokens": \#(outputTokens)}}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(
            to: directory.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
    }
}
