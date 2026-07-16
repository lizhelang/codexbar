import AppKit
import XCTest

final class MenuBarStatusItemPresentationTests: XCTestCase {
    func testActiveAccountUsesCompactUsageBarsByDefault() {
        let account = TokenAccount(
            email: "active@example.com",
            accountId: "acct_active",
            planType: "plus",
            primaryUsedPercent: 67,
            secondaryUsedPercent: 48,
            isActive: true
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [account],
            activeProvider: nil,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )

        XCTAssertEqual(
            presentation.icon,
            .usageBars(MenuBarUsageIconSpec(displayPercents: [67, 48]))
        )
        XCTAssertEqual(presentation.title, "")
        XCTAssertEqual(
            presentation.accessibilityValue,
            "5h \(L.usedShort) 67% · 7d \(L.usedShort) 48%"
        )
        XCTAssertEqual(presentation.emphasis, .primary)
        XCTAssertEqual(presentation.layout, .compact)
    }

    func testOptionalUsageTextPreservesExistingPercentSummary() {
        let account = TokenAccount(
            email: "active@example.com",
            accountId: "acct_active",
            planType: "plus",
            primaryUsedPercent: 67,
            secondaryUsedPercent: 48,
            isActive: true
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [account],
            activeProvider: nil,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false,
            showsUsageText: true
        )

        XCTAssertEqual(
            presentation.icon,
            .usageBars(MenuBarUsageIconSpec(displayPercents: [67, 48]))
        )
        XCTAssertEqual(presentation.title, "67%·48%")
        XCTAssertEqual(presentation.layout, .iconAndText)
    }

    func testWeeklyOnlyAccountUsesSingleCenteredUsageBar() {
        let account = TokenAccount(
            email: "weekly@example.com",
            accountId: "acct_weekly",
            primaryUsedPercent: 73,
            primaryLimitWindowSeconds: 7 * 86_400,
            isActive: true
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [account],
            activeProvider: nil,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )

        XCTAssertEqual(
            presentation.icon,
            .usageBars(MenuBarUsageIconSpec(displayPercents: [73]))
        )
        XCTAssertEqual(presentation.accessibilityValue, "7d \(L.usedShort) 73%")
    }

    func testRestoredFiveHourWindowAutomaticallyUsesTwoBars() {
        let account = TokenAccount(
            email: "restored@example.com",
            accountId: "acct_restored",
            primaryUsedPercent: 24,
            secondaryUsedPercent: 65,
            primaryLimitWindowSeconds: 5 * 3_600,
            secondaryLimitWindowSeconds: 7 * 86_400,
            isActive: true
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [account],
            activeProvider: nil,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )

        XCTAssertEqual(
            presentation.icon,
            .usageBars(MenuBarUsageIconSpec(displayPercents: [24, 65]))
        )
    }

    func testExhaustedWeeklyOnlyWindowUsesWeeklyWarningSemantics() {
        let account = TokenAccount(
            email: "weekly@example.com",
            accountId: "acct_weekly_exhausted",
            primaryUsedPercent: 100,
            primaryLimitWindowSeconds: 7 * 86_400,
            isActive: true
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [account],
            activeProvider: nil,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.icon, .systemSymbol("exclamationmark.triangle.fill"))
        XCTAssertEqual(presentation.accessibilityValue, L.weeklyLimit)
        XCTAssertEqual(presentation.emphasis, .critical)
    }

    func testRemainingModeDrivesBothBarsAndAccessibilitySummary() {
        let account = TokenAccount(
            email: "remaining@example.com",
            accountId: "acct_remaining",
            planType: "plus",
            primaryUsedPercent: 25,
            secondaryUsedPercent: 40,
            isActive: true
        )

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [account],
            activeProvider: nil,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .remaining,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )

