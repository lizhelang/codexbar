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
        syncService: any CodexSynchronizing = CodexSyncService(),
        chatGateway: ProviderDefinitionGatewaySpy = ProviderDefinitionGatewaySpy()
    ) throws -> TokenStore {
        try self.writeConfig(CodexBarConfig(
            active: CodexBarActiveSelection(providerId: active.id, accountId: active.activeAccountId),
            openAI: CodexBarOpenAISettings(accountUsageMode: .switchAccount, hybridTargetSelection: hybridTarget),
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
        defaultProxy: OpenAIAccountGatewayConfiguredProxy?,
        proxyByAccountID: [String: OpenAIAccountGatewayConfiguredProxy]
    ) {}
    func currentRoutedAccountID() -> String? { nil }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { [] }
    func clearStickyBinding(threadID: String) -> Bool { false }
}
