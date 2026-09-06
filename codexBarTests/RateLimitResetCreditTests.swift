import Foundation
import XCTest

final class RateLimitResetCreditTests: XCTestCase {
    func testParsesAvailableCountFromUsagePayload() {
        let result = WhamService.shared.parseUsage([
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 40.0,
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_775_372_003.0,
                ],
            ],
            "rate_limit_reset_credits": [
                "available_count": 3,
            ],
        ])

        XCTAssertEqual(result.resetCreditAvailableCount, 3)
    }

    func testParsesCreditDetailsAndIgnoresUnavailableEntries() {
        let snapshot = RateLimitResetCreditPolicy.parseCreditsSnapshot([
            "available_count": 2,
            "credits": [
                [
                    "id": "RateLimitResetCredit_soon",
                    "reset_type": "codex_rate_limits",
                    "status": "available",
                    "title": "Full reset (Weekly + 5 hr)",
                    "granted_at": "2026-08-01T00:00:00Z",
                    "expires_at": "2026-09-06T04:00:00Z",
                ],
                [
                    "id": "RateLimitResetCredit_used",
                    "status": "redeemed",
                    "title": "Used",
                    "expires_at": "2026-09-10T00:00:00Z",
                ],
                [
                    "id": "RateLimitResetCredit_later",
                    "status": "available",
                    "title": "Full reset",
                    "expires_at": "2026-09-20T00:00:00Z",
                ],
            ],
        ])

        XCTAssertEqual(snapshot.availableCount, 2)
        XCTAssertEqual(snapshot.credits.count, 3)
        let now = Date(timeIntervalSince1970: 1_757_030_400) // 2025-09-05
        XCTAssertEqual(snapshot.availableCredits(now: now).map(\.id), [
            "RateLimitResetCredit_soon",
            "RateLimitResetCredit_later",
        ])
    }

    func testSoonestCreditIsGlobalEarliestExpiry() {
        let now = Date(timeIntervalSince1970: 1_788_595_200) // 2026-09-05
        let later = self.credit(id: "later", expiresAt: now.addingTimeInterval(5 * 86_400))
        let soon = self.credit(id: "soon", expiresAt: now.addingTimeInterval(10 * 3_600))
        let accounts = [
            TokenAccount(
                email: "b@example.com",
                accountId: "acct_b",
                rateLimitResetAvailableCount: 1,
                rateLimitResetCredits: [later]
            ),
            TokenAccount(
                email: "a@example.com",
                accountId: "acct_a",
                primaryUsedPercent: 88,
                rateLimitResetAvailableCount: 1,
                rateLimitResetCredits: [soon]
            ),
        ]

        let soonest = RateLimitResetCreditPresentation.soonest(from: accounts, now: now)
        XCTAssertEqual(soonest?.creditId, "soon")
        XCTAssertEqual(soonest?.accountId, "acct_a")
        XCTAssertEqual(RateLimitResetCreditPresentation.badge(from: accounts, now: now), .urgent)
        XCTAssertEqual(
            RateLimitResetCreditPresentation.accountRowSummary(for: accounts[1], now: now),
            L.resetCreditAccountSummary(1, L.resetCreditInHr(10, 0))
        )
    }

    func testCollapsedItemsKeepOnlyTheSoonestCredit() {
        let now = Date(timeIntervalSince1970: 1_788_595_200)
        let items = (0..<10).map { index in
            RateLimitResetCreditItem(
                accountId: "acct_\(index)",
                accountLabel: "user\(index)@example.com",
                creditId: "credit_\(index)",
                title: "Full reset",
                expiresAt: now.addingTimeInterval(TimeInterval((index + 1) * 3_600)),
                primaryUsedPercent: 40,
                secondaryUsedPercent: 10
            )
        }

        XCTAssertEqual(RateLimitResetCreditPresentation.collapsedVisibleCount, 1)
        XCTAssertEqual(
            RateLimitResetCreditPresentation.collapsedItems(items).map(\.creditId),
            ["credit_0"]
        )
        XCTAssertTrue(RateLimitResetCreditPresentation.canExpand(items))
        XCTAssertFalse(RateLimitResetCreditPresentation.canExpand(Array(items.prefix(1))))
    }

    func testBadgeUsesSeventyTwoHourHorizonAndTwentyFourHourUrgency() {
        let now = Date(timeIntervalSince1970: 1_788_595_200)
        let approaching = TokenAccount(
            email: "warn@example.com",
            accountId: "acct_warn",
            rateLimitResetAvailableCount: 1,
            rateLimitResetCredits: [
                self.credit(id: "warn", expiresAt: now.addingTimeInterval(50 * 3_600)),
            ]
        )
        let quiet = TokenAccount(
            email: "ok@example.com",
            accountId: "acct_ok",
            rateLimitResetAvailableCount: 1,
            rateLimitResetCredits: [
                self.credit(id: "ok", expiresAt: now.addingTimeInterval(8 * 86_400)),
            ]
        )

        XCTAssertEqual(
            RateLimitResetCreditPresentation.badge(from: [approaching], now: now),
            .approaching
        )
        XCTAssertEqual(
            RateLimitResetCreditPresentation.badge(from: [quiet], now: now),
            .none
        )
    }

    func testEmptyWindowWarningUsesLowUsageThreshold() {
        let now = Date(timeIntervalSince1970: 1_788_595_200)
        let unused = RateLimitResetCreditItem(
            accountId: "acct_unused",
            accountLabel: "unused@example.com",
            creditId: "credit_unused",
            title: "Full reset",
            expiresAt: now.addingTimeInterval(3_600),
            primaryUsedPercent: 1,
            secondaryUsedPercent: 0
        )
        let used = RateLimitResetCreditItem(
            accountId: "acct_used",
            accountLabel: "used@example.com",
            creditId: "credit_used",
            title: "Full reset",
            expiresAt: now.addingTimeInterval(3_600),
            primaryUsedPercent: 90,
            secondaryUsedPercent: 10
        )

        XCTAssertTrue(unused.hasMostlyUnusedWindows())
        XCTAssertFalse(used.hasMostlyUnusedWindows())
    }

    func testPendingNotificationsAreDedupedAndOnlyWithinTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_788_595_200)
        let urgent = self.credit(id: "urgent", expiresAt: now.addingTimeInterval(12 * 3_600))
        let later = self.credit(id: "later", expiresAt: now.addingTimeInterval(40 * 3_600))
        let accounts = [
            TokenAccount(
                email: "notify@example.com",
                accountId: "acct_notify",
                rateLimitResetAvailableCount: 2,
                rateLimitResetCredits: [urgent, later]
            ),
        ]
        let already = Set([
            RateLimitResetCreditPolicy.notificationKey(
                creditId: "urgent",
                expiresAt: urgent.expiresAt!
            ),
        ])

        XCTAssertEqual(
            RateLimitResetCreditPresentation.pendingNotificationKeys(
                from: accounts,
                now: now,
                alreadyNotified: []
            ).map(\.creditId),
            ["urgent"]
        )
        XCTAssertTrue(
            RateLimitResetCreditPresentation.pendingNotificationKeys(
                from: accounts,
                now: now,
                alreadyNotified: already
            ).isEmpty
        )
    }

    func testConsumeCodesAreParsed() {
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseConsumeResult(["code": "reset", "windows_reset": 2]).code,
            .reset
        )
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseConsumeResult(["code": "nothing_to_reset"]).code,
            .nothingToReset
        )
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseConsumeResult(["code": "already_redeemed"]).code,
            .alreadyRedeemed
        )
        XCTAssertEqual(
            RateLimitResetCreditPolicy.parseConsumeResult(["code": "no_credit"]).code,
            .noCredit
        )
    }

    private func credit(id: String, expiresAt: Date) -> RateLimitResetCredit {
        RateLimitResetCredit(
            id: id,
            title: "Full reset",
            status: "available",
            grantedAt: expiresAt.addingTimeInterval(-30 * 86_400),
            expiresAt: expiresAt
        )
    }
}

