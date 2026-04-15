import Foundation
import XCTest

final class CodexBarConfigStoreTests: CodexBarTestCase {
    func testLoadOrMigrateRemapsLegacyOAuthIDsToUserScopedIDs() throws {
        let store = CodexBarConfigStore()
        let journalStore = SwitchJournalStore(fileURL: CodexPaths.switchJournalURL)
        let remoteAccountID = "acct_team_shared"
        let localAccountID = "user-first__acct_team_shared"
        let account = try self.makeOAuthAccount(
            accountID: remoteAccountID,
            email: "first-team@example.com",
            planType: "team",
            localAccountID: localAccountID
        )

        let legacyStored = CodexBarProviderAccount(
            id: remoteAccountID,
            kind: .oauthTokens,
            label: "first-team@example.com",
            email: "first-team@example.com",
            openAIAccountId: remoteAccountID,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            addedAt: Date(timeIntervalSince1970: 42),
            planType: "team"
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            activeAccountId: remoteAccountID,
            accounts: [legacyStored]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: remoteAccountID),
            openAI: CodexBarOpenAISettings(accountOrder: [remoteAccountID]),
            providers: [provider]
        )
        try store.save(config)
        try journalStore.appendActivation(
            providerID: provider.id,
            accountID: remoteAccountID,
            previousAccountID: remoteAccountID,
            timestamp: Date(timeIntervalSince1970: 100)
        )

        let loaded = try store.loadOrMigrate()
        let migratedProvider = try XCTUnwrap(loaded.oauthProvider())
        let migratedAccount = try XCTUnwrap(migratedProvider.accounts.first)

        XCTAssertEqual(migratedAccount.id, localAccountID)
        XCTAssertEqual(migratedAccount.openAIAccountId, remoteAccountID)
        XCTAssertEqual(loaded.active.accountId, localAccountID)
        XCTAssertEqual(loaded.openAI.accountOrder, [localAccountID])

