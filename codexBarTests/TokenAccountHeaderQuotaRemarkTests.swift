import Foundation
import XCTest

final class TokenAccountHeaderQuotaRemarkTests: XCTestCase {
    private var originalLanguageOverride: Bool?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLanguageOverride = L.languageOverride
        L.languageOverride = true
    }

    override func tearDownWithError() throws {
        L.languageOverride = originalLanguageOverride
        try super.tearDownWithError()
    }

    func testSecondaryExhaustedShowsCompactWeeklyRemainingTime() {
        let resetAt = Date(timeIntervalSince1970: 1_775_600_000)
        let now = Date(timeIntervalSince1970: 1_775_500_000)
        let account = makeAccount(
            primaryUsedPercent: 0,
            secondaryUsedPercent: 100,
            secondaryResetAt: resetAt,
            secondaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.headerQuotaRemark(now: now), "1天3时")
    }

    func testPrimaryExhaustedShowsRemainingTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetAt = now.addingTimeInterval((2 * 3600) + (15 * 60) + 42)
        let account = makeAccount(
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryResetAt: resetAt,
            primaryLimitWindowSeconds: 18_000
        )

        XCTAssertEqual(account.headerQuotaRemark(now: now), "2时15分")
    }

    func testUsableAccountShowsNearestResetTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = makeAccount(
            primaryUsedPercent: 55,
            secondaryUsedPercent: 40,
            primaryResetAt: now.addingTimeInterval((1 * 3_600) + (20 * 60)),
            secondaryResetAt: now.addingTimeInterval(4 * 86_400),
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.headerQuotaRemark(now: now), "1时20分")
    }

    func testExhaustedAccountWithoutResetTimeShowsNoHeaderQuotaRemark() {
        let account = makeAccount(primaryUsedPercent: 100, secondaryUsedPercent: 0)

        XCTAssertNil(account.headerQuotaRemark(now: Date()))
    }

    func testLaterExhaustedWindowWinsWhenBothWindowsExist() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let primaryResetAt = now.addingTimeInterval((2 * 3_600) + (10 * 60))
        let secondaryResetAt = now.addingTimeInterval((6 * 86_400) + (8 * 3_600))
        let account = makeAccount(
            primaryUsedPercent: 100,
            secondaryUsedPercent: 100,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.headerQuotaRemark(now: now), "6天8时")
    }

    func testWeeklyExhaustedPrefersWeeklyResetEvenWhenPrimaryResetIsSooner() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = makeAccount(
            planType: "plus",
            primaryUsedPercent: 7,
            secondaryUsedPercent: 100,
            primaryResetAt: now.addingTimeInterval((4 * 3_600) + (51 * 60)),
            secondaryResetAt: now.addingTimeInterval((5 * 24 * 3_600) + (4 * 3_600)),
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.headerQuotaRemark(now: now), "5天4时")
    }

    func testNearestResetIgnoresPastWindowWhenFutureWindowExists() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = makeAccount(
            primaryUsedPercent: 90,
            secondaryUsedPercent: 40,
            primaryResetAt: now.addingTimeInterval(-20 * 60),
            secondaryResetAt: now.addingTimeInterval((3 * 3_600) + (30 * 60)),
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.headerQuotaRemark(now: now), "3时30分")
    }

    func testHeaderQuotaRemarkClampsPrimaryResetToFiveHourWindowFromLastChecked() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = makeAccount(
            primaryUsedPercent: 90,
            secondaryUsedPercent: 0,
            primaryResetAt: now.addingTimeInterval(8 * 3_600),
            primaryLimitWindowSeconds: 18_000,
            lastChecked: now.addingTimeInterval(-(90 * 60))
        )

        XCTAssertEqual(account.headerQuotaRemark(now: now), "3时30分")
    }

    func testHeaderQuotaRemarkClampsWeeklyResetToSevenDaysFromLastChecked() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = makeAccount(
            primaryUsedPercent: 30,
            secondaryUsedPercent: 100,
            secondaryResetAt: now.addingTimeInterval(10 * 86_400),
            secondaryLimitWindowSeconds: 604_800,
            lastChecked: now.addingTimeInterval(-(12 * 3_600))
        )

        XCTAssertEqual(account.headerQuotaRemark(now: now), "6天12时")
    }

    func testOAuthSnapshotRoundTripSanitizesPrimaryResetBeforePersistence() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = makeAccount(
            primaryUsedPercent: 90,
            secondaryUsedPercent: 0,
            primaryResetAt: now.addingTimeInterval(8 * 3_600),
            primaryLimitWindowSeconds: 18_000,
            lastChecked: now.addingTimeInterval(-(90 * 60))
        )

        let stored = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
        let restored = try XCTUnwrap(stored.asTokenAccount(isActive: false))

        XCTAssertEqual(stored.primaryResetAt, now.addingTimeInterval(3.5 * 3_600))
        XCTAssertEqual(restored.primaryResetAt, now.addingTimeInterval(3.5 * 3_600))
    }

    func testGroupHeaderRemarkUsesRepresentativeAccountAfterSorting() {
        let now = Date(timeIntervalSince1970: 1_650_000_000)
        let weeklyExhausted = makeAccount(
            email: "group@example.com",
            accountId: "acct_weekly",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 100,
            secondaryResetAt: now.addingTimeInterval((17 * 86_400) + (8 * 3_600)),
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )
        let primaryExhausted = makeAccount(
            email: "group@example.com",
            accountId: "acct_primary",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryResetAt: now.addingTimeInterval((1 * 3_600) + (15 * 60)),
            primaryLimitWindowSeconds: 18_000
        )

        let group = OpenAIAccountListLayout.groupedAccounts(from: [primaryExhausted, weeklyExhausted]).first

        XCTAssertEqual(group?.representativeAccount?.accountId, "acct_primary")
        XCTAssertEqual(group?.headerQuotaRemark(now: now), "1时15分")
    }

    func testGroupHeaderRemarkUsesNearestResetAcrossAllAccountsInGroup() {
        let now = Date(timeIntervalSince1970: 1_650_000_000)
        let usable = makeAccount(
            email: "group@example.com",
            accountId: "acct_usable",
            primaryUsedPercent: 20,
            secondaryUsedPercent: 15,
            primaryResetAt: now.addingTimeInterval((3 * 3_600) + (5 * 60)),
            secondaryResetAt: now.addingTimeInterval(2 * 86_400),
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )
        let exhausted = makeAccount(
            email: "group@example.com",
            accountId: "acct_exhausted",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryResetAt: now.addingTimeInterval((1 * 3_600) + (45 * 60)),
            primaryLimitWindowSeconds: 18_000
        )

        let group = OpenAIAccountListLayout.groupedAccounts(from: [exhausted, usable]).first

        XCTAssertEqual(group?.representativeAccount?.accountId, "acct_usable")
        XCTAssertEqual(group?.headerQuotaRemark(now: now), "1时45分")
    }

    func testGroupHeaderRemarkUsesNearestResetAcrossMultipleUsableIdentities() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let plus = makeAccount(
            email: "group@example.com",
            accountId: "acct_plus",
            primaryUsedPercent: 24,
            secondaryUsedPercent: 57,
            primaryResetAt: now.addingTimeInterval((2 * 3_600) + (10 * 60)),
            secondaryResetAt: now.addingTimeInterval(6 * 86_400),
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )
        let team = makeAccount(
            email: "group@example.com",
            accountId: "acct_team",
            planType: "team",
            primaryUsedPercent: 51,
            secondaryUsedPercent: 18,
            primaryResetAt: now.addingTimeInterval(45 * 60),
            secondaryResetAt: now.addingTimeInterval(5 * 86_400),
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        let group = OpenAIAccountListLayout.groupedAccounts(from: [plus, team]).first

        XCTAssertEqual(group?.headerQuotaRemark(now: now), "45分")
    }

    func testGroupHeaderRemarkPrefersFutureResetOverPastResetInSameGroup() {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let stale = makeAccount(
            email: "group@example.com",
            accountId: "acct_stale",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 20,
            primaryResetAt: now.addingTimeInterval(-5 * 60),
            primaryLimitWindowSeconds: 18_000
        )
        let future = makeAccount(
            email: "group@example.com",
            accountId: "acct_future",
            primaryUsedPercent: 35,
            secondaryUsedPercent: 10,
            primaryResetAt: now.addingTimeInterval((1 * 3_600) + (5 * 60)),
            primaryLimitWindowSeconds: 18_000
        )

        let group = OpenAIAccountListLayout.groupedAccounts(from: [stale, future]).first

        XCTAssertEqual(group?.headerQuotaRemark(now: now), "1时5分")
    }

    func testFreeAccountUsesSevenDayLabelWhenPrimaryWindowIsWeekly() {
        let account = makeAccount(
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.usageWindowDisplays.map(\.label), ["7d"])
    }

    func testPlusWeeklyOnlySnapshotShowsSingleSevenDayWindow() {
        let account = makeAccount(
            planType: "plus",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0,
            primaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.usageWindowDisplays.map(\.label), ["7d"])
        XCTAssertEqual(account.compactUsageSummary(mode: .remaining), "7d 100%")
    }

    func testDuplicateWeeklyWindowsAreCollapsedForDisplayAndPersistence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let primaryResetAt = now.addingTimeInterval(2 * 86_400)
        let secondaryResetAt = now.addingTimeInterval(5 * 86_400)
        let account = makeAccount(
            planType: "plus",
            primaryUsedPercent: 42,
            secondaryUsedPercent: 87,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            primaryLimitWindowSeconds: 604_800,
            secondaryLimitWindowSeconds: 604_800,
            lastChecked: now
        )

        XCTAssertEqual(account.usageWindowDisplays.map(\.label), ["7d"])
        XCTAssertEqual(account.compactUsageSummary(mode: .used), "7d 87%")

        let normalized = account.normalizedQuotaSnapshot(now: now)
        XCTAssertEqual(normalized.primaryUsedPercent, 87)
        XCTAssertEqual(normalized.primaryResetAt, secondaryResetAt)
        XCTAssertEqual(normalized.primaryLimitWindowSeconds, 604_800)
        XCTAssertEqual(normalized.secondaryUsedPercent, 0)
        XCTAssertNil(normalized.secondaryResetAt)
        XCTAssertNil(normalized.secondaryLimitWindowSeconds)
    }

    func testPlusAccountShowsBothUsageWindowLabels() {
        let account = makeAccount(
            primaryUsedPercent: 10,
            secondaryUsedPercent: 20,
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.usageWindowDisplays.map(\.label), ["5h", "7d"])
    }

    func testRemainingUsageDisplayShowsRemainingPercentages() {
        let account = makeAccount(
            primaryUsedPercent: 35,
            secondaryUsedPercent: 80,
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        let displays = account.usageWindowDisplays(mode: .remaining)

        XCTAssertEqual(displays.map(\.displayPercent), [65, 20])
    }

    func testCompactPrimaryUsageSummaryPrefersFiveHourWindowWhenPresent() {
        let account = makeAccount(
            primaryUsedPercent: 55,
            secondaryUsedPercent: 24,
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.compactPrimaryUsageSummary(mode: .remaining), "45%")
    }

    func testCompactPrimaryUsageSummaryUsesWeeklyWindowForFreeAccount() {
        let account = makeAccount(
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0,
            primaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.compactPrimaryUsageSummary(mode: .remaining), "100%")
    }

    func testVisualWarningThresholdUsesRemainingQuota() {
        let warningAccount = makeAccount(
            primaryUsedPercent: 85,
            secondaryUsedPercent: 10,
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )
        let healthyAccount = makeAccount(
            primaryUsedPercent: 75,
            secondaryUsedPercent: 10,
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        XCTAssertTrue(warningAccount.isBelowVisualWarningThreshold())
        XCTAssertFalse(healthyAccount.isBelowVisualWarningThreshold())
    }

    private func makeAccount(
        email: String = "account@example.com",
        accountId: String = UUID().uuidString,
        planType: String = "free",
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil,
        primaryLimitWindowSeconds: Int? = nil,
        secondaryLimitWindowSeconds: Int? = nil,
        lastChecked: Date? = nil
    ) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            primaryLimitWindowSeconds: primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: secondaryLimitWindowSeconds,
            lastChecked: lastChecked
        )
    }
}