@MainActor
final class RateLimitResetCreditRefreshTests: CodexBarTestCase {
    func testRefreshOneLoadsCreditDetailsWhenUsageReportsAvailableCount() async throws {
        let store = TokenStore(
            openAIAccountGatewayService: NoopResetCreditGatewayController(),
            aggregateGatewayLeaseStore: NoopResetCreditAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        let account = try self.makeOAuthAccount(
            accountID: "acct_reset_credits",
            email: "reset@example.com"
        )
        store.addOrUpdate(account)
        let expiresAt = Date(timeIntervalSince1970: 1_789_000_000)
        var detailsFetchCount = 0

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in
                WhamUsageResult(
                    planType: "plus",
                    primaryUsedPercent: 70,
                    secondaryUsedPercent: 20,
                    primaryResetAt: nil,
                    secondaryResetAt: nil,
                    primaryLimitWindowSeconds: 18_000,
                    secondaryLimitWindowSeconds: 604_800,
                    resetCreditAvailableCount: 1
                )
            },
            resetCreditsFetcher: { _ in
                detailsFetchCount += 1
                return RateLimitResetCreditsSnapshot(
                    availableCount: 1,
                    credits: [
                        RateLimitResetCredit(
                            id: "RateLimitResetCredit_one",
                            title: "Full reset",
                            status: "available",
                            grantedAt: nil,
                            expiresAt: expiresAt
                        ),
                    ]
                )
            },
            orgNameFetcher: { _ in nil },
            oauthRefresh: { _ in .skipped }
        )

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(detailsFetchCount, 1)
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(updated.rateLimitResetAvailableCount, 1)
        XCTAssertEqual(updated.rateLimitResetCredits.map(\.id), ["RateLimitResetCredit_one"])
        XCTAssertEqual(updated.primaryUsedPercent, 70)
    }

    func testRefreshOneSkipsCreditDetailsWhenNoneAreAvailable() async throws {
        let store = TokenStore(
            openAIAccountGatewayService: NoopResetCreditGatewayController(),
            aggregateGatewayLeaseStore: NoopResetCreditAggregateLeaseStore(),
            codexRunningProcessIDs: { [] }
        )
        var account = try self.makeOAuthAccount(
            accountID: "acct_no_reset_credits",
            email: "none@example.com"
        )
        account.rateLimitResetAvailableCount = 2
        account.rateLimitResetCredits = [
            RateLimitResetCredit(
                id: "stale",
                title: "Full reset",
                status: "available",
                expiresAt: Date().addingTimeInterval(86_400)
            ),
        ]
        store.addOrUpdate(account)
        var detailsFetchCount = 0

        let outcome = await WhamService.shared.refreshOne(
            account: account,
            store: store,
            usageFetcher: { _ in
                WhamUsageResult(
                    planType: "plus",
                    primaryUsedPercent: 10,
                    secondaryUsedPercent: 0,
                    primaryResetAt: nil,
                    secondaryResetAt: nil,
                    primaryLimitWindowSeconds: 18_000,
                    secondaryLimitWindowSeconds: nil,
                    resetCreditAvailableCount: 0
                )
            },
            resetCreditsFetcher: { _ in
                detailsFetchCount += 1
                return RateLimitResetCreditsSnapshot(availableCount: 0, credits: [])
            },
            orgNameFetcher: { _ in nil },
            oauthRefresh: { _ in .skipped }
        )

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(detailsFetchCount, 0)
        let updated = try XCTUnwrap(store.oauthAccount(accountID: account.accountId))
        XCTAssertEqual(updated.rateLimitResetAvailableCount, 0)
        XCTAssertTrue(updated.rateLimitResetCredits.isEmpty)
    }
}

private final class NoopResetCreditGatewayController: OpenAIAccountGatewayControlling {
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

private final class NoopResetCreditAggregateLeaseStore: OpenAIAggregateGatewayLeaseStoring {
    func loadProcessIDs() -> Set<pid_t> { [] }
    func saveProcessIDs(_ processIDs: Set<pid_t>) {}
    func clear() {}
}
