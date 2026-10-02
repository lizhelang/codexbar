import XCTest

final class ClaudeCodeUsageCollectorTests: XCTestCase {
    func testDeduplicatesStreamedMessagesAcrossTranscriptRoots() throws {
        let home = self.makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let transcripts = home.appendingPathComponent("transcripts", isDirectory: true)
        let first = #"{"type":"assistant","timestamp":"2026-09-30T09:00:00Z","requestId":"req-1","message":{"id":"msg-1","role":"assistant","usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":2,"cache_creation_input_tokens":3}}}"#
        let completed = #"{"type":"assistant","timestamp":"2026-09-30T09:01:00.123Z","requestId":"req-1","message":{"id":"msg-1","role":"assistant","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":4,"cache_creation_input_tokens":3}}}"#
        let separateRequest = #"{"type":"assistant","timestamp":"2026-09-30T09:02:00Z","requestId":"req-2","message":{"id":"msg-1","role":"assistant","usage":{"input_tokens":5,"output_tokens":6}}}"#
        try self.write([first, completed, separateRequest], to: projects.appendingPathComponent("a.jsonl"))
        try self.write([completed], to: transcripts.appendingPathComponent("copy.jsonl"))

        let snapshot = ClaudeCodeUsageCollector(projectsURL: projects, transcriptsURL: transcripts)
            .collect(now: self.date("2026-09-30T12:00:00Z"), calendar: self.utcCalendar)

        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.evidence, .reported)
        XCTAssertEqual(snapshot.dailyEntries.count, 1)
        XCTAssertEqual(snapshot.dailyEntries[0].inputTokens, 15)
        XCTAssertEqual(snapshot.dailyEntries[0].outputTokens, 26)
        XCTAssertEqual(snapshot.dailyEntries[0].cacheReadTokens, 4)
        XCTAssertEqual(snapshot.dailyEntries[0].cacheWriteTokens, 3)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 48)
        XCTAssertNil(snapshot.dailyEntries[0].costUSD)
        XCTAssertEqual(snapshot.latestUsageAt, self.date("2026-09-30T09:02:00Z"))
    }

    func testUsesCalendarDaysAcrossAllHistoryAndSkipsInvalidOrFutureRows() throws {
        let home = self.makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let transcripts = home.appendingPathComponent("transcripts", isDirectory: true)
        try self.write([
            #"{"type":"assistant","timestamp":"2026-04-01T01:00:00Z","message":{"id":"old","role":"assistant","usage":{"input_tokens":1,"output_tokens":2}}}"#,
            #"{"type":"assistant","timestamp":"2026-09-30T13:30:00Z","message":{"id":"before-midnight","role":"assistant","usage":{"input_tokens":3,"output_tokens":4}}}"#,
            #"{"type":"assistant","timestamp":"2026-09-30T14:30:00Z","message":{"id":"after-midnight","role":"assistant","usage":{"input_tokens":5,"output_tokens":6}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-02T00:00:00Z","message":{"id":"future","role":"assistant","usage":{"input_tokens":100,"output_tokens":200}}}"#,
            #"{"type":"user","timestamp":"2026-09-30T15:00:00Z","message":{"id":"user","usage":{"input_tokens":300}}}"#,
            #"{"type":"assistant","timestamp":"2026-09-30T15:00:00Z","message":{"id":"no-tokens","role":"assistant","usage":{"service_tier":"standard"}}}"#,
        ], to: projects.appendingPathComponent("history.jsonl"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 10 * 60 * 60))
        let snapshot = ClaudeCodeUsageCollector(projectsURL: projects, transcriptsURL: transcripts)
            .collect(now: self.date("2026-10-01T12:00:00Z"), calendar: calendar)

        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.dailyEntries.map(\.date), [
            calendar.startOfDay(for: self.date("2026-04-01T01:00:00Z")),
            calendar.startOfDay(for: self.date("2026-09-30T13:30:00Z")),
            calendar.startOfDay(for: self.date("2026-09-30T14:30:00Z")),
        ])
        XCTAssertEqual(snapshot.dailyEntries.map(\.totalTokens), [3, 7, 11])
        XCTAssertEqual(snapshot.latestUsageAt, self.date("2026-09-30T14:30:00Z"))
    }

    func testKeepsReadableUsageButMarksCompleteDamagedRowsPartial() throws {
        let home = self.makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let transcripts = home.appendingPathComponent("transcripts", isDirectory: true)
        try self.write([
            #"{"type":"assistant","timestamp":"2026-09-30T09:00:00Z","message":{"id":"good-1","role":"assistant","usage":{"input_tokens":2,"output_tokens":3}}}"#,
            #"{"type":"assistant","timestamp":"2026-09-30T09:01:00Z","message":{"id":"bad-json","usage":{"input_tokens":8}"#,
            #"{"type":"assistant","timestamp":"2026-09-30T09:02:00Z","message":{"id":"bad-value","role":"assistant","usage":{"input_tokens":"wrong"}}}"#,
            #"{"type":"assistant","timestamp":"2026-09-30T09:03:00Z","message":{"id":"negative","role":"assistant","usage":{"input_tokens":-2,"output_tokens":4}}}"#,
            #"{"type":"assistant","timestamp":"2026-09-30T09:04:00Z","message":{"id":"good-2","role":"assistant","usage":{"input_tokens":5,"output_tokens":7}}}"#,
        ], to: projects.appendingPathComponent("mixed.jsonl"))

        let snapshot = ClaudeCodeUsageCollector(projectsURL: projects, transcriptsURL: transcripts)
            .collect(now: self.date("2026-09-30T12:00:00Z"), calendar: self.utcCalendar)

        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.dailyEntries.map(\.totalTokens), [17])
        XCTAssertEqual(snapshot.latestUsageAt, self.date("2026-09-30T09:04:00Z"))
        XCTAssertEqual(snapshot.statusDetail, "部分 Claude Code 用量记录无法解析")
    }

    func testIgnoresIncompleteTailUntilItIsFinished() throws {
        let home = self.makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let transcripts = home.appendingPathComponent("transcripts", isDirectory: true)
        let file = projects.appendingPathComponent("active.jsonl")
        let complete = #"{"type":"assistant","timestamp":"2026-09-30T09:00:00Z","message":{"id":"done","role":"assistant","usage":{"input_tokens":1,"output_tokens":2}}}"#
        let partial = #"{"type":"assistant","timestamp":"2026-09-30T10:00:00Z","message":{"id":"tail","role":"assistant","usage":{"input_tokens":3,"output_tokens":"#
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data((complete + "\n" + partial).utf8).write(to: file)
        let collector = ClaudeCodeUsageCollector(projectsURL: projects, transcriptsURL: transcripts)
        let now = self.date("2026-09-30T12:00:00Z")

        let before = collector.collect(now: now, calendar: self.utcCalendar)
        XCTAssertEqual(before.availability, .ready)
        XCTAssertEqual(before.dailyEntries.map(\.totalTokens), [3])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("4}}}\n".utf8))
        try handle.close()
        let after = collector.collect(now: now, calendar: self.utcCalendar)
        XCTAssertEqual(after.availability, .ready)
        XCTAssertEqual(after.dailyEntries.map(\.totalTokens), [10])
    }

    func testDistinguishesMissingEmptyAndUnreadableSources() throws {
        let home = self.makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let transcripts = home.appendingPathComponent("transcripts", isDirectory: true)
        let now = self.date("2026-09-30T12:00:00Z")
        let missing = ClaudeCodeUsageCollector(projectsURL: projects, transcriptsURL: transcripts)
            .collect(now: now, calendar: self.utcCalendar)
        XCTAssertEqual(missing.availability, .sourceMissing)
        XCTAssertEqual(missing.refreshedAt, now)

        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let empty = ClaudeCodeUsageCollector(projectsURL: projects, transcriptsURL: transcripts)
            .collect(now: now, calendar: self.utcCalendar)
        XCTAssertEqual(empty.availability, .noRecords)

        try FileManager.default.removeItem(at: projects)
        try Data("not a directory".utf8).write(to: projects)
        let unreadable = ClaudeCodeUsageCollector(projectsURL: projects, transcriptsURL: transcripts)
            .collect(now: now, calendar: self.utcCalendar)
        XCTAssertEqual(unreadable.availability, .failed)
        XCTAssertTrue(unreadable.dailyEntries.isEmpty)
    }

    func testRetainsRealModelSessionTitleProjectAndCompletionAfterStreamingDeduplication() throws {
        let home = self.makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent("projects")
        try self.write([
            #"{"type":"assistant","timestamp":"2026-09-30T09:00:00Z","sessionId":"session-1","cwd":"/project","message":{"id":"message-1","model":"claude-opus-4-7","stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":1}}}"#,
            #"{"type":"assistant","timestamp":"2026-09-30T09:01:00Z","sessionId":"session-1","cwd":"/project","message":{"id":"message-1","model":"claude-opus-4-7","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":8}}}"#,
            #"{"type":"ai-title","sessionId":"session-1","aiTitle":"A recorded title"}"#,
        ], to: projects.appendingPathComponent("session-1.jsonl"))
        let snapshot = ClaudeCodeUsageCollector(projectsURL: projects, transcriptsURL: home.appendingPathComponent("missing"))
            .collect(now: self.date("2026-10-01T00:00:00Z"), calendar: self.utcCalendar)
        let record = try XCTUnwrap(snapshot.usageRecords.first)
        XCTAssertEqual(snapshot.usageRecords.count, 1)
        XCTAssertEqual(record.modelID, "claude-opus-4-7")
        XCTAssertEqual(record.sessionID, "session-1")
        XCTAssertEqual(record.sessionTitle, "A recorded title")
        XCTAssertEqual(record.projectPath, "/project")
        XCTAssertEqual(record.timestamp, self.date("2026-09-30T09:01:00Z"))
        XCTAssertEqual(record.totalTokens, 18)
        XCTAssertEqual(record.sessionIsRunning, false)
        XCTAssertEqual(snapshot.dailyEntries.map(\.totalTokens), [18])
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeTemporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeUsageCollectorTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }
}
