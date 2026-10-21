import Foundation
import SQLite3
import XCTest
@testable import codexbar

final class AntigravityUsageCollectorTests: CodexBarTestCase {
    private var root: URL { CodexPaths.realHome.appendingPathComponent("antigravity") }
    private var now: Date { ISO8601Parsing.parse("2026-10-20T12:00:00Z")! }

    func testReportedTokensUseEventTimeAndRequestedTimeZone() throws {
        let beforeMidnight = self.row(step: 1, time: "2026-10-19T12:55:00Z", input: 10, output: 3, cache: 100)
        let afterMidnight = self.row(step: 2, time: "2026-10-19T13:05:00Z", input: 20, output: 4, cache: 200)
        let file = try self.writeTranscript([beforeMidnight, afterMidnight], session: "session-a")
        try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: file.path)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let snapshot = AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now, calendar: calendar)

        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.evidence, .reported)
        XCTAssertEqual(snapshot.dailyEntries.map(\.totalTokens), [113, 224])
        XCTAssertEqual(snapshot.dailyEntries.map { calendar.component(.day, from: $0.date) }, [19, 20])
        XCTAssertEqual(snapshot.usageRecords.first?.inputTokens, 10)
        XCTAssertEqual(snapshot.usageRecords.first?.cacheReadTokens, 100)
        XCTAssertNil(snapshot.usageRecords.first?.modelID, "缺少模型时不能按当前账号模型猜测")
        XCTAssertNil(snapshot.dailyEntries.first?.costUSD)
        let serialized = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(serialized.contains("PRIVATE_TRANSCRIPT_BODY"))
    }

    func testFullExportAndMirroredRootsDeduplicateWithoutDroppingRegeneratedSteps() throws {
        let first = self.row(step: 7, time: "2026-10-19T11:00:00Z", input: 10, output: 2, cache: 100)
        let regenerated = self.row(step: 7, time: "2026-10-19T11:01:00Z", input: 20, output: 3, cache: 200)
        let full = try self.writeTranscript([first, first, regenerated], session: "same-session")
        try Data((first + "\n").utf8).write(to: full.deletingLastPathComponent().appendingPathComponent("transcript.jsonl"))
        let mirroredRoot = CodexPaths.realHome.appendingPathComponent("antigravity-ide")
        _ = try self.writeTranscript([first, regenerated], session: "same-session", root: mirroredRoot)

        let snapshot = AntigravityUsageCollector(dataDirectories: [self.root, mirroredRoot]).collect(now: self.now)
        XCTAssertEqual(snapshot.usageRecords.count, 2)
        XCTAssertEqual(snapshot.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 335)
    }

    func testDatabaseReplacesEarlierStreamingCountersAndKeepsOldRegeneration() throws {
        let old = self.row(step: 1, time: "2026-10-19T11:00:00Z", input: 5, output: 2, cache: 40)
        let current = self.row(step: 1, time: "2026-10-19T11:01:00Z", input: 10, output: 2, cache: 100)
        _ = try self.writeTranscript([old, current], session: "db-session")
        try self.writeDatabase(session: "db-session", generations: [
            (1, [1, 2, 3], "2026-10-19T11:01:00Z", 10, 3, 100, "claude-sonnet-4-6"),
            (2, [4], "2026-10-19T11:02:00Z", 20, 4, 200, "claude-sonnet-4-6")
        ])
        let database = self.root.appendingPathComponent("conversations/db-session.db")
        let sourceBefore = try Data(contentsOf: database)
        let snapshot = AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now)

        XCTAssertEqual(snapshot.usageRecords.count, 3, "一个生成关联多个steps，不能重复计数；旧重新生成仍保留")
        XCTAssertEqual(snapshot.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 384)
        XCTAssertEqual(snapshot.usageRecords.filter { $0.modelID != nil }.map(\.outputTokens), [3, 4],
                       "同事件采用数据库更新后的输出，不能叠加旧日志的流式计数")
        XCTAssertEqual(snapshot.usageRecords.filter { $0.modelID == "claude-sonnet-4-6" }.count, 2)
        XCTAssertEqual(snapshot.usageRecords.filter { $0.modelID == nil }.count, 1)
        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(try Data(contentsOf: database), sourceBefore, "采集不能修改源会话数据库")
    }

    func testUnknownLegacyHistoryIsUnavailableInsteadOfZero() throws {
        let folder = self.root.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0xFF, 0xAB]).write(to: folder.appendingPathComponent("old-session.pb"))
        let unknown = AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now)
        XCTAssertEqual(unknown.availability, .failed)
        XCTAssertTrue(unknown.dailyEntries.isEmpty)
        XCTAssertTrue(unknown.statusDetail?.contains("尚无可读取") == true)

        _ = try self.writeTranscript([self.row(step: 1)], session: "known-session")
        let partial = AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now)
        XCTAssertEqual(partial.availability, .partial)
        XCTAssertEqual(partial.usageRecords.count, 1)
    }

    func testMissingSourceEmptyDirectoryAndNoGeneratedEventsRemainDistinct() throws {
        XCTAssertEqual(AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now).availability, .sourceMissing)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        XCTAssertEqual(AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now).availability, .noRecords)
        _ = try self.writeTranscript([#"{"step_index":0,"source":"USER","type":"USER_INPUT","created_at":"2026-10-19T10:00:00Z"}"#],
                                    session: "empty-session")
        XCTAssertEqual(AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now).availability, .noRecords)
    }

    func testMissingOrMalformedCountersAreNotEstimatedAndLiveTailIsIgnored() throws {
        let file = try self.writeTranscript([
            self.row(step: 1),
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-19T10:01:00Z","content":"PRIVATE_TRANSCRIPT_BODY"}"#,
            self.row(step: 3).replacingOccurrences(of: "\"input_tokens\":10", with: "\"input_tokens\":true"),
            self.row(step: 4, time: "2027-01-01T00:00:00Z")
        ], session: "partial")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"step_index\":".utf8))
        try handle.close()
        let snapshot = AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.usageRecords.count, 1)
        XCTAssertTrue(snapshot.statusDetail?.contains("1 条模型事件") == true)
        XCTAssertTrue(snapshot.statusDetail?.contains("跳过 1 条") == true)
    }

    func testDatabaseWithUsageButNoEventTimestampDoesNotInventUsageDate() throws {
        try self.writeDatabase(session: "missing-time", generations: [
            (1, [], nil, 10, 3, 100, "fixture-model")
        ])
        let snapshot = AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now)
        XCTAssertEqual(snapshot.availability, .failed)
        XCTAssertTrue(snapshot.usageRecords.isEmpty)
    }

    func testUnreadableDatabaseDoesNotDiscardValidTranscriptUsage() throws {
        _ = try self.writeTranscript([self.row(step: 1)], session: "broken-db")
        let directory = self.root.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not sqlite".utf8).write(to: directory.appendingPathComponent("broken-db.db"))
        let snapshot = AntigravityUsageCollector(dataDirectory: self.root).collect(now: self.now)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.usageRecords.count, 1)
        XCTAssertTrue(snapshot.statusDetail?.contains("无法读取") == true)
    }

    private func row(step: Int, time: String = "2026-10-19T10:00:00Z", input: Int = 10, output: Int = 3, cache: Int = 100) -> String {
        """
        {"step_index":\(step),"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(time)","input_tokens":\(input),"output_tokens":\(output),"cache_read_tokens":\(cache),"content":"PRIVATE_TRANSCRIPT_BODY"}
        """
    }

    @discardableResult
    private func writeTranscript(_ rows: [String], session: String, root: URL? = nil) throws -> URL {
        let logs = (root ?? self.root).appendingPathComponent("brain/\(session)/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("transcript_full.jsonl")
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }

    private typealias GenerationFixture = (index: Int, steps: [Int], timestamp: String?, input: Int, output: Int, cache: Int, model: String)

    private func writeDatabase(session: String, generations: [GenerationFixture]) throws {
        let directory = self.root.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent(session + ".db").path, &pointer) == SQLITE_OK,
              let database = pointer else { throw FixtureError.sqlite }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB); CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB);",
                           nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        for generation in generations {
            let usage = Self.integerField(2, generation.input) + Self.integerField(3, generation.output)
                + Self.integerField(5, generation.cache)
            let chat = Self.bytesField(4, usage) + Self.bytesField(22, Data(generation.model.utf8))
            let packed = generation.steps.reduce(into: Data()) { $0.append(Self.varint($1)) }
            let metadata = Self.bytesField(1, chat) + Self.bytesField(2, packed)
            try self.insert(database, table: "gen_metadata", column: "data", index: generation.index, data: metadata)
            if let timestamp = generation.timestamp.flatMap(ISO8601Parsing.parse) {
                let stamp = Self.integerField(1, Int(timestamp.timeIntervalSince1970))
                for step in generation.steps {
                    try self.insert(database, table: "steps", column: "metadata", index: step, data: Self.bytesField(1, stamp))
                }
            }
        }
    }

    private func insert(_ database: OpaquePointer, table: String, column: String, index: Int, data: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO \(table)(idx,\(column)) VALUES (?,?);", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(index))
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
    }

    private static func varint(_ value: Int) -> Data {
        var remaining = UInt64(value)
        var data = Data()
        while remaining >= 128 { data.append(UInt8(remaining & 127) | 128); remaining >>= 7 }
        data.append(UInt8(remaining))
        return data
    }

    private static func integerField(_ field: Int, _ value: Int) -> Data {
        self.varint(field << 3) + self.varint(value)
    }

    private static func bytesField(_ field: Int, _ value: Data) -> Data {
        self.varint((field << 3) | 2) + self.varint(value.count) + value
    }

    private enum FixtureError: Error { case sqlite }
}
