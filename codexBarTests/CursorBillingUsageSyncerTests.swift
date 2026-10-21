import Foundation
import XCTest
@testable import codexbar

final class CursorBillingUsageSyncerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_540_800)
    private let day: TimeInterval = 86_400
    private let cookie = "user_fixture%3A%3Aaa.bb.cc"
    private let header = "Billing Item ID,Event Time,Product,Charge Category,Usage Type,Principal Type,Principal ID,Usage,Pricing Currency,Pricing Contracted,Model,User Email"

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private var emptyLegacy: ToolUsageSnapshot {
        ToolUsageSnapshot(client: .cursor, availability: .noRecords, evidence: .server)
    }

    func testInitialHistoryUsesContiguous31DayWindowsAndIsolatesAuthenticationHosts() async throws {
        let created = self.now.addingTimeInterval(-70 * self.day)
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: created), .csv(self.header), .csv(self.header), .csv(self.header),
        ])
        let result = try await self.sync(transport)
        XCTAssertEqual(result.availability, .noRecords)
        XCTAssertEqual(result.billingHistoryInterval, DateInterval(start: created, end: self.now))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        let identity = requests[0]
        XCTAssertEqual(identity.url?.host, "api2.cursor.sh")
        XCTAssertEqual(identity.url?.path, "/aiserver.v1.DashboardService/GetMe")
        XCTAssertEqual(identity.httpMethod, "POST")
        XCTAssertEqual(identity.value(forHTTPHeaderField: "Authorization"), "Bearer aa.bb.cc")
        XCTAssertNil(identity.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(identity.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        var expectedEnd = self.now
        for request in requests.dropFirst() {
            XCTAssertEqual(request.url?.host, "cursor.com")
            XCTAssertEqual(request.url?.path, CursorBillingUsageSyncer.exportPath)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=\(self.cookie)")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let query = try self.query(request)
            XCTAssertEqual(query["scope"], "user")
            let start = try XCTUnwrap(query["startTime"].flatMap(self.date))
            let end = try XCTUnwrap(query["endTime"].flatMap(self.date))
            XCTAssertEqual(end, expectedEnd)
            XCTAssertGreaterThan(end, start)
            XCTAssertLessThanOrEqual(end.timeIntervalSince(start), 31 * self.day)
            XCTAssertGreaterThanOrEqual(start, created)
            expectedEnd = start
        }
        XCTAssertEqual(expectedEnd, created)
    }

    func testIdentityMismatchStopsBeforeAnyBillingExport() async throws {
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: self.now.addingTimeInterval(-self.day), authID: "user_someone_else"),
        ])
        await self.assertFailure(.identityMismatch, transport: transport)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testIncrementalRefreshReplacesRecentWindowAndRetainsOlderBillingHistory() async throws {
        let created = self.now.addingTimeInterval(-100 * self.day)
        let old = self.record("cursor-billing:grok-bot:old", daysAgo: 50, input: 11)
        let removed = self.record("cursor-billing:grok-chat:removed", daysAgo: 10, input: 23)
        let previous = self.snapshot([old, removed], coverage: DateInterval(start: created, end: self.now.addingTimeInterval(-3600)))
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: created),
            .csv(self.csv([self.row(id: "new", at: self.now.addingTimeInterval(-2 * self.day), product: "grok-chat", input: 37)])),
        ])
        let result = try await self.sync(transport, previous: previous)
        XCTAssertEqual(result.usageRecords.map(\.id), [old.id, "cursor-billing:grok-chat:new"])
        XCTAssertEqual(result.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 48)
        XCTAssertEqual(result.billingHistoryInterval, DateInterval(start: created, end: self.now))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let query = try self.query(requests[1])
        XCTAssertEqual(query["startTime"].flatMap(self.date), self.now.addingTimeInterval(-31 * self.day))
        XCTAssertEqual(query["endTime"].flatMap(self.date), self.now)
        XCTAssertEqual(previous.usageRecords.map(\.id), [old.id, removed.id])
    }

    func testSuccessfulEmptyRefreshRemovesOnlyRecordsInTheRefreshedWindow() async throws {
        let created = self.now.addingTimeInterval(-100 * self.day)
        let old = self.record("cursor-billing:grok-bot:old", daysAgo: 50, input: 11)
        let removed = self.record("cursor-billing:grok-chat:removed", daysAgo: 10, input: 23)
        let previous = self.snapshot([old, removed], coverage: DateInterval(start: created, end: self.now.addingTimeInterval(-3600)))
        let transport = CursorBillingTransportFixture(responses: [self.identity(created: created), .csv(self.header)])
        let result = try await self.sync(transport, previous: previous)
        XCTAssertEqual(result.usageRecords, [old])
        XCTAssertEqual(result.dailyEntries.map(\.totalTokens), [11])
        XCTAssertEqual(result.billingHistoryInterval?.end, self.now)
    }

    func testMillisecondBoundaryReplacesRepricedCachedEventWithoutDuplicateConflict() async throws {
        let created = self.now.addingTimeInterval(-100 * self.day)
        let requestedStart = self.now.addingTimeInterval(-32 * self.day + 0.123456)
        let boundary = try XCTUnwrap(self.date(self.iso(requestedStart)))
        XCTAssertLessThan(boundary, requestedStart)
        let cached = ToolUsageRecord(id: "cursor-billing:grok-bot:boundary", timestamp: boundary,
            modelID: "claude-sonnet-4", inputTokens: 10, totalTokens: 10)
        let previous = ToolCostEstimator.reprice(self.snapshot([cached],
            coverage: DateInterval(start: created, end: requestedStart)), calendar: self.calendar)
        XCTAssertGreaterThan(try XCTUnwrap(previous.usageRecords.first?.costUSD), 0)
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: created),
            .csv(self.header),
            .csv(self.csv([self.row(id: "boundary", at: boundary, input: 10)])),
        ])
        let result = try await self.sync(transport, previous: previous)
        XCTAssertEqual(result.usageRecords.count, 1)
        XCTAssertEqual(result.usageRecords.first?.id, cached.id)
        XCTAssertEqual(result.usageRecords.first?.timestamp, boundary)
        XCTAssertNil(result.usageRecords.first?.costUSD, "The refreshed row must replace cached pricing and model metadata")
        XCTAssertEqual(result.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 10)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(try self.query(requests[2])["startTime"].flatMap(self.date), boundary)
    }

    func testSubmillisecondNowDoesNotProduceAnEmptyTailExportWindow() async throws {
        let now = self.now.addingTimeInterval(0.123456)
        let cutoff = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        let created = self.now.addingTimeInterval(-100 * self.day)
        let previous = self.snapshot([], coverage: DateInterval(start: created, end: now.addingTimeInterval(-3600)))
        let transport = CursorBillingTransportFixture(responses: [self.identity(created: created), .csv(self.header)])
        let result = try await CursorBillingUsageSyncer(transport: transport).sync(sessionCookie: self.cookie,
            legacy: self.emptyLegacy, previous: previous, now: now, calendar: self.calendar)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "One identity read and one 31-day export must suffice")
        let query = try self.query(requests[1])
        let start = try XCTUnwrap(query["startTime"].flatMap(self.date))
        let end = try XCTUnwrap(query["endTime"].flatMap(self.date))
        XCTAssertLessThan(start, end)
        XCTAssertEqual(end.timeIntervalSince(start), 31 * self.day, accuracy: 0.000_001)
        XCTAssertEqual(end.timeIntervalSince1970, cutoff.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(result.billingHistoryInterval?.end, cutoff)
    }

    func testFailedHistoricalWindowKeepsFreshUsageAndEarlierCacheWithPartialCoverage() async throws {
        let created = self.now.addingTimeInterval(-70 * self.day)
        let old = self.record("cursor-billing:grok-bot:old", daysAgo: 50, input: 11)
        let removed = self.record("cursor-billing:grok-chat:removed", daysAgo: 10, input: 23)
        let previous = self.snapshot([old, removed], coverage: DateInterval(
            start: self.now.addingTimeInterval(-60 * self.day), end: self.now.addingTimeInterval(-3600)))
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: created),
            .csv(self.csv([self.row(id: "recent", at: self.now.addingTimeInterval(-self.day), input: 19)])),
            .init(status: 503, body: Data(), mimeType: "application/json"),
        ])
        let result = try await self.sync(transport, previous: previous)
        XCTAssertEqual(result.availability, .partial)
        XCTAssertEqual(result.usageRecords.map(\.id), [old.id, "cursor-billing:grok-bot:recent"])
        XCTAssertEqual(result.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 30)
        XCTAssertEqual(result.billingHistoryInterval,
            DateInterval(start: self.now.addingTimeInterval(-31 * self.day), end: self.now))
        XCTAssertGreaterThan(try XCTUnwrap(result.billingHistoryInterval?.start), created)
        XCTAssertEqual(previous.usageRecords.map(\.id), [old.id, removed.id])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testFailedCurrentWindowStillThrowsEvenWhenOlderBillingCacheExists() async throws {
        let created = self.now.addingTimeInterval(-70 * self.day)
        let previous = self.snapshot([self.record("cursor-billing:grok-bot:old", daysAgo: 50, input: 11)])
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: created), .init(status: 503, body: Data(), mimeType: "application/json"),
        ])
        do {
            _ = try await self.sync(transport, previous: previous)
            XCTFail("Old cached rows must not disguise a failed current-window refresh")
        } catch { XCTAssertEqual(error as? CursorAccountError, .networkFailure) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testRejectsCrossHostResponsesAndHTMLInsteadOfPublishingEmptyHistory() async throws {
        let responses: [CursorBillingTransportFixture.Response] = [
            .init(status: 200, body: Data(self.header.utf8), mimeType: "text/csv",
                  url: URL(string: "https://elsewhere.test" + CursorBillingUsageSyncer.exportPath)),
            .init(status: 200, body: Data("<html>Sign in</html>".utf8), mimeType: "text/html"),
        ]
        for response in responses {
            let transport = CursorBillingTransportFixture(responses: [
                self.identity(created: self.now.addingTimeInterval(-self.day)), response,
            ])
            await self.assertFailure(.invalidResponse, transport: transport)
        }
    }

    func testResponseAfterDeadlineCannotAdvanceHistoryCoverage() async throws {
        let clock = CursorBillingTestClock()
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: self.now.addingTimeInterval(-self.day)),
            .init(status: 200, body: Data(self.header.utf8), mimeType: "text/csv", duration: 121),
        ], clock: clock)
        do {
            _ = try await CursorBillingUsageSyncer(transport: transport, monotonicNow: { clock.now })
                .sync(sessionCookie: self.cookie, legacy: self.emptyLegacy, previous: nil, now: self.now, calendar: self.calendar)
            XCTFail("A late complete response must not advance the persisted coverage interval")
        } catch { XCTAssertEqual(error as? CursorAccountError, .incompleteHistory) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testIdenticalStableBillingIDsAtWindowBoundaryAreCountedOnce() async throws {
        let created = self.now.addingTimeInterval(-40 * self.day)
        let boundary = self.now.addingTimeInterval(-31 * self.day)
        let row = self.row(id: "boundary", at: boundary, input: 19)
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: created), .csv(self.csv([row])), .csv(self.csv([row])),
        ])
        let result = try await self.sync(transport)
        XCTAssertEqual(result.usageRecords.count, 1)
        XCTAssertEqual(result.dailyEntries.map(\.totalTokens), [19])
    }

    func testConflictingStableBillingIDsAcrossWindowsRejectTheSync() async throws {
        let created = self.now.addingTimeInterval(-40 * self.day)
        let boundary = self.now.addingTimeInterval(-31 * self.day)
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: created),
            .csv(self.csv([self.row(id: "boundary", at: boundary, input: 19)])),
            .csv(self.csv([self.row(id: "boundary", at: boundary, input: 20)])),
        ])
        await self.assertFailure(.incompleteHistory, transport: transport)
    }

    func testRowsOutsideTheRequestedExportWindowAreRejected() async throws {
        let created = self.now.addingTimeInterval(-self.day)
        let transport = CursorBillingTransportFixture(responses: [
            self.identity(created: created),
            .csv(self.csv([self.row(id: "out-of-range", at: created.addingTimeInterval(-self.day))])),
        ])
        await self.assertFailure(.invalidResponse, transport: transport)
    }

    func testLegacyMatchingConsumesOneEventAndPreservesItsMissingMetadata() throws {
        let date = self.now.addingTimeInterval(-self.day)
        let first = ToolUsageRecord(id: "legacy-a", timestamp: date, modelID: "test-model", sessionID: "session-a",
                                    inputTokens: 10, totalTokens: 10, costUSD: 0.25, costEvidence: .reported)
        let second = ToolUsageRecord(id: "legacy-b", timestamp: date, modelID: "test-model", sessionID: "session-b",
                                     inputTokens: 10, totalTokens: 10, costUSD: 0.25, costEvidence: .reported)
        let billing = ToolUsageRecord(id: "cursor-billing:cursor:item", timestamp: date,
                                      inputTokens: 10, totalTokens: 10, billedCostUSD: 0)
        let result = try CursorBillingUsageSyncer.merged(legacy: self.snapshot([first, second]), billing: [billing],
            coverage: DateInterval(start: date, end: self.now), now: self.now, calendar: self.calendar)
        XCTAssertEqual(result.usageRecords.count, 2)
        XCTAssertEqual(result.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 20)
        let matched = try XCTUnwrap(result.usageRecords.first { $0.id == billing.id })
        XCTAssertEqual(matched.modelID, "test-model")
        XCTAssertNotNil(matched.sessionID)
        XCTAssertEqual(matched.costUSD, 0.25)
        XCTAssertEqual(matched.billedCostUSD, 0)
        XCTAssertEqual(Set(result.usageRecords.compactMap(\.sessionID)), ["session-a", "session-b"])
    }

    func testBotAndChatEventsNeverConsumeAnIdenticalLegacyCursorEvent() throws {
        let date = self.now.addingTimeInterval(-self.day)
        let legacy = ToolUsageRecord(id: "legacy", timestamp: date, inputTokens: 10, totalTokens: 10)
        let billing = ["grok-bot", "grok-chat"].map {
            ToolUsageRecord(id: "cursor-billing:\($0):item", timestamp: date, inputTokens: 10, totalTokens: 10)
        }
        let result = try CursorBillingUsageSyncer.merged(legacy: self.snapshot([legacy]), billing: billing,
            coverage: DateInterval(start: date, end: self.now), now: self.now, calendar: self.calendar)
        XCTAssertEqual(Set(result.usageRecords.map(\.id)), Set([legacy.id] + billing.map(\.id)))
        XCTAssertEqual(result.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 30)
    }

    func testKnownLegacyBotModelsDeduplicateOnlyWithinTheirOwnProduct() throws {
        let date = self.now.addingTimeInterval(-self.day)
        for model in ["grok-bot-default", "grok-bot-automation", "grok-bot-cua"] {
            let bot = ToolUsageRecord(id: "legacy-bot", timestamp: date, modelID: model,
                sessionID: "bot-session", inputTokens: 10, totalTokens: 10)
            let cursor = ToolUsageRecord(id: "legacy-cursor", timestamp: date, modelID: "claude-sonnet-4",
                sessionID: "cursor-session", inputTokens: 10, totalTokens: 10)
            // Cursor sorts first. It must not consume the first (Bot) legacy candidate.
            let billing = ["cursor", "grok-bot"].map {
                ToolUsageRecord(id: "cursor-billing:\($0):item", timestamp: date, inputTokens: 10, totalTokens: 10)
            }
            let result = try CursorBillingUsageSyncer.merged(legacy: self.snapshot([bot, cursor]), billing: billing,
                coverage: DateInterval(start: date, end: self.now), now: self.now, calendar: self.calendar)
            XCTAssertEqual(Set(result.usageRecords.map(\.id)), Set(billing.map(\.id)), model)
            XCTAssertEqual(result.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 20, model)
            let matchedBot = try XCTUnwrap(result.usageRecords.first { $0.id == "cursor-billing:grok-bot:item" })
            let matchedCursor = try XCTUnwrap(result.usageRecords.first { $0.id == "cursor-billing:cursor:item" })
            XCTAssertEqual(matchedBot.modelID, model)
            XCTAssertEqual(matchedBot.sessionID, "bot-session")
            XCTAssertEqual(matchedCursor.modelID, "claude-sonnet-4")
            XCTAssertEqual(matchedCursor.sessionID, "cursor-session")
        }
    }

    func testEpochMillisecondsAndISOParsedBillingTimestampMatchTheSameCursorEvent() throws {
        let milliseconds = Int64(self.now.addingTimeInterval(-self.day).timeIntervalSince1970 * 1000) + 123
        let legacy = try CursorUsageSyncer.snapshot(from: [[
            "timestamp": String(milliseconds), "model": "fixture-model",
            "tokenUsage": ["inputTokens": 10],
        ]], now: self.now, calendar: self.calendar)
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let billing = try CursorBillingCSVParser().parse(self.csv([
            self.row(id: "millisecond-event", at: date, product: "cursor", input: 10),
        ]), now: self.now)
        XCTAssertEqual(Int64((try XCTUnwrap(legacy.usageRecords.first?.timestamp).timeIntervalSince1970 * 1000).rounded()), milliseconds)
        XCTAssertEqual(Int64((try XCTUnwrap(billing.first?.timestamp).timeIntervalSince1970 * 1000).rounded()), milliseconds)
        let result = try CursorBillingUsageSyncer.merged(legacy: legacy, billing: billing,
            coverage: DateInterval(start: date, end: self.now), now: self.now, calendar: self.calendar)
        XCTAssertEqual(result.usageRecords.map(\.id), ["cursor-billing:cursor:millisecond-event"])
        XCTAssertEqual(result.dailyEntries.reduce(0) { $0 + $1.totalTokens }, 10)
        XCTAssertEqual(result.usageRecords.first?.modelID, "fixture-model")
    }

    private func sync(_ transport: CursorBillingTransportFixture, previous: ToolUsageSnapshot? = nil) async throws -> ToolUsageSnapshot {
        try await CursorBillingUsageSyncer(transport: transport).sync(sessionCookie: self.cookie,
            legacy: self.emptyLegacy, previous: previous, now: self.now, calendar: self.calendar)
    }

    private func assertFailure(_ expected: CursorAccountError, transport: CursorBillingTransportFixture) async {
        do {
            _ = try await self.sync(transport)
            XCTFail("The incomplete or invalid export must not become a successful snapshot")
        } catch { XCTAssertEqual(error as? CursorAccountError, expected) }
    }

    private func identity(created: Date, authID: String = "user_fixture") -> CursorBillingTransportFixture.Response {
        .init(status: 200, body: try! JSONSerialization.data(withJSONObject: [
            "authId": authID, "userId": 123, "createdAt": self.iso(created),
        ]), mimeType: "application/json")
    }

    private func record(_ id: String, daysAgo: Double, input: Int) -> ToolUsageRecord {
        ToolUsageRecord(id: id, timestamp: self.now.addingTimeInterval(-daysAgo * self.day), inputTokens: input, totalTokens: input)
    }

    private func snapshot(_ records: [ToolUsageRecord], coverage: DateInterval? = nil) -> ToolUsageSnapshot {
        ToolUsageSnapshot(client: .cursor, availability: .ready, evidence: .server,
            usageRecords: records, latestUsageAt: records.map(\.timestamp).max(), billingHistoryInterval: coverage)
    }

    private func row(id: String, at date: Date, product: String = "grok-bot", input: Int = 10) -> String {
        let values = [id, self.iso(date), product, "usage", "included", "user", "fixture-principal",
                      "{\"prompt-text-tokens\":\"\(input)\"}", "USD", "0", "", "fixture@example.test"]
        return values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
    }

    private func csv(_ rows: [String]) -> String { ([self.header] + rows).joined(separator: "\n") + "\n" }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private func query(_ request: URLRequest) throws -> [String: String] {
        let url = try XCTUnwrap(request.url)
        return Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } })
    }
}

