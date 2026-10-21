import Foundation
import XCTest
@testable import codexbar

final class ToolUsageLiveProbeTests: XCTestCase {
    func testUnifiedGrokAccountServerHistoryIfOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_LIVE_GROK_BILLING_PROBE"] == "1" else {
            throw XCTSkip("Real account metadata is read only when explicitly opted in")
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codexbar/cursor-accounts")
        struct Accounts: Decodable { let selectedAccountID: String }
        struct Credential: Decodable { let sessionCookie: String }
        let account = try JSONDecoder().decode(Accounts.self, from: Data(contentsOf: root.appendingPathComponent("accounts.json")))
        let credential = try JSONDecoder().decode(Credential.self, from: Data(contentsOf: root.appendingPathComponent("credentials/\(account.selectedAccountID).json")))
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let snapshot = try await CursorAccountService(transport: GrokLiveProbeTransport()).usage(sessionCookie: credential.sessionCookie, now: now, calendar: calendar)
        let today = snapshot.dailyEntries.filter { $0.date >= calendar.startOfDay(for: now) }.reduce(0) { $0 + $1.totalTokens }
        let bot = snapshot.usageRecords.filter { $0.id.hasPrefix("cursor-billing:grok-bot:") }
        let chat = snapshot.usageRecords.filter { $0.id.hasPrefix("cursor-billing:grok-chat:") }
        XCTAssertGreaterThan(today, 0)
        XCTAssertFalse(bot.isEmpty)
        XCTAssertFalse(chat.isEmpty)
        XCTAssertTrue(snapshot.availability == .ready || snapshot.availability == .partial)
        if snapshot.availability == .partial {
            XCTAssertTrue(snapshot.statusDetail?.contains("部分旧月份导出暂不可用") == true)
        }
        XCTAssertNotNil(snapshot.billingHistoryInterval)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains(credential.sessionCookie))
        let summary: [String: Any] = ["todayTokens": today, "records": snapshot.usageRecords.count,
                                     "grokBotRecords": bot.count, "grokChatRecords": chat.count,
                                     "allTokens": snapshot.dailyEntries.reduce(0) { $0 + $1.totalTokens },
                                     "billingTokens": snapshot.usageRecords.filter { $0.id.hasPrefix("cursor-billing:") }.reduce(0) { $0 + $1.totalTokens },
                                     "periodEnd": snapshot.billingHistoryInterval?.end.timeIntervalSince1970 ?? 0,
                                     "availability": snapshot.availability.rawValue]
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-grok-usage-20261021/live-summary.json")
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("GROK_BILLING_PROBE todayTokens=\(today) botRecords=\(bot.count) chatRecords=\(chat.count)")
    }

    func testAntigravityKnownCostFromExistingMetadataIfOptedIn() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_LIVE_COST_PROBE"] == "1" else {
            throw XCTSkip("Real local cost metadata is read only when explicitly opted in")
        }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codexbar/tool-usage-summary.json")
        let snapshots = try JSONDecoder().decode([ToolUsageSnapshot].self, from: Data(contentsOf: cache))
        let original = try XCTUnwrap(snapshots.first { $0.client == .antigravity })
        let repriced = ToolCostEstimator.reprice(original)
        XCTAssertEqual(repriced.dailyEntries.map(\.totalTokens), original.dailyEntries.map(\.totalTokens))
        let page = MonitorPageData.build(costSummary: .empty, records: nil,
            toolSnapshots: [.antigravity: repriced], modelUsage: nil, runningThreads: .empty,
            period: .allTime, scope: .client(.antigravity), now: Date())
        let mixed = page.sessions.filter {
            $0.modelIDs.contains("gemini-4-argon-trial") && $0.knownCostUSD > 0 && !$0.costIsComplete
        }
        XCTAssertFalse(mixed.isEmpty)
        XCTAssertTrue(repriced.usageRecords.filter { $0.modelID == "gemini-4-argon-trial" }.allSatisfy { $0.costUSD == nil })
        let summary: [[String: Any]] = mixed.map {
            ["tokens": $0.totalTokens, "knownCostUSD": $0.knownCostUSD, "complete": $0.costIsComplete]
        }
        print("COST_PROBE pricedRecords=\(repriced.usageRecords.filter { $0.costUSD != nil }.count) mixedSessions=\(mixed.count)")
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-cost-login-20261020")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("live-cost-summary.json"))
    }

    func testLocalAntigravityAndManagedCursorHistoryIfOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_LIVE_TOKEN_PROBE"] == "1" else {
            throw XCTSkip("Real local usage metadata is read only when explicitly opted in")
        }
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let usageCalendar = calendar
        let antigravity = await Task.detached {
            AntigravityUsageCollector().collect(now: now, calendar: usageCalendar)
        }.value
        struct Accounts: Decodable { let accounts: [CursorManagedAccount] }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codexbar/cursor-accounts")
        let accounts = try JSONDecoder().decode(Accounts.self,
            from: Data(contentsOf: root.appendingPathComponent("accounts.json"))).accounts
        var states: [String: CursorAccountState] = [:]
        for account in accounts {
            let url = root.appendingPathComponent("snapshots").appendingPathComponent(account.id + ".json")
            if let data = try? Data(contentsOf: url) {
                states[account.id] = try JSONDecoder().decode(CursorAccountState.self, from: data)
            }
        }
        let cursor = CursorUsageAggregation.snapshot(accounts: accounts, states: states, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        var summary: [[String: Any]] = []
        for snapshot in [antigravity, cursor] {
            let todayTokens = snapshot.dailyEntries.filter { $0.date >= today && $0.date <= now }
                .reduce(0) { $0 + $1.totalTokens }
            XCTAssertGreaterThan(todayTokens, 0, "\(snapshot.client.rawValue) should expose the known local history")
            summary.append([
                "client": snapshot.client.rawValue, "status": snapshot.availability.rawValue,
                "records": snapshot.usageRecords.count, "todayTokens": todayTokens,
                "totalTokens": snapshot.dailyEntries.reduce(0) { $0 + $1.totalTokens }
            ])
            print("TOKEN_PROBE client=\(snapshot.client.rawValue) status=\(snapshot.availability.rawValue) records=\(snapshot.usageRecords.count) todayTokens=\(todayTokens)")
        }
        let output = URL(fileURLWithPath: "/private/tmp/codexbar-token-usage-20261020")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("live-summary.json"))
    }
}

private struct GrokLiveProbeTransport: CursorUsageHTTPTransport {
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let result = try await CursorUsageURLSessionTransport().data(for: request, limit: limit)
        // Only endpoint paths and response sizes: never query strings, cookies, identities or bodies.
        print("GROK_PROBE_HTTP path=\(request.url?.path ?? "") status=\(result.1.statusCode) bytes=\(result.0.count)")
        return result
    }
}
