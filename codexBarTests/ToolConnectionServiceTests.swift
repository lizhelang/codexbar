import Foundation
import XCTest
@testable import codexbar

final class ToolConnectionServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private let openCodeGoResponse = #"{"usage":{"rolling":{"percent":30},"weekly":{"percent":20}}}"#
    private let openCodeGoPage = "rollingUsage:{usagePercent:45,resetInSec:3600},weeklyUsage:{usagePercent:65,resetInSec:604800}"

    func testClaudeAliasesCreditsAndUnexpiredResetGrantsPreserveReportedUnits() {
        let snapshot = ToolQuotaService.parseClaude([
            "fiveHour": ["usedPercent": 20, "utilization": 99, "resetsAt": "2026-10-10T12:00:00Z"],
            "sevenDay": ["used_percent": 40],
            "spend": ["enabled": true, "used": ["amount_minor": 235, "exponent": 2, "currency": "USD"],
                      "limit": ["amount_minor": 2000, "exponent": 2, "currency": "USD"]],
            "extra_usage": ["is_enabled": true, "used_credits": 9999, "monthly_limit": 99999],
            "cedar_ember": ["grants": [["resets_left": 2, "ends_at": "2026-10-10T00:00:00Z"],
                                        ["resets_left": 10, "ends_at": "2020-01-01T00:00:00Z"], ["resets_left": 0]]],
        ], now: self.now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "usageCredits"])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 20)
        XCTAssertEqual(snapshot.windows[2].used, 2.35)
        XCTAssertEqual(snapshot.windows[2].limit, 20)
        XCTAssertTrue(snapshot.statusDetail.contains("2 张可用重置卡"))
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
    }

    func testClaudeUnlimitedCreditsShowMoneyWithoutInventingPercent() {
        let snapshot = ToolQuotaService.parseClaude([
            "extraUsage": ["isEnabled": true, "used_credits": 450, "decimalPlaces": 2, "currency": "USD"],
        ], now: self.now)
        XCTAssertEqual(snapshot.windows.first?.used, 4.5)
        XCTAssertNil(snapshot.windows.first?.usedPercent)
        XCTAssertNil(snapshot.windows.first?.limit)
    }

    func testOpenCodeWebJSONAliasesAndFractionalPercentageUseUpstreamUnits() {
        let parsed = ToolConnectionService.parseOpenCodeWeb(#"{"rollingUsage":{"usagePercent":0.56,"reset_in_sec":3600},"weeklyUsage":{"used":3,"limit":10,"resetsAt":"2026-10-10T00:00:00Z"},"currentBalanceUSD":12.5}"#, now: self.now)
        XCTAssertEqual(parsed.windows.first?.usedPercent ?? -1, 56, accuracy: 0.0001)
        XCTAssertEqual(parsed.windows.last?.usedPercent, 30)
        XCTAssertEqual(parsed.balance?.amount, 12.5)
        XCTAssertNotNil(parsed.windows.first?.resetsAt)
        XCTAssertNotNil(parsed.windows.last?.resetsAt)
    }

    func testOpenCodeWebAmountRatiosAreConvertedToPercentageOnce() {
        let parsed = ToolConnectionService.parseOpenCodeWeb(#"{"rollingUsage":{"used":0,"limit":100},"weeklyUsage":{"used":0.5,"limit":100},"monthlyUsage":{"used":1,"limit":100}}"#, now: self.now)
        XCTAssertEqual(parsed.windows.map(\.usedPercent), [0, 0.5, 1])
    }

    func testOpenCodeWebReportedFractionalPercentageBoundaryValuesRemainCompatible() {
        let parsed = ToolConnectionService.parseOpenCodeWeb(#"{"rollingUsage":{"usagePercent":0},"weeklyUsage":{"usagePercent":0.5},"monthlyUsage":{"usagePercent":1}}"#, now: self.now)
        XCTAssertEqual(parsed.windows.map(\.usedPercent), [0, 50, 100])
    }

    func testCredentialNormalizationRejectsHeaderInjectionAndClaudeWholeCookie() throws {
        XCTAssertEqual(try ToolConnectionService.claudeCookie("sk-ant-fixture"), "sessionKey=sk-ant-fixture")
        XCTAssertEqual(try ToolConnectionService.openCodeCookie("Cookie: auth=fixture; workspace=one"), "auth=fixture; workspace=one")
        XCTAssertEqual(try ToolConnectionService.openCodeCookie("fixture"), "auth=fixture")
        for invalid in ["sessionKey=sk-ant-fixture; other=bad", "Cookie: sessionKey=sk-ant-fixture", "sk-ant-fixture\r\nX-Leak: yes"] {
            XCTAssertThrowsError(try ToolConnectionService.claudeCookie(invalid))
        }
        XCTAssertThrowsError(try ToolConnectionService.openCodeCookie("auth=fixture\r\nX-Leak: yes"))
        XCTAssertThrowsError(try ToolConnectionService.organizationID("org/../../other"))
    }

    func testClaudeDiscoversEnvironmentThenFileThenInjectedKeychain() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        try self.write(#"{"claudeAiOauth":{"accessToken":"file-fixture"}}"#, home: home, path: ".claude/.credentials.json")
        let keychain = Data(#"{"claudeAiOauth":{"accessToken":"keychain-fixture"}}"#.utf8)
        let environment = ToolConnectionService(home: home, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "env-fixture"], keychainReader: { keychain })
        let fromEnvironment = try await environment.discover(client: .claudeCode, preferences: ApplicationPreferences())
        XCTAssertEqual(fromEnvironment.first?.credential.oauthToken, "env-fixture")
        let file = ToolConnectionService(home: home, environment: [:], keychainReader: { keychain })
        let fromFile = try await file.discover(client: .claudeCode, preferences: ApplicationPreferences())
        XCTAssertEqual(fromFile.first?.credential.oauthToken, "file-fixture")
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/.credentials.json"))
        let fromKeychain = try await file.discover(client: .claudeCode, preferences: ApplicationPreferences())
        XCTAssertEqual(fromKeychain.first?.credential.oauthToken, "keychain-fixture")
    }

    func testClaudeWebOrganizationSelectionIsScopedAndRenewedSessionStaysBackendOnly() async throws {
        let transport = ConnectionFixtureTransport([
            .init(body: #"[{"uuid":"api","capabilities":["api"]},{"uuid":"org-one","name":"One","capabilities":["chat","claude_pro"]},{"uuid":"org-two","name":"Two","capabilities":["chat"]}]"#, cookie: "sessionKey=sk-ant-rotated; Path=/"),
            .init(body: #"{"five_hour":{"utilization":12}}"#, cookie: "sessionKey=sk-ant-final; Path=/"),
            .init(body: #"{"uuid":"account-fixture","email_address":"fixture@example.test"}"#),
        ])
        let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
        let profile = ManagedToolConnection(id: "claudeCode", client: .claudeCode, label: "Claude", source: "fixture", organizationID: "org-two")
        let result = try await service.query(profile: profile, credential: ManagedToolCredential(cookie: "sessionKey=sk-ant-initial"), now: self.now)
        XCTAssertEqual(result.organizationID, "org-two")
        XCTAssertEqual(result.accountIdentity, "account:account-fixture:organization:org-two")
        XCTAssertEqual(result.renewedCookie, "sessionKey=sk-ant-final")
        let requests = await transport.requests
        XCTAssertEqual(requests[1].url?.path, "/api/organizations/org-two/usage")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-ant-rotated")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-ant-final")
        let encoded = String(decoding: try JSONEncoder().encode(result.snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sk-ant-"))
    }

    func testClaudeManyOrganizationsRequireChoiceAndWebAuthenticationNeverFallsBackToOAuth() async throws {
        let transport = ConnectionFixtureTransport([.init(body: #"[{"uuid":"one","capabilities":["chat"]},{"uuid":"two","capabilities":["chat"]}]"#)])
        let service = ToolConnectionService(transport: transport, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "must-not-be-used"], keychainReader: { nil })
        let profile = ManagedToolConnection(id: "claudeCode", client: .claudeCode, label: "Claude", source: "fixture")
        do { _ = try await service.query(profile: profile, credential: ManagedToolCredential(cookie: "sk-ant-fixture"), now: self.now); XCTFail("Choice required") }
        catch { XCTAssertEqual(error as? ToolConnectionError, .organizationSelectionRequired) }
        let rejected = ConnectionFixtureTransport([.init(status: 401, body: #"{"error":"sk-ant-must-not-surface"}"#)])
        let auth = ToolConnectionService(transport: rejected, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "must-not-be-used"], keychainReader: { nil })
        do { _ = try await auth.query(profile: profile, credential: ManagedToolCredential(cookie: "sk-ant-fixture"), now: self.now); XCTFail("Rejected") }
        catch { XCTAssertEqual(error as? ToolConnectionError, .authenticationRequired); XCTAssertFalse(error.localizedDescription.contains("must-not-surface")) }
        let rejectedCount = await rejected.requestCount()
        XCTAssertEqual(rejectedCount, 1)
    }

    func testClaudeOAuthQueriesUsageAndTrustedProfileOnFixedHost() async throws {
        let transport = ConnectionFixtureTransport([
            .init(body: #"{"five_hour":{"utilization":35},"seven_day":{"utilization":20}}"#),
            .init(body: #"{"account":{"uuid":"acc","email_address":"oauth@example.test"},"organization":{"uuid":"org"}}"#),
        ])
        let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
        let profile = ManagedToolConnection(id: "claudeCode", client: .claudeCode, label: "Claude", source: "fixture")
        let result = try await service.query(profile: profile, credential: ManagedToolCredential(oauthToken: "oauth-fixture"), now: self.now)
        XCTAssertEqual(result.accountIdentity, "account:acc:organization:org")
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.host }, ["api.anthropic.com", "api.anthropic.com"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/oauth/usage", "/api/oauth/profile"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testOpenCodeDiscoveryOnlyClaimsGoAndOfficialBoundDeepSeek() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        let env = ["OPENCODE_AUTH_CONTENT": #"{"openai":{"type":"oauth","access":"do-not-query"},"opencode-go":{"type":"api","key":"go-fixture"},"deepseek":{"type":"api","key":"deepseek-fixture"}}"#,
                   "DEEPSEEK_BASE_URL": "https://api.deepseek.com/v1"]
        let service = ToolConnectionService(home: home, environment: env, keychainReader: { nil })
        let profiles = try await service.discover(client: .openCode, preferences: ApplicationPreferences())
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles.map { $0.profile.providerKind }, [.primary, .deepSeekAPI])
        let relay = ToolConnectionService(home: home, environment: env.merging(["OPENCODE_BASE_URL": "https://relay.example", "DEEPSEEK_BASE_URL": "https://relay.example"]) { _, new in new }, keychainReader: { nil })
        let ignored = try await relay.discover(client: .openCode, preferences: ApplicationPreferences())
        XCTAssertTrue(ignored.isEmpty)
    }

    func testOpenCodeWebFallbackQueriesOwnWorkspaceAndZenBalance() async throws {
        let transport = ConnectionFixtureTransport([
            .init(status: 403, body: #"{"error":{"type":"EntitlementError"}}"#),
            .init(body: #"[{"id":"wrk_fixture"}]"#),
            .init(body: "rollingUsage:{usagePercent:30,resetInSec:3600},weeklyUsage:{usagePercent:20,resetInSec:604800}"),
            .init(body: "{balanceUSD:8.25}"),
        ])
        let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
        let profile = ManagedToolConnection(id: "one", client: .openCode, label: "One", source: "fixture")
        let result = try await service.query(profile: profile, credential: ManagedToolCredential(apiKey: "go-fixture", cookie: "auth=cookie-fixture"), now: self.now)
        XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [30, 20])
        XCTAssertEqual(result.snapshot.balance?.amount, 8.25)
        XCTAssertTrue(result.snapshot.windows.allSatisfy { $0.used == nil && $0.limit == nil })
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "opencode.ai" })
        XCTAssertEqual(requests[2].url?.path, "/workspace/wrk_fixture/go")
        XCTAssertNotNil(requests[3].value(forHTTPHeaderField: "X-Server-Id"))
    }

    func testOpenCodeWebAuthenticationFailureRetainsAPIQuotaAndReportsPartialFailure() async throws {
        for status in [401, 403] {
            let transport = ConnectionFixtureTransport([
                .init(body: self.openCodeGoResponse),
                .init(status: status, body: #"{"error":"cookie-must-not-surface"}"#),
            ])
            let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
            let profile = ManagedToolConnection(id: "one", client: .openCode, label: "One", source: "fixture")
            let result = try await service.query(profile: profile,
                credential: ManagedToolCredential(apiKey: "go-fixture", cookie: "auth=cookie-fixture"), now: self.now)
            XCTAssertEqual(result.snapshot.status, .authenticationRequired)
            XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [30, 20])
            XCTAssertTrue(result.snapshot.statusDetail.contains("Cookie"))
            XCTAssertTrue(result.snapshot.statusDetail.contains("仍显示 API Key"))
            XCTAssertFalse(result.snapshot.statusDetail.contains("must-not-surface"))
            let count = await transport.requestCount()
            XCTAssertEqual(count, 2)
        }
    }

    func testOpenCodeWebMalformedSubscriptionRetainsAPIQuotaAndReportsPartialFailure() async throws {
        let transport = ConnectionFixtureTransport([
            .init(body: self.openCodeGoResponse),
            .init(body: #"[{"id":"wrk_fixture"}]"#),
            .init(body: "<html>No Go plan</html>"),
            .init(body: "unrecognized-get-response"),
            .init(body: "unrecognized-post-response"),
        ])
        let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
        let profile = ManagedToolConnection(id: "one", client: .openCode, label: "One", source: "fixture")
        let result = try await service.query(profile: profile,
            credential: ManagedToolCredential(apiKey: "go-fixture", cookie: "auth=cookie-fixture"), now: self.now)
        XCTAssertEqual(result.snapshot.status, .failed)
        XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), [30, 20])
        XCTAssertTrue(result.snapshot.statusDetail.contains("读取失败"))
        XCTAssertTrue(result.snapshot.statusDetail.contains("仍显示 API Key"))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests.last?.httpMethod, "POST")
    }

    func testOpenCodeZenFailureKeepsCookieGoQuotaAndDoesNotBecomeReadyWhenCombinedWithAPI() async throws {
        for credential in [ManagedToolCredential(cookie: "auth=cookie-fixture"),
                           ManagedToolCredential(apiKey: "go-fixture", cookie: "auth=cookie-fixture")] {
            var responses: [ConnectionFixtureTransport.Response] = []
            if credential.apiKey != nil { responses.append(.init(body: self.openCodeGoResponse)) }
            responses.append(contentsOf: [
                .init(body: #"[{"id":"wrk_fixture"}]"#),
                .init(body: self.openCodeGoPage),
                .init(body: "unrecognized-get-response"),
                .init(body: "unrecognized-post-response"),
            ])
            let transport = ConnectionFixtureTransport(responses)
            let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
            let profile = ManagedToolConnection(id: "one", client: .openCode, label: "One", source: "fixture")
            let result = try await service.query(profile: profile, credential: credential, now: self.now)
            XCTAssertEqual(result.snapshot.status, .failed)
            XCTAssertEqual(result.snapshot.windows.map(\.usedPercent), credential.apiKey == nil ? [45, 65] : [30, 20])
            XCTAssertTrue(result.snapshot.statusDetail.contains("Zen 余额读取失败"))
            XCTAssertTrue(result.snapshot.statusDetail.contains("Go 额度"))
            if credential.apiKey != nil { XCTAssertTrue(result.snapshot.statusDetail.contains("API Key")) }
            XCTAssertNil(result.snapshot.balance)
        }
    }

    func testOpenCodeWebNullSubscriptionRemainsAValidEmptyAccount() async throws {
        let transport = ConnectionFixtureTransport([
            .init(body: #"[{"id":"wrk_fixture"}]"#),
            .init(body: "<html>No Go plan</html>"),
            .init(body: "null"),
        ])
        let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
        let profile = ManagedToolConnection(id: "one", client: .openCode, label: "One", source: "fixture")
        let result = try await service.query(profile: profile, credential: ManagedToolCredential(cookie: "auth=cookie-fixture"), now: self.now)
        XCTAssertEqual(result.snapshot.status, .unsupported)
        XCTAssertTrue(result.snapshot.windows.isEmpty)
        XCTAssertNil(result.snapshot.balance)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 3)
    }

    @MainActor
    func testOpenCodeInvalidCookieCannotBeSavedWithAWorkingAPIKey() async throws {
        let directory = try self.home(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ConnectionFixtureTransport([
            .init(body: self.openCodeGoResponse), .init(status: 401, body: "rejected"),
            .init(body: self.openCodeGoResponse),
            .init(body: self.openCodeGoResponse), .init(status: 403, body: "rejected"),
            .init(body: self.openCodeGoResponse), .init(status: 500, body: "unavailable"),
        ])
        let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
        let store = ToolConnectionStore(directory: directory, service: service)
        do {
            try await store.saveOpenCodeProfile(label: "One", apiKey: "go-fixture", cookie: "auth=invalid-fixture-cookie", confirmedSameAccount: true)
            XCTFail("A valid API key must not hide an invalid new Cookie")
        } catch { XCTAssertEqual(error as? ToolConnectionError, .authenticationRequired) }
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("credentials.json").path))

        try await store.saveOpenCodeProfile(label: "One", apiKey: "go-fixture")
        let original = try XCTUnwrap(store.profiles.first)
        let originalQuota = store.quota(for: original.id)
        let credentials = directory.appendingPathComponent("credentials.json")
        let originalCredentialData = try Data(contentsOf: credentials)
        for expected in [ToolConnectionError.authenticationRequired, .networkFailure] {
            do {
                try await store.saveOpenCodeProfile(label: "Updated", cookie: "auth=invalid-fixture-cookie",
                    profileID: original.id, confirmedSameAccount: true)
                XCTFail("An invalid replacement Cookie must not change the saved profile")
            } catch { XCTAssertEqual(error as? ToolConnectionError, expected) }
            XCTAssertEqual(store.profiles, [original])
            XCTAssertEqual(store.quota(for: original.id), originalQuota)
            XCTAssertEqual(try Data(contentsOf: credentials), originalCredentialData)
        }
    }

    @MainActor
    func testOpenCodeRefreshCachesCookieFailureWhileKeepingSuccessfulAPIQuota() async throws {
        let directory = try self.home(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ConnectionFixtureTransport([
            .init(body: self.openCodeGoResponse),
            .init(body: #"[{"id":"wrk_fixture"}]"#),
            .init(body: "<html>No Go plan</html>"),
            .init(body: "{balanceUSD:8.25}"),
            .init(body: self.openCodeGoResponse), .init(status: 401, body: "expired"),
        ])
        let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
        let store = ToolConnectionStore(directory: directory, service: service)
        try await store.saveOpenCodeProfile(label: "One", apiKey: "go-fixture", cookie: "auth=cookie-fixture", confirmedSameAccount: true)
        let original = try XCTUnwrap(store.profiles.first)
        XCTAssertEqual(store.quota(for: original.id)?.balance?.amount, 8.25)
        await store.refresh(profileID: original.id, force: true, now: self.now)
        let refreshed = try XCTUnwrap(store.quota(for: original.id))
        XCTAssertEqual(refreshed.status, .authenticationRequired)
        XCTAssertEqual(refreshed.windows.map(\.usedPercent), [30, 20])
        XCTAssertNil(refreshed.balance)
        XCTAssertEqual(store.profiles, [original])
        let restored = ToolConnectionStore(directory: directory, service: service)
        XCTAssertEqual(restored.quota(for: original.id), refreshed)
    }

    @MainActor
    func testOpenCodeCookieOnlyRefreshCachesZenFailureAndPreservesGoQuota() async throws {
        let directory = try self.home(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ConnectionFixtureTransport([
            .init(body: #"[{"id":"wrk_fixture"}]"#),
            .init(body: self.openCodeGoPage),
            .init(body: "{balanceUSD:8.25}"),
            .init(body: #"[{"id":"wrk_fixture"}]"#),
            .init(body: self.openCodeGoPage),
            .init(body: "unrecognized-get-response"),
            .init(body: "unrecognized-post-response"),
        ])
        let service = ToolConnectionService(transport: transport, environment: [:], keychainReader: { nil })
        let store = ToolConnectionStore(directory: directory, service: service)
        try await store.saveOpenCodeProfile(label: "One", cookie: "auth=cookie-fixture")
        let original = try XCTUnwrap(store.profiles.first)
        XCTAssertEqual(store.quota(for: original.id)?.status, .ready)
        XCTAssertEqual(store.quota(for: original.id)?.balance?.amount, 8.25)
        await store.refresh(profileID: original.id, force: true, now: self.now)
        let refreshed = try XCTUnwrap(store.quota(for: original.id))
        XCTAssertEqual(refreshed.status, .failed)
        XCTAssertEqual(refreshed.windows.map(\.usedPercent), [45, 65])
        XCTAssertTrue(refreshed.statusDetail.contains("Zen 余额读取失败"))
        XCTAssertNil(refreshed.balance)
        XCTAssertEqual(store.profiles, [original])
        let restored = ToolConnectionStore(directory: directory, service: service)
        XCTAssertEqual(restored.quota(for: original.id), refreshed)
    }

    func testDSHDiscoverPreservesEverySnapshotWithoutReadingOrSendingCredentials() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        try self.write(#"{"providers":{"one":{"displayName":"Relay One","credential":"never-read","balance":{"totalBalance":12,"currency":"CNY","updatedAt":1791000000000}},"two":{"displayName":"Relay Two","balance":{"totalBalance":7,"currency":"USD","updatedAt":1790000000000}}}}"#, home: home, path: ".dsh/dsh-usage/provider-snapshots.json")
        let transport = ConnectionFixtureTransport([])
        let service = ToolConnectionService(transport: transport, home: home, environment: ["DEEPSEEK_API_KEY": "unbound-key"], keychainReader: { nil })
        let discovered = try await service.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertEqual(discovered.count, 2)
        XCTAssertTrue(discovered.allSatisfy { $0.profile.providerKind == .dshSnapshot && $0.credential.apiKey == nil })
        let first = try await service.query(profile: discovered[0].profile, credential: discovered[0].credential, now: self.now)
        XCTAssertEqual(first.snapshot.balance?.currency, "CNY")
        let second = try await service.query(profile: discovered[1].profile, credential: discovered[1].credential, now: self.now)
        XCTAssertEqual(second.snapshot.balance?.currency, "USD")
        let snapshotRequests = await transport.requestCount()
        XCTAssertEqual(snapshotRequests, 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(discovered.map(\.profile)), as: UTF8.self).contains("never-read"))
    }

    func testOpenCodeDeepSeekLegacyConnectionUsesOnlyBoundOfficialBalance() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        let transport = ConnectionFixtureTransport([.init(body: #"{"balance_infos":[{"currency":"CNY","total_balance":"6"},{"currency":"USD","total_balance":"12"}]}"#)])
        let service = ToolConnectionService(transport: transport, home: home,
            environment: ["OPENCODE_AUTH_CONTENT": #"{"deepseek":{"type":"api","key":"official-fixture"}}"#, "DEEPSEEK_BASE_URL": "https://api.deepseek.com"], keychainReader: { nil })
        let discovered = try await service.discover(client: .openCode, preferences: ApplicationPreferences())
        let discovery = try XCTUnwrap(discovered.first)
        let result = try await service.query(profile: discovery.profile, credential: discovery.credential, now: self.now)
        XCTAssertEqual(result.snapshot.client, .openCode)
        XCTAssertEqual(result.snapshot.balance?.amount, 12)
        let paths = await transport.paths()
        XCTAssertEqual(paths, ["https://api.deepseek.com/user/balance"])
    }

    func testDSHAliasesCollapseOnlyMatchingCredentialIdentityAndReadNewestSnapshot() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        let path = ".dsh/dsh-usage/provider-snapshots.json"
        try self.write(#"{"providers":{"legacy":{"provider":"deepseek","displayName":"deepseek","credential":"same-source-fixture","balance":{"totalBalance":12,"currency":"CNY","updatedAt":100000}},"modern":{"provider":"deepseek-official","displayName":"DeepSeek","credential":"same-source-fixture","balance":{"totalBalance":11,"currency":"CNY","updatedAt":100333}}}}"#, home: home, path: path)
        let transport = ConnectionFixtureTransport([])
        let service = ToolConnectionService(transport: transport, home: home, environment: [:], keychainReader: { nil })
        let discovered = try await service.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertEqual(discovered.count, 1)
        let source = try XCTUnwrap(discovered.first)
        XCTAssertEqual(source.profile.label, "DeepSeek")
        XCTAssertEqual(source.profile.providerID, "modern")
        let quota = try await service.query(profile: source.profile, credential: source.credential, now: self.now).snapshot
        XCTAssertEqual(quota.balance?.amount, 11)
        XCTAssertEqual(quota.refreshedAt, Date(timeIntervalSince1970: 100.333))
        XCTAssertTrue(quota.statusDetail.contains("只重新读取文件"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(source.profile), as: UTF8.self).contains("same-source-fixture"))
        // Provider renaming/removal preserves the account identity and accepts a fresh value from the alias.
        try self.write(#"{"providers":{"legacy":{"provider":"deepseek","credential":"same-source-fixture","balance":{"totalBalance":10,"currency":"CNY","updatedAt":110000}}}}"#, home: home, path: path)
        let renamed = try await service.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertEqual(renamed.first?.profile.id, source.profile.id)
        let fresh = try await service.query(profile: source.profile, credential: source.credential, now: self.now).snapshot
        XCTAssertEqual(fresh.balance?.amount, 10)
        XCTAssertEqual(fresh.refreshedAt, Date(timeIntervalSince1970: 110))
        let count = await transport.requestCount(); XCTAssertEqual(count, 0)
    }

    func testDSHMatchingBalancesNeverMergeDistinctOrUnknownIdentities() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        try self.write(#"{"providers":{"one":{"provider":"deepseek","credential":"identity-one","balance":{"totalBalance":12,"currency":"CNY","updatedAt":100000}},"two":{"provider":"deepseek-official","credential":"identity-two","balance":{"totalBalance":12,"currency":"CNY","updatedAt":100000}},"three":{"provider":"deepseek","balance":{"totalBalance":12,"currency":"CNY","updatedAt":100000}},"four":{"provider":"deepseek-official","balance":{"totalBalance":12,"currency":"CNY","updatedAt":100000}}}}"#, home: home, path: ".dsh/dsh-usage/provider-snapshots.json")
        let service = ToolConnectionService(home: home, environment: [:], keychainReader: { nil })
        let sources = try await service.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertEqual(sources.count, 4)
        XCTAssertEqual(Set(sources.map { $0.profile.id }).count, 4)
    }

    func testDSHOfficialBindingReadsOwnerPrivateReferenceAndQueriesOnlyLiveOfficialBalance() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        let secretPath = ".dsh/.credentials.yaml"
        try self.write("version: 1\nrefs:\n  DEEPSEEK_API_KEY: 'official-fixture'\nrecords:\n  ignored: secret-not-a-key\n", home: home, path: secretPath)
        let file = home.appendingPathComponent(secretPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let original = try Data(contentsOf: file)
        let transport = ConnectionFixtureTransport([.init(body: #"{"balance_infos":[{"currency":"CNY","total_balance":"9.5"}]}"#)])
        let service = ToolConnectionService(transport: transport, home: home,
            environment: ["DEEPSEEK_BASE_URL": "https://api.deepseek.com/v1"], keychainReader: { nil })
        let discoveries = try await service.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        let discovery = try XCTUnwrap(discoveries.first)
        XCTAssertEqual(discovery.profile.providerKind, .dshOfficialAPI)
        XCTAssertEqual(discovery.credential.apiKey, "official-fixture")
        let result = try await service.query(profile: discovery.profile, credential: discovery.credential, now: self.now)
        XCTAssertEqual(result.snapshot.balance?.amount, 9.5)
        XCTAssertEqual(result.snapshot.refreshedAt, self.now)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, ["https://api.deepseek.com/user/balance"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer official-fixture")
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(discovery.profile), as: UTF8.self).contains("official-fixture"))
    }

    func testDSHHistoricalOfficialSnapshotNeverAuthorizesAnUnboundOrPubliclyReadableKey() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        try self.write("version: 1\nrefs:\n  DEEPSEEK_API_KEY: isolated-fixture\n", home: home, path: ".dsh/.credentials.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent(".dsh/.credentials.yaml").path)
        try self.write(#"{"providers":{"one":{"provider":"deepseek-official","credential":"historical-identity","balance":{"totalBalance":12,"currency":"CNY","updatedAt":100000}}}}"#, home: home, path: ".dsh/dsh-usage/provider-snapshots.json")
        let transport = ConnectionFixtureTransport([])
        for binding in [nil, "https://relay.example", "https://api.deepseek.com.evil.example"] as [String?] {
            let service = ToolConnectionService(transport: transport, home: home,
                environment: binding.map { ["DEEPSEEK_BASE_URL": $0] } ?? [:], keychainReader: { nil })
            let sources = try await service.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
            XCTAssertEqual(sources.count, 1)
            XCTAssertEqual(sources[0].profile.providerKind, .dshSnapshot)
            XCTAssertNil(sources[0].credential.apiKey)
            _ = try await service.query(profile: sources[0].profile, credential: sources[0].credential, now: self.now)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.appendingPathComponent(".dsh/.credentials.yaml").path)
        let official = ToolConnectionService(transport: transport, home: home,
            environment: ["DEEPSEEK_BASE_URL": "https://api.deepseek.com"], keychainReader: { nil })
        let sources = try await official.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertTrue(sources.allSatisfy { $0.profile.providerKind == .dshSnapshot })
        let count = await transport.requestCount(); XCTAssertEqual(count, 0)
    }

    func testDSHRechecksCurrentEndpointAndCredentialBindingBeforeRefresh() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        let path = ".dsh/.env"
        try self.write("DEEPSEEK_BASE_URL=https://api.deepseek.com\nDEEPSEEK_API_KEY=bound-fixture\n", home: home, path: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent(path).path)
        let transport = ConnectionFixtureTransport([])
        let service = ToolConnectionService(transport: transport, home: home, environment: [:], keychainReader: { nil })
        let sources = try await service.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        let source = try XCTUnwrap(sources.first)
        try self.write("DEEPSEEK_BASE_URL=https://relay.example\nDEEPSEEK_API_KEY=bound-fixture\n", home: home, path: path)
        do { _ = try await service.query(profile: source.profile, credential: source.credential, now: self.now); XCTFail("Binding changed") }
        catch { XCTAssertEqual(error as? ToolConnectionError, .unsupported) }
        let count = await transport.requestCount(); XCTAssertEqual(count, 0)
    }

    func testDSHAmbiguousEnvironmentBindingNeverAuthorizesPrivateReference() async throws {
        let home = try self.home(); defer { try? FileManager.default.removeItem(at: home) }
        try self.write("refs:\n  DEEPSEEK_API_KEY: private-fixture\n", home: home, path: ".dsh/.credentials.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent(".dsh/.credentials.yaml").path)
        let transport = ConnectionFixtureTransport([])
        let service = ToolConnectionService(transport: transport, home: home, environment: [:], keychainReader: { nil })
        for environment in [
            "DEEPSEEK_BASE_URL=https://api.deepseek.com\nDEEPSEEK_BASE_URL=https://relay.example\n",
            "DEEPSEEK_BASE_URL=\nDEEPSEEK_BASE_URL=https://api.deepseek.com\n",
            "DEEPSEEK_BASE_URL=https://api.deepseek.com\nDEEPSEEK_API_KEY=one\nDEEPSEEK_API_KEY=two\n",
        ] {
            try self.write(environment, home: home, path: ".dsh/.env")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent(".dsh/.env").path)
            let sources = try await service.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
            XCTAssertTrue(sources.isEmpty)
        }
        try self.write("DEEPSEEK_BASE_URL=https://api.deepseek.com\n", home: home, path: ".dsh/.env")
        try self.write("refs:\n  DEEPSEEK_API_KEY: first-fixture\nrecords: {}\nrefs:\n  DEEPSEEK_API_KEY: second-fixture\n", home: home, path: ".dsh/.credentials.yaml")
        let duplicateReferences = try await service.discover(client: .deepSeekHarness, preferences: ApplicationPreferences())
        XCTAssertTrue(duplicateReferences.isEmpty)
        let count = await transport.requestCount(); XCTAssertEqual(count, 0)
    }

    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-connections-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true); return home
    }
    private func write(_ text: String, home: URL, path: String) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}

private actor ConnectionFixtureTransport: CursorUsageHTTPTransport {
    struct Response: Sendable {
        var status = 200
        var body: String
        var cookie: String? = nil
    }
    private var responses: [Response]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [Response]) { self.responses = responses }
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        guard !self.responses.isEmpty else { throw ToolConnectionError.networkFailure }
        let fixture = self.responses.removeFirst()
        return (Data(fixture.body.utf8), HTTPURLResponse(url: request.url!, statusCode: fixture.status,
            httpVersion: nil, headerFields: fixture.cookie.map { ["Set-Cookie": $0] })!)
    }
    func requestCount() -> Int { self.requests.count }
    func paths() -> [String] { self.requests.compactMap { $0.url?.absoluteString } }
}
