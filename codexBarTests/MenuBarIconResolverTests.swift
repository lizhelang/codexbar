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

    func testActiveOAuthAccountStillDrivesWarningIcon() {
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

        XCTAssertEqual(icon, "exclamationmark.triangle.fill")
    }
}
