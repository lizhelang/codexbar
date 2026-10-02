import Foundation
import SQLite3
import XCTest

private let openCodeFixtureTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class OpenCodeUsageCollectorTests: XCTestCase {
    func testCurrentDatabaseDeduplicatesRewrittenMessagesAndKeepsAllHistory() throws {
        let root = try self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("opencode.db")
        try self.withDatabase(databaseURL) { database in
            try self.createMessageTable("message", in: database)
            try self.createMessageTable("session_message", in: database)
            try self.insert(
                id: "rewritten", table: "message", created: self.millis("2026-01-03T02:00:00Z"),
                updated: self.millis("2026-01-03T02:01:00Z"),
                object: self.assistant(input: 10, output: 2, reasoning: 1, cacheRead: 3, cacheWrite: 1, total: 17, cost: 0.01),
                in: database
            )
            try self.insert(
                id: "rewritten", table: "session_message", created: self.millis("2026-01-03T02:00:00Z"),
                updated: self.millis("2026-01-03T02:02:00Z"),
                object: self.assistant(input: 20, output: -5, reasoning: 8, cacheRead: 4, cacheWrite: 1, total: 28, cost: 0.02),
                in: database
            )
            try self.insert(
                id: "newer-day", table: "message", created: self.millis("2026-09-29T23:30:00Z"),
                updated: self.millis("2026-09-29T23:31:00Z"),
                object: self.assistant(input: 5, output: 3, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 8, cost: nil),
                in: database
            )
            try self.insert(
                id: "user-message", table: "message", created: self.millis("2026-09-29T23:32:00Z"),
                updated: self.millis("2026-09-29T23:32:00Z"),
                object: ["role": "user", "tokens": ["input": 9999]], in: database
            )
        }

        let originalDatabase = try Data(contentsOf: databaseURL)
        let now = self.date("2026-09-30T00:00:00Z")
        let snapshot = OpenCodeUsageCollector(dataDirectory: root, databaseURL: databaseURL)
            .collect(now: now, calendar: self.utcCalendar)

        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.evidence, .reported)
        XCTAssertEqual(snapshot.refreshedAt, now)
        XCTAssertEqual(snapshot.dailyEntries.count, 2)
        XCTAssertEqual(snapshot.dailyEntries.map(\.totalTokens), [28, 8])
        XCTAssertEqual(snapshot.dailyEntries[0].inputTokens, 20)
        XCTAssertEqual(snapshot.dailyEntries[0].outputTokens, 3)
        XCTAssertEqual(snapshot.dailyEntries[0].cacheReadTokens, 4)
        XCTAssertEqual(snapshot.dailyEntries[0].cacheWriteTokens, 1)
        XCTAssertEqual(snapshot.dailyEntries[0].costUSD, 0.02)
        XCTAssertNil(snapshot.dailyEntries[1].costUSD)
        XCTAssertEqual(snapshot.latestUsageAt, self.date("2026-09-29T23:30:00Z"))
        XCTAssertEqual(try Data(contentsOf: databaseURL), originalDatabase)
    }

    func testSessionMessageOnlySchemaAndMissingNativeTotal() throws {
        let root = try self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("opencode.db")
        try self.withDatabase(databaseURL) { database in
            try self.createMessageTable("session_message", in: database)
            try self.insert(
                id: "only", table: "session_message", created: self.millis("2026-04-01T02:00:00Z"),
                updated: self.millis("2026-04-01T02:01:00Z"),
                object: self.assistant(input: 11, output: 4, reasoning: 2, cacheRead: 5, cacheWrite: 1, total: nil, cost: 0),
                in: database
            )
        }

        let snapshot = OpenCodeUsageCollector(dataDirectory: root).collect(
            now: self.date("2026-04-02T00:00:00Z"), calendar: self.utcCalendar
        )
        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.dailyEntries.count, 1)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 23)
        XCTAssertEqual(snapshot.dailyEntries[0].outputTokens, 6)
        XCTAssertNil(snapshot.dailyEntries[0].costUSD, "Unknown custom model cost 0 is not proof of free usage")
    }

    func testDailyCostIsUnknownWhenAnyMessageOmitsCost() throws {
        let root = try self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("opencode.db")
        try self.withDatabase(databaseURL) { database in
            try self.createMessageTable("message", in: database)
            for (id, timestamp, cost) in [
                ("mixed-reported", "2026-05-01T02:00:00Z", 0.5 as Double?),
                ("mixed-unknown", "2026-05-01T03:00:00Z", nil),
                ("known-one", "2026-05-02T02:00:00Z", 0.1),
                ("known-two", "2026-05-02T03:00:00Z", 0.2),
            ] {
                let created = self.millis(timestamp)
                try self.insert(
                    id: id, table: "message", created: created, updated: created,
                    object: self.assistant(
                        input: 10, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0,
                        total: 11, cost: cost
                    ),
                    in: database
                )
            }
        }

        let snapshot = OpenCodeUsageCollector(dataDirectory: root).collect(calendar: self.utcCalendar)
        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.dailyEntries.count, 2)
        XCTAssertNil(snapshot.dailyEntries[0].costUSD)
        XCTAssertEqual(snapshot.dailyEntries[1].costUSD ?? -1, 0.3, accuracy: 1e-12)
    }

    func testLegacyStorageMessageJSONAndDatabaseRecordShareMessageID() throws {
        let root = try self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("opencode.db")
        let time = self.millis("2026-05-02T04:00:00Z")
        try self.withDatabase(databaseURL) { database in
            try self.createMessageTable("message", in: database)
            try self.insert(
                id: "shared", table: "message", created: time, updated: time + 1_000,
                object: self.assistant(input: 100, output: 10, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 110, cost: 0.1),
                in: database
            )
        }
        let legacyDirectory = root.appendingPathComponent("storage/message/session-one", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let later = self.assistant(input: 150, output: 20, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 170, cost: 0.15)
            .merging(["id": "shared", "sessionID": "session-one", "time": ["created": time, "completed": time], "time_updated": time + 2_000]) { _, new in new }
        try self.writeJSON(later, to: legacyDirectory.appendingPathComponent("shared.json"))
        let separate = self.assistant(input: 2, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 3, cost: nil)
            .merging(["role": "assistant", "time": ["created": time + 3_000]]) { _, new in new }
        try self.writeJSON(separate, to: legacyDirectory.appendingPathComponent("legacy-only.json"))

        let snapshot = OpenCodeUsageCollector(dataDirectory: root).collect(calendar: self.utcCalendar)
        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.dailyEntries.count, 1)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 173)
        XCTAssertNil(snapshot.dailyEntries[0].costUSD)
    }

    func testMissingEmptyAndUnreadableSourcesHaveDistinctStates() throws {
        let root = try self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = OpenCodeUsageCollector(dataDirectory: root)
        XCTAssertEqual(collector.collect(calendar: self.utcCalendar).availability, .sourceMissing)

        let databaseURL = root.appendingPathComponent("opencode.db")
        try self.withDatabase(databaseURL) { database in
            try self.createMessageTable("message", in: database)
            try self.insert(
                id: "user-only", table: "message", created: self.millis("2026-05-01T00:00:00Z"),
                updated: self.millis("2026-05-01T00:00:00Z"),
                object: ["role": "user", "tokens": ["input": 100]], in: database
            )
        }
        XCTAssertEqual(collector.collect(calendar: self.utcCalendar).availability, .noRecords)

        try Data("not a sqlite database".utf8).write(to: databaseURL)
        let failed = collector.collect(calendar: self.utcCalendar)
        XCTAssertEqual(failed.availability, .failed)
        XCTAssertTrue(failed.dailyEntries.isEmpty)
        XCTAssertFalse(failed.statusDetail?.contains("sqlite") ?? true)
    }

    func testUnreadableDatabaseWithValidLegacyMessagesIsPartial() throws {
        let root = try self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a sqlite database".utf8).write(to: root.appendingPathComponent("opencode.db"))
        let legacyDirectory = root.appendingPathComponent("storage/message/session-one", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let timestamp = self.millis("2026-05-02T04:00:00Z")
        let legacy = self.assistant(
            input: 10, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0,
            total: 11, cost: 0.1
        ).merging(["id": "legacy-one", "sessionID": "session-one", "time": ["created": timestamp]]) { _, new in new }
        try self.writeJSON(legacy, to: legacyDirectory.appendingPathComponent("legacy-one.json"))

        let snapshot = OpenCodeUsageCollector(dataDirectory: root).collect(calendar: self.utcCalendar)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.dailyEntries.count, 1)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 11)
        XCTAssertEqual(snapshot.dailyEntries[0].costUSD, 0.1)
        XCTAssertEqual(snapshot.statusDetail, "部分 OpenCode 数据不可读")
    }

    func testPreservesModelSessionMetadataAndLatestTurnState() throws {
        let root = try self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("opencode.db")
        try self.withDatabase(databaseURL) { database in
            try self.createMessageTable("message", in: database)
            XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE session(id TEXT, title TEXT, directory TEXT); INSERT INTO session VALUES ('session-one', 'Recorded project title', '/project')", nil, nil, nil), SQLITE_OK)
            let at = self.millis("2026-09-30T02:00:00Z")
            let message = self.assistant(input: 10, output: 4, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 14, cost: 0.01)
                .merging(["modelID": "mimo-v2.5-pro", "finish": "stop"]) { _, newer in newer }
            try self.insert(id: "assistant", table: "message", created: at, updated: at, object: message, in: database)
            try self.insert(id: "new-turn", table: "message", created: at + 1_000, updated: at + 1_000, object: ["role": "user"], in: database)
        }
        let snapshot = OpenCodeUsageCollector(dataDirectory: root).collect(now: self.date("2026-10-01T00:00:00Z"), calendar: self.utcCalendar)
        let record = try XCTUnwrap(snapshot.usageRecords.first)
        XCTAssertEqual(record.modelID, "mimo-v2.5-pro")
        XCTAssertEqual(record.sessionID, "session-one")
        XCTAssertEqual(record.sessionTitle, "Recorded project title")
        XCTAssertEqual(record.projectPath, "/project")
        XCTAssertEqual(record.sessionIsRunning, true)
        XCTAssertEqual(record.totalTokens, 14)
        XCTAssertEqual(record.timestamp, self.date("2026-09-30T02:00:00Z"))
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-opencode-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func assistant(
        input: Int, output: Int, reasoning: Int, cacheRead: Int, cacheWrite: Int,
        total: Int?, cost: Double?
    ) -> [String: Any] {
        var tokens: [String: Any] = [
            "input": input, "output": output, "reasoning": reasoning,
            "cache": ["read": cacheRead, "write": cacheWrite],
        ]
        if let total { tokens["total"] = total }
        var object: [String: Any] = ["role": "assistant", "tokens": tokens]
        if let cost { object["cost"] = cost }
        return object
    }

    private func createMessageTable(_ table: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, "CREATE TABLE \(table) (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenCodeFixture", code: 1)
        }
    }

    private func insert(
        id: String, table: String, created: Int64, updated: Int64,
        object: [String: Any], in database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO \(table) (id, session_id, time_created, time_updated, data) VALUES (?, 'session-one', ?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw NSError(domain: "OpenCodeFixture", code: 2) }
        defer { sqlite3_finalize(statement) }
        let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) ?? "{}"
        _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, openCodeFixtureTransient) }
        sqlite3_bind_int64(statement, 2, created)
        sqlite3_bind_int64(statement, 3, updated)
        _ = json.withCString { sqlite3_bind_text(statement, 4, $0, -1, openCodeFixtureTransient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "OpenCodeFixture", code: 3) }
    }

    private func withDatabase(_ url: URL, body: (OpaquePointer) throws -> Void) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK,
              let database else { throw NSError(domain: "OpenCodeFixture", code: 4) }
        defer { sqlite3_close(database) }
        try body(database)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
    }

    private func millis(_ value: String) -> Int64 {
        Int64(self.date(value).timeIntervalSince1970 * 1_000)
    }
}
