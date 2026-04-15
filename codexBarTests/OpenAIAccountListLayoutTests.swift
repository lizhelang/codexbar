import Foundation
import XCTest

final class OpenAIAccountListLayoutTests: XCTestCase {
    func testDisplaySortingPlacesRunningAccountsBeforeUsableAccounts() {
        let running = makeAccount(
            email: "busy@example.com",
            accountId: "acct_busy",
            primaryUsedPercent: 65,
            secondaryUsedPercent: 15
        )
        let healthierUsable = makeAccount(
            email: "healthy@example.com",
            accountId: "acct_healthy",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        let summary = OpenAIRunningThreadAttribution.Summary(
            availability: .available,
            runningThreadCounts: ["acct_busy": 1],
            unknownThreadCount: 0
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [healthierUsable, running],
            summary: summary
        )

        XCTAssertEqual(grouped.map(\.email), ["busy@example.com", "healthy@example.com"])
    }

    func testDisplaySortingPlacesNextUseAccountsBeforeUsableAccounts() {
        let nextUse = makeAccount(
            email: "next@example.com",
            accountId: "acct_next",
            primaryUsedPercent: 70,
            secondaryUsedPercent: 10,
            isActive: true
        )
        let healthierUsable = makeAccount(
            email: "healthy@example.com",
            accountId: "acct_healthy",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [healthierUsable, nextUse],
            summary: .empty
        )

        XCTAssertEqual(grouped.map(\.email), ["next@example.com", "healthy@example.com"])
    }

    func testDisplaySortingKeepsNormalOrderWithinPrioritizedAccounts() {
        let runningLowerQuota = makeAccount(
            email: "busy@example.com",
            accountId: "acct_busy",
            primaryUsedPercent: 40,
            secondaryUsedPercent: 15
        )
        let nextUseHigherQuota = makeAccount(
            email: "next@example.com",
            accountId: "acct_next",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 10,
            isActive: true
        )
        let summary = OpenAIRunningThreadAttribution.Summary(
            availability: .available,
            runningThreadCounts: ["acct_busy": 1],
            unknownThreadCount: 0
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [runningLowerQuota, nextUseHigherQuota],
            summary: summary
        )

        XCTAssertEqual(grouped.map(\.email), ["next@example.com", "busy@example.com"])
    }

    func testDisplaySortingIgnoresUnavailableRunningState() {
        let busy = makeAccount(
            email: "busy@example.com",
            accountId: "acct_busy",
            primaryUsedPercent: 40,
            secondaryUsedPercent: 15
        )
        let healthierUsable = makeAccount(
            email: "healthy@example.com",
            accountId: "acct_healthy",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [healthierUsable, busy],
            summary: .unavailable
        )

        XCTAssertEqual(grouped.map(\.email), ["healthy@example.com", "busy@example.com"])
    }

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

    func testMixedPlanWeightedQuotaTreatsPlusNinetyPercentLikeFreeZeroPercent() {
        let free = makeAccount(
            email: "free@example.com",
            accountId: "acct_free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let plus = makeAccount(
            email: "plus@example.com",
            accountId: "acct_plus",
            planType: "plus",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [free, plus])

        XCTAssertEqual(grouped.map(\.email), ["plus@example.com", "free@example.com"])
    }

    func testMixedPlanWeightedQuotaPrefersEarlierResetBeforePlanWeightFallback() {
        let free = makeAccount(
            email: "free@example.com",
            accountId: "acct_free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 60 * 60),
            secondaryResetAt: Date(timeIntervalSinceNow: 6 * 24 * 60 * 60)
        )
        let plus = makeAccount(
            email: "plus@example.com",
            accountId: "acct_plus",
            planType: "plus",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90,
            primaryResetAt: Date(timeIntervalSinceNow: 2 * 60 * 60),
            secondaryResetAt: Date(timeIntervalSinceNow: 7 * 24 * 60 * 60)
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [plus, free])

        XCTAssertEqual(grouped.map(\.email), ["free@example.com", "plus@example.com"])
    }

    func testExhaustedPlusRecoveringSoonBeatsFreeAccountsWithoutSecondaryWindow() {
        let free = makeAccount(
            email: "free@example.com",
            accountId: "acct_free",
            planType: "free",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 5 * 24 * 60 * 60)
        )
        let plus = makeAccount(
            email: "plus@example.com",
            accountId: "acct_plus",
            planType: "plus",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 99,
            primaryResetAt: Date(timeIntervalSinceNow: 50 * 60),
            secondaryResetAt: Date(timeIntervalSinceNow: 7 * 24 * 60 * 60)
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [free, plus])

        XCTAssertEqual(grouped.map(\.email), ["plus@example.com", "free@example.com"])
    }

