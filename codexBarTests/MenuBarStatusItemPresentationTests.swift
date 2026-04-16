import XCTest

final class MenuBarStatusItemPresentationTests: XCTestCase {
    func testActiveAccountUsesUsageSummary() {
        let account = TokenAccount(
            email: "active@example.com",
            accountId: "acct_active",
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

        XCTAssertEqual(presentation.iconName, "terminal.fill")
        XCTAssertEqual(presentation.title, "67%·48%")
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testAggregateModeUsesAggregateRoutedAccountSummary() {
        let aggregate = TokenAccount(
            email: "agg@example.com",
            accountId: "acct_agg",
            primaryUsedPercent: 42,
            secondaryUsedPercent: 80
        )
        let provider = CodexBarProvider(id: "openai", kind: .openAIOAuth, label: "OpenAI")

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: aggregate,
            usageDisplayMode: .used,
            accountUsageMode: .aggregateGateway,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.title, L.openAIRouteSummaryCompact("42%"))
        XCTAssertEqual(presentation.emphasis, .primary)
    }

    func testFallbackProviderLabelIsTrimmed() {
        let provider = CodexBarProvider(id: "compatible", kind: .openAICompatible, label: "ProviderLong")

        let presentation = MenuBarStatusItemPresentation.make(
            accounts: [],
            activeProvider: provider,
            aggregateRoutedAccount: nil,
            usageDisplayMode: .used,
            accountUsageMode: .switchAccount,
            updateAvailable: false
        )

        XCTAssertEqual(presentation.iconName, "network")
        XCTAssertEqual(presentation.title, "Provid")
        XCTAssertEqual(presentation.emphasis, .secondary)
    }
}
