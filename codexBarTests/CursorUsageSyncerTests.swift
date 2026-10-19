import Foundation
import SQLite3
import XCTest
@testable import codexbar

final class CursorUsageSyncerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testReadsOnlyDesktopTokenAndNormalizesJWTSessionCookie() throws {
        let subject = Data(#"{"sub":"auth0|user_fixture123"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "a.\(subject).b"
        let databaseURL = try self.makeStateDatabase(token: token)
        let cookie = try CursorDesktopSessionReader(databaseURL: databaseURL).sessionCookie()
        XCTAssertEqual(cookie, "user_fixture123%3A%3A\(token)")
    }

    func testRejectsMissingOrMalformedDesktopSessionWithoutNetwork() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.vscdb")
        XCTAssertThrowsError(try CursorDesktopSessionReader(databaseURL: missing).sessionCookie()) { error in
            XCTAssertEqual(error as? CursorUsageSyncError, .noDesktopSession)
        }
        let malformed = try self.makeStateDatabase(token: "not-a-cursor-token")
        XCTAssertThrowsError(try CursorDesktopSessionReader(databaseURL: malformed).sessionCookie()) { error in
            XCTAssertEqual(error as? CursorUsageSyncError, .invalidDesktopSession)
        }
        for token in [
            "user_fixture%3A%3Aaa.bb.cc;OtherCookie=leak",
            "user_fixture%3A%3Aaa.bb.cc\r\nX-Injected: yes",
            "user_fixture%3A%3Aaa.bb.cc%3Bbad",
        ] {
            XCTAssertThrowsError(try CursorDesktopSessionReader.normalizedCookie(token)) { error in
                XCTAssertEqual(error as? CursorUsageSyncError, .invalidDesktopSession)
            }
        }
    }

    func testFetchesAllPagesAndAggregatesReportedTokens() async throws {
        let databaseURL = try self.makeStateDatabase(token: "user_fixture%3A%3Aaa.bb.cc")
        let firstEvent: [String: Any] = [
            "timestamp": "1782867600000", "model": "model-a", "conversationId": "actual-conversation", "kind": "USAGE_EVENT_KIND_USAGE_BASED",
            "tokenUsage": ["inputTokens": 10, "outputTokens": 5, "cacheReadTokens": 3, "cacheWriteTokens": 2],
            "isChargeable": true, "chargedCents": 12.5,
        ]
        let secondEvent: [String: Any] = [
            "timestamp": "1782871200000", "model": "model-b", "kind": "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
            "tokenUsage": ["inputTokens": 4, "outputTokens": 6, "cacheReadTokens": 0, "cacheWriteTokens": 0],
            "isChargeable": true, "chargedCents": 7.0,
        ]
        let transport = CursorFixtureTransport(pages: [
            (200, ["totalUsageEventsCount": 2, "usageEventsDisplay": [firstEvent]]),
            (200, ["totalUsageEventsCount": 2, "usageEventsDisplay": [secondEvent]]),
        ])
        let syncer = CursorUsageSyncer(
            sessionReader: CursorDesktopSessionReader(databaseURL: databaseURL),
            transport: transport
        )
        let now = Date(timeIntervalSince1970: 1_782_900_000)
        let result = try await syncer.sync(now: now, calendar: self.calendar)
        XCTAssertEqual(result.availability, .ready)
        XCTAssertEqual(result.evidence, .server)
        XCTAssertEqual(result.dailyEntries.count, 1)
        XCTAssertEqual(result.dailyEntries[0].inputTokens, 14)
        XCTAssertEqual(result.dailyEntries[0].outputTokens, 11)
        XCTAssertEqual(result.dailyEntries[0].cacheReadTokens, 3)
        XCTAssertEqual(result.dailyEntries[0].cacheWriteTokens, 2)
        XCTAssertEqual(result.dailyEntries[0].totalTokens, 30)
        XCTAssertEqual(result.dailyEntries[0].costUSD ?? 0, 0.195, accuracy: 0.00001)
        XCTAssertEqual(result.refreshedAt, now)
        XCTAssertEqual(result.usageRecords.map(\.modelID), ["model-a", "model-b"])
        XCTAssertEqual(result.usageRecords.map(\.sessionID), ["actual-conversation", nil])
        XCTAssertEqual(result.usageRecords.map(\.totalTokens), [20, 10])
        XCTAssertEqual(result.usageRecords.first?.costUSD, 0.125)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.host, "cursor.com")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Origin"), "https://cursor.com")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=user_fixture%3A%3Aaa.bb.cc")
        for (index, request) in requests.enumerated() {
            let body = try XCTUnwrap(request.httpBody)
            let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(parameters["page"] as? Int, index + 1)
            XCTAssertEqual(parameters["pageSize"] as? Int, 500)
            XCTAssertEqual(parameters["teamId"] as? Int, 0)
            XCTAssertEqual(parameters["startDate"] as? String, "0")
            XCTAssertEqual(parameters["endDate"] as? String, "1782900000000")
        }
    }

    func testNewUsageDuringPaginationDoesNotShiftTheFixedHistoryWindow() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let transport = CursorPaginatedTransport(
            eventCount: 1_001, now: now, insertUsageAfterFirstPage: true
        )
        let result = try await CursorUsageSyncer(transport: transport)
            .sync(sessionCookie: "user_fixture%3A%3Aaa.bb.cc", now: now, calendar: self.calendar)

        XCTAssertEqual(result.usageRecords.count, 1_001)
        XCTAssertEqual(Set(result.usageRecords.compactMap(\.sessionID)).count, 1_001)
        XCTAssertEqual(result.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 1_001)
        XCTAssertTrue(result.usageRecords.allSatisfy { $0.timestamp < now })
        let requests = await transport.requests
        let serverEventCount = await transport.eventCount
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(serverEventCount, 1_002, "The server gained usage while older pages were being read")
    }

    func testThirteenPageHistoryCanFinishBeyondThirtySeconds() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = CursorTestClock()
        let transport = CursorPaginatedTransport(eventCount: 6_389, now: now, clock: clock, pageDuration: 4)
        let result = try await CursorUsageSyncer(transport: transport, monotonicNow: { clock.now })
            .sync(sessionCookie: "user_fixture%3A%3Aaa.bb.cc", now: now, calendar: self.calendar)

        XCTAssertEqual(result.usageRecords.count, 6_389)
        XCTAssertEqual(result.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 6_389)
        XCTAssertEqual(clock.now, 52)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 13)
        XCTAssertTrue(requests.allSatisfy { $0.timeoutInterval == 15 })
    }

    func testExhaustedHistoryBudgetStopsBeforeRequestingFurtherPages() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = CursorTestClock()
        let transport = CursorPaginatedTransport(eventCount: 7_001, now: now, clock: clock, pageDuration: 10)
        let syncer = CursorUsageSyncer(transport: transport, monotonicNow: { clock.now })

        do {
            _ = try await syncer.sync(sessionCookie: "user_fixture%3A%3Aaa.bb.cc", now: now, calendar: self.calendar)
            XCTFail("A partial history must not be published after the total time budget expires")
        } catch {
            XCTAssertEqual(error as? CursorUsageSyncError, .incompleteHistory)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 12)
        XCTAssertEqual(clock.now, 120)
        XCTAssertEqual(requests.last?.timeoutInterval, 10)
    }

    func testFinalPageArrivingAfterHistoryBudgetDoesNotPublishSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = CursorTestClock()
        let transport = CursorPaginatedTransport(eventCount: 6_389, now: now, clock: clock, pageDuration: 9.5)
        let syncer = CursorUsageSyncer(transport: transport, monotonicNow: { clock.now })

        do {
            _ = try await syncer.sync(sessionCookie: "user_fixture%3A%3Aaa.bb.cc", now: now, calendar: self.calendar)
            XCTFail("Even a complete final page must be rejected when it arrives after the deadline")
        } catch {
            XCTAssertEqual(error as? CursorUsageSyncError, .incompleteHistory)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 13)
        XCTAssertEqual(clock.now, 123.5)
        XCTAssertEqual(requests.last?.timeoutInterval, 6)
    }

    func testUsageBasedCostIsConvertedFromCentsToDollars() throws {
        let snapshot = try CursorUsageSyncer.snapshot(from: [[
            "timestamp": "1782867600000", "kind": "USAGE_EVENT_KIND_USAGE_BASED",
            "tokenUsage": ["inputTokens": 10, "outputTokens": 5],
            "isChargeable": true, "chargedCents": 125.5,
        ]], now: Date(), calendar: self.calendar)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 15)
        XCTAssertEqual(snapshot.dailyEntries[0].costUSD ?? 0, 1.255, accuracy: 0.00001)
    }

    func testIncludedChargeableEventCountsReportedCharge() throws {
        let snapshot = try CursorUsageSyncer.snapshot(from: [[
            "timestamp": "1782867600000", "kind": "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
            "tokenUsage": ["inputTokens": 10],
            "isChargeable": true, "chargedCents": 42.5,
        ]], now: Date(), calendar: self.calendar)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 10)
        XCTAssertEqual(snapshot.dailyEntries[0].costUSD ?? 0, 0.425, accuracy: 0.00001)
    }

    func testUnchargeableEventKeepsZeroBillWithoutInventingZeroUsageValue() throws {
        let snapshot = try CursorUsageSyncer.snapshot(from: [[
            "timestamp": "1782867600000", "kind": "USAGE_EVENT_KIND_USAGE_BASED",
            "tokenUsage": ["inputTokens": 10],
            "isChargeable": false, "chargedCents": 99,
        ]], now: Date(), calendar: self.calendar)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 10)
        XCTAssertNil(snapshot.dailyEntries[0].costUSD)
        XCTAssertEqual(snapshot.dailyEntries[0].billedCostUSD, 0)
    }

    func testIncludedUsageKeepsAPIValueAndBillSeparate() throws {
        let snapshot = try CursorUsageSyncer.snapshot(from: [[
            "timestamp": "1782867600000", "kind": "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
            "model": "default", "tokenUsage": ["inputTokens": 10, "totalCents": 125.5],
            "isChargeable": false, "chargedCents": 99,
        ]], now: Date(), calendar: self.calendar)
        XCTAssertEqual(snapshot.usageRecords[0].costUSD ?? 0, 1.255, accuracy: 0.00001)
        XCTAssertEqual(snapshot.usageRecords[0].billedCostUSD, 0)
        XCTAssertEqual(snapshot.usageRecords[0].costEvidence, .reported)
        XCTAssertEqual(snapshot.dailyEntries[0].costUSD ?? 0, 1.255, accuracy: 0.00001)
        XCTAssertEqual(snapshot.dailyEntries[0].billedCostUSD, 0)
    }

    func testIncludedUsageWithoutValueUsesKnownModelPrice() throws {
        let snapshot = try CursorUsageSyncer.snapshot(from: [[
            "timestamp": "1782867600000", "model": "claude-opus-4-7",
            "tokenUsage": ["inputTokens": 1_000_000], "isChargeable": false,
        ]], now: Date(), calendar: self.calendar)
        XCTAssertEqual(snapshot.dailyEntries[0].costUSD, 5)
        XCTAssertEqual(snapshot.dailyEntries[0].costEvidence, .estimated)
        XCTAssertEqual(snapshot.dailyEntries[0].billedCostUSD, 0)
    }

    func testRequestPricedEventWithoutTokenUsageStillCountsCost() throws {
        let snapshot = try CursorUsageSyncer.snapshot(from: [[
            "timestamp": "1782867600000", "kind": "USAGE_EVENT_KIND_USAGE_BASED",
            "isTokenBasedCall": false, "isChargeable": true, "chargedCents": 125,
        ]], now: Date(), calendar: self.calendar)
        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 0)
        XCTAssertEqual(snapshot.dailyEntries[0].costUSD, 1.25)
    }

    func testMissingChargeFlagMakesDailyCostUnknown() throws {
        let snapshot = try CursorUsageSyncer.snapshot(from: [[
            "timestamp": "1782867600000", "tokenUsage": ["inputTokens": 10],
            "chargedCents": 99,
        ]], now: Date(), calendar: self.calendar)
        XCTAssertEqual(snapshot.dailyEntries[0].totalTokens, 10)
        XCTAssertNil(snapshot.dailyEntries[0].costUSD)
    }

    func testNonemptyEventsWithoutTokenUsageAreNotTreatedAsNoRecords() {
        let malformedEvents: [[String: Any]] = [
            ["timestamp": "1782867600000", "model": "model-a", "chargedCents": 15],
            ["timestamp": "1782867600000", "model": "model-a", "tokenUsage": [:]],
        ]
        for event in malformedEvents {
            XCTAssertThrowsError(try CursorUsageSyncer.snapshot(from: [event], now: Date(), calendar: self.calendar)) { error in
                XCTAssertEqual(error as? CursorUsageSyncError, .invalidResponse)
            }
        }
    }

    func testRejectsMalformedPageAndIncompleteHistory() async throws {
        let databaseURL = try self.makeStateDatabase(token: "user_fixture%3A%3Aaa.bb.cc")
        let malformed = CursorUsageSyncer(
            sessionReader: CursorDesktopSessionReader(databaseURL: databaseURL),
            transport: CursorFixtureTransport(pages: [(200, ["totalUsageEventsCount": 0])])
        )
        do {
            _ = try await malformed.sync(calendar: self.calendar)
            XCTFail("Missing event array must fail")
        } catch {
            XCTAssertEqual(error as? CursorUsageSyncError, .invalidResponse)
        }

        let truncated = CursorUsageSyncer(
            sessionReader: CursorDesktopSessionReader(databaseURL: databaseURL),
            transport: CursorFixtureTransport(pages: [
                (200, ["totalUsageEventsCount": 2, "usageEventsDisplay": [[
                    "timestamp": "1782867600000", "tokenUsage": ["inputTokens": 1],
                ]]]),
                (200, ["totalUsageEventsCount": 2, "usageEventsDisplay": []]),
            ])
        )
        do {
            _ = try await truncated.sync(calendar: self.calendar)
            XCTFail("A short page before advertised total must fail")
        } catch {
            XCTAssertEqual(error as? CursorUsageSyncError, .incompleteHistory)
        }
    }

    func testRejectsChangingTotalsAndOverlappingPages() async throws {
        let databaseURL = try self.makeStateDatabase(token: "user_fixture%3A%3Aaa.bb.cc")
        let firstEvent: [String: Any] = [
            "timestamp": "1782867600000", "tokenUsage": ["inputTokens": 1],
        ]
        let secondEvent: [String: Any] = [
            "timestamp": "1782867600001", "tokenUsage": ["inputTokens": 2],
        ]
        let cases: [[(Int, [String: Any])]] = [
            [
                (200, ["totalUsageEventsCount": 2, "usageEventsDisplay": [firstEvent]]),
                (200, ["totalUsageEventsCount": 3, "usageEventsDisplay": [secondEvent]]),
            ],
            [
                (200, ["totalUsageEventsCount": 2, "usageEventsDisplay": [firstEvent]]),
                (200, ["totalUsageEventsCount": 2, "usageEventsDisplay": [firstEvent]]),
            ],
            [
                (200, ["totalUsageEventsCount": 1, "usageEventsDisplay": [firstEvent, secondEvent]]),
            ],
        ]
        for pages in cases {
            let syncer = CursorUsageSyncer(
                sessionReader: CursorDesktopSessionReader(databaseURL: databaseURL),
                transport: CursorFixtureTransport(pages: pages)
            )
            do {
                _ = try await syncer.sync(calendar: self.calendar)
                XCTFail("Inconsistent or overlapping pages must not replace cached usage")
            } catch {
                XCTAssertEqual(error as? CursorUsageSyncError, .incompleteHistory)
            }
        }
    }

    func testRejectsPageWithoutAdvertisedTotal() async throws {
        let databaseURL = try self.makeStateDatabase(token: "user_fixture%3A%3Aaa.bb.cc")
        let syncer = CursorUsageSyncer(
            sessionReader: CursorDesktopSessionReader(databaseURL: databaseURL),
            transport: CursorFixtureTransport(pages: [(200, ["usageEventsDisplay": []])])
        )
        do {
            _ = try await syncer.sync(calendar: self.calendar)
            XCTFail("Missing total count must fail")
        } catch {
            XCTAssertEqual(error as? CursorUsageSyncError, .invalidResponse)
        }
    }

    func testExpiredSessionIsReportedWithoutErrorBody() async throws {
        let databaseURL = try self.makeStateDatabase(token: "user_fixture%3A%3Aaa.bb.cc")
        let syncer = CursorUsageSyncer(
            sessionReader: CursorDesktopSessionReader(databaseURL: databaseURL),
            transport: CursorFixtureTransport(pages: [(401, ["message": "fake-secret-should-not-surface"])])
        )
        do {
            _ = try await syncer.sync(calendar: self.calendar)
            XCTFail("Expired session must fail")
        } catch {
            XCTAssertEqual(error as? CursorUsageSyncError, .sessionExpired)
            XCTAssertFalse(String(describing: error).contains("fake-secret"))
        }
    }

    private func makeStateDatabase(token: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.vscdb")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CursorUsageSyncError.unreadableDesktopSession
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil) == SQLITE_OK else {
            throw CursorUsageSyncError.unreadableDesktopSession
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO ItemTable(key,value) VALUES ('cursorAuth/accessToken',?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CursorUsageSyncError.unreadableDesktopSession }
        defer { sqlite3_finalize(statement) }
        let result = token.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw CursorUsageSyncError.unreadableDesktopSession
        }
        return url
    }
}

