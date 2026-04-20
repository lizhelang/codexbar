import XCTest

final class MenuBarRefreshErrorResolverTests: XCTestCase {
    func testSilentRefreshSuccessClearsExistingRefreshError() {
        let current = MenuBarErrorBannerState(
            message: "Token 已过期",
            source: .refresh
        )

        let next = MenuBarRefreshErrorResolver.nextBanner(
            current: current,
            announceResult: false,
            refreshMessage: nil
        )

        XCTAssertNil(next)
    }

    func testSilentRefreshSuccessKeepsExistingGenericError() {
        let current = MenuBarErrorBannerState(
            message: "OpenAI login failed.",
            source: .generic
        )

        let next = MenuBarRefreshErrorResolver.nextBanner(
            current: current,
            announceResult: false,
            refreshMessage: nil
        )

        XCTAssertEqual(next, current)
    }

    func testAnnouncedRefreshFailureReplacesBannerWithRefreshError() {
        let current = MenuBarErrorBannerState(
            message: "OpenAI login failed.",
            source: .generic
        )

        let next = MenuBarRefreshErrorResolver.nextBanner(
            current: current,
            announceResult: true,
            refreshMessage: "alice@example.com: \(L.authRecoveryDeferredMsg)"
        )

        XCTAssertEqual(
            next,
            MenuBarErrorBannerState(
                message: "alice@example.com: \(L.authRecoveryDeferredMsg)",
                source: .refresh
            )
        )
    }
}
