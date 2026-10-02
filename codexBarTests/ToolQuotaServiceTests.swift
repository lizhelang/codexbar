import Foundation
import XCTest
@testable import codexbar

final class ToolQuotaServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    func testClaudeReturnsRealWindowsAndRejectsInvalidNumbers() {
        let snapshot = ToolQuotaService.parseClaude([
            "five_hour": ["utilization": 24.5, "resets_at": "2026-10-01T12:00:00Z"],
            "seven_day": ["utilization": 110],
            "seven_day_opus": ["utilization": true],
            "seven_day_sonnet": ["utilization": Double.infinity],
        ], now: self.now)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [24.5, 100])
        XCTAssertNotNil(snapshot.windows.first?.resetsAt)
        XCTAssertNil(snapshot.balance)
    }

    func testCursorSeparatesModelWindowsAndBillingAmounts() {
        let snapshot = ToolQuotaService.parseCursor([
            "billingCycleEnd": "2026-10-10T00:00:00.000Z",
            "individualUsage": [
                "plan": ["autoPercentUsed": 20, "apiPercentUsed": 75],
                "onDemand": ["used": 1550, "limit": 10000],
            ],
            "teamUsage": ["pooled": ["used": 2500, "limit": 10000]],
        ], now: self.now)
        XCTAssertEqual(snapshot.windows.count, 4)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 20)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 75)
        XCTAssertEqual(snapshot.windows[2].used, 15.5)
        XCTAssertEqual(snapshot.windows[2].limit, 100)
        XCTAssertEqual(snapshot.windows[3].usedPercent, 25)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt != nil })
        XCTAssertEqual(ToolQuotaService.parseCursor([:], now: self.now).status, .unsupported)
    }

    func testGoRateLimitedWithoutPercentAndDeepSeekBalanceAreNotInferred() {
        let go = ToolQuotaService.parseOpenCodeGo(["usage": [
            "rolling": ["status": "rate-limited"],
            "weekly": ["percent": 32],
        ]], now: self.now)
        XCTAssertEqual(go.windows.map(\.usedPercent), [100, 32])
        XCTAssertTrue(go.windows.allSatisfy { $0.used == nil && $0.limit == nil })
        let balance = ToolQuotaService.deepSeekBalance(["balance_infos": [
            ["currency": "USD", "total_balance": "-0.05"],
        ]])
        XCTAssertEqual(balance?.amount, -0.05)
        XCTAssertEqual(balance?.currency, "USD")
    }

    func testDSHCachedProviderKeepsIdentityAndNeverIncludesCredential() throws {
        let snapshot = try XCTUnwrap(ToolQuotaService.parseDeepSeekSnapshot(["providers": [
            "custom": ["displayName": "Relay", "credential": "must-not-persist",
                       "balance": ["currency": "CNY", "totalBalance": "15.3", "updatedAt": 1791000000000]],
            "official": ["displayName": "DeepSeek", "credential": "other-private-value",
                         "balance": ["currency": "USD", "totalBalance": "5", "updatedAt": 1790000000000]],
        ]]))
        XCTAssertEqual(snapshot.providerName, "DSH · Relay")
        XCTAssertEqual(snapshot.balance?.amount, 15.3)
        XCTAssertTrue(snapshot.windows.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("must-not-persist"))
        XCTAssertFalse(encoded.contains("other-private-value"))
        XCTAssertFalse(encoded.contains("credential"))
    }

    func testDSHThirdPartyOrUnboundKeyNeverLeavesDevice() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for baseURL in [nil, "https://ds.zooe.cc/v1", "http://api.deepseek.com", "https://api.deepseek.com.evil.test", "https://api.deepseek.com:444", "https://user:pass@api.deepseek.com"] {
            var environment = ["DEEPSEEK_API_KEY": "private-third-party-key"]
            environment["DEEPSEEK_BASE_URL"] = baseURL
            let transport = QuotaFixtureTransport(body: #"{"balance_infos":[{"currency":"USD","total_balance":"8"}]}"#)
            let service = ToolQuotaService(transport: transport, home: home, environment: environment, readsSystemKeychain: false)
            let snapshot = await service.fetch(client: .deepSeekHarness, preferences: ApplicationPreferences(), now: self.now)
            XCTAssertEqual(snapshot.status, .notConfigured)
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testDSHExplicitOfficialBindingUsesOnlyFixedBalanceEndpoint() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = QuotaFixtureTransport(body: #"{"balance_infos":[{"currency":"USD","total_balance":"8"}]}"#)
        let service = ToolQuotaService(transport: transport, home: home,
            environment: ["DEEPSEEK_API_KEY": "official-fixture", "DEEPSEEK_BASE_URL": "https://api.deepseek.com/v1"],
            readsSystemKeychain: false)
        let snapshot = await service.fetch(client: .deepSeekHarness, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.balance?.amount, 8)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, ["https://api.deepseek.com/user/balance"])
    }

    func testOpenCodeCustomProviderDoesNotSendKeyToOfficialService() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try self.write(#"{"deepseek":{"type":"api","key":"third-party-key"}}"#, to: home, path: ".local/share/opencode/auth.json")
        try self.write("""
        { // A built-in provider ID can still point at a private service.
          "provider": { "deepseek": { "options": { "baseURL": "https://relay.example/v1", }, }, },
        }
        """, to: home, path: ".config/opencode/opencode.jsonc")
        let transport = QuotaFixtureTransport(body: "{}")
        let service = ToolQuotaService(transport: transport, home: home, environment: [:], readsSystemKeychain: false)
        let snapshot = await service.fetch(client: .openCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(snapshot.status, .unsupported)
        XCTAssertTrue(snapshot.statusDetail.contains("自定义"))
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOpenCodeInvalidConfigurationFailsClosed() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = QuotaFixtureTransport(body: "{}")
        let service = ToolQuotaService(transport: transport, home: home, environment: [
            "OPENCODE_AUTH_CONTENT": #"{"deepseek":{"type":"api","key":"fixture"}}"#,
            "OPENCODE_CONFIG_CONTENT": "{malformed",
        ], readsSystemKeychain: false)
        let snapshot = await service.fetch(client: .openCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(snapshot.status, .unsupported)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOpenCodeOfficialAccountsReturnQuotaAndProviderSpecificBalance() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = QuotaFixtureTransport(body: """
        {"rate_limit":{"primary_window":{"used_percent":45,"limit_window_seconds":18000,"reset_at":1791001000}},
         "balance_infos":[{"currency":"CNY","total_balance":"12.3"}]}
        """)
        let service = ToolQuotaService(transport: transport, home: home, environment: [
            "OPENCODE_AUTH_CONTENT": #"{"openai":{"type":"oauth","access":"oauth-fixture","accountId":"account-fixture"},"deepseek":{"type":"api","key":"api-fixture"}}"#,
            "DEEPSEEK_BASE_URL": "https://api.deepseek.com",
        ], readsSystemKeychain: false)
        let snapshot = await service.fetch(client: .openCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 45)
        XCTAssertEqual(snapshot.balance?.amount, 12.3)
        XCTAssertTrue(snapshot.providerName.contains("OpenAI"))
        XCTAssertTrue(snapshot.providerName.contains("DeepSeek"))
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.host }, ["chatgpt.com", "api.deepseek.com"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-fixture")
    }

    func testClaudeCustomEndpointAndRedirectedResponseAreRejected() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = QuotaFixtureTransport(body: #"{"five_hour":{"utilization":2}}"#, responseURL: URL(string: "https://other.example/quota"))
        let custom = ToolQuotaService(transport: transport, home: home, environment: [
            "CLAUDE_CODE_OAUTH_TOKEN": "fixture", "ANTHROPIC_BASE_URL": "https://relay.example",
        ], readsSystemKeychain: false)
        let customSnapshot = await custom.fetch(client: .claudeCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(customSnapshot.status, .unsupported)
        let initialRequests = await transport.requests
        XCTAssertTrue(initialRequests.isEmpty)
        let official = ToolQuotaService(transport: transport, home: home, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "fixture"], readsSystemKeychain: false)
        let redirect = await official.fetch(client: .claudeCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(redirect.status, .failed)
        XCTAssertTrue(redirect.windows.isEmpty)
    }

    func testAuthenticationFailureAndGoNoSubscriptionAreDistinct() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = QuotaFixtureTransport(body: "{}", statusCode: 401)
        let claude = ToolQuotaService(transport: transport, home: home, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "fixture"], readsSystemKeychain: false)
        let expired = await claude.fetch(client: .claudeCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(expired.status, .authenticationRequired)
        let goTransport = QuotaFixtureTransport(body: #"{"error":{"type":"EntitlementError"}}"#, statusCode: 403)
        let go = ToolQuotaService(transport: goTransport, home: home,
            environment: ["OPENCODE_AUTH_CONTENT": #"{"opencode-go":{"type":"api","key":"fixture"}}"#], readsSystemKeychain: false)
        let noPlan = await go.fetch(client: .openCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(noPlan.status, .unsupported)
        XCTAssertTrue(noPlan.statusDetail.contains("没有 OpenCode Go 订阅"))
    }

    func testUnboundOpenCodeAPIKeyAndMalformedWindowCannotEscapeOrCrash() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = QuotaFixtureTransport(body: "{}")
        let service = ToolQuotaService(transport: transport, home: home, environment: [
            "OPENCODE_AUTH_CONTENT": #"{"deepseek":{"type":"api","key":"unbound-fixture"}}"#,
        ], readsSystemKeychain: false)
        let snapshot = await service.fetch(client: .openCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(snapshot.status, .unsupported)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        let malformed = ToolQuotaService.openAIWindows(["rate_limit": [
            "primary_window": ["used_percent": 1, "limit_window_seconds": 1e100],
        ]])
        XCTAssertEqual(malformed.count, 1)
        XCTAssertEqual(malformed.first?.label, "OpenAI · 用量")
    }

    func testExpiredOpenCodeOpenAIRequiresAuthentication() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = QuotaFixtureTransport(body: "{}", statusCode: 401)
        let service = ToolQuotaService(transport: transport, home: home, environment: [
            "OPENCODE_AUTH_CONTENT": #"{"openai":{"type":"oauth","access":"expired-fixture"}}"#,
        ], readsSystemKeychain: false)
        let snapshot = await service.fetch(client: .openCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(snapshot.status, .authenticationRequired)
        XCTAssertTrue(snapshot.statusDetail.contains("在 OpenCode 重新登录 OpenAI"))
        XCTAssertTrue(snapshot.windows.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, ["https://chatgpt.com/backend-api/wham/usage"])
    }

    func testExpiredGoDoesNotHideOtherOpenCodeProviderQuota() async throws {
        let home = try self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = MixedGoQuotaFixtureTransport()
        let service = ToolQuotaService(transport: transport, home: home, environment: [
            "OPENCODE_AUTH_CONTENT": #"{"opencode-go":{"type":"api","key":"expired-go"},"openai":{"type":"oauth","access":"valid-openai"}}"#,
        ], readsSystemKeychain: false)
        let snapshot = await service.fetch(client: .openCode, preferences: ApplicationPreferences(), now: self.now)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.providerName, "OpenAI")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 45)
        XCTAssertTrue(snapshot.statusDetail.contains("OpenCode Go 登录/额度读取失败"))
        let hosts = await transport.hosts
        XCTAssertEqual(hosts, ["opencode.ai", "chatgpt.com"])
    }

    func testLiveConfiguredSourcesIfOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_LIVE_QUOTA_PROBE"] == "1" else {
            throw XCTSkip("Read-only live quota probe is opt-in; deterministic tests do not access real credentials")
        }
        let service = ToolQuotaService()
        let results = await Task.detached(priority: .utility) {
            var summaries: [String] = []
            for client in ToolUsageClient.allCases {
                let snapshot = await service.fetch(client: client, preferences: ApplicationPreferences(), now: Date())
                summaries.append("QUOTA_PROBE client=\(client.rawValue) status=\(snapshot.status.rawValue) windows=\(snapshot.windows.count) hasBalance=\(snapshot.balance != nil) detail=\(snapshot.statusDetail)")
            }
            do {
                let usage = try await CursorUsageSyncer().sync(now: Date(), calendar: .current)
                let known = usage.usageRecords.filter { $0.costUSD != nil }.count
                summaries.append("CURSOR_USAGE_PROBE status=\(usage.availability.rawValue) records=\(usage.usageRecords.count) knownCosts=\(known) unknownCosts=\(usage.usageRecords.count - known)")
            } catch let error as CursorUsageSyncError {
                summaries.append("CURSOR_USAGE_PROBE failed=\(error.statusDetail)")
            } catch {
                summaries.append("CURSOR_USAGE_PROBE failed=network-or-response")
            }
            return summaries
        }.value
        for result in results { print(result) }
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to home: URL, path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
}

private actor QuotaFixtureTransport: CursorUsageHTTPTransport {
    let body: String
    let statusCode: Int
    let responseURL: URL?
    private(set) var requests: [URLRequest] = []
    init(body: String, statusCode: Int = 200, responseURL: URL? = nil) {
        self.body = body
        self.statusCode = statusCode
        self.responseURL = responseURL
    }
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        let data = Data(self.body.utf8)
        guard data.count < limit else { throw CursorUsageSyncError.responseTooLarge }
        return (data, HTTPURLResponse(url: self.responseURL ?? request.url!, statusCode: self.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private actor MixedGoQuotaFixtureTransport: CursorUsageHTTPTransport {
    private(set) var hosts: [String] = []
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let host = request.url!.host!
        self.hosts.append(host)
        let body = host == "opencode.ai" ? "{}" : #"{"rate_limit":{"primary_window":{"used_percent":45,"limit_window_seconds":18000}}}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: host == "opencode.ai" ? 403 : 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