private actor CursorFixtureTransport: CursorUsageHTTPTransport {
    private var pages: [(Int, [String: Any])]
    private(set) var requests: [URLRequest] = []

    init(pages: [(Int, [String: Any])]) {
        self.pages = pages
    }

    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        guard !self.pages.isEmpty else { throw CursorUsageSyncError.incompleteHistory }
        let (status, object) = self.pages.removeFirst()
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= limit else { throw CursorUsageSyncError.responseTooLarge }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

private nonisolated final class CursorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    var now: TimeInterval { self.lock.withLock { self.elapsed } }
    func advance(by duration: TimeInterval) { self.lock.withLock { self.elapsed += duration } }
}

/// Applies the request's actual date filter and page offsets so new server events
/// would move the result set if the client stopped sending a fixed cutoff.
private actor CursorPaginatedTransport: CursorUsageHTTPTransport {
    private var timestamps: [Int64]
    private let cutoff: Int64
    private let insertUsageAfterFirstPage: Bool
    private let clock: CursorTestClock?
    private let pageDuration: TimeInterval
    private(set) var requests: [URLRequest] = []
    var eventCount: Int { self.timestamps.count }

    init(eventCount: Int, now: Date, insertUsageAfterFirstPage: Bool = false,
         clock: CursorTestClock? = nil, pageDuration: TimeInterval = 0) {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
        self.cutoff = cutoff
        self.timestamps = (1...eventCount).map { cutoff - Int64($0) }
        self.insertUsageAfterFirstPage = insertUsageAfterFirstPage
        self.clock = clock
        self.pageDuration = pageDuration
    }

    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        guard let body = request.httpBody,
              let parameters = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let page = parameters["page"] as? Int, page > 0,
              let pageSize = parameters["pageSize"] as? Int, pageSize > 0 else {
            throw CursorUsageSyncError.invalidResponse
        }
        if self.insertUsageAfterFirstPage, self.requests.count == 2 {
            self.timestamps.insert(self.cutoff + 1, at: 0)
        }
        let startDate = (parameters["startDate"] as? String).flatMap(Int64.init) ?? Int64.min
        let endDate = (parameters["endDate"] as? String).flatMap(Int64.init) ?? Int64.max
        let matching = self.timestamps.filter { $0 >= startDate && $0 <= endDate }
        let events: [[String: Any]] = matching.dropFirst((page - 1) * pageSize).prefix(pageSize).map {
            ["timestamp": String($0), "conversationId": "event-\($0)", "tokenUsage": ["inputTokens": 1]]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "totalUsageEventsCount": matching.count, "usageEventsDisplay": events,
        ])
        guard data.count <= limit else { throw CursorUsageSyncError.responseTooLarge }
        self.clock?.advance(by: self.pageDuration)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
