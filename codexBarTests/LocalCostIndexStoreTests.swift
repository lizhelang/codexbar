import SQLite3
import XCTest

final class LocalCostIndexStoreTests: XCTestCase {
    func testStoreCreatesWALSchemaAndAggregateSnapshot() throws {
        let root = try self.makeRoot()
        let databaseURL = root.appendingPathComponent("cost-usage.sqlite")
        let store = try self.makeStore(databaseURL: databaseURL)
        let event = self.event(
            key: "wal|event",
            path: "/tmp/wal.jsonl",
            input: 100,
            cachedInput: 20,
            output: 20
        )

        try store.commitFileScan(
            LocalCostFileScanCommit(
                path: event.path,
                fileIdentifier: "inode-1",
                size: 128,
                modificationTime: self.date("2026-04-05T08:10:00Z"),
                parsedBytes: 128,
                anchorHash: "anchor",
                parserStateData: Data("{}".utf8),
                isComplete: true,
                replaceExistingEvents: true,
                events: [event]
            )
        )
        try store.updateProgress(
            LocalCostIndexProgress(
                state: .idle,
                processedBytes: 128,
                totalBytes: 128,
                completedFiles: 1,
                totalFiles: 1,
                lastSuccessfulScanAt: self.date("2026-04-05T08:11:00Z"),
                latestUsageEventAt: event.timestamp,
                errorMessage: nil
            )
        )
        let indexedFile = try XCTUnwrap(store.indexedFile(path: event.path))
        let summary = try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary

        XCTAssertEqual(indexedFile.parsedBytes, 128)
        XCTAssertEqual(indexedFile.isComplete, true)
        XCTAssertEqual(summary.todayTokens, 120)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.00101, accuracy: 1e-12)
        XCTAssertEqual(try self.sqliteText(databaseURL: databaseURL, sql: "PRAGMA journal_mode"), "wal")
        XCTAssertEqual(try self.sqliteInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','events','file_day_aggregates','day_aggregates','scan_metadata')"), 5)
    }

    func testReplacingFileScanRemovesOldEventsBeforeAggregating() throws {
        let root = try self.makeRoot()
        let store = try self.makeStore(databaseURL: root.appendingPathComponent("cost-usage.sqlite"))
        let path = "/tmp/replace.jsonl"
        try store.commitFileScan(
            LocalCostFileScanCommit(
                path: path,
                fileIdentifier: "inode-1",
                size: 256,
                modificationTime: self.date("2026-04-05T08:10:00Z"),
                parsedBytes: 256,
                anchorHash: "first",
                parserStateData: Data("{}".utf8),
                isComplete: true,
                replaceExistingEvents: true,
                events: [
                    self.event(key: "replace|first", path: path, input: 100, cachedInput: 0, output: 20),
                ]
            )
        )
        try store.rebuildAggregates()
        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 120)

        try store.commitFileScan(
            LocalCostFileScanCommit(
                path: path,
                fileIdentifier: "inode-1",
                size: 128,
                modificationTime: self.date("2026-04-05T08:12:00Z"),
                parsedBytes: 128,
                anchorHash: "second",
                parserStateData: Data("{}".utf8),
                isComplete: true,
                replaceExistingEvents: true,
                events: [
                    self.event(key: "replace|second", path: path, input: 50, cachedInput: 0, output: 10),
                ]
            )
        )
        try store.rebuildAggregates()

