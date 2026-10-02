import Foundation
import XCTest

@MainActor
final class OpenAIOAuthRefreshServiceTests: CodexBarTestCase {
    func testChangedLiveAuthWithUnchangedTimestampWinsOverOldRefreshCompletion() async throws {
        for fails in [false, true] {
            let fixture = try self.makeInactiveRefreshFixture(suffix: fails ? "live-failure" : "live-success")
            var source = fixture.account
            source.tokenLastRefreshAt = Date(timeIntervalSince1970: 1_800_000_000)
            fixture.store.addOrUpdate(source)
            try self.writeAuth(source)
            var externalRotation = source
            externalRotation.refreshToken = "synthetic-live-rotation"
            let staleResponse = self.rotated(source, suffix: "stale-live-response")
            let service = OpenAIOAuthRefreshService(store: fixture.store, refreshAction: { _ in
                try self.writeAuth(externalRotation)
                if fails { throw OpenAIOAuthError.serverError("invalid_grant") }
                return staleResponse
            })

            let outcome = await service.refreshNow(account: source)

            guard case .refreshed(let returned) = outcome else { return XCTFail("Expected the live rotation") }
            XCTAssertEqual(returned.refreshToken, externalRotation.refreshToken)
            XCTAssertFalse(returned.tokenExpired)
            XCTAssertEqual(fixture.store.oauthAccount(accountID: source.accountId)?.refreshToken,
                           externalRotation.refreshToken)
        }
    }

    func testConcurrentStoreRotationWinsOverUnchangedOrReformattedOldAuth() async throws {
        for reformatAuth in [false, true] {
            let fixture = try self.makeInactiveRefreshFixture(suffix: reformatAuth ? "reformatted" : "unchanged")
            try self.writeAuth(fixture.account)
            let originalAuth = try Data(contentsOf: CodexPaths.authURL)
            var newer = self.rotated(fixture.account, suffix: "latest-store")
            newer.tokenExpired = true
            let staleResponse = self.rotated(fixture.account, suffix: "stale-response")
            let service = OpenAIOAuthRefreshService(store: fixture.store, refreshAction: { _ in
                fixture.store.addOrUpdate(newer)
                if reformatAuth {
                    var reformattedAuth = originalAuth
                    reformattedAuth.append(contentsOf: [0x0A])
                    try CodexPaths.writeSecureFile(reformattedAuth, to: CodexPaths.authURL)
                }
                return staleResponse
            })

            let outcome = await service.refreshNow(account: fixture.account)

            guard case .refreshed(let returned) = outcome else { return XCTFail("Expected the new store credentials") }
            XCTAssertEqual(returned.refreshToken, newer.refreshToken)
            XCTAssertTrue(returned.tokenExpired)
            XCTAssertEqual(fixture.store.oauthAccount(accountID: fixture.account.accountId)?.refreshToken,
                           newer.refreshToken)
        }
    }

    func testReformattingAlreadyStaleAuthDoesNotSupersedeCurrentRequestCredentials() async throws {
        let fixture = try self.makeInactiveRefreshFixture()
        try self.writeAuth(fixture.account)
        let oldAuth = try Data(contentsOf: CodexPaths.authURL)
        var source = fixture.account
        source.refreshToken = "synthetic-newer-stored-refresh"
        fixture.store.addOrUpdate(source)
        let refreshed = self.rotated(source, suffix: "fresh-after-format")
        let service = OpenAIOAuthRefreshService(store: fixture.store, refreshAction: { sent in
            XCTAssertEqual(sent.refreshToken, source.refreshToken)
            var reformattedAuth = oldAuth
            reformattedAuth.append(contentsOf: [0x0A])
            try CodexPaths.writeSecureFile(reformattedAuth, to: CodexPaths.authURL)
            return refreshed
        })

        let outcome = await service.refreshNow(account: source)

        guard case .refreshed(let returned) = outcome else { return XCTFail("Expected the fresh result") }
        XCTAssertEqual(returned.refreshToken, refreshed.refreshToken)
        XCTAssertEqual(fixture.store.oauthAccount(accountID: source.accountId)?.refreshToken,
                       refreshed.refreshToken)
    }

