import Foundation
import XCTest

@MainActor
final class TokenStoreProviderDefinitionsTests: CodexBarTestCase {
    func testRemovingInactiveProviderAccountRefreshesSavedCredential() throws {
        let oauth = try self.oauthProvider()
        let first = self.apiAccount("first")
        let second = self.apiAccount("second")
        let provider = self.compatibleProvider(accounts: [first, second])
        let store = try self.makeStore(active: oauth, providers: [oauth, provider])
        let authBefore = try Data(contentsOf: CodexPaths.authURL)

        XCTAssertTrue(try self.toml().contains("test-key-first"))
        try store.removeCustomProviderAccount(providerID: provider.id, accountID: first.id)

        let text = try self.toml()
        XCTAssertFalse(text.contains("test-key-first"))
        XCTAssertTrue(text.contains("test-key-second"))
        XCTAssertTrue(text.contains("model_provider = \"openai\""))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), authBefore)
    }

    func testRemovingInactiveProviderRemovesDefinitionWithoutChangingOpenAIAuth() throws {
        let oauth = try self.oauthProvider()
        let provider = self.compatibleProvider(accounts: [self.apiAccount("unused")])
        let store = try self.makeStore(active: oauth, providers: [oauth, provider])
        let authBefore = try Data(contentsOf: CodexPaths.authURL)

        try store.removeCustomProvider(providerID: provider.id)

        XCTAssertFalse(try self.toml().contains("codexbar.compatible"))
        XCTAssertFalse(try self.toml().contains("test-key-unused"))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), authBefore)
    }

    func testRemovingLastProviderOrItsLastAccountRestoresOpenAIDefault() throws {
        for removeWholeProvider in [false, true] {
            let provider = self.compatibleProvider(accounts: [self.apiAccount("last")])
            let preservedAuth = Data("{\"preserved\":true}".utf8)
            try CodexPaths.writeSecureFile(preservedAuth, to: CodexPaths.authURL)
            let store = try self.makeStore(active: provider, providers: [provider])
            XCTAssertTrue(try self.toml().contains("model_provider = \"codexbar.compatible\""))

            if removeWholeProvider {
                try store.removeCustomProvider(providerID: provider.id)
            } else {
                try store.removeCustomProviderAccount(providerID: provider.id, accountID: "last")
            }

            let text = try self.toml()
            XCTAssertTrue(text.contains("model_provider = \"openai\""))
            XCTAssertFalse(text.contains("codexbar.compatible"))
            XCTAssertFalse(text.contains("test-key-last"))
            XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), preservedAuth)
        }
    }

    func testRemovingHybridTargetAccountReturnsToActiveOpenAIProvider() throws {
        let oauth = try self.oauthProvider()
        let first = self.apiAccount("first")
        let target = self.apiAccount("target")
        let provider = self.compatibleProvider(accounts: [first, target])
        let store = try self.makeStore(
            active: oauth,
            providers: [oauth, provider],
            hybridTarget: CodexBarHybridTargetSelection(providerId: provider.id, accountId: target.id)
        )
        XCTAssertTrue(try self.toml().contains("test-key-target"))

        try store.removeCustomProviderAccount(providerID: provider.id, accountID: target.id)

        XCTAssertNil(store.config.openAI.hybridTargetSelection)
        let text = try self.toml()
        XCTAssertTrue(text.contains("model_provider = \"openai\""))
        XCTAssertTrue(text.contains("test-key-first"))
        XCTAssertFalse(text.contains("test-key-target"))
        XCTAssertEqual(try self.readAuthJSON()["auth_mode"] as? String, "chatgpt")
    }

    func testOpenRouterSaveAndLastAccountRemovalRefreshProviderDefinitions() throws {
        let oauth = try self.oauthProvider()
        let store = try self.makeStore(active: oauth, providers: [oauth])
        let authBefore = try Data(contentsOf: CodexPaths.authURL)

        try store.addOpenRouterProvider(apiKey: "test-openrouter-one", selectedModelID: "vendor/model")
        XCTAssertTrue(try self.toml().contains("codexbar.openrouter"))
        XCTAssertTrue(try self.toml().contains("model_provider = \"openai\""))
        try store.addOpenRouterProviderAccount(apiKey: "test-openrouter-two")
        let accounts = try XCTUnwrap(store.openRouterProvider).accounts
        XCTAssertEqual(accounts.count, 2)
        for account in accounts {
            try store.removeOpenRouterProviderAccount(accountID: account.id)
        }

        XCTAssertFalse(try self.toml().contains("codexbar.openrouter"))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), authBefore)
    }

    func testProviderDefinitionWriteFailureIsReportedToCaller() throws {
        let oauth = try self.oauthProvider()
        let provider = self.compatibleProvider(accounts: [self.apiAccount("old")])
        let syncService = CodexSyncService(writeSecureFile: { data, url in
            if url == CodexPaths.configTomlURL {
                throw CocoaError(.fileWriteNoPermission)
            }
            try CodexPaths.writeSecureFile(data, to: url)
        })
        let store = try self.makeStore(active: oauth, providers: [oauth, provider], syncService: syncService)

        XCTAssertThrowsError(try store.addCustomProviderAccount(
            providerID: provider.id, label: "New", apiKey: "test-new-key"
        ))
    }

    func testChatGatewayUsesResolvedHybridTargetAccountForAuthentication() throws {
        let oauth = try self.oauthProvider()
        let first = self.apiAccount("first")
        let target = self.apiAccount("target")
        let provider = self.compatibleProvider(accounts: [first, target], wireAPI: .chat)
        let gateway = ProviderDefinitionGatewaySpy()
        _ = try self.makeStore(
            active: oauth,
            providers: [oauth, provider],
            hybridTarget: CodexBarHybridTargetSelection(providerId: provider.id, accountId: target.id),
            chatGateway: gateway
        )

        XCTAssertEqual(gateway.lastProvider?.activeAccountId, target.id)
        XCTAssertEqual(gateway.lastProvider?.chatCompletionsServiceableSelection?.account.apiKey, target.apiKey)
        XCTAssertTrue(try self.toml().contains("test-key-target"))
        XCTAssertTrue(gateway.started)
    }

    func testChangingChatRouteModelUpdatesGatewayAndCodexConfiguration() throws {
        let provider = self.compatibleProvider(accounts: [self.apiAccount("chat")], wireAPI: .chat)
        let gateway = ProviderDefinitionGatewaySpy()
        let store = try self.makeStore(active: provider, providers: [provider], chatGateway: gateway)

        try store.updateRouteModel("updated-vendor-model")

        XCTAssertEqual(store.activeModel, "updated-vendor-model")
        XCTAssertEqual(store.activeProvider?.selectedModelID, "updated-vendor-model")
        XCTAssertEqual(gateway.lastProvider?.chatCompletionsServiceableSelection?.modelID, "updated-vendor-model")
        XCTAssertTrue(try self.toml().contains("model = \"updated-vendor-model\""))
    }

    func testResponsesMigrationKeepsAccountsAndStopsActiveChatGateway() throws {
        let first = self.apiAccount("first")
        let second = self.apiAccount("second")
        var provider = self.legacyDeepSeekProvider(accounts: [first, second])
        provider.activeAccountId = second.id
        provider.pinnedModelIDs.append("user-custom-model")
        provider.cachedModelCatalog = [
            CodexBarOpenRouterModel(id: "user-custom-model", name: "User Custom Model"),
            CodexBarOpenRouterModel(id: "deepseek-flash", name: "My Flash Label"),
        ]
        let gateway = ProviderDefinitionGatewaySpy()
        let authBefore = Data("{\"preserved\":true}".utf8)
        try CodexPaths.writeSecureFile(authBefore, to: CodexPaths.authURL)
        let store = try self.makeStore(active: provider, providers: [provider], chatGateway: gateway)
        XCTAssertTrue(gateway.started)
        let activeBefore = store.config.active

        try store.migrateProviderToResponses(providerID: provider.id)

        let updated = try XCTUnwrap(store.config.providers.first(where: { $0.id == provider.id }))
        XCTAssertEqual(updated.accounts, provider.accounts)
        XCTAssertEqual(updated.activeAccountId, second.id)
        XCTAssertEqual(updated.id, provider.id)
        XCTAssertEqual(updated.label, provider.label)
        XCTAssertEqual(updated.wireAPI, .responses)
        XCTAssertEqual(updated.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(updated.compatibleEffectiveModelID, "deepseek-flash")
        XCTAssertEqual(updated.defaultModel, "deepseek-flash")
        XCTAssertEqual(updated.pinnedModelIDs, ["deepseek-chat", "user-custom-model", "deepseek-flash"])
        XCTAssertEqual(Array(updated.cachedModelCatalog.prefix(2)), provider.cachedModelCatalog)
        XCTAssertEqual(updated.cachedModelCatalog.filter { $0.id == "deepseek-flash" }.count, 1)
        XCTAssertTrue(updated.cachedModelCatalog.contains { $0.id == "deepseek-v4-pro" })
        XCTAssertEqual(store.config.active, activeBefore)
        XCTAssertFalse(gateway.started)
        XCTAssertNil(gateway.lastProvider)
        XCTAssertTrue(try self.toml().contains("model = \"deepseek-flash\""))
        XCTAssertFalse(try self.toml().contains("127.0.0.1:1458"))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), authBefore)
    }

    func testResponsesMigrationRefreshesInactiveDefinitionWithoutChangingOAuth() throws {
        let oauth = try self.oauthProvider()
        let provider = self.legacyDeepSeekProvider(accounts: [self.apiAccount("inactive")])
        let store = try self.makeStore(active: oauth, providers: [oauth, provider])
        let authBefore = try Data(contentsOf: CodexPaths.authURL)
        let activeBefore = store.config.active

        try store.migrateProviderToResponses(providerID: provider.id)

        XCTAssertEqual(store.config.active, activeBefore)
        XCTAssertTrue(try self.toml().contains("model_provider = \"openai\""))
        XCTAssertTrue(try self.toml().contains("base_url = \"https://api.deepseek.com\""))
        XCTAssertFalse(try self.toml().contains("127.0.0.1:1458"))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), authBefore)
    }

    func testResponsesMigrationRefreshesHybridTargetAndPreservesItsAccount() throws {
        let oauth = try self.oauthProvider()
        let first = self.apiAccount("first")
        let target = self.apiAccount("target")
        let provider = self.legacyDeepSeekProvider(accounts: [first, target])
        let hybrid = CodexBarHybridTargetSelection(providerId: provider.id, accountId: target.id)
        let gateway = ProviderDefinitionGatewaySpy()
        let store = try self.makeStore(
            active: oauth, providers: [oauth, provider], hybridTarget: hybrid, chatGateway: gateway
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
        XCTAssertTrue(gateway.started)

        try store.migrateProviderToResponses(providerID: provider.id)

        XCTAssertEqual(store.config.openAI.hybridTargetSelection, hybrid)
        XCTAssertFalse(gateway.started)
        XCTAssertTrue(try self.toml().contains("test-key-target"))
        XCTAssertTrue(try self.toml().contains("model = \"deepseek-flash\""))
        XCTAssertFalse(try self.toml().contains("127.0.0.1:1458"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testResponsesMigrationProposalsUseOfficialEndpointsAndPreserveKnownModels() {
        var provider = self.legacyDeepSeekProvider(accounts: [self.apiAccount("account")])
        provider.presetID = nil
        provider.selectedModelID = "deepseek-v4-pro"
        XCTAssertEqual(CodexBarProviderResponsesMigration.proposal(for: provider)?.modelID, "deepseek-v4-pro")

        for (url, expectedBaseURL, expectedModel) in [
            ("https://api.deepseek.com/v1/", "https://api.deepseek.com", "deepseek-flash"),
            ("https://open.bigmodel.cn/api/paas/v4", "https://open.bigmodel.cn/api/v1", "glm-5.3"),
            ("https://open.bigmodel.cn/api/v1", "https://open.bigmodel.cn/api/v1", "glm-5.3"),
            ("https://router.requesty.ai/v1", "https://router.requesty.ai/v1", "openai-responses/gpt-5"),
        ] {
            provider.baseURL = url
            provider.selectedModelID = "legacy-model"
            let proposal = CodexBarProviderResponsesMigration.proposal(for: provider)
            XCTAssertEqual(proposal?.baseURL, expectedBaseURL)
            XCTAssertEqual(proposal?.modelID, expectedModel)
        }
        provider.wireAPI = .responses
        XCTAssertNil(CodexBarProviderResponsesMigration.proposal(for: provider))
    }

    func testResponsesMigrationRejectsUnknownEndpointsEvenWithDeepSeekPreset() throws {
        var provider = self.legacyDeepSeekProvider(accounts: [self.apiAccount("account")])
        for url in [
            "https://relay.example/v1", "https://api.deepseek.com.evil.example/v1",
            "https://api.deepseek.com/custom", "https://api.deepseek.com/v1?route=custom",
            "https://api.deepseek.com:8443/v1", "http://api.deepseek.com/v1",
            "https://open.bigmodel.cn/api/coding/paas/v4",
        ] {
            provider.baseURL = url
            XCTAssertNil(CodexBarProviderResponsesMigration.proposal(for: provider), url)
        }
        let store = try self.makeStore(active: provider, providers: [provider])
        let previous = try Data(contentsOf: CodexPaths.barConfigURL)
        XCTAssertThrowsError(try store.migrateProviderToResponses(providerID: provider.id))
        XCTAssertEqual(store.config.providers.first, provider)
        XCTAssertEqual(try Data(contentsOf: CodexPaths.barConfigURL), previous)
    }

    func testRepeatedResponsesMigrationDoesNotWriteOrSynchronizeAgain() throws {
        let provider = self.legacyDeepSeekProvider(accounts: [self.apiAccount("account")])
        let synchronizer = ProviderMigrationSynchronizer()
        let store = try self.makeStore(active: provider, providers: [provider], syncService: synchronizer)
        try store.migrateProviderToResponses(providerID: provider.id)
        let savedData = try Data(contentsOf: CodexPaths.barConfigURL)
        let syncCount = synchronizer.calls
        let modifiedAt = try FileManager.default.attributesOfItem(atPath: CodexPaths.barConfigURL.path)[.modificationDate] as? Date

        try store.migrateProviderToResponses(providerID: provider.id)

        XCTAssertEqual(synchronizer.calls, syncCount)
        XCTAssertEqual(try Data(contentsOf: CodexPaths.barConfigURL), savedData)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: CodexPaths.barConfigURL.path)[.modificationDate] as? Date, modifiedAt)
    }

    func testFailedResponsesMigrationRestoresSavedAndPublishedConfiguration() throws {
        for activeThirdParty in [false, true] {
            let oauth = try self.oauthProvider()
            let provider = self.legacyDeepSeekProvider(accounts: [self.apiAccount("account")])
            let synchronizer = ProviderMigrationSynchronizer()
            let gateway = ProviderDefinitionGatewaySpy()
            let store = try self.makeStore(
                active: activeThirdParty ? provider : oauth,
                providers: [oauth, provider], syncService: synchronizer, chatGateway: gateway
            )
            let previous = store.config
            let savedData = try Data(contentsOf: CodexPaths.barConfigURL)
            let tomlBefore = try self.toml()
            let gatewayWasStarted = gateway.started
            synchronizer.failWrites = true

            XCTAssertThrowsError(try store.migrateProviderToResponses(providerID: provider.id))

            XCTAssertEqual(store.config.providers, previous.providers)
            XCTAssertEqual(store.config.active, previous.active)
            XCTAssertEqual(store.config.openAI.hybridTargetSelection, previous.openAI.hybridTargetSelection)
            XCTAssertEqual(try Data(contentsOf: CodexPaths.barConfigURL), savedData)
            XCTAssertEqual(try self.toml(), tomlBefore)
            XCTAssertEqual(gateway.started, gatewayWasStarted)
        }
    }

    func testDeepSeekCompatibilityDetectionDoesNotTrustHostSuffixes() {
        XCTAssertTrue(CodexBarProviderCompatibility.isDeepSeek(presetID: "deepseek", baseURL: "https://relay.example"))
        XCTAssertTrue(CodexBarProviderCompatibility.isDeepSeek(presetID: nil, baseURL: "https://api.deepseek.com/v1"))
        XCTAssertTrue(CodexBarProviderCompatibility.isDeepSeek(presetID: nil, baseURL: " \nhttps://api.deepseek.com/v1\t "))
        XCTAssertFalse(CodexBarProviderCompatibility.isDeepSeek(presetID: nil, baseURL: "https://api.deepseek.com.evil.example"))
        XCTAssertFalse(CodexBarProviderCompatibility.isDeepSeek(presetID: nil, baseURL: " https://api.deepseek.com.evil.example \n"))
        XCTAssertFalse(CodexBarProviderCompatibility.isDeepSeek(presetID: nil, baseURL: "https://api.deepseek.com@evil.example"))
    }

    func testResponsesMigrationPreservesExternallyRefreshedFixedOAuthIdentity() throws {
        for failSync in [false, true] {
            if FileManager.default.fileExists(atPath: CodexPaths.authURL.path) {
                try FileManager.default.removeItem(at: CodexPaths.authURL)
            }
            let oauth = try self.oauthProvider()
            let identity = try XCTUnwrap(oauth.activeAccount)
            let provider = self.legacyDeepSeekProvider(accounts: [self.apiAccount("target")])
            let synchronizer = ProviderMigrationSynchronizer()
            let store = try self.makeStore(
                active: provider, providers: [oauth, provider],
                remoteConnectionAccountID: identity.id, syncService: synchronizer
            )
            let previousProviders = store.config.providers
            let previousSavedConfig = try Data(contentsOf: CodexPaths.barConfigURL)
            let refreshAt = Date(timeIntervalSinceNow: 600)
            let refreshed = try self.makeOAuthAccount(
                accountID: identity.id, email: "test@example.invalid",
                refreshToken: "test-externally-refreshed-token",
                accessTokenExpiresAt: Date(timeIntervalSinceNow: 7_200),
                tokenLastRefreshAt: refreshAt
            )
            try self.writeAuthJSON(
                accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken,
                idToken: refreshed.idToken, remoteAccountID: refreshed.remoteAccountId,
                lastRefresh: refreshAt
            )
            let refreshedAuthData = try Data(contentsOf: CodexPaths.authURL)
            synchronizer.failWrites = failSync

            if failSync {
                XCTAssertThrowsError(try store.migrateProviderToResponses(providerID: provider.id))
                XCTAssertEqual(store.config.providers, previousProviders)
                XCTAssertEqual(try Data(contentsOf: CodexPaths.barConfigURL), previousSavedConfig)
                XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), refreshedAuthData)
            } else {
                try store.migrateProviderToResponses(providerID: provider.id)
                let current = try XCTUnwrap(store.config.remoteConnectionAccount())
                let saved = try XCTUnwrap(CodexBarConfigStore().load().remoteConnectionAccount())
                let authTokens = try XCTUnwrap(self.readAuthJSON()["tokens"] as? [String: Any])
                XCTAssertEqual(current.accessToken, refreshed.accessToken)
                XCTAssertEqual(current.refreshToken, refreshed.refreshToken)
                XCTAssertEqual(saved.accessToken, refreshed.accessToken)
                XCTAssertEqual(saved.refreshToken, refreshed.refreshToken)
                XCTAssertEqual(authTokens["access_token"] as? String, refreshed.accessToken)
                XCTAssertEqual(authTokens["refresh_token"] as? String, refreshed.refreshToken)
            }
        }
    }

    private func legacyDeepSeekProvider(accounts: [CodexBarProviderAccount]) -> CodexBarProvider {
        var provider = self.compatibleProvider(accounts: accounts, wireAPI: .chat)
        provider.presetID = "deepseek"
        provider.baseURL = "https://api.deepseek.com/v1"
        provider.defaultModel = "deepseek-chat"
        provider.selectedModelID = "deepseek-chat"
        provider.pinnedModelIDs = ["deepseek-chat"]
        return provider
    }

    private func apiAccount(_ id: String) -> CodexBarProviderAccount {
        CodexBarProviderAccount(id: id, kind: .apiKey, label: id, apiKey: "test-key-\(id)")
    }

    private func compatibleProvider(
        accounts: [CodexBarProviderAccount],
        wireAPI: CodexBarWireAPI = .responses
    ) -> CodexBarProvider {
        CodexBarProvider(
            id: "compatible", kind: .openAICompatible, label: "Compatible",
            baseURL: "https://example.invalid/v1", wireAPI: wireAPI,
            defaultModel: "vendor-model", selectedModelID: "vendor-model",
            activeAccountId: accounts.first?.id, accounts: accounts
        )
    }

    private func oauthProvider() throws -> CodexBarProvider {
        let account = CodexBarProviderAccount.fromTokenAccount(
            try self.makeOAuthAccount(accountID: "openai-test", email: "test@example.invalid"),
            existingID: "openai-test"
        )
        return CodexBarProvider(
            id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI",
            activeAccountId: account.id, accounts: [account]
        )
    }

    private func makeStore(
        active: CodexBarProvider,
        providers: [CodexBarProvider],
        hybridTarget: CodexBarHybridTargetSelection? = nil,
        remoteConnectionAccountID: String? = nil,
        syncService: any CodexSynchronizing = CodexSyncService(),
        chatGateway: ProviderDefinitionGatewaySpy = ProviderDefinitionGatewaySpy()
    ) throws -> TokenStore {
        try self.writeConfig(CodexBarConfig(
            active: CodexBarActiveSelection(providerId: active.id, accountId: active.activeAccountId),
            openAI: CodexBarOpenAISettings(
                accountUsageMode: .switchAccount,
                remoteConnectionAccountID: remoteConnectionAccountID,
                hybridTargetSelection: hybridTarget
            ),
            providers: providers
        ))
        return TokenStore(
            syncService: syncService,
            openAIAccountGatewayService: ProviderDefinitionOpenAIGatewayStub(),
            openRouterGatewayService: ProviderDefinitionGatewaySpy(),
            chatCompletionsGatewayService: chatGateway,
            codexRunningProcessIDs: { [] },
            loadServiceTierCatalog: { nil }
        )
    }

    private func toml() throws -> String {
        try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
    }
}

