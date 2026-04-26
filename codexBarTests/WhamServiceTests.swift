import Foundation
import XCTest

@MainActor
final class WhamServiceTests: CodexBarTestCase {
    func testFetchUsageParsesRawJSONViaRust() async throws {
        let account = try self.makeOAuthAccount(
            accountID: "acct_wham_fetch_usage",
            email: "wham-fetch-usage@example.com",
            remoteAccountID: "remote-wham-usage"
        )

        var capturedAuthorization: String?
        var capturedRemoteAccountID: String?
        MockURLProtocol.handler = { request in
            capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            capturedRemoteAccountID = request.value(forHTTPHeaderField: "chatgpt-account-id")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(
                """
                {
                  "plan_type": "plus",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 12.0,
                      "limit_window_seconds": 18000,
                      "reset_at": 1775372003.0
                    },
                    "secondary_window": {
                      "used_percent": 34.0,
                      "limit_window_seconds": 604800,
                      "reset_at": 1775690771.0
                    }
                  }
                }
                """.utf8
            )
            return (response, body)
        }

        let service = WhamService(session: self.makeMockSession())
        let result = try await service.fetchUsage(account: account)

        XCTAssertEqual(capturedAuthorization, "Bearer \(account.accessToken)")
        XCTAssertEqual(capturedRemoteAccountID, "remote-wham-usage")
        XCTAssertEqual(result.planType, "plus")
        XCTAssertEqual(result.primaryUsedPercent, 12)
        XCTAssertEqual(result.secondaryUsedPercent, 34)
        XCTAssertEqual(result.primaryLimitWindowSeconds, 18_000)
        XCTAssertEqual(result.secondaryLimitWindowSeconds, 604_800)
    }

    func testFetchOrgNameParsesRawJSONViaRust() async throws {
        let account = try self.makeOAuthAccount(
            accountID: "acct_wham_fetch_org",
            email: "wham-fetch-org@example.com",
            remoteAccountID: "remote-wham-org"
        )

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(
                """
                {
                  "accounts": {
                    "remote-wham-org": {
                      "account": {
                        "name": " Team From API "
                      }
                    }
                  }
                }
                """.utf8
            )
            return (response, body)
        }

        let service = WhamService(session: self.makeMockSession())
        let name = await service.fetchOrgName(account: account)