    func testSlowSuccessReturnsConcurrentCredentialsWithoutReplacingState() async throws {
        let fixture = try self.makeInactiveRefreshFixture()
        var newer = self.rotated(fixture.account, suffix: "newer")
        newer.username = "newer-profile"
        newer.primaryUsedPercent = 73
        newer.lastChecked = Date()
        newer.isSuspended = true
        newer.tokenExpired = true
        let staleResult = self.rotated(fixture.account, suffix: "stale-response")
        let service = OpenAIOAuthRefreshService(store: fixture.store, refreshAction: { _ in
            fixture.store.addOrUpdate(newer)
            return staleResult
        })

        let outcome = await service.refreshNow(account: fixture.account)

        guard case .refreshed(let returned) = outcome else { return XCTFail("Expected the latest credentials") }
        let stored = try XCTUnwrap(fixture.store.oauthAccount(accountID: fixture.account.accountId))
        XCTAssertEqual(returned.refreshToken, newer.refreshToken)
        XCTAssertEqual(stored.refreshToken, newer.refreshToken)
        XCTAssertEqual(stored.accessToken, newer.accessToken)
        XCTAssertEqual(stored.idToken, newer.idToken)
        XCTAssertEqual(stored.username, newer.username)
        XCTAssertEqual(stored.primaryUsedPercent, 73)
        XCTAssertTrue(stored.isSuspended)
        XCTAssertTrue(stored.tokenExpired)
        let disk = try XCTUnwrap(CodexBarConfigStore().load().oauthTokenAccounts().first {
            $0.accountId == fixture.account.accountId
        })
        XCTAssertEqual(disk.refreshToken, newer.refreshToken)
        XCTAssertTrue(disk.tokenExpired)
    }

    func testSlowTerminalFailureDoesNotExpireConcurrentCredentials() async throws {
        let fixture = try self.makeInactiveRefreshFixture()
        let newer = self.rotated(fixture.account, suffix: "newer")
        let service = OpenAIOAuthRefreshService(store: fixture.store, refreshAction: { _ in
            fixture.store.addOrUpdate(newer)
            throw OpenAIOAuthError.serverError("invalid_grant: stale refresh token")
        })

        let outcome = await service.refreshNow(account: fixture.account)

        guard case .refreshed(let returned) = outcome else { return XCTFail("Expected the newer credentials") }
        let stored = try XCTUnwrap(fixture.store.oauthAccount(accountID: fixture.account.accountId))
        XCTAssertEqual(returned.refreshToken, newer.refreshToken)
        XCTAssertEqual(stored.refreshToken, newer.refreshToken)
        XCTAssertFalse(stored.tokenExpired)
        XCTAssertFalse(try XCTUnwrap(CodexBarConfigStore().load().oauthTokenAccounts().first {
            $0.accountId == fixture.account.accountId
        }).tokenExpired)
    }

    func testSuccessfulRefreshMergesCredentialsIntoConcurrentMetadataAndStatus() async throws {
        let fixture = try self.makeInactiveRefreshFixture()
        var updatedState = fixture.account
        updatedState.username = "concurrent-profile"
        updatedState.primaryUsedPercent = 81
        updatedState.isSuspended = true
        updatedState.tokenExpired = true
        let refreshed = self.rotated(fixture.account, suffix: "refreshed")
        let service = OpenAIOAuthRefreshService(store: fixture.store, refreshAction: { _ in
            fixture.store.addOrUpdate(updatedState)
            return refreshed
        })

        let outcome = await service.refreshNow(account: fixture.account)

        guard case .refreshed(let returned) = outcome else { return XCTFail("Expected refresh to succeed") }
        XCTAssertEqual(returned.refreshToken, refreshed.refreshToken)
        XCTAssertEqual(returned.username, updatedState.username)
        XCTAssertEqual(returned.primaryUsedPercent, 81)
        XCTAssertTrue(returned.isSuspended)
        XCTAssertTrue(returned.tokenExpired)
        let stored = try XCTUnwrap(fixture.store.oauthAccount(accountID: fixture.account.accountId))
        XCTAssertEqual(stored.refreshToken, refreshed.refreshToken)
        XCTAssertTrue(stored.isSuspended)
        XCTAssertTrue(stored.tokenExpired)
    }

