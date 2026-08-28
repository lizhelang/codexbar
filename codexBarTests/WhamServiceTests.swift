import Foundation
import XCTest

@MainActor
final class WhamServiceTests: CodexBarTestCase {
    func testRefreshOneStoresProfileWhenUsageRefreshSucceeds() async throws {
        let store = self.makeWhamStore()
        let account = try self.makeOAuthAccount(
            accountID: "acct_wham_profile_success",
            email: "profile-success@example.com"
        )
        store.addOrUpdate(account)

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in self.makeWhamUsageResult() },
            orgNameFetcher: { _ in nil },
            profileFetcher: { _ in
                OpenAIProfileSnapshot(
                    username: " profile-user ",
                    displayName: " Profile User "
                )
            },
            profileRefreshInterval: 0,
            oauthRefresh: { _ in .skipped }
        )

        XCTAssertEqual(outcome, .updated)
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(updated.username, "profile-user")
        XCTAssertEqual(updated.displayName, "Profile User")
        XCTAssertNotNil(updated.profileLastCheckedAt)
    }

    func testSuccessfulEmptyProfileClearsCachedNames() async throws {
        let store = self.makeWhamStore()
        var account = try self.makeOAuthAccount(
            accountID: "acct_wham_profile_cleared",
            email: "profile-cleared@example.com"
        )
        account.username = "old-user"
        account.displayName = "Old User"
        account.profileLastCheckedAt = Date(timeIntervalSince1970: 1_000)
        store.addOrUpdate(account)

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in self.makeWhamUsageResult() },
            orgNameFetcher: { _ in nil },
            profileFetcher: { _ in OpenAIProfileSnapshot(username: nil, displayName: nil) },
            profileRefreshInterval: 0,
            oauthRefresh: { _ in .skipped }
        )

        XCTAssertEqual(outcome, .updated)
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertNil(updated.username)
        XCTAssertNil(updated.displayName)
        XCTAssertGreaterThan(updated.profileLastCheckedAt?.timeIntervalSince1970 ?? 0, 1_000)
        XCTAssertEqual(updated.displayIdentifier, account.email)
    }

    func testRefreshOneKeepsCachedProfileAndRecordsAttemptWhenProfileFetchFails() async throws {
        let store = self.makeWhamStore()
        var account = try self.makeOAuthAccount(
            accountID: "acct_wham_profile_failure",
            email: "profile-failure@example.com"
        )
        account.username = "cached-user"
        account.displayName = "Cached User"
        account.profileLastCheckedAt = Date(timeIntervalSince1970: 1_000)
        store.addOrUpdate(account)

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in self.makeWhamUsageResult() },
            orgNameFetcher: { _ in nil },
            profileFetcher: { _ in nil },
            profileRefreshInterval: 0,
            oauthRefresh: { _ in .skipped }
        )

        XCTAssertEqual(outcome, .updated)
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(updated.username, "cached-user")
        XCTAssertEqual(updated.displayName, "Cached User")
        XCTAssertGreaterThan(updated.profileLastCheckedAt?.timeIntervalSince1970 ?? 0, 1_000)
    }

    func testRefreshOneSkipsFreshProfileSnapshot() async throws {
        let store = self.makeWhamStore()
        var account = try self.makeOAuthAccount(
            accountID: "acct_wham_profile_fresh",
            email: "profile-fresh@example.com"
        )
        let lastChecked = Date()
        account.username = "fresh-user"
        account.profileLastCheckedAt = lastChecked
        store.addOrUpdate(account)

        var profileFetchCount = 0
        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in self.makeWhamUsageResult() },
            orgNameFetcher: { _ in nil },
            profileFetcher: { _ in
                profileFetchCount += 1
                return OpenAIProfileSnapshot(username: "unexpected", displayName: nil)
            },
            profileRefreshInterval: 60 * 60,
            oauthRefresh: { _ in .skipped }
        )

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(profileFetchCount, 0)
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(updated.username, "fresh-user")
        XCTAssertEqual(updated.profileLastCheckedAt, lastChecked)
    }

    func testRefreshOneDoesNotSuspendAccountWhenUsageEndpointDeniesAccess() async throws {
        for statusCode in [402, 403] {
            let store = self.makeWhamStore()
            let account = try self.makeOAuthAccount(
                accountID: "acct_wham_denied_\(statusCode)",
                email: "wham-denied-\(statusCode)@example.com"
            )
            store.addOrUpdate(account)

            let outcome = await WhamService.shared.refreshOne(
                account: account,
                store: store,
                usageFetcher: { _ in throw WhamError.usageEndpointAccessDenied(statusCode) },
                orgNameFetcher: { _ in nil },
                oauthRefresh: { _ in .skipped }
            )

            XCTAssertEqual(
                outcome,
                .usageUnavailable(L.usageEndpointAccessDeniedMsg(statusCode))
            )
            let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
            XCTAssertFalse(updated.isSuspended)
        }
    }

    func testRefreshOneStoresProfileWhenUsageEndpointDeniesAccess() async throws {
        for statusCode in [402, 403] {
            let store = self.makeWhamStore()
            let account = try self.makeOAuthAccount(
                accountID: "acct_wham_denied_profile_\(statusCode)",
                email: "wham-denied-profile-\(statusCode)@example.com"
            )
            store.addOrUpdate(account)

            let outcome = await WhamService.shared.refreshOne(
                account: account,
                store: store,
                usageFetcher: { _ in throw WhamError.usageEndpointAccessDenied(statusCode) },
                orgNameFetcher: { _ in nil },
                profileFetcher: { _ in
                    OpenAIProfileSnapshot(username: "denied-\(statusCode)", displayName: nil)
                },
                profileRefreshInterval: 0,
                oauthRefresh: { _ in .skipped }
            )

            XCTAssertEqual(
                outcome,
                .usageUnavailable(L.usageEndpointAccessDeniedMsg(statusCode))
            )
            let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
            XCTAssertEqual(updated.username, "denied-\(statusCode)")
            XCTAssertNotNil(updated.profileLastCheckedAt)
        }
    }

    func testSuccessfulRefreshClearsLegacySuspension() async throws {
        let store = TokenStore(
            openAIAccountGatewayService: NoopWhamGatewayController(),
            aggregateGatewayLeaseStore: NoopWhamAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        var account = try self.makeOAuthAccount(
            accountID: "acct_wham_legacy_suspension",
            email: "wham-legacy-suspension@example.com"
        )
        account.isSuspended = true
        store.addOrUpdate(account)

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in
                WhamUsageResult(
                    planType: "plus",
                    primaryUsedPercent: 10,
                    secondaryUsedPercent: 20,
                    primaryResetAt: nil,
                    secondaryResetAt: nil,
                    primaryLimitWindowSeconds: 18_000,
                    secondaryLimitWindowSeconds: 604_800
                )
            },
            orgNameFetcher: { _ in nil },
            oauthRefresh: { _ in .skipped }
        )

        XCTAssertEqual(outcome, .updated)
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertFalse(updated.isSuspended)
    }

    func testRefreshOneClearsStaleWeeklyWindowWhenUpstreamOnlyReturnsMonthlyWindow() async throws {
        let store = TokenStore(
            openAIAccountGatewayService: NoopWhamGatewayController(),
            aggregateGatewayLeaseStore: NoopWhamAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let monthlyWindowSeconds = 2_628_000
        var account = try self.makeOAuthAccount(
            accountID: "acct_wham_monthly_only",
            email: "monthly-only@example.com"
        )
        account.planType = "team"
        account.primaryUsedPercent = 0
        account.secondaryUsedPercent = 3
        account.primaryLimitWindowSeconds = 7 * 86_400
        account.secondaryLimitWindowSeconds = monthlyWindowSeconds
        store.addOrUpdate(account)

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in
                WhamUsageResult(
                    planType: "team",
                    primaryUsedPercent: 3,
                    secondaryUsedPercent: 0,
                    primaryResetAt: Date(timeIntervalSince1970: 1_787_000_000),
                    secondaryResetAt: nil,
                    primaryLimitWindowSeconds: monthlyWindowSeconds,
                    secondaryLimitWindowSeconds: nil
                )
            },
            orgNameFetcher: { _ in nil },
            oauthRefresh: { _ in .skipped }
        )

        XCTAssertEqual(outcome, .updated)
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(updated.primaryUsedPercent, 3)
        XCTAssertEqual(updated.primaryLimitWindowSeconds, monthlyWindowSeconds)
        XCTAssertNotNil(updated.primaryResetAt)
        XCTAssertEqual(updated.secondaryUsedPercent, 0)
        XCTAssertNil(updated.secondaryResetAt)
        XCTAssertNil(updated.secondaryLimitWindowSeconds)
        XCTAssertEqual(updated.usageWindowDisplays(mode: .used).count, 1)
    }

    func testRefreshOneUsesOAuthRefreshBeforeMarkingTokenExpired() async throws {
        let store = self.makeWhamStore()
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

    func testRefreshOneFetchesProfileWithRefreshedTokenAfterOAuthRecovery() async throws {
        let store = self.makeWhamStore()
        let account = try self.makeOAuthAccount(
            accountID: "acct_wham_profile_recovery",
            email: "wham-profile-recovery@example.com"
        )
        store.addOrUpdate(account)

        var refreshedAccount = account
        refreshedAccount.accessToken = "access-wham-profile-new"
        refreshedAccount.idToken = "id-wham-profile-new"
        refreshedAccount.tokenLastRefreshAt = Date(timeIntervalSince1970: 1_820_000_000)
        refreshedAccount.expiresAt = Date(timeIntervalSince1970: 1_820_003_600)

        var profileAccessTokens: [String] = []
        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { account in
                if account.accessToken == "access-wham-profile-new" {
                    return self.makeWhamUsageResult()
                }
                throw WhamError.unauthorized
            },
            orgNameFetcher: { _ in nil },
            profileFetcher: { account in
                profileAccessTokens.append(account.accessToken)
                return OpenAIProfileSnapshot(username: "recovered-profile", displayName: nil)
            },
            profileRefreshInterval: 0,
            oauthRefresh: { _ in .refreshed(refreshedAccount) }
        )

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(profileAccessTokens, ["access-wham-profile-new"])
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(updated.username, "recovered-profile")
        XCTAssertFalse(updated.tokenExpired)
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
        let store = self.makeWhamStore()

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

    private func makeWhamStore() -> TokenStore {
        TokenStore(
            openAIAccountGatewayService: NoopWhamGatewayController(),
            aggregateGatewayLeaseStore: NoopWhamAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
    }

    private func makeWhamUsageResult(
        planType: String = "plus",
        primaryUsedPercent: Double = 12,
        secondaryUsedPercent: Double = 0
    ) -> WhamUsageResult {
        WhamUsageResult(
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: nil,
            secondaryResetAt: nil,
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: nil
        )
    }
}

private final class NoopWhamGatewayController: OpenAIAccountGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        defaultProxy: OpenAIAccountGatewayConfiguredProxy?,
        proxyByAccountID: [String: OpenAIAccountGatewayConfiguredProxy]
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
