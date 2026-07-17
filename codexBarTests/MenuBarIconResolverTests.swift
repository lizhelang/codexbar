import XCTest

final class MenuBarIconResolverTests: XCTestCase {
    func testCompatibleProviderUsesNetworkIconWhenOAuthWarningsExist() {
        let accounts = [
            TokenAccount(
                email: "alice@example.com",
                accountId: "acct_alice",
                secondaryUsedPercent: 100
            )
        ]

        let icon = MenuBarIconResolver.iconName(
            accounts: accounts,
            activeProviderKind: .openAICompatible
        )

        XCTAssertEqual(icon, "network")
    }

    func testActiveOAuthAccountKeepsUsageIconWhenQuotaIsExhausted() {
        let accounts = [
            TokenAccount(
                email: "alice@example.com",
                accountId: "acct_alice",
                secondaryUsedPercent: 100,
                isActive: true
            )
        ]

        let icon = MenuBarIconResolver.iconName(
            accounts: accounts,
            activeProviderKind: .openAIOAuth
        )

        XCTAssertEqual(icon, "terminal.fill")
    }

    func testVisualWarningThresholdDoesNotReplaceUsageIcon() {
        let warningAccounts = [
            TokenAccount(
                email: "alice@example.com",
                accountId: "acct_alice",
                primaryUsedPercent: 85,
                secondaryUsedPercent: 10,
                isActive: true
            )
        ]
        let healthyAccounts = [
            TokenAccount(
                email: "bob@example.com",
                accountId: "acct_bob",
                primaryUsedPercent: 75,
                secondaryUsedPercent: 10,
                isActive: true
            )
        ]

        let warning = MenuBarIconResolver.iconName(
            accounts: warningAccounts,
            activeProviderKind: .openAIOAuth
        )
        let healthy = MenuBarIconResolver.iconName(
            accounts: healthyAccounts,
            activeProviderKind: .openAIOAuth
        )

        XCTAssertEqual(warning, "terminal.fill")
        XCTAssertEqual(healthy, "terminal.fill")
    }

    func testUpdateAvailableOverridesNormalIcon() {
        let accounts = [
            TokenAccount(
                email: "alice@example.com",
                accountId: "acct_alice",
                primaryUsedPercent: 100,
                secondaryUsedPercent: 100,
                isActive: true
            )
        ]

        let icon = MenuBarIconResolver.iconName(
            accounts: accounts,
            activeProviderKind: .openAIOAuth,
            updateAvailable: true
        )

        XCTAssertEqual(icon, "arrow.down.circle.fill")
    }
}
