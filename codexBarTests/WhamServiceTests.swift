import Foundation
import XCTest

@MainActor
final class WhamServiceTests: CodexBarTestCase {
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
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        gatewayCredential: OpenAIAccountGatewayResolvedCredential
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
