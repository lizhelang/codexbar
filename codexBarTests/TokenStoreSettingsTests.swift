import Foundation
import XCTest

@MainActor
final class TokenStoreSettingsTests: CodexBarTestCase {
    func testInitializationRebuildsLocalCostSummaryWhenCacheIsMissing() throws {
        let sessionDirectory = CodexPaths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("cost-rebuild.jsonl")
        let content = [
            #"{"payload":{"type":"session_meta","id":"cost-rebuild","timestamp":"2026-04-05T08:00:00Z"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            #"{"timestamp":"2026-04-05T09:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let sessionStore = SessionLogStore(
            codexRootURL: CodexPaths.codexRoot,
            persistedCacheURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-cost-session-cache.json"),
            persistedUsageLedgerURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-cost-event-ledger.json")
        )
        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(sessionLogStore: sessionStore),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        let timeout = Date().addingTimeInterval(3)
        while store.localCostSummary.updatedAt == nil && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertNotNil(store.localCostSummary.updatedAt)
        XCTAssertEqual(store.localCostSummary.todayTokens, 0)
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 230)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 230)
        XCTAssertEqual(store.localCostSummary.last30DaysCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(store.localCostSummary.lifetimeCostUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertEqual(store.localCostSummary.dailyEntries.count, 1)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].totalTokens, 230)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].costUSD, 0.0008075, accuracy: 1e-12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.costCacheURL.path))
    }

    func testInitializationSeedsHistoricalModelsFromConfigThenRefreshesInBackground() throws {
        var config = CodexBarConfig()
        config.modelPricing = [
            "google/gemini-2.5-pro": CodexBarModelPricing(
                inputUSDPerToken: 0.9e-6,
                cachedInputUSDPerToken: 0.4e-6,
                outputUSDPerToken: 1.8e-6
            ),
        ]
        try self.writeConfig(config)

        let sessionDirectory = CodexPaths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("historical-models.jsonl")
        let content = [
            #"{"payload":{"type":"session_meta","id":"historical-models","timestamp":"2026-04-05T08:00:00Z"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let sessionStore = SessionLogStore(
            codexRootURL: CodexPaths.codexRoot,
            persistedCacheURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-historical-models-session-cache.json"),
            persistedUsageLedgerURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-historical-models-ledger.json")
        )

        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(sessionLogStore: sessionStore),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertEqual(store.historicalModels, ["google/gemini-2.5-pro"])

        let timeout = Date().addingTimeInterval(3)
        while Set(store.historicalModels) != Set(["google/gemini-2.5-pro", "gpt-5.4"]) && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(Set(store.historicalModels), Set(["google/gemini-2.5-pro", "gpt-5.4"]))
    }

    func testSaveModelPricingSettingsPersistsAcrossReload() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.saveModelPricingSettings(
            ModelPricingSettingsUpdate(
                upserts: [
                    "gpt-5.4": CodexBarModelPricing(
                        inputUSDPerToken: 9.9e-6,
                        cachedInputUSDPerToken: 9.9e-7,
                        outputUSDPerToken: 2.4e-5
                    ),
                ],
                removals: []
            )
        )

        XCTAssertEqual(
            store.config.modelPricing["gpt-5.4"],
            CodexBarModelPricing(
                inputUSDPerToken: 9.9e-6,
                cachedInputUSDPerToken: 9.9e-7,
                outputUSDPerToken: 2.4e-5
            )
        )

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(
            reloaded.modelPricing["gpt-5.4"],
            CodexBarModelPricing(
                inputUSDPerToken: 9.9e-6,
                cachedInputUSDPerToken: 9.9e-7,
                outputUSDPerToken: 2.4e-5
            )
        )
    }

    func testSaveModelPricingSettingsSanitizesNonFiniteValues() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.saveModelPricingSettings(
            ModelPricingSettingsUpdate(
                upserts: [
                    "gpt-5.4": CodexBarModelPricing(
                        inputUSDPerToken: .infinity,
                        cachedInputUSDPerToken: -1,
                        outputUSDPerToken: 2.4e-5
                    ),
                ],
                removals: []
            )
        )

        XCTAssertEqual(
            store.config.modelPricing["gpt-5.4"],
            CodexBarModelPricing(
                inputUSDPerToken: 0,
                cachedInputUSDPerToken: 0,
                outputUSDPerToken: 2.4e-5
            )
        )
    }

    func testInitializationRebuildsLocalCostSummaryWhenCachedSummaryIsZeroButLedgerExists() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        let sessionDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("cost-zero-cache.jsonl")
        let content = [
            #"{"payload":{"type":"session_meta","id":"cost-zero-cache","timestamp":"2026-04-05T08:00:00Z"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-04-05T08:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            #"{"timestamp":"2026-04-05T09:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let sessionStore = SessionLogStore(
            codexRootURL: codexRoot,
            persistedCacheURL: root.appendingPathComponent(".codexbar/test-cost-session-cache.json"),
            persistedUsageLedgerURL: root.appendingPathComponent(".codexbar/test-cost-event-ledger.json")
        )
        _ = LocalCostSummaryService(sessionLogStore: sessionStore).load(
            now: ISO8601Parsing.parse("2026-04-05T12:00:00Z") ?? Date()
        )

        let zeroSummary = LocalCostSummary(
            todayCostUSD: 0,
            todayTokens: 0,
            last30DaysCostUSD: 0,
            last30DaysTokens: 0,
            lifetimeCostUSD: 0,
            lifetimeTokens: 0,
            dailyEntries: [],
            updatedAt: ISO8601Parsing.parse("2026-04-20T10:10:00Z")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(
            try encoder.encode(zeroSummary),
            to: CodexPaths.costCacheURL
        )
        let ledgerData = try Data(contentsOf: root.appendingPathComponent(".codexbar/test-cost-event-ledger.json"))
        try CodexPaths.writeSecureFile(ledgerData, to: CodexPaths.costEventLedgerURL)

        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(sessionLogStore: sessionStore),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        let timeout = Date().addingTimeInterval(3)
        while store.localCostSummary.updatedAt == nil && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertNotNil(store.localCostSummary.updatedAt)
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 230)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 230)
        XCTAssertEqual(store.localCostSummary.dailyEntries.count, 1)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].totalTokens, 230)
    }

    func testSaveOpenAIAccountSettingsWritesAccountOrderModeAndManualActivationBehavior() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_beta", email: "beta@example.com"))

        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_beta", "acct_alpha"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .manual,
                manualActivationBehavior: .launchNewInstance
            )
        )

        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_beta", "acct_alpha"])
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .manual)
        XCTAssertEqual(store.config.openAI.manualActivationBehavior, .launchNewInstance)
    }

    func testSavingOnlyGatewayCredentialModeTriggersCodexSyncRewrite() throws {
        try CodexPaths.ensureDirectories()

        let account = try self.makeOAuthAccount(
            accountID: "acct_gateway_credential_sync",
            email: "gateway-credential-sync@example.com"
        )
        let storedAccount = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedAccount.id,
            accounts: [storedAccount]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: storedAccount.id),
                openAI: CodexBarOpenAISettings(
                    accountUsageMode: .aggregateGateway,
                    gatewayCredentialMode: .oauthPassthrough
                ),
                providers: [provider]
            )
        )

        let store = TokenStore(
            syncService: CodexSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerStub(),
            openRouterGatewayService: OpenRouterGatewayControllerStub(),
            openRouterModelCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            ),
            aggregateGatewayLeaseStore: AggregateGatewayLeaseStoreStub(),
            aggregateRouteJournalStore: AggregateRouteJournalStoreStub(),
            codexRunningProcessIDs: { [] }
        )

        let passthroughAuth = try String(contentsOf: CodexPaths.authURL, encoding: .utf8)
        XCTAssertTrue(passthroughAuth.contains(#""auth_mode" : "chatgpt""#))

        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: [],
                accountUsageMode: .aggregateGateway,
                accountOrderingMode: .quotaSort,
                manualActivationBehavior: .updateConfigOnly,
                gatewayCredentialMode: .localAPIKey
            )
        )

        let authObject = try self.readAuthJSON()
        let authText = try String(contentsOf: CodexPaths.authURL, encoding: .utf8)
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        let credentialData = try Data(contentsOf: CodexPaths.openAIGatewayCredentialURL)
        let credential = try JSONDecoder.iso8601.decode(OpenAIGatewayCredentialSnapshot.self, from: credentialData)

        XCTAssertEqual(store.config.openAI.gatewayCredentialMode, .localAPIKey)
        XCTAssertEqual(authObject["OPENAI_API_KEY"] as? String, credential.openAIAPIKey)
        XCTAssertNil(authObject["tokens"])
        XCTAssertFalse(authText.contains(account.accessToken))
        XCTAssertTrue(tomlText.contains(#"openai_base_url = "http://localhost:1456/v1""#))
    }

    func testSaveOpenAIUsageSettingsOnlyTouchesUsageFields() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .manual,
                manualActivationBehavior: .launchNewInstance
            )
        )

        try store.saveOpenAIUsageSettings(
            OpenAIUsageSettingsUpdate(
                usageDisplayMode: .remaining,
                plusRelativeWeight: 6,
                proRelativeToPlusMultiplier: 14,
                teamRelativeToPlusMultiplier: 2
            )
        )

        XCTAssertEqual(store.config.openAI.usageDisplayMode, .remaining)
        XCTAssertEqual(store.config.openAI.quotaSort.plusRelativeWeight, 6)
        XCTAssertEqual(store.config.openAI.quotaSort.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(store.config.openAI.quotaSort.teamRelativeToPlusMultiplier, 2)
        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_alpha"])
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .manual)
        XCTAssertEqual(store.config.openAI.manualActivationBehavior, .launchNewInstance)
    }

    func testSaveDesktopSettingsOnlyTouchesPreferredPath() throws {
        let store = TokenStore.shared
        store.load()
        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: [],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .quotaSort,
                manualActivationBehavior: .launchNewInstance
            )
        )

        let validAppURL = try self.makeValidCodexApp(named: "Test/Codex.app")
        try store.saveDesktopSettings(
            DesktopSettingsUpdate(preferredCodexAppPath: validAppURL.path)
        )

        XCTAssertEqual(store.config.desktop.preferredCodexAppPath, validAppURL.path)
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .quotaSort)
        XCTAssertEqual(store.config.openAI.manualActivationBehavior, .launchNewInstance)
    }

    func testRestoreActiveSelectionPersistsPreviousCompatibleProvider() throws {
        let store = TokenStore.shared
        store.load()

        try store.addCustomProvider(
            label: "Provider A",
            baseURL: "https://a.example.com/v1",
            accountLabel: "Alpha",
            apiKey: "sk-provider-a"
        )
        let providerA = try XCTUnwrap(store.activeProvider)
        let accountA = try XCTUnwrap(store.activeProviderAccount)

        try store.addCustomProvider(
            label: "Provider B",
            baseURL: "https://b.example.com/v1",
            accountLabel: "Beta",
            apiKey: "sk-provider-b"
        )
        XCTAssertEqual(store.activeProvider?.label, "Provider B")

        try store.restoreActiveSelection(
            activeProviderID: providerA.id,
            activeAccountID: accountA.id
        )

        XCTAssertEqual(store.activeProvider?.id, providerA.id)
        XCTAssertEqual(store.activeProviderAccount?.id, accountA.id)
    }

    func testAddCustomProviderNamedOpenRouterAvoidsReservedProviderID() throws {
        let store = TokenStore.shared
        store.load()

        try store.addCustomProvider(
            label: "OpenRouter",
            baseURL: "https://relay.example.com/v1",
            accountLabel: "Relay",
            apiKey: "sk-relay"
        )

        XCTAssertEqual(store.activeProvider?.kind, .openAICompatible)
        XCTAssertEqual(store.activeProvider?.id, "openrouter-custom")
    }

    func testOpenRouterManualModelFallbackWorksWithoutCatalog() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-manual")

        XCTAssertNil(store.openRouterProvider?.openRouterEffectiveModelID)
        XCTAssertTrue(store.openRouterProvider?.cachedModelCatalog.isEmpty ?? true)

        try store.updateOpenRouterSelectedModel("google/gemini-2.5-pro")

        XCTAssertEqual(store.openRouterProvider?.selectedModelID, "google/gemini-2.5-pro")
        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "google/gemini-2.5-pro")
        XCTAssertTrue(store.openRouterProvider?.cachedModelCatalog.isEmpty ?? true)

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.openRouterProvider()?.selectedModelID, "google/gemini-2.5-pro")
    }

    func testOpenRouterPinnedModelsRemainAfterSwitchingCurrentModel() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_500)
        let catalog = [
            CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
            CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        ]

        try store.addOpenRouterProvider(
            apiKey: "sk-or-v1-primary",
            selectedModelID: "openai/gpt-4.1",
            pinnedModelIDs: ["openai/gpt-4.1", "google/gemini-2.5-pro"],
            cachedModelCatalog: catalog,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(store.openRouterProvider?.pinnedModelIDs, ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "openai/gpt-4.1")

        try store.updateOpenRouterSelectedModel("google/gemini-2.5-pro")

        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "google/gemini-2.5-pro")
        XCTAssertEqual(store.openRouterProvider?.pinnedModelIDs, ["openai/gpt-4.1", "google/gemini-2.5-pro"])
        XCTAssertEqual(store.openRouterProvider?.cachedModelCatalog.map(\.id), ["openai/gpt-4.1", "google/gemini-2.5-pro"])
    }

    func testRefreshOpenRouterModelCatalogCachesFetchedModels() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let catalogService = OpenRouterModelCatalogServiceSpy(
            result: .success(
                OpenRouterModelCatalogSnapshot(
                    models: [
                        CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
                        CodexBarOpenRouterModel(id: "openai/gpt-4.1", name: "GPT-4.1"),
                    ],
                    fetchedAt: fetchedAt
                )
            )
        )
        let store = self.makeTokenStore(openRouterCatalogService: catalogService)

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-primary")
        try await store.refreshOpenRouterModelCatalog()

        XCTAssertEqual(catalogService.requestedAPIKeys, ["sk-or-v1-primary"])
        XCTAssertEqual(
            store.openRouterProvider?.cachedModelCatalog.map(\.id),
            ["anthropic/claude-3.7-sonnet", "openai/gpt-4.1"]
        )
        XCTAssertEqual(store.openRouterProvider?.modelCatalogFetchedAt, fetchedAt)

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(
            reloaded.openRouterProvider()?.cachedModelCatalog.map(\.id),
            ["anthropic/claude-3.7-sonnet", "openai/gpt-4.1"]
        )
        XCTAssertEqual(reloaded.openRouterProvider()?.modelCatalogFetchedAt, fetchedAt)
    }

    func testRefreshOpenRouterCatalogFailurePreservesSelectedModelAndCache() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_710_000_100)
        let catalogService = OpenRouterModelCatalogServiceSpy(
            result: .success(
                OpenRouterModelCatalogSnapshot(
                    models: [
                        CodexBarOpenRouterModel(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet"),
                        CodexBarOpenRouterModel(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
                    ],
                    fetchedAt: fetchedAt
                )
            )
        )
        let store = self.makeTokenStore(openRouterCatalogService: catalogService)

        try store.addOpenRouterProvider(accountLabel: "Primary", apiKey: "sk-or-v1-primary")
        try store.updateOpenRouterSelectedModel("anthropic/claude-3.7-sonnet")
        try await store.refreshOpenRouterModelCatalog()

        catalogService.result = .failure(URLError(.notConnectedToInternet))

        do {
            try await store.refreshOpenRouterModelCatalog()
            XCTFail("Expected refresh to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        XCTAssertEqual(store.openRouterProvider?.openRouterEffectiveModelID, "anthropic/claude-3.7-sonnet")
        XCTAssertEqual(
            store.openRouterProvider?.cachedModelCatalog.map(\.id),
            ["anthropic/claude-3.7-sonnet", "google/gemini-2.5-pro"]
        )
        XCTAssertEqual(store.openRouterProvider?.modelCatalogFetchedAt, fetchedAt)
    }

    private func makeValidCodexApp(named relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
        let appURL = root.appendingPathComponent(relativePath)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let executableURL = resourcesURL.appendingPathComponent("codex")
        try Data().write(to: executableURL)
        return appURL
    }

    private func makeTokenStore(
        costSummaryService: LocalCostSummaryService = LocalCostSummaryService(),
        openRouterCatalogService: any OpenRouterModelCatalogFetching
    ) -> TokenStore {
        TokenStore(
            syncService: CodexSyncServiceNoOp(),
            costSummaryService: costSummaryService,
            openAIAccountGatewayService: OpenAIAccountGatewayControllerStub(),
            openRouterGatewayService: OpenRouterGatewayControllerStub(),
            openRouterModelCatalogService: openRouterCatalogService,
            aggregateGatewayLeaseStore: AggregateGatewayLeaseStoreStub(),
            aggregateRouteJournalStore: AggregateRouteJournalStoreStub(),
            codexRunningProcessIDs: { [] }
        )
    }
}

private final class CodexSyncServiceNoOp: CodexSynchronizing {
    func synchronize(config _: CodexBarConfig) throws {}
}

private final class OpenAIAccountGatewayControllerStub: OpenAIAccountGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(
        accounts _: [TokenAccount],
        quotaSortSettings _: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode _: CodexBarOpenAIAccountUsageMode,
        gatewayCredential _: OpenAIAccountGatewayResolvedCredential
    ) {}

    func currentRoutedAccountID() -> String? { nil }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { [] }
    func clearStickyBinding(threadID _: String) -> Bool { false }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class OpenRouterGatewayControllerStub: OpenRouterGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(provider _: CodexBarProvider?, isActiveProvider _: Bool) {}
}

private final class AggregateGatewayLeaseStoreStub: OpenAIAggregateGatewayLeaseStoring {
    func loadProcessIDs() -> Set<pid_t> { [] }
    func saveProcessIDs(_: Set<pid_t>) {}
    func clear() {}
}

private final class AggregateRouteJournalStoreStub: OpenAIAggregateRouteJournalStoring {
    func recordRoute(threadID _: String, accountID _: String, timestamp _: Date) {}
    func routeHistory() -> [OpenAIAggregateRouteRecord] { [] }
}

private final class OpenRouterModelCatalogServiceSpy: OpenRouterModelCatalogFetching {
    var result: Result<OpenRouterModelCatalogSnapshot, Error>
    private(set) var requestedAPIKeys: [String] = []

    init(result: Result<OpenRouterModelCatalogSnapshot, Error>) {
        self.result = result
    }

    func fetchCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot {
        self.requestedAPIKeys.append(apiKey)
        return try self.result.get()
    }
}
