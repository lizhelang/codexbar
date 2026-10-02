import Foundation
import XCTest

final class DeepSeekHarnessUsageCollectorTests: XCTestCase {
    private let firstDay = 1_700_000_000_000
    private let secondDay = 1_700_086_400_000

    func testHighestTranscriptVersionWinsWithoutCountingOldEncoding() throws {
        let root = try makeSessionsDirectory()
        let session = root.appendingPathComponent("project/session-1", isDirectory: true)
        try write([
            message(id: "old", time: firstDay, input: 1_000, output: 1_000)
        ], to: session.appendingPathComponent("session.jsonl"))
        try write([
            message(id: "v3", time: firstDay, input: 100, output: 10)
        ], to: session.appendingPathComponent("session.v3.jsonl"))
        try write([
            message(id: "v4", time: firstDay, input: 20, output: 10)
        ], to: session.appendingPathComponent("session.v4.jsonl"))

        let result = DeepSeekHarnessUsageCollector(sessionsDirectory: root).collect(now: Date(), calendar: utcCalendar())
        XCTAssertEqual(result.availability, .ready)
        XCTAssertEqual(result.dailyEntries.map(\.totalTokens), [30])
        XCTAssertNil(result.dailyEntries[0].costUSD)
    }

    func testLastStreamUsageReplacesSampleWhileRetryAndCompactionAddCalls() throws {
        let root = try makeSessionsDirectory()
        let session = root.appendingPathComponent("project/session-2", isDirectory: true)
        try write([
            #"{"type":"session","id":"session-2"}"#,
            #"{"type":"assistant/attempt","seq":1,"time":1700000000000,"data":{"turn":1,"step":1,"stream":[{"type":"chunk","chunk":{"type":"usage","usage":{"inputTokens":10,"outputTokens":2}}},{"type":"chunk","chunk":{"type":"usage","usage":{"inputTokens":20,"outputTokens":5}}}]}}"#,
            #"{"type":"assistant/message","seq":2,"time":1700000000001,"data":{"turn":1,"step":1,"message":{"id":"settlement-1","source":{"provider":"p","model":"m"}},"usage":{"inputTokens":30,"outputTokens":7,"cacheReadTokens":4,"cacheWriteTokens":6,"reasoningTokens":5},"stream":[{"type":"chunk","chunk":{"type":"usage","usage":{"inputTokens":999,"outputTokens":999}}}]}}"#,
            #"{"type":"llm/retry-started","seq":3,"time":1700000000002,"data":{"turn":1,"step":1}}"#,
            #"{"type":"assistant/message","seq":4,"time":1700000000003,"data":{"turn":1,"step":1,"message":{"id":"settlement-2","source":{"provider":"p","model":"m"}},"usage":{"inputTokens":40,"outputTokens":10}}}"#,
            #"{"type":"compaction/summary","seq":5,"time":1700000000004,"data":{"compactionId":"summary-1","usage":{"inputTokens":2,"outputTokens":3}}}"#,
            // A replayed durable line must not add a second call.
            #"{"type":"compaction/summary","seq":5,"time":1700000000004,"data":{"compactionId":"summary-1","usage":{"inputTokens":2,"outputTokens":3}}}"#,
        ], to: session.appendingPathComponent("session.jsonl"))

        let result = DeepSeekHarnessUsageCollector(sessionsDirectory: root).collect(now: Date(), calendar: utcCalendar())
        XCTAssertEqual(result.availability, .ready)
        XCTAssertEqual(result.dailyEntries[0].inputTokens, 72)
        XCTAssertEqual(result.dailyEntries[0].outputTokens, 20)
        XCTAssertEqual(result.dailyEntries[0].cacheReadTokens, 4)
        XCTAssertEqual(result.dailyEntries[0].cacheWriteTokens, 6)
        XCTAssertEqual(result.dailyEntries[0].totalTokens, 102)
    }