        let summary = try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary
        XCTAssertEqual(summary.lifetimeTokens, 60)
    }

    func testCustomPricingDoesNotInheritLongContextPremiumFromStoredRateClass() throws {
        let root = try self.makeRoot()
        let store = try self.makeStore(databaseURL: root.appendingPathComponent("cost-usage.sqlite"))
        let event = self.event(
            key: "custom-long-context",
            path: "/tmp/custom-long-context.jsonl",
            input: 300_000,
            cachedInput: 0,
            output: 10
        )
        try store.commitFileScan(
            LocalCostFileScanCommit(
                path: event.path,
                fileIdentifier: "inode-custom",
                size: 512,
                modificationTime: self.date("2026-04-05T08:10:00Z"),
                parsedBytes: 512,
                anchorHash: "custom",
                parserStateData: Data("{}".utf8),
                isComplete: true,
                replaceExistingEvents: true,
                events: [event]
            )
        )
        try store.rebuildAggregates()

        let summary = try store.summary(
            now: self.date("2026-04-05T12:00:00Z"),
            modelPricingOverrides: [
                "gpt-5.5": CodexBarModelPricing(
                    inputUSDPerToken: 1e-6,
                    cachedInputUSDPerToken: 1e-6,
                    outputUSDPerToken: 1e-6
                ),
            ]
        ).summary

        XCTAssertEqual(summary.lifetimeCostUSD, 0.30001, accuracy: 1e-12)
    }

    func testIncompatibleDerivedSchemaIsRebuiltSafely() throws {
        let root = try self.makeRoot()
        let databaseURL = root.appendingPathComponent("cost-usage.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE files (broken TEXT); PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try self.makeStore(databaseURL: databaseURL)
        let event = self.event(
            key: "rebuilt-schema",
            path: "/tmp/rebuilt-schema.jsonl",
            input: 10,
            cachedInput: 0,
            output: 2
        )
        try store.commitFileScan(
            LocalCostFileScanCommit(
                path: event.path,
                fileIdentifier: "inode-rebuilt",
                size: 64,
                modificationTime: self.date("2026-04-05T08:10:00Z"),
                parsedBytes: 64,
                anchorHash: "rebuilt",
                parserStateData: Data("{}".utf8),
                isComplete: true,
                replaceExistingEvents: true,
                events: [event]
            )
        )

        XCTAssertEqual(try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary.lifetimeTokens, 12)
        XCTAssertEqual(try self.sqliteInt(databaseURL: databaseURL, sql: "PRAGMA user_version"), LocalCostIndexStore.currentSchemaVersion)
    }

    func testPriorityEventsKeepPerEventRateAfterDailyAggregation() throws {
        let root = try self.makeRoot()
        let store = try self.makeStore(databaseURL: root.appendingPathComponent("cost-usage.sqlite"))
        let path = "/tmp/priority-aggregate.jsonl"
        let first = self.event(
            key: "priority-1",
            path: path,
            input: 200_000,
            cachedInput: 0,
            output: 10,
            serviceTier: .priority
        )
        let second = self.event(
            key: "priority-2",
            path: path,
            input: 200_000,
            cachedInput: 0,
            output: 10,
            serviceTier: .priority
        )
        try store.commitFileScan(
            LocalCostFileScanCommit(
                path: path,
                fileIdentifier: "inode-priority",
                size: 1_024,
                modificationTime: self.date("2026-04-05T08:10:00Z"),
                parsedBytes: 1_024,
                anchorHash: "priority",
                parserStateData: Data("{}".utf8),
                isComplete: true,
                replaceExistingEvents: true,
                events: [first, second]
            )
        )

        let summary = try store.summary(now: self.date("2026-04-05T12:00:00Z")).summary
        let expected = 400_000 * 1.25e-5 + 20 * 7.5e-5
        XCTAssertEqual(summary.lifetimeCostUSD, expected, accuracy: 1e-12)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-cost-index-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStore(databaseURL: URL) throws -> LocalCostIndexStore {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return try LocalCostIndexStore(databaseURL: databaseURL, calendar: calendar)
    }

    private func event(
        key: String,
        path: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        serviceTier: SessionLogStore.ServiceTier = .unknown
    ) -> LocalCostIndexedEvent {
        LocalCostIndexedEvent(
            eventKey: key,
            path: path,
            sessionID: "store-session",
            timestamp: self.date("2026-04-05T08:05:00Z"),
            model: "gpt-5.5",
            turnID: "turn-1",
            serviceTier: serviceTier,
            source: .nativeSession,
            usage: SessionLogStore.Usage(
                inputTokens: input,
                cachedInputTokens: cachedInput,
                outputTokens: output
            )
        )
    }

    private func sqliteText(databaseURL: URL, sql: String) throws -> String {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return String(cString: sqlite3_column_text(statement, 0))
    }

    private func sqliteInt(databaseURL: URL, sql: String) throws -> Int {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func date(_ value: String) -> Date {
        ISO8601Parsing.parse(value) ?? Date(timeIntervalSince1970: 0)
    }
}
