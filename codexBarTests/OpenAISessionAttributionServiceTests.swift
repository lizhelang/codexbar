import Foundation
import XCTest

final class OpenAISessionAttributionServiceTests: CodexBarTestCase {
    func testLoadAttributesSessionsUsingLatestPrecedingActivation() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sessionStore = SessionLogStore(
            codexRootURL: codexRoot,
            persistedCacheURL: home.appendingPathComponent(".codexbar/test-attribution-cache.json")
        )
        let journalStore = SwitchJournalStore(
            fileURL: home.appendingPathComponent(".codexbar/switch-journal.jsonl")
        )
        let service = OpenAILiveSessionAttributionService(
            sessionLogStore: sessionStore,
            switchJournalStore: journalStore
        )

        try journalStore.appendActivation(
            providerID: "openai-oauth",
            accountID: "acct_a",
            timestamp: self.date("2026-04-05T08:00:00Z")
        )
        try journalStore.appendActivation(
            providerID: "openai-oauth",
            accountID: "acct_b",
            previousAccountID: "acct_a",
            reason: .autoThreshold,
            automatic: true,
            timestamp: self.date("2026-04-05T09:30:00Z")
        )

        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "session-a.jsonl",
            id: "session-a",
            timestamp: "2026-04-05T09:00:00Z",
            modificationDate: self.date("2026-04-05T11:45:00Z")
        )
        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "session-b.jsonl",
            id: "session-b",
            timestamp: "2026-04-05T10:00:00Z",
            modificationDate: self.date("2026-04-05T11:50:00Z")
        )

        let attribution = service.load(
            now: self.date("2026-04-05T12:00:00Z"),
            recentActivityWindow: OpenAILiveSessionAttributionService.defaultRecentActivityWindow
        )

        XCTAssertEqual(attribution.inUseSessionCounts["acct_a"], 1)
        XCTAssertEqual(attribution.inUseSessionCounts["acct_b"], 1)
        XCTAssertEqual(attribution.totalInUseSessionCount, 2)
        XCTAssertEqual(attribution.unknownSessionCount, 0)
    }

    func testSnapshotIgnoresUnattributedArchivedAndInactiveSessions() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let sessionStore = SessionLogStore(
            codexRootURL: codexRoot,
            persistedCacheURL: home.appendingPathComponent(".codexbar/test-attribution-cache.json")
        )
        let journalStore = SwitchJournalStore(
            fileURL: home.appendingPathComponent(".codexbar/switch-journal.jsonl")
        )
        let service = OpenAILiveSessionAttributionService(
            sessionLogStore: sessionStore,
            switchJournalStore: journalStore
        )

        try journalStore.appendActivation(
            providerID: "openai-oauth",
            accountID: "acct_a",
            timestamp: self.date("2026-04-05T08:00:00Z")
        )

        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "fresh.jsonl",
            id: "fresh",
            timestamp: "2026-04-05T10:00:00Z",
            modificationDate: self.date("2026-04-05T11:40:00Z")
        )
        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "stale.jsonl",
            id: "stale",
            timestamp: "2026-04-05T09:00:00Z",
            modificationDate: self.date("2026-04-05T10:30:00Z")
        )
        try self.writeSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "unknown.jsonl",
            id: "unknown",
            timestamp: "2026-04-05T07:00:00Z",
            modificationDate: self.date("2026-04-05T11:55:00Z")
        )
        try self.writeSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "archived.jsonl",
            id: "archived",
            timestamp: "2026-04-05T10:30:00Z",
            modificationDate: self.date("2026-04-05T11:55:00Z")
        )

        let attribution = service.load(
            now: self.date("2026-04-05T12:00:00Z"),
            recentActivityWindow: OpenAILiveSessionAttributionService.defaultRecentActivityWindow
        )

        XCTAssertEqual(attribution.inUseSessionCounts["acct_a"], 1)
        XCTAssertEqual(attribution.totalInUseSessionCount, 1)
        XCTAssertEqual(attribution.unknownSessionCount, 1)
        XCTAssertEqual(attribution.sessions.count, 2)
    }

    func testLiveSummaryExpiresSessionsAfterActivityWindow() {
        let attribution = OpenAILiveSessionAttribution(
            sessions: [
                .init(
                    sessionID: "fresh-attributed",
                    startedAt: self.date("2026-04-05T10:00:00Z"),
                    lastActivityAt: self.date("2026-04-05T11:40:00Z"),
                    accountID: "acct_a"
                ),
                .init(
                    sessionID: "fresh-unknown",
                    startedAt: self.date("2026-04-05T10:10:00Z"),
                    lastActivityAt: self.date("2026-04-05T11:55:00Z"),
                    accountID: nil
                ),
                .init(
                    sessionID: "expired",
                    startedAt: self.date("2026-04-05T09:00:00Z"),
                    lastActivityAt: self.date("2026-04-05T10:30:00Z"),
                    accountID: "acct_a"
                ),
            ],
            inUseSessionCounts: ["acct_a": 2],
            unknownSessionCount: 1,
            recentActivityWindow: OpenAILiveSessionAttributionService.defaultRecentActivityWindow
        )

        let summary = attribution.liveSummary(now: self.date("2026-04-05T12:00:00Z"))

        XCTAssertEqual(summary.inUseSessionCount(for: "acct_a"), 1)
        XCTAssertEqual(summary.totalInUseSessionCount, 1)
        XCTAssertEqual(summary.unknownSessionCount, 1)
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

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
    }

    private func writeSession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        modificationDate: Date
    ) throws {
        let fileURL = directory.appendingPathComponent(fileName)
        let content = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: fileURL.path
        )
    }
}
