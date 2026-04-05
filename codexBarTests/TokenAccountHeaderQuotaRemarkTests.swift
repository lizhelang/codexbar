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

    func testUsableAccountShowsNoHeaderQuotaRemark() {
        let account = makeAccount(primaryUsedPercent: 55, secondaryUsedPercent: 40)

        XCTAssertNil(account.headerQuotaRemark(now: Date()))
    }

    func testExhaustedAccountWithoutResetTimeShowsNoHeaderQuotaRemark() {
        let account = makeAccount(primaryUsedPercent: 100, secondaryUsedPercent: 0)

        XCTAssertNil(account.headerQuotaRemark(now: Date()))
    }

    func testSecondaryRemarkTakesPriorityWhenBothWindowsAreExhausted() {
        let primaryResetAt = Date(timeIntervalSince1970: 1_700_000_000)
        let secondaryResetAt = Date(timeIntervalSince1970: 1_800_000_000)
        let now = secondaryResetAt.addingTimeInterval(-TimeInterval((17 * 86_400) + (8 * 3_600)))
        let account = makeAccount(
            primaryUsedPercent: 100,
            secondaryUsedPercent: 100,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.headerQuotaRemark(now: now), "17天8时")
    }

    func testGroupHeaderRemarkUsesRepresentativeAccountAfterSorting() {
        let weeklyExhausted = makeAccount(
            email: "group@example.com",
            accountId: "acct_weekly",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 100,
            secondaryResetAt: Date(timeIntervalSince1970: 1_800_000_000),
            primaryLimitWindowSeconds: 18_000,
            secondaryLimitWindowSeconds: 604_800
        )
        let primaryExhausted = makeAccount(
            email: "group@example.com",
            accountId: "acct_primary",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSince1970: 1_700_000_000),
            primaryLimitWindowSeconds: 18_000
        )

        let group = OpenAIAccountListLayout.groupedAccounts(from: [primaryExhausted, weeklyExhausted]).first

        XCTAssertEqual(group?.representativeAccount?.accountId, "acct_weekly")
        XCTAssertEqual(
            group?.headerQuotaRemark(
                now: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-TimeInterval((17 * 86_400) + (8 * 3_600)))
            ),
            "17天8时"
        )
    }

    func testGroupHeaderRemarkStaysHiddenWhenRepresentativeAccountHasQuota() {
        let usable = makeAccount(
            email: "group@example.com",
            accountId: "acct_usable",
            primaryUsedPercent: 20,
            secondaryUsedPercent: 15
        )
        let exhausted = makeAccount(
            email: "group@example.com",
            accountId: "acct_exhausted",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSince1970: 1_700_000_000),
            primaryLimitWindowSeconds: 18_000
        )

        let group = OpenAIAccountListLayout.groupedAccounts(from: [exhausted, usable]).first

        XCTAssertEqual(group?.representativeAccount?.accountId, "acct_usable")
        XCTAssertNil(group?.headerQuotaRemark(now: Date(timeIntervalSince1970: 1_650_000_000)))
    }

    func testFreeAccountUsesSevenDayLabelWhenPrimaryWindowIsWeekly() {
        let account = makeAccount(
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryLimitWindowSeconds: 604_800
        )

        XCTAssertEqual(account.usageWindowDisplays.map(\.label), ["7d"])
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

    private func makeAccount(
        email: String = "account@example.com",
        accountId: String = UUID().uuidString,
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil,
        primaryLimitWindowSeconds: Int? = nil,
        secondaryLimitWindowSeconds: Int? = nil
    ) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            primaryLimitWindowSeconds: primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: secondaryLimitWindowSeconds
        )
    }
}
