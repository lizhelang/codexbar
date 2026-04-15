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
}

private final class NoopWhamAggregateLeaseStore: OpenAIAggregateGatewayLeaseStoring {
    func loadProcessIDs() -> Set<pid_t> { [] }
    func saveProcessIDs(_ processIDs: Set<pid_t>) {}
    func clear() {}
}