        let history = journalStore.activationHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.accountID, localAccountID)
        XCTAssertEqual(history.first?.previousAccountID, localAccountID)
    }

    func testLoadOrMigrateSanitizesHistoricalOverWindowResetAt() throws {
        let store = CodexBarConfigStore()
        let lastChecked = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = CodexBarProviderAccount(
            id: "acct_over_window",
            kind: .oauthTokens,
            label: "over-window@example.com",
            email: "over-window@example.com",
            openAIAccountId: "acct_over_window",
            accessToken: "token",
            refreshToken: "refresh",
            idToken: "id",
            addedAt: Date(timeIntervalSince1970: 42),
            planType: "plus",
            primaryUsedPercent: 80,
            secondaryUsedPercent: 0,
            primaryResetAt: lastChecked.addingTimeInterval(8 * 3_600),
            primaryLimitWindowSeconds: 18_000,
            lastChecked: lastChecked
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            activeAccountId: stored.id,
            accounts: [stored]
        )
        try store.save(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: stored.id),
                providers: [provider]
            )
        )

        let loaded = try store.loadOrMigrate()
        let account = try XCTUnwrap(loaded.oauthProvider()?.accounts.first)

        XCTAssertEqual(account.primaryResetAt, lastChecked.addingTimeInterval(5 * 3_600))
        XCTAssertEqual(account.primaryLimitWindowSeconds, 18_000)
    }

    func testLoadOrMigratePreservesOAuthLifecycleMetadataRoundtrip() throws {
        let store = CodexBarConfigStore()
        let tokenLastRefreshAt = Date(timeIntervalSince1970: 1_710_000_000)
        let expiresAt = Date(timeIntervalSince1970: 1_710_003_600)
        let account = try self.makeOAuthAccount(
            accountID: "acct_roundtrip",
            email: "roundtrip@example.com",
            accessTokenExpiresAt: expiresAt,
            oauthClientID: "app_roundtrip_client",
            tokenLastRefreshAt: tokenLastRefreshAt
        )
        let stored = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            activeAccountId: stored.id,
            accounts: [stored]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: stored.id),
                providers: [provider]
            )
        )

        let loaded = try store.loadOrMigrate()
        let reloadedStored = try XCTUnwrap(loaded.oauthProvider()?.accounts.first)
        let reloadedAccount = try XCTUnwrap(loaded.oauthTokenAccounts().first)

        XCTAssertEqual(reloadedStored.expiresAt, expiresAt)
        XCTAssertEqual(reloadedStored.oauthClientID, "app_roundtrip_client")
        XCTAssertEqual(reloadedStored.tokenLastRefreshAt, tokenLastRefreshAt)
        XCTAssertEqual(reloadedAccount.expiresAt, expiresAt)
        XCTAssertEqual(reloadedAccount.oauthClientID, "app_roundtrip_client")
        XCTAssertEqual(reloadedAccount.tokenLastRefreshAt, tokenLastRefreshAt)
    }

    func testLoadOrMigrateImportsOAuthLifecycleMetadataFromAuthJSON() throws {
        let store = CodexBarConfigStore()
        let tokenLastRefreshAt = Date(timeIntervalSince1970: 1_720_000_000)
        let expiresAt = Date(timeIntervalSince1970: 1_720_003_600)
        let account = try self.makeOAuthAccount(
            accountID: "acct_import_auth",
            email: "import-auth@example.com",
            accessTokenExpiresAt: expiresAt,
            oauthClientID: "app_import_client",
            tokenLastRefreshAt: tokenLastRefreshAt
        )
        try self.writeAuthJSON(
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            remoteAccountID: account.remoteAccountId,
            clientID: "app_import_client",
            lastRefresh: tokenLastRefreshAt
        )

        let loaded = try store.loadOrMigrate()
        let stored = try XCTUnwrap(loaded.oauthProvider()?.accounts.first)
        let restored = try XCTUnwrap(loaded.oauthTokenAccounts().first)

        XCTAssertEqual(stored.expiresAt, expiresAt)
        XCTAssertEqual(stored.oauthClientID, "app_import_client")
        XCTAssertEqual(stored.tokenLastRefreshAt, tokenLastRefreshAt)
        XCTAssertEqual(restored.expiresAt, expiresAt)
        XCTAssertEqual(restored.oauthClientID, "app_import_client")
        XCTAssertEqual(restored.tokenLastRefreshAt, tokenLastRefreshAt)
    }

    func testLoadOrMigrateAbsorbsNewerAuthJSONSnapshotForSameAccount() throws {
        let store = CodexBarConfigStore()
        let olderRefreshAt = Date(timeIntervalSince1970: 1_730_000_000)
        let newerRefreshAt = Date(timeIntervalSince1970: 1_730_000_600)
        let oldAccount = try self.makeOAuthAccount(
            accountID: "acct_reconcile",
            email: "reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_730_003_600),
            oauthClientID: "app_old_client",
            tokenLastRefreshAt: olderRefreshAt
        )
        let newAccount = try self.makeOAuthAccount(
            accountID: "acct_reconcile",
            email: "reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_730_007_200),
            oauthClientID: "app_new_client",
            tokenLastRefreshAt: newerRefreshAt
        )
        var stored = CodexBarProviderAccount.fromTokenAccount(oldAccount, existingID: oldAccount.accountId)
        stored.tokenExpired = true
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            activeAccountId: stored.id,
            accounts: [stored]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: stored.id),
                providers: [provider]
            )
        )
        try self.writeAuthJSON(
            accessToken: newAccount.accessToken,
            refreshToken: newAccount.refreshToken,
            idToken: newAccount.idToken,
            remoteAccountID: newAccount.remoteAccountId,
            clientID: "app_new_client",
            lastRefresh: newerRefreshAt
        )

        let loaded = try store.loadOrMigrate()
        let reconciled = try XCTUnwrap(loaded.oauthTokenAccounts().first)

        XCTAssertEqual(reconciled.accessToken, newAccount.accessToken)
        XCTAssertEqual(reconciled.refreshToken, newAccount.refreshToken)
        XCTAssertEqual(reconciled.idToken, newAccount.idToken)
        XCTAssertEqual(reconciled.oauthClientID, "app_new_client")
        XCTAssertEqual(reconciled.tokenLastRefreshAt, newerRefreshAt)
        XCTAssertFalse(reconciled.tokenExpired)
    }

    func testLoadOrMigrateKeepsLocalSnapshotWhenAuthJSONIsOlder() throws {
        let store = CodexBarConfigStore()
        let newerLocalRefreshAt = Date(timeIntervalSince1970: 1_740_000_600)
        let olderAuthRefreshAt = Date(timeIntervalSince1970: 1_740_000_000)
        let localAccount = try self.makeOAuthAccount(
            accountID: "acct_keep_local",
            email: "keep-local@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_740_007_200),
            oauthClientID: "app_local_client",
            tokenLastRefreshAt: newerLocalRefreshAt
        )
        let oldAuthAccount = try self.makeOAuthAccount(
            accountID: "acct_keep_local",
            email: "keep-local@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_740_003_600),
            oauthClientID: "app_old_client",
            tokenLastRefreshAt: olderAuthRefreshAt
        )
        let stored = CodexBarProviderAccount.fromTokenAccount(localAccount, existingID: localAccount.accountId)
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            activeAccountId: stored.id,
            accounts: [stored]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: stored.id),
                providers: [provider]
            )
        )
        try self.writeAuthJSON(
            accessToken: oldAuthAccount.accessToken,
            refreshToken: oldAuthAccount.refreshToken,
            idToken: oldAuthAccount.idToken,
            remoteAccountID: oldAuthAccount.remoteAccountId,
            clientID: "app_old_client",
            lastRefresh: olderAuthRefreshAt
        )

        let loaded = try store.loadOrMigrate()
        let resolved = try XCTUnwrap(loaded.oauthTokenAccounts().first)

        XCTAssertEqual(resolved.accessToken, localAccount.accessToken)
        XCTAssertEqual(resolved.oauthClientID, "app_local_client")
        XCTAssertEqual(resolved.tokenLastRefreshAt, newerLocalRefreshAt)
    }

    func testLoadOrMigrateDoesNotAbsorbDifferentAccountThatOnlyMatchesEmail() throws {
        let store = CodexBarConfigStore()
        let localAccount = try self.makeOAuthAccount(
            accountID: "acct_local_only",
            email: "same-email@example.com",
            remoteAccountID: "acct_local_remote",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_750_003_600),
            oauthClientID: "app_local_only",
            tokenLastRefreshAt: Date(timeIntervalSince1970: 1_750_000_600)
        )
        let otherAccount = try self.makeOAuthAccount(
            accountID: "acct_other_only",
            email: "same-email@example.com",
            remoteAccountID: "acct_other_remote",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_750_007_200),
            oauthClientID: "app_other_only",
            tokenLastRefreshAt: Date(timeIntervalSince1970: 1_750_001_200)
        )
        let stored = CodexBarProviderAccount.fromTokenAccount(localAccount, existingID: localAccount.accountId)
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            activeAccountId: stored.id,
            accounts: [stored]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: stored.id),
                providers: [provider]
            )
        )
        try self.writeAuthJSON(
            accessToken: otherAccount.accessToken,
            refreshToken: otherAccount.refreshToken,
            idToken: otherAccount.idToken,
            remoteAccountID: otherAccount.remoteAccountId,
            clientID: "app_other_only",
            lastRefresh: Date(timeIntervalSince1970: 1_750_001_200)
        )

        let loaded = try store.loadOrMigrate()
        let resolved = try XCTUnwrap(loaded.oauthTokenAccounts().first)

        XCTAssertEqual(resolved.accountId, localAccount.accountId)
        XCTAssertEqual(resolved.remoteAccountId, localAccount.remoteAccountId)
        XCTAssertEqual(resolved.accessToken, localAccount.accessToken)
        XCTAssertEqual(resolved.oauthClientID, "app_local_only")
    }

    func testUpsertOAuthAccountPropagatesSharedTeamOrganizationNameToSibling() throws {
        let sharedRemoteAccountID = "acct_team_shared"
        let first = try self.makeStoredOAuthAccount(
            localAccountID: "user-first__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID,
            email: "first-team@example.com",
            planType: "team",
            organizationName: "Acme Team"
        )
        let second = try self.makeOAuthAccount(
            accountID: sharedRemoteAccountID,
            email: "second-team@example.com",
            planType: "team",
            localAccountID: "user-second__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID
        )
        var config = self.makeOAuthConfig(accounts: [first], activeAccountID: first.id)

        let result = config.upsertOAuthAccount(second, activate: false)
        let accounts = try XCTUnwrap(config.oauthProvider()?.accounts)

        XCTAssertEqual(self.organizationName(for: first.id, in: accounts), "Acme Team")
        XCTAssertEqual(self.organizationName(for: second.accountId, in: accounts), "Acme Team")
        XCTAssertEqual(result.storedAccount.organizationName, "Acme Team")
    }

    func testUpsertOAuthAccountTrimsSharedTeamOrganizationNameBeforePropagation() throws {
        let sharedRemoteAccountID = "acct_team_trim"
        let first = try self.makeStoredOAuthAccount(
            localAccountID: "user-first__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID,
            email: "first-trim@example.com",
            planType: "team",
            organizationName: "  Acme Team  "
        )
        let second = try self.makeOAuthAccount(
            accountID: sharedRemoteAccountID,
            email: "second-trim@example.com",
            planType: "team",
            localAccountID: "user-second__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID
        )
        var config = self.makeOAuthConfig(accounts: [first], activeAccountID: first.id)

        let result = config.upsertOAuthAccount(second, activate: false)
        let accounts = try XCTUnwrap(config.oauthProvider()?.accounts)

        XCTAssertEqual(self.organizationName(for: first.id, in: accounts), "Acme Team")
        XCTAssertEqual(self.organizationName(for: second.accountId, in: accounts), "Acme Team")
        XCTAssertEqual(result.storedAccount.organizationName, "Acme Team")
    }

    func testLoadOrMigrateNormalizesHistoricalSharedTeamOrganizationName() throws {
        let store = CodexBarConfigStore()
        let sharedRemoteAccountID = "acct_team_load"
        let first = try self.makeStoredOAuthAccount(
            localAccountID: "user-first__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID,
            email: "first-load@example.com",
            planType: "team",
            organizationName: "Acme Team"
        )
        let second = try self.makeStoredOAuthAccount(
            localAccountID: "user-second__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID,
            email: "second-load@example.com",
            planType: "team",
            organizationName: nil
        )
        try self.writeConfig(self.makeOAuthConfig(accounts: [first, second], activeAccountID: first.id))

        let loaded = try store.loadOrMigrate()
        let accounts = try XCTUnwrap(loaded.oauthProvider()?.accounts)

        XCTAssertEqual(self.organizationName(for: first.id, in: accounts), "Acme Team")
        XCTAssertEqual(self.organizationName(for: second.id, in: accounts), "Acme Team")
    }

    func testLoadOrMigrateKeepsExistingConsumersSimpleForSharedTeamOrganizationName() throws {
        let store = CodexBarConfigStore()
        let sharedRemoteAccountID = "acct_team_consumer"
        let first = try self.makeStoredOAuthAccount(
            localAccountID: "user-first__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID,
            email: "first-consumer@example.com",
            planType: "team",
            organizationName: "Acme Team"
        )
        let second = try self.makeStoredOAuthAccount(
            localAccountID: "user-second__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID,
            email: "second-consumer@example.com",
            planType: "team",
            organizationName: nil
        )
        try self.writeConfig(self.makeOAuthConfig(accounts: [first, second], activeAccountID: first.id))

        let loaded = try store.loadOrMigrate()
        let tokenAccount = try XCTUnwrap(
            loaded.oauthTokenAccounts().first(where: { $0.accountId == second.id })
        )

        XCTAssertEqual(
            OpenAIAccountPresentation.planBadgeTitle(for: tokenAccount, isHovered: true),
            "Acme Team"
        )
    }

    func testUpsertOAuthAccountLeavesConflictingSharedTeamOrganizationNamesUnchanged() throws {
        let sharedRemoteAccountID = "acct_team_conflict"
        let first = try self.makeStoredOAuthAccount(
            localAccountID: "user-first__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID,
            email: "first-conflict@example.com",
            planType: "team",
            organizationName: "Acme Team"
        )
        let second = try self.makeStoredOAuthAccount(
            localAccountID: "user-second__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID,
            email: "second-conflict@example.com",
            planType: "team",
            organizationName: "Other Team"
        )
        let third = try self.makeOAuthAccount(
            accountID: sharedRemoteAccountID,
            email: "third-conflict@example.com",
            planType: "team",
            localAccountID: "user-third__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID
        )
        var config = self.makeOAuthConfig(accounts: [first, second], activeAccountID: first.id)

        let result = config.upsertOAuthAccount(third, activate: false)
        let accounts = try XCTUnwrap(config.oauthProvider()?.accounts)

        XCTAssertEqual(self.organizationName(for: first.id, in: accounts), "Acme Team")
        XCTAssertEqual(self.organizationName(for: second.id, in: accounts), "Other Team")
        XCTAssertNil(self.organizationName(for: third.accountId, in: accounts))
        XCTAssertNil(result.storedAccount.organizationName)
    }

    func testUpsertOAuthAccountDoesNotPropagateSharedOrganizationNameForNonTeamSibling() throws {
        let sharedRemoteAccountID = "acct_plus_shared"
        let first = try self.makeStoredOAuthAccount(
            localAccountID: "user-first__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID,
            email: "first-plus@example.com",
            planType: "plus",
            organizationName: "Acme Team"
        )
        let second = try self.makeOAuthAccount(
            accountID: sharedRemoteAccountID,
            email: "second-plus@example.com",
            planType: "plus",
            localAccountID: "user-second__\(sharedRemoteAccountID)",
            remoteAccountID: sharedRemoteAccountID
        )
        var config = self.makeOAuthConfig(accounts: [first], activeAccountID: first.id)

        let result = config.upsertOAuthAccount(second, activate: false)
        let accounts = try XCTUnwrap(config.oauthProvider()?.accounts)

        XCTAssertEqual(self.organizationName(for: first.id, in: accounts), "Acme Team")
        XCTAssertNil(self.organizationName(for: second.accountId, in: accounts))
        XCTAssertNil(result.storedAccount.organizationName)
    }

    private func makeStoredOAuthAccount(
        localAccountID: String,
        remoteAccountID: String,
        email: String,
        planType: String,
        organizationName: String?
    ) throws -> CodexBarProviderAccount {
        var account = try self.makeOAuthAccount(
            accountID: remoteAccountID,
            email: email,
            planType: planType,
            localAccountID: localAccountID,
            remoteAccountID: remoteAccountID
        )
        account.organizationName = organizationName
        return CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
    }

    private func makeOAuthConfig(
        accounts: [CodexBarProviderAccount],
        activeAccountID: String?
    ) -> CodexBarConfig {
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            activeAccountId: activeAccountID ?? accounts.first?.id,
            accounts: accounts
        )
        return CodexBarConfig(
            active: CodexBarActiveSelection(
                providerId: provider.id,
                accountId: activeAccountID ?? accounts.first?.id
            ),
            openAI: CodexBarOpenAISettings(accountOrder: accounts.map(\.id)),
            providers: [provider]
        )
    }

    private func organizationName(
        for accountID: String,
        in accounts: [CodexBarProviderAccount]
    ) -> String? {
        accounts.first(where: { $0.id == accountID })?.organizationName
    }
}