    func testWeeklyExhaustedAccountSortsByWeeklyResetNotSoonerPrimaryReset() {
        let free = makeAccount(
            email: "free@example.com",
            accountId: "acct_free",
            planType: "free",
            primaryUsedPercent: 100,
            secondaryUsedPercent: 0,
            primaryResetAt: Date(timeIntervalSinceNow: 5 * 24 * 60 * 60)
        )
        let plus = makeAccount(
            email: "plus@example.com",
            accountId: "acct_plus",
            planType: "plus",
            primaryUsedPercent: 7,
            secondaryUsedPercent: 100,
            primaryResetAt: Date(timeIntervalSinceNow: 50 * 60),
            secondaryResetAt: Date(timeIntervalSinceNow: 7 * 24 * 60 * 60)
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [free, plus])

        XCTAssertEqual(grouped.map(\.email), ["free@example.com", "plus@example.com"])
    }

    func testMixedPlanWeightedQuotaGivesTeamOnePointFivePlusValue() {
        let plus = makeAccount(
            email: "plus@example.com",
            accountId: "acct_plus",
            planType: "plus",
            primaryUsedPercent: 40,
            secondaryUsedPercent: 40
        )
        let team = makeAccount(
            email: "team@example.com",
            accountId: "acct_team",
            planType: "team",
            primaryUsedPercent: 60,
            secondaryUsedPercent: 60
        )

        XCTAssertEqual(plus.weightedPrimaryRemainingPercent, 600.0)
        XCTAssertEqual(team.weightedPrimaryRemainingPercent, 600.0)

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [plus, team])

