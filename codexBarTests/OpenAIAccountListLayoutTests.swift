import Foundation
import XCTest

final class OpenAIAccountListLayoutTests: XCTestCase {
    func testAccountsSortByPrimaryRemainingBeforeSecondaryRemaining() {
        let highPrimary = makeAccount(
            email: "high@example.com",
            accountId: "acct_high",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 90
        )
        let lowPrimary = makeAccount(
            email: "low@example.com",
            accountId: "acct_low",
            primaryUsedPercent: 30,
            secondaryUsedPercent: 0
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [lowPrimary, highPrimary])

        XCTAssertEqual(grouped.map(\.email), ["high@example.com", "low@example.com"])
    }

    func testExhaustedAccountsSinkToBottom() {
        let usable = makeAccount(
            email: "usable@example.com",
            accountId: "acct_usable",
            primaryUsedPercent: 15,
            secondaryUsedPercent: 10
        )
        let weeklyExhausted = makeAccount(
            email: "weekly@example.com",
            accountId: "acct_weekly",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 100
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [weeklyExhausted, usable])

        XCTAssertEqual(grouped.map(\.email), ["usable@example.com", "weekly@example.com"])
    }

    func testActiveAccountDoesNotOverrideQuotaSorting() {
        let activeLowerQuota = makeAccount(
            email: "active@example.com",
            accountId: "acct_active",
            primaryUsedPercent: 75,
            secondaryUsedPercent: 10,
            isActive: true
        )
        let inactiveHigherQuota = makeAccount(
            email: "inactive@example.com",
            accountId: "acct_inactive",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [activeLowerQuota, inactiveHigherQuota])

        XCTAssertEqual(grouped.map(\.email), ["inactive@example.com", "active@example.com"])
    }

    func testGroupsAreRankedByBestAccount() {
        let topGroupLow = makeAccount(
            email: "alpha@example.com",
            accountId: "acct_alpha_low",
            primaryUsedPercent: 60,
            secondaryUsedPercent: 10
        )
        let topGroupHigh = makeAccount(
            email: "alpha@example.com",
            accountId: "acct_alpha_high",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 15
        )
        let middleGroup = makeAccount(
            email: "beta@example.com",
            accountId: "acct_beta",
            primaryUsedPercent: 20,
            secondaryUsedPercent: 5
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [middleGroup, topGroupLow, topGroupHigh])

        XCTAssertEqual(grouped.map(\.email), ["alpha@example.com", "beta@example.com"])
        XCTAssertEqual(grouped.first?.accounts.map(\.accountId), ["acct_alpha_high", "acct_alpha_low"])
    }

    func testFullyExhaustedGroupsSinkBelowMixedGroups() {
        let mixedUsable = makeAccount(
            email: "mixed@example.com",
            accountId: "acct_mixed_usable",
            primaryUsedPercent: 25,
            secondaryUsedPercent: 10
        )
        let mixedExhausted = makeAccount(
            email: "mixed@example.com",
            accountId: "acct_mixed_exhausted",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 10
        )
        let fullyExhaustedA = makeAccount(
            email: "exhausted@example.com",
            accountId: "acct_exhausted_a",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0
        )
        let fullyExhaustedB = makeAccount(
            email: "exhausted@example.com",
            accountId: "acct_exhausted_b",
            primaryUsedPercent: 20,
            secondaryUsedPercent: 100
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [fullyExhaustedA, mixedExhausted, mixedUsable, fullyExhaustedB]
        )

        XCTAssertEqual(grouped.map(\.email), ["mixed@example.com", "exhausted@example.com"])
        XCTAssertEqual(grouped.first?.accounts.map(\.accountId), ["acct_mixed_usable", "acct_mixed_exhausted"])
    }

    func testVisibleGroupsLimitsByAccountCountAcrossGroups() {
        let firstA = makeAccount(
            email: "alpha@example.com",
            accountId: "acct_alpha_1",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 5
        )
        let firstB = makeAccount(
            email: "alpha@example.com",
            accountId: "acct_alpha_2",
            primaryUsedPercent: 20,
            secondaryUsedPercent: 5
        )
        let secondA = makeAccount(
            email: "beta@example.com",
            accountId: "acct_beta_1",
            primaryUsedPercent: 15,
            secondaryUsedPercent: 5
        )
        let secondB = makeAccount(
            email: "beta@example.com",
            accountId: "acct_beta_2",
            primaryUsedPercent: 25,
            secondaryUsedPercent: 5
        )
        let secondC = makeAccount(
            email: "beta@example.com",
            accountId: "acct_beta_3",
            primaryUsedPercent: 35,
            secondaryUsedPercent: 5
        )
        let third = makeAccount(
            email: "gamma@example.com",
            accountId: "acct_gamma_1",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [firstA, firstB, secondA, secondB, secondC, third])
        let visible = OpenAIAccountListLayout.visibleGroups(from: grouped, maxAccounts: 5)

        XCTAssertEqual(visible.map(\.email), ["gamma@example.com", "alpha@example.com", "beta@example.com"])
        XCTAssertEqual(visible.flatMap(\.accounts).map(\.accountId), [
            "acct_gamma_1",
            "acct_alpha_1",
            "acct_alpha_2",
            "acct_beta_1",
            "acct_beta_2",
        ])
    }

    private func makeAccount(
        email: String,
        accountId: String,
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double,
        isActive: Bool = false
    ) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            isActive: isActive
        )
    }
}
