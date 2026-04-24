import Foundation
import XCTest

final class CodexBarConfigStoreTests: CodexBarTestCase {
    func testLoadOrMigrateUpgradesV118ConfigWithoutLosingOAuthAccounts() throws {
        let store = CodexBarConfigStore()
        let first = try self.makeOAuthAccount(
            accountID: "acct_upgrade_first",
            email: "upgrade-first@example.com",
            planType: "plus",
            localAccountID: "user-first__acct_upgrade_first",
            remoteAccountID: "acct_upgrade_first"
        )
        let second = try self.makeOAuthAccount(
            accountID: "acct_upgrade_second",
            email: "upgrade-second@example.com",
            planType: "team",
            localAccountID: "user-second__acct_upgrade_second",
            remoteAccountID: "acct_upgrade_second"
        )
        let legacyConfig = LegacyV118Config(
            global: LegacyV118GlobalSettings(
                defaultModel: "anthropic/claude-3.7-sonnet",
                reviewModel: "gpt-5.4",
                reasoningEffort: "high"
            ),
            active: LegacyV118ActiveSelection(
                providerId: "openai-oauth",
                accountId: first.accountId
            ),
            openAI: LegacyV118OpenAISettings(
                accountOrder: [second.accountId, first.accountId],
                accountUsageMode: .switchAccount,
                switchModeSelection: LegacyV118ActiveSelection(
                    providerId: "openai-oauth",
                    accountId: second.accountId
                ),
                accountOrderingMode: .manual,
                manualActivationBehavior: .launchNewInstance,
                usageDisplayMode: .used,
                quotaSort: LegacyV118QuotaSortSettings(
                    plusRelativeWeight: 6,
                    teamRelativeToPlusMultiplier: 2
                )
            ),
            providers: [
                LegacyV118Provider(
                    id: "openai-oauth",
                    kind: .openAIOAuth,
                    label: "OpenAI",
                    enabled: true,
                    activeAccountId: first.accountId,
                    accounts: [
                        LegacyV118ProviderAccount.fromTokenAccount(first),
                        LegacyV118ProviderAccount.fromTokenAccount(second),
                    ]
                ),
                LegacyV118Provider(
                    id: "legacy-openrouter",
                    kind: .openAICompatible,
                    label: "Legacy OpenRouter",
                    enabled: true,
                    baseURL: "https://openrouter.ai/api/v1",
                    activeAccountId: "acct-openrouter-legacy",
                    accounts: [
                        LegacyV118ProviderAccount(
                            id: "acct-openrouter-legacy",
                            kind: .apiKey,
                            label: "Primary",
                            apiKey: "sk-or-v1-primary"
                        )
                    ]
                ),
            ]
        )
        try self.writeLegacyV118Config(legacyConfig)

        let loaded = try store.loadOrMigrate()
        let oauthProvider = try XCTUnwrap(loaded.oauthProvider())
        let oauthAccounts = loaded.oauthTokenAccounts()
        let openRouterProvider = try XCTUnwrap(loaded.openRouterProvider())

        XCTAssertEqual(oauthProvider.accounts.count, 2)
        XCTAssertEqual(Set(oauthAccounts.map(\.accountId)), Set([first.accountId, second.accountId]))
        XCTAssertEqual(Set(oauthAccounts.map(\.remoteAccountId)), Set([first.remoteAccountId, second.remoteAccountId]))
        XCTAssertEqual(loaded.active.providerId, "openai-oauth")
        XCTAssertEqual(loaded.active.accountId, first.accountId)
        XCTAssertEqual(loaded.openAI.accountOrder, [second.accountId, first.accountId])
        XCTAssertEqual(loaded.openAI.accountOrderingMode, .manual)
        XCTAssertEqual(loaded.openAI.manualActivationBehavior, .launchNewInstance)
        XCTAssertEqual(loaded.openAI.switchModeSelection?.accountId, second.accountId)
        XCTAssertEqual(loaded.openAI.quotaSort.plusRelativeWeight, 6)
        XCTAssertEqual(loaded.openAI.quotaSort.teamRelativeToPlusMultiplier, 2)
        XCTAssertEqual(loaded.openAI.quotaSort.proRelativeToPlusMultiplier, 10)
        XCTAssertEqual(openRouterProvider.id, "openrouter")
        XCTAssertEqual(openRouterProvider.accounts.count, 1)
        XCTAssertEqual(openRouterProvider.selectedModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(openRouterProvider.pinnedModelIDs, ["anthropic/claude-3.7-sonnet"])
        XCTAssertNil(openRouterProvider.defaultModel)
    }

    func testLoadOrMigrateReadsLegacyTomlThroughRustParser() throws {
        let store = CodexBarConfigStore()
        let legacyToml = """
        model = "gpt-5.4"
        review_model = "gpt-5.4-mini"
        model_reasoning_effort = "high"
        [model_providers.OpenAI]
        name = "OpenAI"
        base_url = "https://gateway.example.com/v1"
        """
        try CodexPaths.writeSecureFile(Data(legacyToml.utf8), to: CodexPaths.configTomlURL)
        let authJSON: [String: Any] = [
            "auth_mode": "apikey",
            "OPENAI_API_KEY": "sk-legacy",
        ]
        let authData = try JSONSerialization.data(withJSONObject: authJSON, options: [.prettyPrinted, .sortedKeys])
        try CodexPaths.writeSecureFile(authData, to: CodexPaths.authURL)

        let loaded = try store.loadOrMigrate()
        let provider = try XCTUnwrap(
            loaded.providers.first { $0.baseURL == "https://gateway.example.com/v1" }
        )

        XCTAssertEqual(loaded.global.defaultModel, "gpt-5.4")
        XCTAssertEqual(loaded.global.reviewModel, "gpt-5.4-mini")
        XCTAssertEqual(loaded.global.reasoningEffort, "high")
        XCTAssertEqual(provider.kind, .openAICompatible)
        XCTAssertEqual(provider.accounts.first?.apiKey, "sk-legacy")
        XCTAssertEqual(loaded.active.providerId, provider.id)
    }

    func testLoadOrMigratePromotesLegacyOpenRouterCompatibleProvider() throws {
        let store = CodexBarConfigStore()
        let account = CodexBarProviderAccount(
            id: "acct-openrouter-legacy",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-primary"
        )
        let provider = CodexBarProvider(
            id: "legacy-openrouter",
            kind: .openAICompatible,
            label: "Legacy OpenRouter",
            enabled: true,
            baseURL: "https://openrouter.ai/api/v1",
            activeAccountId: account.id,
            accounts: [account]
        )
        try self.writeConfig(
            CodexBarConfig(
                global: CodexBarGlobalSettings(
                    defaultModel: "anthropic/claude-3.7-sonnet",
                    reviewModel: "gpt-5.4",
                    reasoningEffort: "high"
                ),
                active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
                providers: [provider]
            )
        )

        let loaded = try store.loadOrMigrate()

        let openRouterProvider = try XCTUnwrap(loaded.openRouterProvider())
        XCTAssertEqual(openRouterProvider.id, "openrouter")
        XCTAssertEqual(openRouterProvider.accounts.count, 1)
        XCTAssertEqual(openRouterProvider.accounts.first?.apiKey, "sk-or-v1-primary")
        XCTAssertEqual(openRouterProvider.selectedModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(openRouterProvider.pinnedModelIDs, ["anthropic/claude-3.7-sonnet"])
        XCTAssertNil(openRouterProvider.defaultModel)
        XCTAssertEqual(loaded.active.providerId, "openrouter")
        XCTAssertEqual(loaded.active.accountId, account.id)
        XCTAssertTrue(loaded.providers.contains(where: { $0.kind == .openAICompatible }) == false)
    }

    func testLoadOrMigrateInfersOpenRouterDefaultModelFromLegacyModelPageURL() throws {
        let store = CodexBarConfigStore()
        let account = CodexBarProviderAccount(
            id: "acct-openrouter-page",
            kind: .apiKey,
            label: "Elephant",
            apiKey: "sk-or-v1-elephant"
        )
        let provider = CodexBarProvider(
            id: "legacy-openrouter-page",
            kind: .openAICompatible,
            label: "Elephant Alpha",
            enabled: true,
            baseURL: "https://openrouter.ai/openrouter/elephant-alpha/api",
            activeAccountId: account.id,
            accounts: [account]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
                providers: [provider]
            )
        )

        let loaded = try store.loadOrMigrate()

        XCTAssertEqual(loaded.openRouterProvider()?.selectedModelID, "openrouter/elephant-alpha")
        XCTAssertNil(loaded.openRouterProvider()?.defaultModel)
    }

    func testLoadOrMigrateRecoversRecentExplicitOpenRouterModelWhenLegacyProviderHasNoModel() throws {
        let store = CodexBarConfigStore(
            recentOpenRouterModelResolver: { "openrouter/elephant-alpha" }
        )
        let account = CodexBarProviderAccount(
            id: "acct-openrouter-recent",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-primary"
        )
        let provider = CodexBarProvider(
            id: "legacy-openrouter-empty",
            kind: .openAICompatible,
            label: "OpenRouter",
            enabled: true,
            baseURL: "https://openrouter.ai/api/v1",
            activeAccountId: account.id,
            accounts: [account]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
                providers: [provider]
            )
        )

        let loaded = try store.loadOrMigrate()
        let openRouterProvider = try XCTUnwrap(loaded.openRouterProvider())

        XCTAssertEqual(openRouterProvider.selectedModelID, "openrouter/elephant-alpha")
        XCTAssertEqual(openRouterProvider.pinnedModelIDs, ["openrouter/elephant-alpha"])
        XCTAssertNil(openRouterProvider.defaultModel)
        XCTAssertEqual(loaded.active.providerId, "openrouter")
        XCTAssertEqual(loaded.active.accountId, account.id)
    }

