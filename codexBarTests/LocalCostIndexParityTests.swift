import XCTest

final class LocalCostIndexParityTests: XCTestCase {
    func testIncrementalIndexMatchesLegacyLedgerForNativeForkAndSubagentUsage() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cost-index-parity-\(UUID().uuidString)", isDirectory: true)
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sessions = codexRoot.appendingPathComponent("sessions/2026/04/05", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try self.write(lines: [
            #"{"payload":{"type":"session_meta","id":"parent","timestamp":"2026-04-05T08:00:00Z"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            #"{"timestamp":"2026-04-05T08:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
        ], to: sessions.appendingPathComponent("parent.jsonl"))

        try self.write(lines: [
            #"{"payload":{"type":"session_meta","id":"fork","timestamp":"2026-04-05T08:15:00Z","forked_from_id":"parent"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-04-05T08:16:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30}}}}"#,
            #"{"timestamp":"2026-04-05T08:17:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":35,"output_tokens":40}}}}"#,
        ], to: sessions.appendingPathComponent("fork.jsonl"))

        try self.write(lines: [
            #"{"payload":{"type":"session_meta","id":"subagent","timestamp":"2026-04-05T09:00:00Z","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.6-terra"}}"#,
            #"{"timestamp":"2026-04-05T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50},"last_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50}}}}"#,
            #"{"payload":{"type":"session_meta","id":"subagent","timestamp":"2026-04-05T09:00:00Z","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
            #"{"type":"inter_agent_communication_metadata","payload":{"kind":"start"}}"#,
            #"{"timestamp":"2026-04-05T09:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":540,"cached_input_tokens":110,"output_tokens":60}}}}"#,
        ], to: sessions.appendingPathComponent("subagent.jsonl"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let now = ISO8601Parsing.parse("2026-04-05T12:00:00Z") ?? Date()
        let legacyStore = SessionLogStore(
            codexRootURL: codexRoot,
            persistedCacheURL: home.appendingPathComponent("legacy-session-cache.json"),
            persistedUsageLedgerURL: home.appendingPathComponent("legacy-ledger.json")
        )
        let legacy = LocalCostSummaryService(
            sessionLogStore: legacyStore,
            calendar: calendar,
            useIncrementalIndex: false
        ).load(now: now)

        let indexStore = try LocalCostIndexStore(
            databaseURL: home.appendingPathComponent("cost-usage.sqlite"),
            calendar: calendar
        )
        let scanner = LocalCostIncrementalScanner(codexRootURL: codexRoot, store: indexStore)
        _ = try scanner.scan(budget: .unbounded)
        let indexed = try indexStore.summary(now: now).summary

        XCTAssertEqual(indexed.todayTokens, legacy.todayTokens)
        XCTAssertEqual(indexed.last30DaysTokens, legacy.last30DaysTokens)
        XCTAssertEqual(indexed.lifetimeTokens, legacy.lifetimeTokens)
        XCTAssertEqual(indexed.todayCostUSD, legacy.todayCostUSD, accuracy: 1e-12)
        XCTAssertEqual(indexed.last30DaysCostUSD, legacy.last30DaysCostUSD, accuracy: 1e-12)
        XCTAssertEqual(indexed.lifetimeCostUSD, legacy.lifetimeCostUSD, accuracy: 1e-12)
        XCTAssertEqual(indexed.dailyEntries.map(\.totalTokens), legacy.dailyEntries.map(\.totalTokens))
    }

    private func write(lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
