import SQLite3
import XCTest

final class SessionDisplayTitleTests: XCTestCase {
    func testMetadataPrefersDisplayNameAndSupportsOlderSchema() throws {
        let root = try self.makeRoot()
        let newest = root.appendingPathComponent("state_10.sqlite")
        try self.database(newest, sql: """
            CREATE TABLE threads (id TEXT, title TEXT, name TEXT, cwd TEXT, preview TEXT, agent_nickname TEXT, agent_role TEXT);
            INSERT INTO threads VALUES ('named', '# Files mentioned by the user:', 'Human task name', '/fixture/current', '', '', '');
            INSERT INTO threads VALUES ('agent', '', '', '/fixture/agent', '', 'review_worker', 'reviewer');
            INSERT INTO threads VALUES ('preview', '', '', '/fixture/preview', 'Cached summary', '', '');
            """)
        try self.database(root.appendingPathComponent("state_9.sqlite"), sql: """
            CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT);
            INSERT INTO threads VALUES ('named', 'Old title', '/fixture/old');
            INSERT INTO threads VALUES ('legacy', 'Legacy name', '/fixture/legacy');
            """)
        // An unfinished newer version must not hide a valid older database.
        try self.database(root.appendingPathComponent("state_11.sqlite"), sql: "CREATE TABLE unrelated (id TEXT);")
        let metadata = CodexSessionMetadataStore(codexRootURL: root).load()
        XCTAssertEqual(metadata["named"]?.title, "Human task name")
        XCTAssertEqual(metadata["named"]?.projectPath, "/fixture/current")
        XCTAssertEqual(metadata["legacy"]?.title, "Legacy name")
        XCTAssertTrue(metadata["agent"]?.title?.contains("review_worker") == true)
        XCTAssertEqual(metadata["preview"]?.title, "Cached summary")
    }

    func testCompactNameIndexSuppliesLatestNamesWithoutRollouts() throws {
        let root = try self.makeRoot()
        try self.database(root.appendingPathComponent("state_5.sqlite"), sql: """
            CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT);
            INSERT INTO threads VALUES ('indexed', '# Files mentioned by the user:', '/fixture');
            """)
        let entries: [[String: String]] = [
            ["id": "indexed", "thread_name": "Renamed task", "updated_at": "2026-10-01T00:00:00.100Z"],
            ["id": "indexed", "thread_name": "Older task", "updated_at": "2026-10-01T00:00:00Z"],
            ["id": "index-only", "thread_name": "Archived task", "updated_at": "2026-10-01T01:00:00Z"],
        ]
        var data = Data("invalid partial entry\n".utf8)
        for entry in entries { data.append(try JSONSerialization.data(withJSONObject: entry)); data.append(10) }
        try data.write(to: root.appendingPathComponent("session_index.jsonl"))
        let metadata = CodexSessionMetadataStore(codexRootURL: root).load()
        XCTAssertEqual(metadata["indexed"]?.title, "Renamed task")
        XCTAssertEqual(metadata["index-only"]?.title, "Archived task")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions").path))
    }

    func testAttachmentAndIdentifierFallbacksAreNotDisplayedAsTitles() {
        let id = "01234567-abcd-4567-abcd-0123456789ab"
        XCTAssertNil(SessionDisplayTitle.cleaned("# Files mentioned by the user:\n## image.png: /private/image.png", sessionID: id))
        XCTAssertNil(SessionDisplayTitle.cleaned(id, sessionID: id))
        XCTAssertNil(SessionDisplayTitle.cleaned(String(id.prefix(12)), sessionID: id))
        XCTAssertEqual(SessionDisplayTitle.cleaned("# Files mentioned by the user:\n## image.png\n## My request:\nRepair the menu layout\n<image name=fixture>", sessionID: id), "Repair the menu layout")
        XCTAssertEqual(SessionDisplayTitle.preferred([nil, ""], sessionID: id), SessionDisplayTitle.unnamed)
    }