        XCTAssertEqual(
            presentation.icon,
            .usageBars(MenuBarUsageIconSpec(displayPercents: [75, 60]))
        )
        XCTAssertEqual(
            presentation.accessibilityValue,
            "5h \(L.remainingShort) 75% · 7d \(L.remainingShort) 60%"
        )
    }

    func testAggregateModeUsesAggregateRoutedAccount() {
        let aggregate = TokenAccount(
            email: "agg@example.com",
            accountId: "acct_agg",
            planType: "plus",
            primaryUsedPercent: 42,
            secondaryUsedPercent: 70
        )
        let provider = CodexBarProvider(id: "openai", kind: .openAIOAuth, label: "OpenAI")

        let compact = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: aggregate,
            usageDisplayMode: .used,
            accountUsageMode: .aggregateGateway,
            updateAvailable: false
        )
        let withText = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: aggregate,
            usageDisplayMode: .used,
            accountUsageMode: .aggregateGateway,
            updateAvailable: false,
            showsUsageText: true
        )

        XCTAssertEqual(
            compact.icon,
            .usageBars(MenuBarUsageIconSpec(displayPercents: [42, 70]))
        )
        XCTAssertEqual(compact.title, "")
        XCTAssertEqual(
            compact.accessibilityValue,
            "5h \(L.usedShort) 42% · 7d \(L.usedShort) 70%"
        )
        XCTAssertEqual(withText.title, L.openAIRouteSummaryCompact("42%"))
        XCTAssertEqual(withText.emphasis, .primary)
    }

    func testAggregateWarningPriorityUsesRoutedAccountInsteadOfPreferredActiveAccount() {
        let preferred = TokenAccount(
            email: "preferred@example.com",
            accountId: "acct_preferred",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 20,
            isActive: true
        )
        let exhaustedRoute = TokenAccount(
            email: "route@example.com",
            accountId: "acct_route",
            primaryUsedPercent: 100,
            primaryLimitWindowSeconds: 7 * 86_400
        )
        let provider = CodexBarProvider(id: "openai", kind: .openAIOAuth, label: "OpenAI")

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [preferred],
            activeProvider: provider,
            aggregateRoutedAccount: exhaustedRoute,
            usageDisplayMode: .used,
            accountUsageMode: .aggregateGateway,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.icon, .systemSymbol("exclamationmark.triangle.fill"))
    }

    func testAggregateHealthyRouteDoesNotInheritPreferredAccountWarning() {
        let exhaustedPreferred = TokenAccount(
            email: "preferred@example.com",
            accountId: "acct_preferred",
            primaryUsedPercent: 100,
            primaryLimitWindowSeconds: 7 * 86_400,
            isActive: true
        )
        let healthyRoute = TokenAccount(
            email: "route@example.com",
            accountId: "acct_route",
            planType: "plus",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 20
        )
        let provider = CodexBarProvider(id: "openai", kind: .openAIOAuth, label: "OpenAI")

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [exhaustedPreferred],
            activeProvider: provider,
            aggregateRoutedAccount: healthyRoute,
            usageDisplayMode: .used,
            accountUsageMode: .aggregateGateway,
            updateAvailable: false
        )

        XCTAssertEqual(
            presentation.icon,
            .usageBars(MenuBarUsageIconSpec(displayPercents: [10, 20]))
        )
    }

    func testUpdateAndQuotaWarningsKeepSystemSymbolPriority() {
        let healthy = TokenAccount(
            email: "healthy@example.com",
            accountId: "acct_healthy",
            planType: "plus",
            primaryUsedPercent: 20,
            secondaryUsedPercent: 30,
            isActive: true
        )
        let warning = TokenAccount(
            email: "warning@example.com",
            accountId: "acct_warning",
            planType: "plus",
            primaryUsedPercent: 85,
            secondaryUsedPercent: 30,
            isActive: true
        )

        let updatePresentation = MenuBarStatusItemPresentation.make(
            accounts: [healthy],
            activeProvider: nil,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: true
        )
        let warningPresentation = MenuBarStatusItemPresentation.make(
            accounts: [warning],
            activeProvider: nil,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )

        XCTAssertEqual(updatePresentation.icon, .systemSymbol("arrow.down.circle.fill"))
        XCTAssertEqual(warningPresentation.icon, .systemSymbol("bolt.circle.fill"))
        XCTAssertEqual(updatePresentation.layout, .compact)
        XCTAssertEqual(warningPresentation.layout, .compact)
    }

    func testFallbackProviderLabelIsOptionalWithUsageTextSetting() {
        let provider = CodexBarProvider(id: "compatible", kind: .openAICompatible, label: "ProviderLong")

        let compact = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )
        let withText = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false,
            showsUsageText: true
        )

        XCTAssertEqual(compact.icon, .systemSymbol("network"))
        XCTAssertEqual(compact.title, "")
        XCTAssertEqual(compact.accessibilityValue, "ProviderLong")
        XCTAssertEqual(withText.title, "Provid")
        XCTAssertEqual(withText.emphasis, .secondary)
    }

    func testStatusItemImageUsesTemplateRendering() {
        let presentation = MenuBarStatusItemPresentation(
            iconName: "terminal.fill",
            title: "67%·48%",
            emphasis: .primary
        )

        let image = presentation.makeTemplateImage(accessibilityDescription: "Codexbar")

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, true)
    }

    func testCompactAndTextLayoutsUseExpectedStatusItemSizing() {
        XCTAssertEqual(
            MenuBarStatusItemPresentation.Layout.compact.statusItemLength,
            NSStatusItem.squareLength
        )
        XCTAssertEqual(
            MenuBarStatusItemPresentation.Layout.iconAndText.statusItemLength,
            NSStatusItem.variableLength
        )
        XCTAssertEqual(MenuBarStatusItemPresentation.Layout.compact.imagePosition, .imageOnly)
        XCTAssertEqual(MenuBarStatusItemPresentation.Layout.iconAndText.imagePosition, .imageLeading)
    }

    func testAttributedTitleDoesNotPinForegroundColor() {
        let presentation = MenuBarStatusItemPresentation(
            iconName: "exclamationmark.triangle.fill",
            title: "每周额度",
            emphasis: .critical
        )

        let title = presentation.attributedTitle
        let attributes = title.attributes(at: 0, effectiveRange: nil)

        XCTAssertEqual(title.string, " 每周额度")
        XCTAssertNotNil(attributes[.font] as? NSFont)
        XCTAssertNil(attributes[.foregroundColor])
    }
}
