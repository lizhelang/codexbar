import XCTest

@MainActor
final class CodexQuotaResumeAccountResolutionTests: CodexBarTestCase {
    func testManualModeResolvesLocalAccountIDFromMatchingDesktopIdentity() throws {
        let account = try self.makeOAuthAccount(accountID: "local-user", email: "same@example.test", remoteAccountID: "workspace")
        XCTAssertEqual(CodexQuotaResumeAccountResolution.resolve(mode: .switchAccount, isOpenAIProvider: true,
            activeAccount: account, authRemoteAccountID: "workspace", authAccessToken: account.accessToken), .resolved(accountID: "local-user"))
    }

    func testOnlyActualAggregateModeReportsAggregateMode() throws {
        let account = try self.makeOAuthAccount(accountID: "account", email: "fixture@example.test")
        let aggregate = CodexQuotaResumeAccountResolution.resolve(mode: .aggregateGateway, isOpenAIProvider: true,
            activeAccount: account, authRemoteAccountID: account.remoteAccountId, authAccessToken: account.accessToken)
        XCTAssertTrue(aggregate.failureReason?.contains("聚合网关") == true)
        for result in [
            CodexQuotaResumeAccountResolution.resolve(mode: .switchAccount, isOpenAIProvider: false, activeAccount: account, authRemoteAccountID: "account", authAccessToken: account.accessToken),
            .resolve(mode: .switchAccount, isOpenAIProvider: true, activeAccount: nil, authRemoteAccountID: "account", authAccessToken: account.accessToken),
            .resolve(mode: .switchAccount, isOpenAIProvider: true, activeAccount: account, authRemoteAccountID: nil, authAccessToken: account.accessToken),
            .resolve(mode: .switchAccount, isOpenAIProvider: true, activeAccount: account, authRemoteAccountID: "another", authAccessToken: account.accessToken),
        ] {
            XCTAssertNil(result.accountID)
            XCTAssertNotNil(result.failureReason)
            XCTAssertFalse(result.failureReason?.contains("聚合网关") == true)
        }
    }

    func testUnavailableAccountDoesNotBecomeSelectableAutomatically() throws {
        var account = try self.makeOAuthAccount(accountID: "account", email: "fixture@example.test")
        account.tokenExpired = true
        XCTAssertNil(CodexQuotaResumeAccountResolution.resolve(mode: .switchAccount, isOpenAIProvider: true,
            activeAccount: account, authRemoteAccountID: "account", authAccessToken: account.accessToken).accountID)
        account.tokenExpired = false
        account.isSuspended = true
        XCTAssertNil(CodexQuotaResumeAccountResolution.resolve(mode: .switchAccount, isOpenAIProvider: true,
            activeAccount: account, authRemoteAccountID: "account", authAccessToken: account.accessToken).accountID)
    }

    func testSameWorkspaceDifferentUserCannotBorrowSelectedAccountQuota() throws {
        let selected = try self.makeOAuthAccount(accountID: "selected", email: "same@example.test",
            remoteAccountID: "workspace", userID: "user-a")
        let desktop = try self.makeOAuthAccount(accountID: "desktop", email: "same@example.test",
            remoteAccountID: "workspace", userID: "user-b")
        let result = CodexQuotaResumeAccountResolution.resolve(mode: .switchAccount, isOpenAIProvider: true,
            activeAccount: selected, authRemoteAccountID: "workspace", authAccessToken: desktop.accessToken)
        XCTAssertNil(result.accountID)
    }

    func testMatchingUserAndWorkspaceWorkWithoutAccountUserClaim() throws {
        let selected = try self.makeOAuthAccount(accountID: "selected", email: "fixture@example.test",
            remoteAccountID: "workspace", userID: "user-a")
        let desktop = try self.makeOAuthAccount(accountID: "desktop", email: "fixture@example.test",
            remoteAccountID: "workspace", userID: "user-a", includeAccountUserID: false)
        XCTAssertEqual(CodexQuotaResumeAccountResolution.resolve(mode: .switchAccount, isOpenAIProvider: true,
            activeAccount: selected, authRemoteAccountID: "workspace", authAccessToken: desktop.accessToken),
            .resolved(accountID: selected.id))
    }

    func testWorkspaceOnlyOrUnreadableTokenCannotConfirmUserIdentity() throws {
        let selected = try self.makeOAuthAccount(accountID: "selected", email: "fixture@example.test",
            remoteAccountID: "workspace", userID: "user-a")
        let workspaceOnly = try self.makeJWT(payload: ["https://api.openai.com/auth": ["chatgpt_account_id": "workspace"]])
        for token in [nil, "malformed", workspaceOnly] as [String?] {
            XCTAssertNil(CodexQuotaResumeAccountResolution.resolve(mode: .switchAccount, isOpenAIProvider: true,
                activeAccount: selected, authRemoteAccountID: "workspace", authAccessToken: token).accountID)
        }
    }

    func testConflictingTokenWorkspaceOrUserClaimsAreRejected() throws {
        let selected = try self.makeOAuthAccount(accountID: "selected", email: "fixture@example.test",
            remoteAccountID: "workspace", userID: "user-a")
        let wrongWorkspace = try self.makeOAuthAccount(accountID: "selected", email: "fixture@example.test",
            remoteAccountID: "other-workspace", userID: "user-a")
        let wrongUser = try self.makeOAuthAccount(accountID: "selected", email: "fixture@example.test",
            remoteAccountID: "workspace", userID: "user-b")
        let wrongAccountUser = try self.makeOAuthAccount(accountID: "other-local", email: "fixture@example.test",
            remoteAccountID: "workspace", userID: "user-a")
        for desktop in [wrongWorkspace, wrongUser, wrongAccountUser] {
            XCTAssertNil(CodexQuotaResumeAccountResolution.resolve(mode: .switchAccount, isOpenAIProvider: true,
                activeAccount: selected, authRemoteAccountID: "workspace", authAccessToken: desktop.accessToken).accountID)
        }
    }
}
