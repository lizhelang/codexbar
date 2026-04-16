import Foundation
import XCTest

@MainActor
final class OpenAIOAuthRefreshServiceTests: CodexBarTestCase {
    func testRefreshDueAccountsOnlyRefreshesAccountsInsideWindow() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TokenStore(
            openAIAccountGatewayService: NoopGatewayController(),
            aggregateGatewayLeaseStore: NoopAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let dueAccount = try self.makeOAuthAccount(
            accountID: "acct_due_refresh",
            email: "due-refresh@example.com",
            accessTokenExpiresAt: now.addingTimeInterval(10 * 60),
            tokenLastRefreshAt: now.addingTimeInterval(-60)
        )
        let futureAccount = try self.makeOAuthAccount(
            accountID: "acct_future_refresh",
            email: "future-refresh@example.com",
            accessTokenExpiresAt: now.addingTimeInterval(2 * 60 * 60),
            tokenLastRefreshAt: now.addingTimeInterval(-60)
        )
        store.addOrUpdate(dueAccount)
        store.addOrUpdate(futureAccount)

        var refreshedAccountIDs: [String] = []
        let service = OpenAIOAuthRefreshService(
            store: store,
            refreshWindow: 30 * 60,
            now: { now },
            refreshAction: { account in
                refreshedAccountIDs.append(account.accountId)
                return account
            }
        )

        await service.refreshDueAccountsNow()

        XCTAssertEqual(refreshedAccountIDs, [dueAccount.accountId])
    }

    func testRefreshActiveAccountWritesBackLatestTokens() async throws {
        let refreshedAt = Date(timeIntervalSince1970: 1_810_000_000)
        let store = TokenStore(
            openAIAccountGatewayService: NoopGatewayController(),
            aggregateGatewayLeaseStore: NoopAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let currentAccount = try self.makeOAuthAccount(
            accountID: "acct_active_refresh",
            email: "active-refresh@example.com",
            refreshToken: "refresh-old",
            oauthClientID: "app_current_client",
            tokenLastRefreshAt: refreshedAt.addingTimeInterval(-600)
        )
        store.addOrUpdate(currentAccount)
        try store.activate(currentAccount)

        var refreshedAccount = currentAccount
        refreshedAccount.accessToken = "access-new"
        refreshedAccount.refreshToken = "refresh-old"
        refreshedAccount.idToken = "id-new"
        refreshedAccount.oauthClientID = "app_refreshed_client"
        refreshedAccount.tokenLastRefreshAt = refreshedAt
        refreshedAccount.expiresAt = refreshedAt.addingTimeInterval(3_600)

        let service = OpenAIOAuthRefreshService(
            store: store,
            now: { refreshedAt },
            refreshAction: { _ in
                refreshedAccount
            }
        )

        let outcome = await service.refreshNow(account: currentAccount, force: true)
        guard case .refreshed(let updatedAccount) = outcome else {
            return XCTFail("Expected refresh to succeed")
        }

        let authObject = try self.readAuthJSON()
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)

        XCTAssertEqual(updatedAccount.accessToken, "access-new")
        XCTAssertEqual(tokens["access_token"] as? String, "access-new")
        XCTAssertEqual(tokens["refresh_token"] as? String, "refresh-old")
        XCTAssertEqual(authObject["client_id"] as? String, "app_refreshed_client")
        XCTAssertEqual(store.activeAccount()?.accessToken, "access-new")
        XCTAssertTrue(tomlText.contains(#"model_provider = "openai""#))
    }
}

private final class NoopGatewayController: OpenAIAccountGatewayControlling {
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

private final class NoopAggregateLeaseStore: OpenAIAggregateGatewayLeaseStoring {
    func loadProcessIDs() -> Set<pid_t> { [] }
    func saveProcessIDs(_ processIDs: Set<pid_t>) {}
    func clear() {}
}