private final class ProviderMigrationSynchronizer: CodexSynchronizing {
    var calls = 0
    var failWrites = false

    private var service: CodexSyncService {
        CodexSyncService(writeSecureFile: { data, url in
            if self.failWrites, url == CodexPaths.configTomlURL {
                throw CocoaError(.fileWriteNoPermission)
            }
            try CodexPaths.writeSecureFile(data, to: url)
        })
    }

    func synchronize(config: CodexBarConfig) throws {
        self.calls += 1
        try self.service.synchronize(config: config)
    }

    func synchronizeProviderDefinitions(config: CodexBarConfig) throws {
        self.calls += 1
        try self.service.synchronizeProviderDefinitions(config: config)
    }
}

private final class ProviderDefinitionGatewaySpy: OpenRouterGatewayControlling, ChatCompletionsGatewayControlling {
    private(set) var lastProvider: CodexBarProvider?
    private(set) var started = false
    func startIfNeeded() { self.started = true }
    func stop() { self.started = false }
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {
        self.lastProvider = provider
    }
}

private final class ProviderDefinitionOpenAIGatewayStub: OpenAIAccountGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        reserveActiveAccountQuota: Bool,
        defaultProxy: OpenAIAccountGatewayConfiguredProxy?,
        proxyByAccountID: [String: OpenAIAccountGatewayConfiguredProxy]
    ) {}
    func currentRoutedAccountID() -> String? { nil }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { [] }
    func clearStickyBinding(threadID: String) -> Bool { false }
}