    func testLoadOrMigrateSkipsUnknownProviderKindWithoutLosingOAuthAccounts() throws {
        let store = CodexBarConfigStore()
        let account = try self.makeOAuthAccount(
            accountID: "acct_skip_unknown",
            email: "skip-unknown@example.com",
            localAccountID: "user-skip__acct_skip_unknown",
            remoteAccountID: "acct_skip_unknown"
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            activeAccountId: account.accountId,
            accounts: [CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: account.accountId),
            providers: [oauthProvider]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(config)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        providers.append([
            "id": "future-provider",
            "kind": "future_provider",
            "label": "Future Provider",
            "enabled": true,
            "accounts": [],
        ])
        object["providers"] = providers
        let mutated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try CodexPaths.writeSecureFile(mutated, to: CodexPaths.barConfigURL)

        let loaded = try store.loadOrMigrate()

        XCTAssertEqual(loaded.oauthTokenAccounts().count, 1)
        XCTAssertEqual(loaded.oauthTokenAccounts().first?.accountId, account.accountId)
        XCTAssertNil(loaded.providers.first(where: { $0.id == "future-provider" }))
    }

    func testSavePersistsOpenRouterProviderInLegacyCompatibleShape() throws {
        let store = CodexBarConfigStore()
        let account = CodexBarProviderAccount(
            id: "acct-openrouter-save",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-primary"
        )
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            baseURL: nil,
            selectedModelID: "anthropic/claude-3.7-sonnet",
            pinnedModelIDs: [
                "anthropic/claude-3.7-sonnet",
                "openai/gpt-4.1",
            ],
            cachedModelCatalog: [
                CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
                CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            ],
            modelCatalogFetchedAt: Date(timeIntervalSince1970: 1_710_000_000),
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )

        try store.save(config)

        let persistedData = try Data(contentsOf: CodexPaths.barConfigURL)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
        let providers = try XCTUnwrap(persisted["providers"] as? [[String: Any]])
        let savedProvider = try XCTUnwrap(providers.first)
        let savedActive = try XCTUnwrap(persisted["active"] as? [String: Any])

        XCTAssertEqual(savedProvider["id"] as? String, "openrouter-compat")
        XCTAssertEqual(savedProvider["kind"] as? String, "openai_compatible")
        XCTAssertEqual(savedProvider["baseURL"] as? String, "https://openrouter.ai/api/v1")
        XCTAssertEqual(savedProvider["selectedModelID"] as? String, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(savedProvider["defaultModel"] as? String, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(savedProvider["pinnedModelIDs"] as? [String], ["anthropic/claude-3.7-sonnet", "openai/gpt-4.1"])
        let savedCatalog = try XCTUnwrap(savedProvider["cachedModelCatalog"] as? [[String: Any]])
        XCTAssertEqual(savedCatalog.count, 2)
        XCTAssertEqual(savedActive["providerId"] as? String, "openrouter-compat")

        let loaded = try store.loadOrMigrate()
        let openRouterProvider = try XCTUnwrap(loaded.openRouterProvider())
        XCTAssertEqual(openRouterProvider.id, "openrouter")
        XCTAssertEqual(openRouterProvider.kind, .openRouter)
        XCTAssertEqual(openRouterProvider.selectedModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(openRouterProvider.pinnedModelIDs, ["anthropic/claude-3.7-sonnet", "openai/gpt-4.1"])
        XCTAssertNil(openRouterProvider.defaultModel)
        XCTAssertEqual(openRouterProvider.cachedModelCatalog.count, 2)
        XCTAssertEqual(loaded.active.providerId, "openrouter")
        XCTAssertEqual(loaded.active.accountId, account.id)
    }

    func testLoadOrMigrateRestoresOpenRouterSwitchModeSelectionFromCompatPersistence() throws {
        let store = CodexBarConfigStore()
        let openRouterAccount = CodexBarProviderAccount(
            id: "acct-openrouter-switch",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-primary"
        )
        let customAccount = CodexBarProviderAccount(
            id: "acct-compatible-switch",
            kind: .apiKey,
            label: "Compatible",
            apiKey: "sk-compatible"
        )
        let openRouterProvider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            selectedModelID: "anthropic/claude-3.7-sonnet",
            activeAccountId: openRouterAccount.id,
            accounts: [openRouterAccount]
        )
        let customProvider = CodexBarProvider(
            id: "compatible-provider",
            kind: .openAICompatible,
            label: "Compatible",
            enabled: true,
            baseURL: "https://example.invalid/v1",
            activeAccountId: customAccount.id,
            accounts: [customAccount]
        )
        try store.save(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: customProvider.id, accountId: customAccount.id),
                openAI: CodexBarOpenAISettings(
                    accountUsageMode: .switchAccount,
                    switchModeSelection: CodexBarActiveSelection(
                        providerId: openRouterProvider.id,
                        accountId: openRouterAccount.id
                    )
                ),
                providers: [openRouterProvider, customProvider]
            )
        )

        let loaded = try store.loadOrMigrate()

        XCTAssertEqual(loaded.openAI.switchModeSelection?.providerId, "openrouter")
        XCTAssertEqual(loaded.openAI.switchModeSelection?.accountId, openRouterAccount.id)
        XCTAssertEqual(loaded.active.providerId, customProvider.id)
        XCTAssertEqual(loaded.active.accountId, customAccount.id)
    }

