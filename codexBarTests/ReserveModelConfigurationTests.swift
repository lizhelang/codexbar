import Foundation
import XCTest

final class ReserveModelConfigurationTests: CodexBarTestCase {
    func testLegacyForcedReserveSettingIsIgnoredWithoutSelectingAModel() throws {
        let original = Self.fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var settings = try XCTUnwrap(object["openAI"] as? [String: Any])
        settings["forcedReserveAccountID"] = "reserve-account"
        object["openAI"] = settings
        let config = try JSONDecoder().decode(CodexBarConfig.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(try CodexRouteResolver.resolve(config: config), try CodexRouteResolver.resolve(config: original))
        XCTAssertNil(config.oauthProvider()?.accounts.first(where: { $0.id == "reserve-account" })?.selectedModelID)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertNil((encoded["openAI"] as? [String: Any])?["forcedReserveAccountID"])
    }

    func testAccountModelSelectionIsOptionalAndRoundTrips() throws {
        let account = Self.fixture().oauthProvider()!.accounts[0]
        let legacy = try JSONDecoder().decode(CodexBarProviderAccount.self, from: JSONEncoder().encode(account))
        XCTAssertNil(legacy.selectedModelID)

        var selected = account
        selected.selectedModelID = ReserveModelPolicy.modelID
        let restored = try JSONDecoder().decode(CodexBarProviderAccount.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(restored.selectedModelID, ReserveModelPolicy.modelID)
    }

    func testOAuthModelPriorityIsAccountThenProviderThenGlobal() throws {
        var config = Self.fixture()
        config.providers[0].defaultModel = "provider-model"
        XCTAssertEqual(try CodexRouteResolver.resolve(config: config).effectiveModel, "provider-model")
        try config.setOAuthSelectedModel(accountID: "normal-account", value: " account-model ")
        XCTAssertEqual(try CodexRouteResolver.resolve(config: config).effectiveModel, "account-model")
        try config.setOAuthSelectedModel(accountID: "normal-account", value: "  ")
        XCTAssertNil(config.activeAccount()?.selectedModelID)
        config.providers[0].defaultModel = nil
        XCTAssertEqual(try CodexRouteResolver.resolve(config: config).effectiveModel, "gpt-6-astra")
    }

    func testReserveSelectionUsesSelectedAccountDirectlyInEveryMode() throws {
        for mode in CodexBarOpenAIAccountUsageMode.allCases {
            var config = Self.fixture(mode: mode)
            config.openAI.remoteConnectionAccountID = "normal-account"
            config.active.accountId = "reserve-account"
            try config.setOAuthSelectedModel(accountID: "reserve-account", value: ReserveModelPolicy.modelID)
            let route = try CodexRouteResolver.resolve(config: config)

            XCTAssertEqual(route.mode, mode)
            XCTAssertEqual(route.targetAccount.id, "reserve-account")
            XCTAssertEqual(route.authAccount.id, "reserve-account")
            XCTAssertEqual(route.effectiveModel, ReserveModelPolicy.modelID)
            XCTAssertFalse(route.usesFixedOAuthIdentity)
            XCTAssertFalse(route.routesOpenAITargetThroughGateway)
            XCTAssertEqual(config.openAI.remoteConnectionAccountID, "normal-account")
            XCTAssertEqual(config.global.defaultModel, "gpt-6-astra")
            XCTAssertEqual(config.global.serviceTier, "fast")
        }
    }

    func testReserveAccountSelectionDoesNotOverrideOtherAccounts() throws {
        var config = Self.fixture(mode: .aggregateGateway)
        try config.setOAuthSelectedModel(accountID: "reserve-account", value: ReserveModelPolicy.modelID)
        XCTAssertEqual(try CodexRouteResolver.resolve(config: config).effectiveModel, "gpt-6-astra")
        XCTAssertTrue(try CodexRouteResolver.resolve(config: config).routesOpenAITargetThroughGateway)

        config.active.accountId = "reserve-account"
        XCTAssertEqual(try CodexRouteResolver.resolve(config: config).effectiveModel, ReserveModelPolicy.modelID)
        config.active.accountId = "normal-account"
        XCTAssertEqual(try CodexRouteResolver.resolve(config: config).effectiveModel, "gpt-6-astra")
        XCTAssertTrue(try CodexRouteResolver.resolve(config: config).routesOpenAITargetThroughGateway)
    }

    func testReserveOAuthRequestTargetIgnoresFixedIdentityAndDoesNotFallBackOnExhaustion() throws {
        var config = Self.fixture(mode: .aggregateGateway)
        try config.setOAuthSelectedModel(accountID: "reserve-account", value: ReserveModelPolicy.modelID)
        config.providers[0].accounts[1].lunaReserveUsedPercent = 100
        config.openAI.remoteConnectionAccountID = "missing-fixed-identity"
        config.openAI.hybridTargetSelection = CodexBarHybridTargetSelection(
            providerId: "openai-oauth", accountId: "reserve-account"
        )

        let route = try CodexRouteResolver.resolve(config: config)
        XCTAssertEqual(route.authAccount.id, "reserve-account")
        XCTAssertEqual(route.effectiveModel, ReserveModelPolicy.modelID)
        XCTAssertFalse(route.routesOpenAITargetThroughGateway)
    }

    func testSelectingOrdinaryModelRestoresExistingFixedIdentityRouting() throws {
        var config = Self.fixture(mode: .aggregateGateway)
        config.active.accountId = "reserve-account"
        config.openAI.remoteConnectionAccountID = "normal-account"
        try config.setOAuthSelectedModel(accountID: "reserve-account", value: ReserveModelPolicy.modelID)
        XCTAssertFalse(try CodexRouteResolver.resolve(config: config).routesOpenAITargetThroughGateway)

        try config.setOAuthSelectedModel(accountID: "reserve-account", value: "gpt-6-sol")
        let route = try CodexRouteResolver.resolve(config: config)
        XCTAssertEqual(route.effectiveModel, "gpt-6-sol")
        XCTAssertEqual(route.authAccount.id, "normal-account")
        XCTAssertTrue(route.usesFixedOAuthIdentity)
        XCTAssertTrue(route.routesOpenAITargetThroughGateway)
    }

    func testReserveNameDoesNotChangeThirdPartyRouting() throws {
        var config = Self.fixture()
        config.active = CodexBarActiveSelection(providerId: "relay", accountId: "relay-account")
        config.providers[1].defaultModel = ReserveModelPolicy.modelID
        config.openAI.remoteConnectionAccountID = "normal-account"

        let route = try CodexRouteResolver.resolve(config: config)
        XCTAssertEqual(route.targetProvider.id, "relay")
        XCTAssertEqual(route.authAccount.id, "normal-account")
        XCTAssertTrue(route.usesFixedOAuthIdentity)
        XCTAssertTrue(route.requiresOpenAIAuth)
    }

    func testOAuthCredentialRefreshPreservesModelSelectionAndSynchronizesActualReserveIdentity() throws {
        var config = Self.fixture(mode: .aggregateGateway)
        config.openAI.hybridTargetSelection = CodexBarHybridTargetSelection(
            providerId: "openai-oauth", accountId: "reserve-account"
        )
        config.openAI.remoteConnectionAccountID = "normal-account"
        try config.setOAuthSelectedModel(accountID: "reserve-account", value: ReserveModelPolicy.modelID)
        var refreshed = try XCTUnwrap(config.providers[0].accounts[1].asTokenAccount(isActive: false))
        refreshed.accessToken = "test-refreshed-reserve"

        let result = config.upsertOAuthAccount(refreshed, activate: false)
        XCTAssertEqual(result.storedAccount.selectedModelID, ReserveModelPolicy.modelID)
        XCTAssertTrue(result.syncCodex)
        let unchanged = config.upsertOAuthAccount(refreshed, activate: false)
        XCTAssertFalse(unchanged.syncCodex)
    }

    func testRemoteConnectionCredentialRefreshPreservesModelSelection() throws {
        var config = Self.fixture()
        var remote = config.providers[0].accounts[1]
        remote.id = "remote-only"
        remote.openAIAccountId = "remote-only-backend"
        remote.selectedModelID = "gpt-6-sol"
        config.openAI.remoteConnectionAccounts = [remote]
        var refreshed = try XCTUnwrap(remote.asTokenAccount(isActive: false))
        refreshed.accessToken = "test-refreshed-remote"

        let result = config.upsertRemoteConnectionAccount(refreshed)
        XCTAssertEqual(result.selectedModelID, "gpt-6-sol")
    }

    func testSynchronizeWritesReserveDefaultWithoutGatewayOrGlobalPreferenceChanges() throws {
        var config = Self.fixture(mode: .aggregateGateway)
        config.active.accountId = "reserve-account"
        config.openAI.remoteConnectionAccountID = "normal-account"
        try config.setOAuthSelectedModel(accountID: "reserve-account", value: ReserveModelPolicy.modelID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let globalBefore = try encoder.encode(config.global)
        try CodexSyncService(loadServiceTierCatalog: { nil }).synchronize(config: config)
        let text = try Self.readConfig()

        XCTAssertTrue(text.contains(#"model_provider = "codexbar.openai-oauth.reserve""#), text)
        XCTAssertTrue(text.contains(#"model = "gpt-reserve""#), text)
        XCTAssertTrue(text.contains(#"review_model = "gpt-reserve""#), text)
        XCTAssertTrue(text.contains(#"model_reasoning_effort = "medium""#), text)
        XCTAssertTrue(text.contains("model_context_window = 272000"), text)
        XCTAssertTrue(text.contains(#"service_tier = "fast""#), text)
        let root = String(text.prefix { $0 != "[" })
        XCTAssertTrue(root.contains("openai_base_url = \"\(OpenAIAccountGatewayConfiguration.baseURLString)\""), root)
        let reserveProvider = try Self.providerBlock(in: text, identifier: "codexbar.openai-oauth.reserve")
        XCTAssertFalse(reserveProvider.contains("127.0.0.1:1456"), reserveProvider)
        XCTAssertTrue(reserveProvider.contains("supports_websockets = true"), reserveProvider)
        let ordinaryProvider = try Self.providerBlock(in: text, identifier: "codexbar.openai-oauth")
        XCTAssertTrue(ordinaryProvider.contains(OpenAIAccountGatewayConfiguration.baseURLString), ordinaryProvider)
        XCTAssertEqual(try encoder.encode(config.global), globalBefore)
        let auth = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: CodexPaths.authURL)) as? [String: Any])
        XCTAssertEqual((auth["tokens"] as? [String: Any])?["account_id"] as? String, "reserve-remote")
    }

    func testReserveContextWindowUsesCatalogAndRespectsUserOverride() throws {
        var config = Self.fixture()
        try config.setOAuthSelectedModel(accountID: "normal-account", value: ReserveModelPolicy.modelID)
        let catalog = try CodexServiceTierCatalog.parse(Data(#"{"models":[{"slug":"gpt-reserve","context_window":300000}]}"#.utf8))
        let service = CodexSyncService(loadServiceTierCatalog: { catalog })
        try service.synchronize(config: config)
        XCTAssertTrue(try Self.readConfig().contains("model_context_window = 300000"))
        config.global.modelContextWindows[ReserveModelPolicy.modelID] = 400_000
        try service.synchronize(config: config)
        XCTAssertTrue(try Self.readConfig().contains("model_context_window = 400000"))
    }

    func testReserveReasoningOptionsAndFallbackMatchSynchronization() {
        XCTAssertEqual(CodexBarGlobalSettings.defaultContextWindow(for: ReserveModelPolicy.modelID), 272_000)
        XCTAssertEqual(CodexBarGlobalSettings.reasoningEffortOptions(for: ReserveModelPolicy.modelID),
                       ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(CodexBarGlobalSettings.compatibleReasoningEffort("ultra", for: ReserveModelPolicy.modelID), "medium")
        XCTAssertFalse(CodexBarGlobalSettings.supportsReasoningEffort("ultra", for: ReserveModelPolicy.modelID))
        XCTAssertTrue(CodexBarGlobalSettings.supportsReasoningEffort("max", for: ReserveModelPolicy.modelID))
    }

    func testReserveReasoningKeepsSupportedEffortsAndNormalizesOthers() throws {
        var config = Self.fixture()
        try config.setOAuthSelectedModel(accountID: "normal-account", value: ReserveModelPolicy.modelID)
        let service = CodexSyncService(loadServiceTierCatalog: { nil })
        for (input, expected) in [("low", "low"), ("medium", "medium"), ("high", "high"),
                                  ("xhigh", "xhigh"), ("max", "max"), ("ultra", "medium"), ("none", "medium")] {
            config.global.reasoningEffort = input
            try service.synchronize(config: config)
            let text = try Self.readConfig()
            XCTAssertTrue(text.contains("model_reasoning_effort = \"\(expected)\""), text)
        }
    }

    func testReserveUsesIsolatedDirectAliasForEveryTransportWhilePreservingOrdinaryRoutes() throws {
        let directives: [CodexWebSocketSupportDirective] = [.remove, .write(false), .write(true)]
        for (mode, fixedIdentity) in [(CodexBarOpenAIAccountUsageMode.aggregateGateway, false),
                                      (.switchAccount, true), (.switchAccount, false)] {
            for directive in directives {
                var config = Self.fixture(mode: mode)
                if fixedIdentity { config.openAI.remoteConnectionAccountID = "reserve-account" }
                let usesGateway = mode == .aggregateGateway || fixedIdentity
                let gatewaySetting = "openai_base_url = \"\(OpenAIAccountGatewayConfiguration.baseURLString)\""
                let profiles = """
                [profiles.old_chat]
                model_provider = "codexbar.openai-oauth"
                model = "gpt-6-astra"

                [profiles.old_builtin_chat]
                model_provider = "openai"
                model = "gpt-6-astra"
                """
                let service = CodexSyncService(
                    loadServiceTierCatalog: { nil },
                    webSocketSupportDirective: { _, _ in directive }
                )
                try CodexPaths.ensureDirectories()
                try CodexPaths.writeSecureFile(Data(profiles.utf8), to: CodexPaths.configTomlURL)
                try service.synchronize(config: config)
                let ordinaryConfig = try Self.readConfig()
                let ordinaryRoot = String(ordinaryConfig.prefix { $0 != "[" })
                let ordinaryBefore = try Self.providerBlock(in: ordinaryConfig, identifier: "codexbar.openai-oauth")
                XCTAssertEqual(ordinaryRoot.contains(gatewaySetting), usesGateway, ordinaryRoot)
                if usesGateway { XCTAssertTrue(ordinaryRoot.contains(#"model_provider = "openai""#), ordinaryRoot) }

                try config.setOAuthSelectedModel(accountID: "normal-account", value: ReserveModelPolicy.modelID)
                try service.synchronize(config: config)
                let reserveConfig = try Self.readConfig()
                let root = String(reserveConfig.prefix { $0 != "[" })
                XCTAssertTrue(root.contains(#"model_provider = "codexbar.openai-oauth.reserve""#), root)
                XCTAssertEqual(root.contains(gatewaySetting), usesGateway, root)
                XCTAssertTrue(reserveConfig.contains(profiles), reserveConfig)
                let ordinaryDuringReserve = try Self.providerBlock(in: reserveConfig, identifier: "codexbar.openai-oauth")
                XCTAssertEqual(ordinaryDuringReserve, ordinaryBefore)
                XCTAssertEqual(ordinaryDuringReserve.contains(OpenAIAccountGatewayConfiguration.baseURLString), usesGateway, ordinaryDuringReserve)
                let reserveProvider = try Self.providerBlock(in: reserveConfig, identifier: "codexbar.openai-oauth.reserve")
                XCTAssertTrue(reserveProvider.contains(#"base_url = "https://chatgpt.com/backend-api/codex""#), reserveProvider)
                XCTAssertFalse(reserveProvider.contains("127.0.0.1:1456"), reserveProvider)
                XCTAssertTrue(reserveProvider.contains("supports_websockets = \(directive == .write(false) ? "false" : "true")"), reserveProvider)
                try service.synchronizeProviderDefinitions(config: config)
                XCTAssertEqual(try Self.readConfig(), reserveConfig)

                try config.setOAuthSelectedModel(accountID: "normal-account", value: "gpt-6-astra")
                try service.synchronize(config: config)
                let restored = try Self.readConfig()
                let restoredRoot = String(restored.prefix { $0 != "[" })
                XCTAssertEqual(restoredRoot.contains(gatewaySetting), usesGateway, restoredRoot)
                XCTAssertEqual(try Self.providerBlock(in: restored, identifier: "codexbar.openai-oauth"), ordinaryBefore)
                XCTAssertEqual(try Self.providerBlock(in: restored, identifier: "codexbar.openai-oauth.reserve"), reserveProvider)
            }
        }
    }

    func testReserveSynchronizationUsesTheSameCatalogReasoningFallbackAsTheUI() throws {
        var config = Self.fixture()
        try config.setOAuthSelectedModel(accountID: "normal-account", value: ReserveModelPolicy.modelID)
        let catalog = try CodexServiceTierCatalog.parse(Data(#"{"models":[{"slug":"gpt-reserve","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"default_reasoning_level":"high"}]}"#.utf8))
        XCTAssertEqual(CodexBarGlobalSettings.compatibleReasoningEffort("ultra", for: ReserveModelPolicy.modelID, catalog: catalog), "high")
        try CodexSyncService(loadServiceTierCatalog: { catalog }).synchronize(config: config)
        let text = try Self.readConfig()
        XCTAssertTrue(text.contains(#"model_reasoning_effort = "high""#), text)
    }

    private static func providerBlock(in text: String, identifier: String) throws -> String {
        let header = "[model_providers.\"\(identifier)\"]"
        let parts = text.components(separatedBy: header)
        XCTAssertEqual(parts.count, 2)
        let body = try XCTUnwrap(parts.dropFirst().first)
        return String(body.components(separatedBy: "\n[").first ?? body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readConfig() throws -> String {
        try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
    }

    private static func fixture(mode: CodexBarOpenAIAccountUsageMode = .switchAccount) -> CodexBarConfig {
        let normal = CodexBarProviderAccount(
            id: "normal-account", kind: .oauthTokens, label: "Normal", openAIAccountId: "normal-remote",
            accessToken: "test-normal", refreshToken: "test-refresh-normal", idToken: "test-id-normal"
        )
        let reserve = CodexBarProviderAccount(
            id: "reserve-account", kind: .oauthTokens, label: "Reserve", openAIAccountId: "reserve-remote",
            accessToken: "test-reserve", refreshToken: "test-refresh-reserve", idToken: "test-id-reserve"
        )
        let oauth = CodexBarProvider(
            id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: normal.id,
            accounts: [normal, reserve]
        )
        let relayAccount = CodexBarProviderAccount(id: "relay-account", kind: .apiKey, label: "Relay", apiKey: "test-key")
        let relay = CodexBarProvider(
            id: "relay", kind: .openAICompatible, label: "Relay", baseURL: "https://relay.invalid/v1",
            defaultModel: "relay-model", activeAccountId: relayAccount.id, accounts: [relayAccount]
        )
        return CodexBarConfig(
            global: CodexBarGlobalSettings(
                defaultModel: "gpt-6-astra", reviewModel: "gpt-6-sol", reasoningEffort: "ultra", serviceTier: "fast",
                modelContextWindows: ["gpt-6-astra": 872_000, "relay-model": 512_000]
            ),
            active: CodexBarActiveSelection(providerId: oauth.id, accountId: normal.id),
            openAI: CodexBarOpenAISettings(accountUsageMode: mode),
            providers: [oauth, relay]
        )
    }
}