        XCTAssertEqual(name, "Team From API")
    }

    func testRefreshOneUsesOAuthRefreshBeforeMarkingTokenExpired() async throws {
        let store = TokenStore(
            openAIAccountGatewayService: NoopWhamGatewayController(),
            aggregateGatewayLeaseStore: NoopWhamAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let account = try self.makeOAuthAccount(
            accountID: "acct_wham_refresh",
            email: "wham-refresh@example.com"
        )
        store.addOrUpdate(account)

        var refreshedAccount = account
        refreshedAccount.accessToken = "access-wham-new"
        refreshedAccount.idToken = "id-wham-new"
        refreshedAccount.tokenLastRefreshAt = Date(timeIntervalSince1970: 1_820_000_000)
        refreshedAccount.expiresAt = Date(timeIntervalSince1970: 1_820_003_600)

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { account in
                if account.accessToken == "access-wham-new" {
                    return WhamUsageResult(
                        planType: "plus",
                        primaryUsedPercent: 12,
                        secondaryUsedPercent: 0,
                        primaryResetAt: nil,
                        secondaryResetAt: nil,
                        primaryLimitWindowSeconds: 18_000,
                        secondaryLimitWindowSeconds: nil
                    )
                }
                throw WhamError.unauthorized
            },
            orgNameFetcher: { _ in "Recovered Org" },
            oauthRefresh: { _ in .refreshed(refreshedAccount) }
        )

        XCTAssertEqual(outcome, .updated)
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(updated.accessToken, "access-wham-new")
        XCTAssertEqual(updated.organizationName, "Recovered Org")
        XCTAssertFalse(updated.tokenExpired)
        XCTAssertEqual(updated.primaryUsedPercent, 12)
    }

    func testRefreshOneMarksTokenExpiredOnlyOnTerminalRefreshFailure() async throws {
        let store = TokenStore(
            openAIAccountGatewayService: NoopWhamGatewayController(),
            aggregateGatewayLeaseStore: NoopWhamAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let account = try self.makeOAuthAccount(
            accountID: "acct_wham_terminal",
            email: "wham-terminal@example.com"
        )
        store.addOrUpdate(account)

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in
                throw WhamError.unauthorized
            },
            orgNameFetcher: { _ in nil },
            oauthRefresh: { _ in
                .terminalFailure("invalid_grant")
            }
        )

        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(outcome, .unauthorized("Token 已过期"))
        XCTAssertTrue(updated.tokenExpired)
    }

    func testRefreshOneReturnsDeferredAuthRecoveryMessageWhenRefreshIsSkipped() async throws {
        let store = TokenStore(
            openAIAccountGatewayService: NoopWhamGatewayController(),
            aggregateGatewayLeaseStore: NoopWhamAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let account = try self.makeOAuthAccount(
            accountID: "acct_wham_skipped",
            email: "wham-skipped@example.com"
        )
        store.addOrUpdate(account)

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in
                throw WhamError.unauthorized
            },
            orgNameFetcher: { _ in nil },
            oauthRefresh: { _ in
                .skipped
            }
        )

        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(outcome, .failed(L.authRecoveryDeferredMsg))
        XCTAssertFalse(updated.tokenExpired)
    }

    func testRefreshOneReturnsNeutralMessageWhenUnauthorizedPersistsAfterRefresh() async throws {
        let store = TokenStore(
            openAIAccountGatewayService: NoopWhamGatewayController(),
            aggregateGatewayLeaseStore: NoopWhamAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let account = try self.makeOAuthAccount(
            accountID: "acct_wham_retry_unauthorized",
            email: "wham-retry-unauthorized@example.com"
        )
        store.addOrUpdate(account)

        var refreshedAccount = account
        refreshedAccount.accessToken = "access-wham-refreshed"

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in
                throw WhamError.unauthorized
            },
            orgNameFetcher: { _ in nil },
            oauthRefresh: { _ in
                .refreshed(refreshedAccount)
            }
        )

        XCTAssertEqual(outcome, .failed(L.authValidationFailedMsg))
    }

    func testRefreshAllLimitsConcurrentAccountRefreshes() async throws {
        let store = TokenStore(
            openAIAccountGatewayService: NoopWhamGatewayController(),
            aggregateGatewayLeaseStore: NoopWhamAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )

        for index in 0..<5 {
            store.addOrUpdate(
                try self.makeOAuthAccount(
                    accountID: "acct_wham_limited_\(index)",
                    email: "limited-\(index)@example.com"
                )
            )
        }

        let lock = NSLock()
        var activeFetchCount = 0
        var maxActiveFetchCount = 0

        let outcomes = await WhamService.shared.refreshAll(
            store: store,
            usageFetcher: { _ in
                lock.lock()
                activeFetchCount += 1
                maxActiveFetchCount = max(maxActiveFetchCount, activeFetchCount)
                lock.unlock()

                try await Task.sleep(nanoseconds: 50_000_000)

                lock.lock()
                activeFetchCount -= 1
                lock.unlock()

                return WhamUsageResult(
                    planType: "plus",
                    primaryUsedPercent: 12,
                    secondaryUsedPercent: 0,
                    primaryResetAt: nil,
                    secondaryResetAt: nil,
                    primaryLimitWindowSeconds: 18_000,
                    secondaryLimitWindowSeconds: nil
                )
            },
            orgNameFetcher: { _ in nil },
            maxConcurrentAccounts: 2
        )

        XCTAssertEqual(outcomes.count, 5)
        XCTAssertEqual(outcomes.filter { $0 == .updated }.count, 5)
        XCTAssertLessThanOrEqual(maxActiveFetchCount, 2)
    }
}

private final class NoopWhamGatewayController: OpenAIAccountGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode
    ) {}
    func currentRoutedAccountID() -> String? { nil }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { [] }
    func clearStickyBinding(threadID: String) -> Bool { false }
}

private final class NoopWhamAggregateLeaseStore: OpenAIAggregateGatewayLeaseStoring {
    func loadProcessIDs() -> Set<pid_t> { [] }
    func saveProcessIDs(_ processIDs: Set<pid_t>) {}
    func clear() {}
}