    func testLoadOrMigrateDefaultsUnknownOpenAISettingsEnumValuesWithoutLosingOAuthAccounts() throws {
        let store = CodexBarConfigStore()
        let account = try self.makeOAuthAccount(
            accountID: "acct_unknown_settings",
            email: "unknown-settings@example.com",
            localAccountID: "user-unknown__acct_unknown_settings",
            remoteAccountID: "acct_unknown_settings"
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            activeAccountId: account.accountId,
            accounts: [CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: account.accountId),
            openAI: CodexBarOpenAISettings(
                accountOrder: [account.accountId],
                accountUsageMode: .switchAccount,
                switchModeSelection: CodexBarActiveSelection(providerId: oauthProvider.id, accountId: account.accountId),
                accountOrderingMode: .manual,
                manualActivationBehavior: .launchNewInstance,
                usageDisplayMode: .remaining
            ),
            providers: [oauthProvider]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(config)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var openAI = try XCTUnwrap(object["openAI"] as? [String: Any])
        openAI["accountUsageMode"] = "future_mode"
        openAI["accountOrderingMode"] = "future_ordering"
        openAI["manualActivationBehavior"] = "future_activation_behavior"
        openAI["usageDisplayMode"] = "future_usage_display"
        object["openAI"] = openAI
        let mutated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try CodexPaths.writeSecureFile(mutated, to: CodexPaths.barConfigURL)

        let loaded = try store.loadOrMigrate()

        XCTAssertEqual(loaded.oauthTokenAccounts().count, 1)
        XCTAssertEqual(loaded.oauthTokenAccounts().first?.accountId, account.accountId)
        XCTAssertEqual(loaded.openAI.accountUsageMode, .switchAccount)
        XCTAssertEqual(loaded.openAI.accountOrderingMode, .quotaSort)
        XCTAssertEqual(loaded.openAI.manualActivationBehavior, .updateConfigOnly)
        XCTAssertEqual(loaded.openAI.usageDisplayMode, .used)
    }

    func testLoadOrMigrateRemapsNonOpenRouterProviderUsingReservedOpenRouterID() throws {
        let store = CodexBarConfigStore()
        let account = CodexBarProviderAccount(
            id: "acct-custom-openrouter",
            kind: .apiKey,
            label: "Custom OpenRouter",
            apiKey: "sk-custom"
        )
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openAICompatible,
            label: "OpenRouter",
            enabled: true,
            baseURL: "https://relay.example.com/v1",
            activeAccountId: account.id,
            accounts: [account]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
                providers: [provider]
            )
        )