private actor CursorBillingTransportFixture: CursorUsageHTTPTransport {
    struct Response: Sendable {
        let status: Int
        let body: Data
        let mimeType: String
        var url: URL? = nil
        var duration: TimeInterval = 0
        static func csv(_ text: String) -> Self { .init(status: 200, body: Data(text.utf8), mimeType: "text/csv") }
    }
    private var responses: [Response]
    private let clock: CursorBillingTestClock?
    private(set) var requests: [URLRequest] = []

    init(responses: [Response], clock: CursorBillingTestClock? = nil) {
        self.responses = responses
        self.clock = clock
    }

    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        guard !self.responses.isEmpty else { throw CursorUsageSyncError.incompleteHistory }
        let response = self.responses.removeFirst()
        self.clock?.advance(by: response.duration)
        guard response.body.count <= limit else { throw CursorUsageSyncError.responseTooLarge }
        return (response.body, HTTPURLResponse(url: response.url ?? request.url!, statusCode: response.status,
            httpVersion: nil, headerFields: ["Content-Type": response.mimeType])!)
    }
}

private nonisolated final class CursorBillingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    var now: TimeInterval { self.lock.withLock { self.elapsed } }
    func advance(by duration: TimeInterval) { self.lock.withLock { self.elapsed += duration } }
}