    func testForkSeedIsExcludedForLegacyAndV3Sessions() throws {
        let root = try makeSessionsDirectory()
        let project = root.appendingPathComponent("project", isDirectory: true)
        try write([
            #"{"type":"session","id":"parent"}"#,
            message(id: "inherited", time: firstDay, input: 90, output: 10, seq: 2)
        ], to: project.appendingPathComponent("parent/session.jsonl"))
        try write([
            #"{"type":"session","id":"legacy-child","seedLength":5}"#,
            message(id: "inherited", time: firstDay, input: 90, output: 10, seq: 2),
            message(id: "child-own", time: firstDay, input: 15, output: 5, seq: 5),
        ], to: project.appendingPathComponent("legacy-child/session.jsonl"))
        try write([
            #"{"type":"session","id":"v3-child","isSeeded":true}"#,
            message(id: "inherited", time: firstDay, input: 90, output: 10, seq: 2),
            #"{"type":"session/end-seed","seq":3,"data":{"inherited":true}}"#,
            message(id: "v3-own", time: firstDay, input: 20, output: 10, seq: 4),
        ], to: project.appendingPathComponent("v3-child/session.v3.jsonl"))

        let result = DeepSeekHarnessUsageCollector(sessionsDirectory: root).collect(now: Date(), calendar: utcCalendar())
        XCTAssertEqual(result.availability, .ready)
        XCTAssertEqual(result.dailyEntries.map(\.totalTokens), [150])
    }

    func testConcatenatedZstdFramesSkipBrokenJSONAndIncompleteTail() throws {
        let root = try makeSessionsDirectory()
        let file = root.appendingPathComponent("project/compressed/session.v4.jsonl.zstd")
        // Two independent zstd frames, with a malformed row and a torn final JSONL row.
        let fixture = "KLUv/QRYVQQA4gkdHIAn1RjUGITSWFLDxpL21SS4lOUz+6/EFlbECAHEe8/AWhqNfJEGpANrCpldtvG9z7mAlnTG1fnSYgjSUrtcj9XSjhcDl7ucMFLGglHkegwbi3xAd1wByK4eAkOErdklxLvori510nFezDhKZlf3XFUB2wUGAGis1cariBg1qUgvbr+iQj0BZwfpHCi1L/0EWB0FAOJKIR5wN9UBZCgapXqFSBiKLclScPWh1P+0b4SURQpw4uDdbYw5B9F9PLgv5+SZabIADzamHhO+dH89T6Bp18vb806TMljXHvOKOLj8csOQlFldW4s8n9RjPubRQ+nFHImFMUZx8rrUezHyBcovVwHErOvwGHqsmNHz2g7eI6HZ8kCBabIuIAYKAHRI4JoAcqgA4AOaxRni1kTxNhZbKmohAGf+SLWF"
        try writeData(try XCTUnwrap(Data(base64Encoded: fixture)), to: file)

        let result = DeepSeekHarnessUsageCollector(sessionsDirectory: root).collect(now: Date(), calendar: utcCalendar())
        XCTAssertEqual(result.availability, .partial)
        XCTAssertTrue(result.statusDetail?.contains("1 行") == true)
        XCTAssertEqual(result.dailyEntries.map(\.totalTokens), [10, 15])
        XCTAssertEqual(result.latestUsageAt, Date(timeIntervalSince1970: Double(secondDay) / 1_000))
    }

    func testMalformedMiddleLinePreservesUsableUsageAndMarksPartial() throws {
        let root = try makeSessionsDirectory()
        let file = root.appendingPathComponent("project/malformed/session.jsonl")
        try write([
            message(id: "before", time: firstDay, input: 7, output: 3),
            "{broken json}",
            message(id: "after", time: firstDay, input: 11, output: 4),
        ], to: file)

        let result = DeepSeekHarnessUsageCollector(sessionsDirectory: root).collect(now: Date(), calendar: utcCalendar())
        XCTAssertEqual(result.availability, .partial)
        XCTAssertEqual(result.dailyEntries.map(\.totalTokens), [25])
        XCTAssertTrue(result.statusDetail?.contains("1 行") == true)
    }

    func testIncompleteFinalLineWaitsForNextScanWithoutMarkingPartial() throws {
        let root = try makeSessionsDirectory()
        let file = root.appendingPathComponent("project/live/session.jsonl")
        let bytes = Data((message(id: "complete", time: firstDay, input: 7, output: 3)
                          + "\n{\"type\":\"assistant/message\"").utf8)
        try writeData(bytes, to: file)

        let result = DeepSeekHarnessUsageCollector(sessionsDirectory: root).collect(now: Date(), calendar: utcCalendar())
        XCTAssertEqual(result.availability, .ready)
        XCTAssertEqual(result.dailyEntries.map(\.totalTokens), [10])
        XCTAssertNil(result.statusDetail)
    }