        let loaded = try store.loadOrMigrate()
        let customProvider = try XCTUnwrap(loaded.providers.first(where: { $0.kind == .openAICompatible }))

        XCTAssertEqual(customProvider.id, "openrouter-custom")
        XCTAssertEqual(loaded.active.providerId, "openrouter-custom")
        XCTAssertNil(loaded.openRouterProvider())
    }

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
            planType: "team",
            localAccountID: "user-import__acct_import_auth",
            remoteAccountID: "acct_import_auth",
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

        XCTAssertEqual(stored.id, "user-import__acct_import_auth")
        XCTAssertEqual(stored.openAIAccountId, "acct_import_auth")
        XCTAssertEqual(stored.email, "import-auth@example.com")
        XCTAssertEqual(stored.planType, "team")
        XCTAssertEqual(stored.expiresAt, expiresAt)
        XCTAssertEqual(stored.oauthClientID, "app_import_client")
        XCTAssertEqual(stored.tokenLastRefreshAt, tokenLastRefreshAt)
        XCTAssertEqual(restored.accountId, "user-import__acct_import_auth")
        XCTAssertEqual(restored.remoteAccountId, "acct_import_auth")
        XCTAssertEqual(restored.email, "import-auth@example.com")
        XCTAssertEqual(restored.planType, "team")
        XCTAssertEqual(restored.expiresAt, expiresAt)
        XCTAssertEqual(restored.oauthClientID, "app_import_client")
        XCTAssertEqual(restored.tokenLastRefreshAt, tokenLastRefreshAt)
    }

    func testLoadOrMigrateRefreshesStoredOAuthMetadataFromTokensWhenMissing() throws {
        let store = CodexBarConfigStore()
        let tokenLastRefreshAt = Date(timeIntervalSince1970: 1_710_000_000)
        let expiresAt = Date(timeIntervalSince1970: 1_767_168_000)
        let account = try self.makeOAuthAccount(
            accountID: "acct_metadata",
            email: "metadata@example.com",
            accessTokenExpiresAt: expiresAt,
            oauthClientID: "app_roundtrip_client",
            tokenLastRefreshAt: tokenLastRefreshAt
        )
        let stored = CodexBarProviderAccount(
            id: account.accountId,
            kind: .oauthTokens,
            label: "metadata@example.com",
            email: nil,
            openAIAccountId: nil,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            expiresAt: nil,
            oauthClientID: nil,
            tokenLastRefreshAt: nil,
            lastRefresh: tokenLastRefreshAt,
            addedAt: Date(timeIntervalSince1970: 42),
            planType: account.planType,
            interopProxyKey: "http|127.0.0.1|7890||",
            interopNotes: "imported",
            interopConcurrency: 10,
            interopAutoPauseOnExpired: true,
            interopCredentialsJSON: #"{"client_id":"app_roundtrip_client"}"#,
            interopExtraJSON: #"{"privacy_mode":"training_off"}"#
        )
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
        let refreshed = try XCTUnwrap(loaded.oauthProvider()?.accounts.first)

        XCTAssertEqual(refreshed.email, "metadata@example.com")
        XCTAssertEqual(refreshed.openAIAccountId, "acct_metadata")
        XCTAssertEqual(refreshed.oauthClientID, "app_roundtrip_client")
        XCTAssertEqual(refreshed.expiresAt, expiresAt)
        XCTAssertEqual(refreshed.tokenLastRefreshAt, tokenLastRefreshAt)
        XCTAssertEqual(refreshed.interopProxyKey, "http|127.0.0.1|7890||")
        XCTAssertEqual(refreshed.interopNotes, "imported")
        XCTAssertEqual(refreshed.interopConcurrency, 10)
        XCTAssertEqual(refreshed.interopAutoPauseOnExpired, true)
        XCTAssertEqual(refreshed.interopCredentialsJSON, #"{"client_id":"app_roundtrip_client"}"#)
        XCTAssertEqual(refreshed.interopExtraJSON, #"{"privacy_mode":"training_off"}"#)
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

    private func writeLegacyV118Config(_ config: LegacyV118Config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try CodexPaths.writeSecureFile(data, to: CodexPaths.barConfigURL)
    }
}

private enum LegacyV118ProviderKind: String, Codable {
    case openAIOAuth = "openai_oauth"
    case openAICompatible = "openai_compatible"
}

private enum LegacyV118UsageDisplayMode: String, Codable {
    case remaining
    case used
}

private enum LegacyV118AccountKind: String, Codable {
    case oauthTokens = "oauth_tokens"
    case apiKey = "api_key"
}

private enum LegacyV118ManualActivationBehavior: String, Codable {
    case updateConfigOnly
    case launchNewInstance
}

private enum LegacyV118AccountUsageMode: String, Codable {
    case switchAccount = "switch"
    case aggregateGateway = "aggregate_gateway"
}

private enum LegacyV118AccountOrderingMode: String, Codable {
    case quotaSort
    case manual
}

private struct LegacyV118GlobalSettings: Codable {
    var defaultModel: String
    var reviewModel: String
    var reasoningEffort: String
}

private struct LegacyV118ActiveSelection: Codable {
    var providerId: String?
    var accountId: String?
}

private struct LegacyV118QuotaSortSettings: Codable {
    var plusRelativeWeight: Double
    var teamRelativeToPlusMultiplier: Double
}

private struct LegacyV118OpenAISettings: Codable {
    var accountOrder: [String]
    var accountUsageMode: LegacyV118AccountUsageMode
    var switchModeSelection: LegacyV118ActiveSelection?
    var accountOrderingMode: LegacyV118AccountOrderingMode
    var manualActivationBehavior: LegacyV118ManualActivationBehavior
    var usageDisplayMode: LegacyV118UsageDisplayMode
    var quotaSort: LegacyV118QuotaSortSettings
}

private struct LegacyV118ProviderAccount: Codable {
    var id: String
    var kind: LegacyV118AccountKind
    var label: String
    var email: String?
    var openAIAccountId: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var lastRefresh: Date?
    var apiKey: String?
    var addedAt: Date?
    var planType: String?
    var primaryUsedPercent: Double?
    var secondaryUsedPercent: Double?
    var primaryResetAt: Date?
    var secondaryResetAt: Date?
    var primaryLimitWindowSeconds: Int?
    var secondaryLimitWindowSeconds: Int?
    var lastChecked: Date?
    var isSuspended: Bool?
    var tokenExpired: Bool?
    var organizationName: String?

    static func fromTokenAccount(_ account: TokenAccount) -> LegacyV118ProviderAccount {
        LegacyV118ProviderAccount(
            id: account.accountId,
            kind: .oauthTokens,
            label: account.email,
            email: account.email,
            openAIAccountId: account.remoteAccountId,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            lastRefresh: account.tokenLastRefreshAt,
            apiKey: nil,
            addedAt: Date(timeIntervalSince1970: 42),
            planType: account.planType,
            primaryUsedPercent: account.primaryUsedPercent,
            secondaryUsedPercent: account.secondaryUsedPercent,
            primaryResetAt: account.primaryResetAt,
            secondaryResetAt: account.secondaryResetAt,
            primaryLimitWindowSeconds: account.primaryLimitWindowSeconds,
            secondaryLimitWindowSeconds: account.secondaryLimitWindowSeconds,
            lastChecked: account.lastChecked,
            isSuspended: account.isSuspended,
            tokenExpired: account.tokenExpired,
            organizationName: account.organizationName
        )
    }
}

private struct LegacyV118Provider: Codable {
    var id: String
    var kind: LegacyV118ProviderKind
    var label: String
    var enabled: Bool
    var baseURL: String?
    var activeAccountId: String?
    var accounts: [LegacyV118ProviderAccount]
}

private struct LegacyV118Config: Codable {
    var version: Int = 1
    var global: LegacyV118GlobalSettings
    var active: LegacyV118ActiveSelection
    var desktop: CodexBarDesktopSettings = CodexBarDesktopSettings()
    var openAI: LegacyV118OpenAISettings
    var providers: [LegacyV118Provider]
}
