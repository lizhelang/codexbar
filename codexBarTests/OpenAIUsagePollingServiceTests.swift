import Foundation
import XCTest

final class OpenAIUsagePollingServiceTests: XCTestCase {
    func testPolicyRefreshesStaleActiveOAuthAccount() {
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI"
        )
        let account = TokenAccount(
            email: "alice@example.com",
            accountId: "acct_openai_alice",
            lastChecked: Date(timeIntervalSince1970: 0)
        )

        let result = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: provider,
            activeAccount: account,
            now: Date(timeIntervalSince1970: 90),
            maxAge: 60,
            force: false
        )

        XCTAssertEqual(result?.accountId, account.accountId)
    }

    func testPolicySkipsFreshOAuthSnapshot() {
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI"
        )
        let account = TokenAccount(
            email: "alice@example.com",
            accountId: "acct_openai_alice",
            lastChecked: Date(timeIntervalSince1970: 40)
        )

        let result = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: provider,
            activeAccount: account,
            now: Date(timeIntervalSince1970: 90),
            maxAge: 60,
            force: false
        )

        XCTAssertNil(result)
    }

    func testPolicySkipsCompatibleProvider() {
        let provider = CodexBarProvider(
            id: "custom-openai",
            kind: .openAICompatible,
            label: "Custom"
        )
        let account = TokenAccount(
            email: "alice@example.com",
            accountId: "acct_openai_alice",
            lastChecked: Date(timeIntervalSince1970: 0)
        )

        let result = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: provider,
            activeAccount: account,
            now: Date(timeIntervalSince1970: 90),
            maxAge: 60,
            force: false
        )

        XCTAssertNil(result)
    }

    func testPolicySkipsExpiredAccount() {
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI"
        )
        let account = TokenAccount(
            email: "alice@example.com",
            accountId: "acct_openai_alice",
            lastChecked: Date(timeIntervalSince1970: 0),
            tokenExpired: true
        )

        let result = OpenAIUsagePollingPolicy.accountToRefresh(
            activeProvider: provider,
            activeAccount: account,
            now: Date(timeIntervalSince1970: 90),
            maxAge: 60,
            force: false
        )

        XCTAssertNil(result)
    }

    func testPolicyRefreshesAllAccountsWhenNeverFetched() {
        XCTAssertTrue(
            OpenAIUsagePollingPolicy.shouldRefreshAllAccounts(
                lastAllAccountsRefreshAt: nil,
                now: Date(timeIntervalSince1970: 90),
                interval: 300,
                force: false
            )
        )
    }

    func testPolicySkipsAllAccountsRefreshWhileIntervalIsFresh() {
        XCTAssertFalse(
            OpenAIUsagePollingPolicy.shouldRefreshAllAccounts(
                lastAllAccountsRefreshAt: Date(timeIntervalSince1970: 40),
                now: Date(timeIntervalSince1970: 90),
                interval: 300,
                force: false
            )
        )
        XCTAssertTrue(
            OpenAIUsagePollingPolicy.shouldRefreshAllAccounts(
                lastAllAccountsRefreshAt: Date(timeIntervalSince1970: 40),
                now: Date(timeIntervalSince1970: 90),
                interval: 300,
                force: true
            )
        )
    }
}