    func testCachedMetadataRestoresIndexedTitleAndSurvivesRuntimeWrapper() {
        let now = Date(timeIntervalSince1970: 1_790_800_000)
        let record = HistoricalSessionRecord(sessionID: "fixture", modelID: "gpt", startedAt: now,
            lastActivityAt: now, isArchived: false, totalTokens: 100, title: "Human task name", projectPath: "/fixture")
        let cached = RecordsSnapshot(generatedAt: now, refreshMode: .incremental, models: [], sessions: [record], warnings: [])
        let indexed = MonitorCodexSessionUsage(sessionID: "fixture", title: nil, projectPath: "/fixture", modelIDs: ["gpt"],
            firstUsageAt: now, lastActivityAt: now, totalTokens: 20, knownCostUSD: 1, costIsComplete: true)
        let running = OpenAIRunningThreadAttribution(threads: [
            .init(threadID: "fixture", source: "cli", cwd: "/fixture", title: "# Files mentioned by the user:", lastRuntimeAt: now, accountID: nil),
        ], summary: .empty, recentActivityWindow: 5, diagnosticMessage: nil, unavailableReason: nil)
        let data = MonitorPageData.build(costSummary: .empty, records: cached, toolSnapshots: [:], modelUsage: nil,
            runningThreads: running, period: .allTime, scope: .all, codexSessions: [indexed], now: now)
        XCTAssertEqual(data.sessions.first?.title, "Human task name")
        XCTAssertEqual(data.sessions.first?.totalTokens, 20)
    }

    func testUntitledIndexedSessionHasExplicitFallback() {
        let now = Date()
        let indexed = MonitorCodexSessionUsage(sessionID: "01234567-abcd-4567-abcd-0123456789ab", title: nil,
            projectPath: nil, modelIDs: [], firstUsageAt: now, lastActivityAt: now,
            totalTokens: 2, knownCostUSD: 0, costIsComplete: false)
        let data = MonitorPageData.build(costSummary: .empty, records: nil, toolSnapshots: [:], modelUsage: nil,
            runningThreads: .empty, period: .allTime, scope: .all, codexSessions: [indexed], now: now)
        XCTAssertEqual(data.sessions.first?.title, SessionDisplayTitle.unnamed)
    }

    func testRunningSessionKeepsDisplayNameAheadOfFirstMessage() {
        let now = Date()
        let record = HistoricalSessionRecord(sessionID: "fixture", modelID: "gpt", startedAt: now,
            lastActivityAt: now, isArchived: false, totalTokens: 100,
            title: "Original first message", projectPath: "/fixture")
        let cached = RecordsSnapshot(generatedAt: now, refreshMode: .incremental, models: [],
            sessions: [record], warnings: [])
        let indexed = MonitorCodexSessionUsage(sessionID: "fixture", title: "Renamed task",
            projectPath: "/fixture", modelIDs: ["gpt"], firstUsageAt: now, lastActivityAt: now,
            totalTokens: 20, knownCostUSD: 1, costIsComplete: true)
        let running = OpenAIRunningThreadAttribution(threads: [
            .init(threadID: "fixture", source: "cli", cwd: "/fixture", title: "Original first message",
                  lastRuntimeAt: now, accountID: nil),
        ], summary: .empty, recentActivityWindow: 5, diagnosticMessage: nil, unavailableReason: nil)
        let data = MonitorPageData.build(costSummary: .empty, records: cached, toolSnapshots: [:],
            modelUsage: nil, runningThreads: running, period: .allTime, scope: .all,
            codexSessions: [indexed], now: now)
        XCTAssertEqual(data.sessions.first?.title, "Renamed task")
        XCTAssertTrue(data.sessions.first?.isRunning == true)
        XCTAssertEqual(data.sessions.first?.totalTokens, 20)
    }

    func testExternalSessionUsesNewestValidTitleRegardlessOfRecordOrder() {
        let now = Date()
        let records = [
            ToolUsageRecord(id: "new", timestamp: now.addingTimeInterval(-1), sessionID: "fixture",
                sessionTitle: "Renamed external task", totalTokens: 20),
            ToolUsageRecord(id: "wrapper", timestamp: now, sessionID: "fixture",
                sessionTitle: "# Files mentioned by the user:", totalTokens: 30),
            ToolUsageRecord(id: "old", timestamp: now.addingTimeInterval(-2), sessionID: "fixture",
                sessionTitle: "Original first message", totalTokens: 10),
        ]
        for ordered in [records, Array(records.reversed())] {
            let snapshot = ToolUsageSnapshot(client: .openCode, availability: .ready, usageRecords: ordered)
            let data = MonitorPageData.build(costSummary: .empty, records: nil,
                toolSnapshots: [.openCode: snapshot], modelUsage: nil, runningThreads: .empty,
                period: .allTime, scope: .all, now: now)
            XCTAssertEqual(data.sessions.first?.title, "Renamed external task")
            XCTAssertEqual(data.sessions.first?.totalTokens, 60)
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-title-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func database(_ url: URL, sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }
}