    func testUnreadableCompressedSessionIsReportedAsFailure() throws {
        let root = try makeSessionsDirectory()
        let file = root.appendingPathComponent("project/bad/session.jsonl.zstd")
        try writeData(Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00]), to: file)

        let result = DeepSeekHarnessUsageCollector(sessionsDirectory: root).collect(now: Date(), calendar: utcCalendar())
        XCTAssertEqual(result.availability, .failed)
        XCTAssertEqual(result.dailyEntries.count, 0)
    }

    func testLargeFrameDrainsAfterCompressedInputIsConsumed() throws {
        let root = try makeSessionsDirectory()
        let file = root.appendingPathComponent("project/large/session.jsonl.zstd")
        // Decodes to a 400 KB ignored user row followed by a small usage row.
        let fixture = "KLUv/QRYNAIAIkQOFpC16WTVinabUTNEXL5mpmvGkK/nBiCB7URNlIiXfXllcs0h1hhUESAMrlFXbJczGaWDWNzuIchXAgCS/cflh6GpJwIAEHgCABB4HQMA9AN4In1hc3Npc3RhbnR0aW1lIjoxNzA6ey1yZXN1bHQifSwidTp7ImlucHV0VG9rZW5zIjoxMywib3V0Mn19fQoJAGta29cQ3TSwITKoFIllDdEGuH1sNUTmxGqIDDTWHrABJWHW3A=="
        try writeData(try XCTUnwrap(Data(base64Encoded: fixture)), to: file)

        let result = DeepSeekHarnessUsageCollector(sessionsDirectory: root).collect(now: Date(), calendar: utcCalendar())
        XCTAssertEqual(result.availability, .ready)
        XCTAssertEqual(result.dailyEntries.map(\.totalTokens), [15])
    }

    func testRetainsPersistedTitleModelTurnStateAndContextWithoutUsingFileModificationTime() throws {
        let root = try makeSessionsDirectory()
        let file = root.appendingPathComponent("project/session-1/session.jsonl")
        try write([
            #"{"type":"session","id":"session-1","cwd":"/project"}"#,
            #"{"type":"turn/start","data":{}}"#,
            #"{"type":"request/context","data":{"contextWindow":1000000}}"#,
            message(id: "usage", time: firstDay, input: 20, output: 10),
            #"{"type":"llm/chunk","data":{"chunk":{"type":"usage","usage":{"inputTokens":20,"outputTokens":10}}}}"#,
            #"{"type":"session/title","data":{"title":"Actual recorded title"}}"#,
            #"{"type":"turn/end","data":{"reason":"completed"}}"#,
        ], to: file)
        let snapshot = DeepSeekHarnessUsageCollector(sessionsDirectory: root).collect(calendar: utcCalendar())
        let record = try XCTUnwrap(snapshot.usageRecords.first)
        XCTAssertEqual(record.sessionID, "session-1")
        XCTAssertEqual(record.sessionTitle, "Actual recorded title")
        XCTAssertEqual(record.projectPath, "/project")
        XCTAssertEqual(record.modelID, "m")
        XCTAssertEqual(record.sessionIsRunning, false)
        XCTAssertEqual(record.contextWindowTokens, 1000000)
        XCTAssertEqual(record.contextUsedTokens, 30)
        XCTAssertEqual(record.timestamp, Date(timeIntervalSince1970: Double(firstDay) / 1000))
    }

    private func makeSessionsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ lines: [String], to file: URL) throws {
        try writeData(Data((lines.joined(separator: "\n") + "\n").utf8), to: file)
    }

    private func writeData(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func message(id: String, time: Int, input: Int, output: Int, seq: Int = 1) -> String {
        #"{"type":"assistant/message","seq":\#(seq),"time":\#(time),"data":{"message":{"id":"\#(id)","source":{"provider":"p","model":"m"}},"usage":{"inputTokens":\#(input),"outputTokens":\#(output)}}}"#
    }
}