    func testActiveRefreshDoesNotReabsorbOldAuthWhenPreservingConcurrentExpiredState() async throws {
        let fixture = try self.makeInactiveRefreshFixture()
        try fixture.store.activate(fixture.account)
        let source = try XCTUnwrap(fixture.store.oauthAccount(accountID: fixture.account.accountId))
        var updatedState = source
        updatedState.tokenExpired = true
        let refreshed = self.rotated(source, suffix: "active-refreshed")
        let service = OpenAIOAuthRefreshService(store: fixture.store, refreshAction: { _ in
            fixture.store.addOrUpdate(updatedState)
            return refreshed
        })

        let outcome = await service.refreshNow(account: source)

        guard case .refreshed(let returned) = outcome else { return XCTFail("Expected the fresh active credentials") }
        XCTAssertEqual(returned.refreshToken, refreshed.refreshToken)
        XCTAssertTrue(returned.tokenExpired)
        XCTAssertEqual(fixture.store.activeAccount()?.refreshToken, refreshed.refreshToken)
        let auth = try self.readAuthJSON()
        let tokens = try XCTUnwrap(auth["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["refresh_token"] as? String, refreshed.refreshToken)
    }

    func testRefreshCompletionDoesNotRecreateDeletedAccount() async throws {
        for fails in [false, true] {
            let fixture = try self.makeInactiveRefreshFixture(suffix: fails ? "failure" : "success")
            let refreshed = self.rotated(fixture.account, suffix: "deleted")
            let service = OpenAIOAuthRefreshService(store: fixture.store, refreshAction: { _ in
                fixture.store.remove(fixture.account)
                if fails { throw OpenAIOAuthError.serverError("invalid_grant") }
                return refreshed
            })

            let outcome = await service.refreshNow(account: fixture.account)

            guard case .skipped = outcome else { return XCTFail("Deleted accounts must be skipped") }
            XCTAssertNil(fixture.store.oauthAccount(accountID: fixture.account.accountId))
            XCTAssertFalse(try CodexBarConfigStore().load().oauthTokenAccounts().contains {
                $0.accountId == fixture.account.accountId
            })
        }
    }

    func testRemoteRefreshPreservesConcurrentCredentialsAndSelectedIdentity() async throws {
        let store = self.makeRefreshStore()
        let original = try self.makeOAuthAccount(accountID: "remote-race", email: "remote@example.com")
        let selected = try self.makeOAuthAccount(accountID: "remote-selected", email: "selected@example.com")
        _ = try store.importRemoteConnectionAccount(original)
        let newer = self.rotated(original, suffix: "new-remote")
        let oldResponse = self.rotated(original, suffix: "old-remote")
        let service = OpenAIOAuthRefreshService(store: store, refreshAction: { _ in
            _ = try store.importRemoteConnectionAccount(newer)
            _ = try store.importRemoteConnectionAccount(selected)
            return oldResponse
        })

        let outcome = await service.refreshNow(account: original)

        guard case .refreshed(let returned) = outcome else { return XCTFail("Expected the current remote credentials") }
        XCTAssertEqual(returned.refreshToken, newer.refreshToken)
        XCTAssertEqual(store.remoteConnectionAccounts.first { $0.accountId == original.accountId }?.refreshToken,
                       newer.refreshToken)
        XCTAssertEqual(store.remoteConnectionAccount?.accountId, selected.accountId)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testRemoteRefreshSavesNewCredentialsWithoutReactivatingOutgoingIdentity() async throws {
        let store = self.makeRefreshStore()
        let outgoing = try self.makeOAuthAccount(accountID: "remote-outgoing", email: "outgoing@example.com")
        let selected = try self.makeOAuthAccount(accountID: "remote-current", email: "current@example.com")
        _ = try store.importRemoteConnectionAccount(outgoing)
        let refreshed = self.rotated(outgoing, suffix: "fresh-remote")
        let service = OpenAIOAuthRefreshService(store: store, refreshAction: { _ in
            _ = try store.importRemoteConnectionAccount(selected)
            return refreshed
        })

        let outcome = await service.refreshNow(account: outgoing)

        guard case .refreshed(let returned) = outcome else { return XCTFail("Expected remote refresh to succeed") }
        XCTAssertEqual(returned.refreshToken, refreshed.refreshToken)
        XCTAssertEqual(store.remoteConnectionAccount?.accountId, selected.accountId)
        XCTAssertEqual(store.remoteConnectionAccounts.first { $0.accountId == outgoing.accountId }?.refreshToken,
                       refreshed.refreshToken)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testCurrentPauseAndDeletedAccountAreCheckedBeforeSendingRefresh() async throws {
        let fixture = try self.makeInactiveRefreshFixture()
        var paused = fixture.account
        paused.isSuspended = true
        fixture.store.addOrUpdate(paused)
        var requestCount = 0
        let service = OpenAIOAuthRefreshService(store: fixture.store, refreshAction: { account in
            requestCount += 1
            return account
        })

        let pausedOutcome = await service.refreshNow(account: fixture.account)
        guard case .skipped = pausedOutcome else { return XCTFail("The latest pause must be respected") }
        fixture.store.remove(paused)
        let deletedOutcome = await service.refreshNow(account: fixture.account)
        guard case .skipped = deletedOutcome else { return XCTFail("Deleted accounts must not be sent") }
        XCTAssertEqual(requestCount, 0)
    }

    private func makeRefreshStore() -> TokenStore {
        TokenStore(
            openAIAccountGatewayService: NoopGatewayController(),
            aggregateGatewayLeaseStore: NoopAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
    }

    private func makeInactiveRefreshFixture(suffix: String = "race") throws -> (store: TokenStore, account: TokenAccount) {
        let store = self.makeRefreshStore()
        let active = try self.makeOAuthAccount(accountID: "active-\(suffix)", email: "active@example.com")
        let inactive = try self.makeOAuthAccount(accountID: "inactive-\(suffix)", email: "inactive@example.com")
        store.addOrUpdate(active)
        store.addOrUpdate(inactive)
        try store.activate(active)
        return (store, try XCTUnwrap(store.oauthAccount(accountID: inactive.accountId)))
    }

    private func rotated(_ account: TokenAccount, suffix: String) -> TokenAccount {
        var result = account
        result.accessToken = "synthetic-access-\(suffix)"
        result.refreshToken = "synthetic-refresh-\(suffix)"
        result.idToken = "synthetic-id-\(suffix)"
        result.tokenLastRefreshAt = Date()
        return result
    }

    private func writeAuth(_ account: TokenAccount) throws {
        try self.writeAuthJSON(
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            remoteAccountID: account.remoteAccountId,
            lastRefresh: account.tokenLastRefreshAt
        )
    }

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

    func testRefreshDueAccountsRefreshesRemoteConnectionAccountWithoutPromotingIt() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TokenStore(
            openAIAccountGatewayService: NoopGatewayController(),
            aggregateGatewayLeaseStore: NoopAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let remoteAccount = try self.makeOAuthAccount(
            accountID: "remote_only_refresh",
            email: "remote-refresh@example.com",
            refreshToken: "refresh-old",
            remoteAccountID: "acct_remote_refresh",
            accessTokenExpiresAt: now.addingTimeInterval(10 * 60),
            tokenLastRefreshAt: now.addingTimeInterval(-60)
        )
        _ = try store.importRemoteConnectionAccount(remoteAccount)

        var refreshedAccountIDs: [String] = []
        let service = OpenAIOAuthRefreshService(
            store: store,
            refreshWindow: 30 * 60,
            now: { now },
            refreshAction: { account in
                refreshedAccountIDs.append(account.accountId)
                var refreshed = account
                refreshed.accessToken = "access-new"
                refreshed.refreshToken = "refresh-new"
                refreshed.idToken = "id-new"
                refreshed.tokenLastRefreshAt = now
                refreshed.expiresAt = now.addingTimeInterval(60 * 60)
                return refreshed
            }
        )

        await service.refreshDueAccountsNow()

        let storedRemoteAccount = try XCTUnwrap(store.remoteConnectionAccount)
        XCTAssertEqual(refreshedAccountIDs, [remoteAccount.accountId])
        XCTAssertEqual(storedRemoteAccount.accessToken, "access-new")
        XCTAssertEqual(storedRemoteAccount.refreshToken, "refresh-new")
        XCTAssertEqual(storedRemoteAccount.idToken, "id-new")
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testRefreshDueAccountsUsesEarlierIDTokenExpiration() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TokenStore(
            openAIAccountGatewayService: NoopGatewayController(),
            aggregateGatewayLeaseStore: NoopAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let accessTokenExpiresAt = now.addingTimeInterval(10 * 24 * 60 * 60)
        let dueAccount = try self.makeOAuthAccount(
            accountID: "acct_due_id_token_refresh",
            email: "due-id-token-refresh@example.com",
            accessTokenExpiresAt: accessTokenExpiresAt,
            idTokenExpiresAt: now.addingTimeInterval(10 * 60),
            tokenLastRefreshAt: now.addingTimeInterval(-60)
        )
        let futureAccount = try self.makeOAuthAccount(
            accountID: "acct_future_id_token_refresh",
            email: "future-id-token-refresh@example.com",
            accessTokenExpiresAt: accessTokenExpiresAt,
            idTokenExpiresAt: now.addingTimeInterval(2 * 60 * 60),
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
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        reserveActiveAccountQuota: Bool,
        reserveActiveAccountQuotaPercent: Int,
        defaultProxy: OpenAIAccountGatewayConfiguredProxy?,
        proxyByAccountID: [String: OpenAIAccountGatewayConfiguredProxy]
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