        XCTAssertEqual(grouped.map(\.email), ["team@example.com", "plus@example.com"])
    }

    func testProPlanUsesDedicatedWeightInsteadOfFreeFallback() {
        let free = makeAccount(
            email: "free@example.com",
            accountId: "acct_free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let pro = makeAccount(
            email: "pro@example.com",
            accountId: "acct_pro",
            planType: "pro",
            primaryUsedPercent: 92,
            secondaryUsedPercent: 92
        )

        XCTAssertEqual(pro.planQuotaMultiplier, 100.0)
        XCTAssertEqual(pro.weightedPrimaryRemainingPercent, 800.0)

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [free, pro])

        XCTAssertEqual(grouped.map(\.email), ["pro@example.com", "free@example.com"])
    }

    func testProPlanAssumesPaidSecondaryWindowByDefault() {
        let pro = makeAccount(
            email: "pro@example.com",
            accountId: "acct_pro",
            planType: "pro",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 0
        )

        XCTAssertEqual(pro.secondaryRemainingPercent, 100.0)
    }

    func testCustomQuotaSortSettingsAdjustRelativeWeights() {
        let free = makeAccount(
            email: "free@example.com",
            accountId: "acct_free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let plus = makeAccount(
            email: "plus@example.com",
            accountId: "acct_plus",
            planType: "plus",
            primaryUsedPercent: 80,
            secondaryUsedPercent: 80
        )
        let quotaSort = CodexBarOpenAISettings.QuotaSortSettings(
            plusRelativeWeight: 4,
            teamRelativeToPlusMultiplier: 2
        )

        XCTAssertEqual(plus.planQuotaMultiplier(using: quotaSort), 4)
        XCTAssertEqual(plus.weightedPrimaryRemainingPercent(using: quotaSort), 80)

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [free, plus],
            quotaSortSettings: quotaSort
        )

        XCTAssertEqual(grouped.map(\.email), ["free@example.com", "plus@example.com"])
    }

    func testCustomQuotaSortSettingsClampProRatioToMinimumRange() {
        let free = makeAccount(
            email: "free@example.com",
            accountId: "acct_free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let pro = makeAccount(
            email: "pro@example.com",
            accountId: "acct_pro",
            planType: "pro",
            primaryUsedPercent: 79,
            secondaryUsedPercent: 79
        )
        let quotaSort = CodexBarOpenAISettings.QuotaSortSettings(
            plusRelativeWeight: 1,
            proRelativeToPlusMultiplier: 1.0,
            teamRelativeToPlusMultiplier: 2
        )

        XCTAssertEqual(quotaSort.proRelativeToPlusMultiplier, 5)
        XCTAssertEqual(pro.planQuotaMultiplier(using: quotaSort), 5)
        XCTAssertEqual(pro.weightedPrimaryRemainingPercent(using: quotaSort), 105)

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [free, pro],
            quotaSortSettings: quotaSort
        )

        XCTAssertEqual(grouped.map(\.email), ["pro@example.com", "free@example.com"])
    }

    func testUnknownPlanTypeFallsBackToFreeWeight() {
        let unknown = makeAccount(
            email: "unknown@example.com",
            accountId: "acct_unknown",
            planType: "enterprise",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let plus = makeAccount(
            email: "plus@example.com",
            accountId: "acct_plus",
            planType: "plus",
            primaryUsedPercent: 90,
            secondaryUsedPercent: 90
        )

        XCTAssertEqual(unknown.planQuotaMultiplier, 1.0)
        XCTAssertEqual(plus.planQuotaMultiplier, 10.0)
        XCTAssertEqual(unknown.weightedPrimaryRemainingPercent, 100.0)
        XCTAssertEqual(plus.weightedPrimaryRemainingPercent, 100.0)

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [unknown, plus])
        XCTAssertEqual(grouped.map(\.email), ["plus@example.com", "unknown@example.com"])
    }

    func testUnavailableAccountsDoNotBeatUsableAccountsBecauseOfPlanWeight() {
        let healthyFree = makeAccount(
            email: "free@example.com",
            accountId: "acct_free",
            planType: "free",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0
        )
        let suspendedTeam = makeAccount(
            email: "team@example.com",
            accountId: "acct_team",
            planType: "team",
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0,
            isSuspended: true
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(from: [suspendedTeam, healthyFree])

        XCTAssertEqual(grouped.map(\.email), ["free@example.com", "team@example.com"])
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

    func testActiveAccountFloatsIntoPrioritizedBand() {
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

        XCTAssertEqual(grouped.map(\.email), ["active@example.com", "inactive@example.com"])
    }

    func testAggregateModeCanDisableActiveAccountFloating() {
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

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [activeLowerQuota, inactiveHigherQuota],
            highlightActiveAccount: false
        )

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

    func testPreferredAccountOrderDefinesBaseOrderAcrossGroups() {
        let healthy = makeAccount(
            email: "healthy@example.com",
            accountId: "acct_healthy",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        let manualTop = makeAccount(
            email: "manual@example.com",
            accountId: "acct_manual",
            primaryUsedPercent: 70,
            secondaryUsedPercent: 20
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [healthy, manualTop],
            preferredAccountOrder: ["acct_manual", "acct_healthy"]
        )

        XCTAssertEqual(grouped.map(\.email), ["manual@example.com", "healthy@example.com"])
    }

    func testPreferredAccountOrderKeepsUnlistedAccountsOnQuotaFallback() {
        let listed = makeAccount(
            email: "listed@example.com",
            accountId: "acct_listed",
            primaryUsedPercent: 60,
            secondaryUsedPercent: 10
        )
        let unlistedBetter = makeAccount(
            email: "better@example.com",
            accountId: "acct_better",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [unlistedBetter, listed],
            preferredAccountOrder: ["acct_listed"]
        )

        XCTAssertEqual(grouped.map(\.email), ["listed@example.com", "better@example.com"])
    }

    func testDisplaySortingKeepsPrioritizedAccountsInTopBandBeforePreferredBaseOrder() {
        let running = makeAccount(
            email: "running@example.com",
            accountId: "acct_running",
            primaryUsedPercent: 70,
            secondaryUsedPercent: 10
        )
        let manualTop = makeAccount(
            email: "manual@example.com",
            accountId: "acct_manual",
            primaryUsedPercent: 80,
            secondaryUsedPercent: 20
        )
        let healthierFallback = makeAccount(
            email: "fallback@example.com",
            accountId: "acct_fallback",
            primaryUsedPercent: 5,
            secondaryUsedPercent: 5
        )
        let summary = OpenAIRunningThreadAttribution.Summary(
            availability: .available,
            runningThreadCounts: ["acct_running": 1],
            unknownThreadCount: 0
        )

        let grouped = OpenAIAccountListLayout.groupedAccounts(
            from: [healthierFallback, manualTop, running],
            summary: summary,
            preferredAccountOrder: ["acct_manual"]
        )

        XCTAssertEqual(
            grouped.map(\.email),
            ["running@example.com", "manual@example.com", "fallback@example.com"]
        )
    }

    private func makeAccount(
        email: String,
        accountId: String,
        planType: String = "free",
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil,
        isActive: Bool = false,
        isSuspended: Bool = false,
        tokenExpired: Bool = false
    ) -> TokenAccount {
        TokenAccount(
            email: email,
            accountId: accountId,
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            isActive: isActive,
            isSuspended: isSuspended,
            tokenExpired: tokenExpired
        )
    }
}
