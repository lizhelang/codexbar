import Foundation
import XCTest

@MainActor
final class TokenStoreSettingsTests: CodexBarTestCase {
    func testLoadPreservesNewerInMemoryQuotaWhenDiskFallsBackToDefaults() throws {
        let olderCheckedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let newerCheckedAt = olderCheckedAt.addingTimeInterval(600)
        let accountID = "acct_preserve_newer_quota"
        try self.writeOAuthConfig(
            accountID: accountID,
            primaryUsedPercent: 63,
            secondaryUsedPercent: 27,
            lastChecked: newerCheckedAt
        )
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try self.writeOAuthConfig(
            accountID: accountID,
            primaryUsedPercent: 0,
            secondaryUsedPercent: 0,
            lastChecked: nil
        )

        store.load()

        let loaded = try XCTUnwrap(store.oauthAccount(accountID: accountID))
        XCTAssertEqual(loaded.primaryUsedPercent, 63)
        XCTAssertEqual(loaded.secondaryUsedPercent, 27)
        XCTAssertEqual(loaded.lastChecked, newerCheckedAt)

        let repaired = try XCTUnwrap(CodexBarConfigStore().load().oauthTokenAccounts().first)
        XCTAssertEqual(repaired.primaryUsedPercent, 63)
        XCTAssertEqual(repaired.secondaryUsedPercent, 27)
        XCTAssertEqual(repaired.lastChecked, newerCheckedAt)
    }

    func testLoadAcceptsNewerQuotaSnapshotFromDisk() throws {
        let olderCheckedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let newerCheckedAt = olderCheckedAt.addingTimeInterval(600)
        let accountID = "acct_accept_newer_disk_quota"
        try self.writeOAuthConfig(
            accountID: accountID,
            primaryUsedPercent: 63,
            secondaryUsedPercent: 27,
            lastChecked: olderCheckedAt
        )
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try self.writeOAuthConfig(
            accountID: accountID,
            primaryUsedPercent: 41,
            secondaryUsedPercent: 19,
            lastChecked: newerCheckedAt
        )

        store.load()

        let loaded = try XCTUnwrap(store.oauthAccount(accountID: accountID))
        XCTAssertEqual(loaded.primaryUsedPercent, 41)
        XCTAssertEqual(loaded.secondaryUsedPercent, 19)
        XCTAssertEqual(loaded.lastChecked, newerCheckedAt)
    }

    func testReasoningEffortOptionsFollowGPT56ModelCapabilities() {
        XCTAssertEqual(
            CodexBarGlobalSettings.reasoningEffortOptions(for: "gpt-5.6-sol"),
            ["low", "medium", "high", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(
            CodexBarGlobalSettings.reasoningEffortOptions(for: "gpt-5.6-terra"),
            ["low", "medium", "high", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(
            CodexBarGlobalSettings.reasoningEffortOptions(for: "gpt-5.6-luna"),
            ["low", "medium", "high", "xhigh", "max"]
        )
    }

    func testReasoningEffortOptionsPreserveUnknownCurrentValue() {
        XCTAssertEqual(
            CodexBarGlobalSettings.reasoningEffortOptions(
                for: "future-model",
                currentValue: "future-effort"
            ),
            ["low", "medium", "high", "xhigh", "future-effort"]
        )
    }

    func testInitializationRebuildsLocalCostSummaryWhenCacheIsMissing() throws {
        let fixture = Self.recentCostFixtureTimestamps()
        let sessionDirectory = CodexPaths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("cost-rebuild.jsonl")
        let content = [
            #"{"payload":{"type":"session_meta","id":"cost-rebuild","timestamp":"\#(fixture.sessionStartedAt)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            #"{"timestamp":"\#(fixture.firstUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            #"{"timestamp":"\#(fixture.secondUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
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
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 200)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 200)
        XCTAssertEqual(store.localCostSummary.last30DaysCostUSD, 0.001615, accuracy: 1e-12)
        XCTAssertEqual(store.localCostSummary.lifetimeCostUSD, 0.001615, accuracy: 1e-12)
        XCTAssertEqual(store.localCostSummary.dailyEntries.count, 1)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].totalTokens, 200)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].costUSD, 0.001615, accuracy: 1e-12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.costCacheURL.path))
    }

    func testInitializationRebuildsLocalCostSummaryWhenCachedSchemaIsLegacy() throws {
        let fixture = Self.recentCostFixtureTimestamps()
        let sessionDirectory = CodexPaths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("cost-legacy-cache.jsonl")
        let content = [
            #"{"payload":{"type":"session_meta","id":"cost-legacy-cache","timestamp":"\#(fixture.sessionStartedAt)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            #"{"timestamp":"\#(fixture.firstUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            #"{"timestamp":"\#(fixture.secondUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let legacyCache = """
        {
          "todayCostUSD": 659,
          "todayTokens": 3710000,
          "last30DaysCostUSD": 19906.99,
          "last30DaysTokens": 20190000000,
          "lifetimeCostUSD": 22684.09,
          "lifetimeTokens": 23290000000,
          "dailyEntries": [
            {
              "id": "2026-06-01T00:00:00Z",
              "date": "2026-06-01T00:00:00Z",
              "costUSD": 17329.25,
              "totalTokens": 17970000000
            }
          ],
          "updatedAt": "2026-06-17T04:27:52Z"
        }
        """
        try CodexPaths.writeSecureFile(Data(legacyCache.utf8), to: CodexPaths.costCacheURL)

        let sessionStore = SessionLogStore(
            codexRootURL: CodexPaths.codexRoot,
            persistedCacheURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-cost-session-cache.json"),
            persistedUsageLedgerURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(".codexbar/test-cost-event-ledger.json")
        )
        let refreshGate = NSCondition()
        var mayRefresh = false
        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(
                sessionLogStoreProvider: {
                    refreshGate.lock()
                    while mayRefresh == false {
                        refreshGate.wait()
                    }
                    refreshGate.unlock()
                    return sessionStore
                }
            ),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertEqual(store.localCostSummary.schemaVersion, 0)
        XCTAssertNil(store.localCostSummary.updatedAt)
        XCTAssertEqual(store.localCostSummary.todayTokens, 3_710_000)
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 20_190_000_000)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 23_290_000_000)
        XCTAssertEqual(store.localCostSummary.dailyEntries.count, 1)

        refreshGate.lock()
        mayRefresh = true
        refreshGate.broadcast()
        refreshGate.unlock()

        let timeout = Date().addingTimeInterval(3)
        while store.localCostSummary.last30DaysTokens != 200 && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(store.localCostSummary.schemaVersion, LocalCostSummary.currentSchemaVersion)
        XCTAssertEqual(store.localCostSummary.todayTokens, 0)
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 200)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 200)
        XCTAssertEqual(store.localCostSummary.last30DaysCostUSD, 0.001615, accuracy: 1e-12)
        XCTAssertEqual(store.localCostSummary.lifetimeCostUSD, 0.001615, accuracy: 1e-12)
        XCTAssertEqual(store.localCostSummary.dailyEntries.count, 1)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].totalTokens, 200)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].costUSD, 0.001615, accuracy: 1e-12)
    }

    func testInitializationPreservesLegacyCostSummaryWhenRebuildIsIncomplete() throws {
        try self.writeCostSummaryCache(schemaVersion: nil, updatedAt: "2026-06-17T04:27:52Z")
        let fixture = Self.recentCostFixtureTimestamps()
        let sessionDirectory = CodexPaths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let validContent = [
            #"{"payload":{"type":"session_meta","id":"partial-valid","timestamp":"\#(fixture.sessionStartedAt)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            #"{"timestamp":"\#(fixture.firstUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
        ].joined(separator: "\n") + "\n"
        try validContent.write(
            to: sessionDirectory.appendingPathComponent("partial-valid.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"type":"session_meta","payload":{"id":"partial-invalid"}}"#.write(
            to: sessionDirectory.appendingPathComponent("partial-invalid.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let sessionStore = SessionLogStore(
            codexRootURL: CodexPaths.codexRoot,
            persistedCacheURL: CodexPaths.costCacheURL.deletingLastPathComponent()
                .appendingPathComponent("empty-session-cache.json"),
            persistedUsageLedgerURL: CodexPaths.costCacheURL.deletingLastPathComponent()
                .appendingPathComponent("empty-event-ledger.json")
        )
        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(sessionLogStore: sessionStore),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(store.localCostSummary.schemaVersion, 0)
        XCTAssertNil(store.localCostSummary.updatedAt)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 23_290_000_000)

        let cachedData = try Data(contentsOf: CodexPaths.costCacheURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cachedSummary = try decoder.decode(LocalCostSummary.self, from: cachedData)
        XCTAssertEqual(cachedSummary.schemaVersion, 0)
        XCTAssertEqual(cachedSummary.lifetimeTokens, 23_290_000_000)
        XCTAssertNotNil(cachedSummary.updatedAt)
    }

    func testFutureCostSummaryIsNotRebuiltOrOverwrittenByOlderApp() throws {
        let futureSchemaVersion = LocalCostSummary.currentSchemaVersion + 1
        let sessionStore = SessionLogStore(
            codexRootURL: CodexPaths.codexRoot,
            persistedCacheURL: CodexPaths.costCacheURL.deletingLastPathComponent()
                .appendingPathComponent("future-session-cache.json"),
            persistedUsageLedgerURL: CodexPaths.costCacheURL.deletingLastPathComponent()
                .appendingPathComponent("future-event-ledger.json")
        )
        let refreshGate = NSCondition()
        var startedLoadCount = 0
        var mayFinishLoading = false
        let store = self.makeTokenStore(
            costSummaryService: LocalCostSummaryService(
                sessionLogStoreProvider: {
                    refreshGate.lock()
                    startedLoadCount += 1
                    refreshGate.broadcast()
                    while mayFinishLoading == false {
                        refreshGate.wait()
                    }
                    refreshGate.unlock()
                    return sessionStore
                }
            ),
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        refreshGate.lock()
        let loadDeadline = Date().addingTimeInterval(1)
        while startedLoadCount < 2, Date() < loadDeadline {
            refreshGate.wait(until: loadDeadline)
        }
        refreshGate.unlock()

        try self.writeCostSummaryCache(schemaVersion: futureSchemaVersion, updatedAt: nil)
        store.load()
        store.refreshLocalCostSummary(force: true, minimumInterval: 0, refreshSessionCache: true)

        refreshGate.lock()
        mayFinishLoading = true
        refreshGate.broadcast()
        refreshGate.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(store.localCostSummary.schemaVersion, futureSchemaVersion)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 23_290_000_000)

        let cachedData = try Data(contentsOf: CodexPaths.costCacheURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cachedSummary = try decoder.decode(LocalCostSummary.self, from: cachedData)
        XCTAssertEqual(cachedSummary.schemaVersion, futureSchemaVersion)
        XCTAssertEqual(cachedSummary.lifetimeTokens, 23_290_000_000)
    }

    func testInitializationSeedsHistoricalModelsFromConfigUntilExplicitRefresh() throws {
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
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
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
        store.refreshHistoricalModels()

        let timeout = Date().addingTimeInterval(3)
        while Set(store.historicalModels) != Set(["google/gemini-2.5-pro", "gpt-5.5"]) && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(Set(store.historicalModels), Set(["google/gemini-2.5-pro", "gpt-5.5"]))
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
                    "gpt-5.5": CodexBarModelPricing(
                        inputUSDPerToken: 9.9e-6,
                        cachedInputUSDPerToken: 9.9e-7,
                        outputUSDPerToken: 2.4e-5
                    ),
                ],
                removals: []
            )
        )

        XCTAssertEqual(
            store.config.modelPricing["gpt-5.5"],
            CodexBarModelPricing(
                inputUSDPerToken: 9.9e-6,
                cachedInputUSDPerToken: 9.9e-7,
                outputUSDPerToken: 2.4e-5
            )
        )

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(
            reloaded.modelPricing["gpt-5.5"],
            CodexBarModelPricing(
                inputUSDPerToken: 9.9e-6,
                cachedInputUSDPerToken: 9.9e-7,
                outputUSDPerToken: 2.4e-5
            )
        )
    }

    func testSaveGlobalSettingsPersistsAcrossReload() throws {
        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.saveGlobalSettings(
            GlobalSettingsUpdate(
                defaultModel: "gpt-5.5-mini",
                reviewModel: "gpt-5.5-mini",
                reasoningEffort: "medium",
                serviceTier: "fast"
            )
        )

        XCTAssertEqual(store.config.global.defaultModel, "gpt-5.5-mini")
        XCTAssertEqual(store.config.global.reviewModel, "gpt-5.5-mini")
        XCTAssertEqual(store.config.global.reasoningEffort, "medium")
        XCTAssertEqual(store.config.global.serviceTier, "fast")

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.global.defaultModel, "gpt-5.5-mini")
        XCTAssertEqual(reloaded.global.reviewModel, "gpt-5.5-mini")
        XCTAssertEqual(reloaded.global.reasoningEffort, "medium")
        XCTAssertEqual(reloaded.global.serviceTier, "fast")
    }

    func testUpdateReasoningEffortPreservesModels() throws {
        var config = CodexBarConfig()
        config.global = CodexBarGlobalSettings(
            defaultModel: "gpt-5.5-mini",
            reviewModel: "gpt-5.5-mini",
            reasoningEffort: "medium",
            serviceTier: "flex"
        )
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.updateReasoningEffort("high")

        XCTAssertEqual(store.config.global.defaultModel, "gpt-5.5-mini")
        XCTAssertEqual(store.config.global.reviewModel, "gpt-5.5-mini")
        XCTAssertEqual(store.config.global.reasoningEffort, "high")
        XCTAssertEqual(store.config.global.serviceTier, "flex")

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.global.defaultModel, "gpt-5.5-mini")
        XCTAssertEqual(reloaded.global.reviewModel, "gpt-5.5-mini")
        XCTAssertEqual(reloaded.global.reasoningEffort, "high")
        XCTAssertEqual(reloaded.global.serviceTier, "flex")
    }

    func testSwitchingFromUltraToLunaFallsBackToMax() throws {
        var config = CodexBarConfig()
        config.global = CodexBarGlobalSettings(
            defaultModel: "gpt-5.6-terra",
            reviewModel: "gpt-5.6-terra",
            reasoningEffort: "ultra",
            serviceTier: "flex"
        )
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.updateRouteModel("gpt-5.6-luna")

        XCTAssertEqual(store.config.global.defaultModel, "gpt-5.6-luna")
        XCTAssertEqual(store.config.global.reviewModel, "gpt-5.6-luna")
        XCTAssertEqual(store.config.global.reasoningEffort, "max")

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.global.defaultModel, "gpt-5.6-luna")
        XCTAssertEqual(reloaded.global.reasoningEffort, "max")
    }

    func testLunaRejectsUnsupportedUltraReasoningEffort() throws {
        var config = CodexBarConfig()
        config.global = CodexBarGlobalSettings(
            defaultModel: "gpt-5.6-luna",
            reviewModel: "gpt-5.6-luna",
            reasoningEffort: "max",
            serviceTier: "flex"
        )
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        XCTAssertThrowsError(try store.updateReasoningEffort("ultra"))
        XCTAssertEqual(store.config.global.reasoningEffort, "max")
    }

    func testCompatibleProviderUsesItsRouteModelForReasoningEffort() throws {
        var config = CodexBarConfig()
        config.global = CodexBarGlobalSettings(
            defaultModel: "gpt-5.6-luna",
            reviewModel: "gpt-5.6-luna",
            reasoningEffort: "max",
            serviceTier: "flex"
        )
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )
        try store.addCompatibleProvider(
            label: "Route Model",
            baseURL: "https://route.example.com/v1",
            accountLabel: "Primary",
            apiKey: "sk-route-model",
            wireAPI: .responses,
            presetID: nil,
            model: "gpt-5.6-sol"
        )

        try store.updateReasoningEffort("ultra")

        XCTAssertEqual(store.config.global.defaultModel, "gpt-5.6-luna")
        XCTAssertEqual(store.activeModel, "gpt-5.6-sol")
        XCTAssertEqual(store.config.global.reasoningEffort, "ultra")

        try store.updateRouteModel("gpt-5.6-luna")

        XCTAssertEqual(store.activeModel, "gpt-5.6-luna")
        XCTAssertEqual(store.config.global.reasoningEffort, "max")

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.activeProvider()?.defaultModel, "gpt-5.6-luna")
        XCTAssertEqual(reloaded.global.reasoningEffort, "max")
    }

    func testUpdateServiceTierPreservesModelsAndReasoningEffort() throws {
        var config = CodexBarConfig()
        config.global = CodexBarGlobalSettings(
            defaultModel: "gpt-5.5-mini",
            reviewModel: "gpt-5.5-mini",
            reasoningEffort: "high",
            serviceTier: "flex"
        )
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.updateServiceTier("fast")

        XCTAssertEqual(store.config.global.defaultModel, "gpt-5.5-mini")
        XCTAssertEqual(store.config.global.reviewModel, "gpt-5.5-mini")
        XCTAssertEqual(store.config.global.reasoningEffort, "high")
        XCTAssertEqual(store.config.global.serviceTier, "fast")

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.global.defaultModel, "gpt-5.5-mini")
        XCTAssertEqual(reloaded.global.reviewModel, "gpt-5.5-mini")
        XCTAssertEqual(reloaded.global.reasoningEffort, "high")
        XCTAssertEqual(reloaded.global.serviceTier, "fast")
    }

    func testUpdateModelContextWindowPersistsPerModelOverrides() throws {
        var config = CodexBarConfig()
        config.global = CodexBarGlobalSettings(
            defaultModel: "gpt-5.5",
            reviewModel: "gpt-5.5",
            reasoningEffort: "high",
            serviceTier: "flex",
            modelContextWindows: ["gpt-5.4": 1_000_000]
        )
        try self.writeConfig(config)

        let store = self.makeTokenStore(
            openRouterCatalogService: OpenRouterModelCatalogServiceSpy(
                result: .failure(URLError(.notConnectedToInternet))
            )
        )

        try store.updateModelContextWindow(512_000, for: "gpt-5.5")

        XCTAssertEqual(store.config.global.modelContextWindows["gpt-5.5"], 512_000)
        XCTAssertEqual(store.config.global.modelContextWindows["gpt-5.4"], 1_000_000)

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.global.modelContextWindows["gpt-5.5"], 512_000)
        XCTAssertEqual(reloaded.global.modelContextWindows["gpt-5.4"], 1_000_000)

        try store.updateModelContextWindow(nil, for: "gpt-5.5")

        XCTAssertNil(store.config.global.modelContextWindows["gpt-5.5"])
        XCTAssertEqual(store.config.global.modelContextWindows["gpt-5.4"], 1_000_000)
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
                    "gpt-5.5": CodexBarModelPricing(
                        inputUSDPerToken: .infinity,
                        cachedInputUSDPerToken: -1,
                        outputUSDPerToken: 2.4e-5
                    ),
                ],
                removals: []
            )
        )

        XCTAssertEqual(
            store.config.modelPricing["gpt-5.5"],
            CodexBarModelPricing(
                inputUSDPerToken: 0,
                cachedInputUSDPerToken: 0,
                outputUSDPerToken: 2.4e-5
            )
        )
    }

    func testInitializationRebuildsLocalCostSummaryWhenCachedSummaryIsZeroButLedgerExists() throws {
        let fixture = Self.recentCostFixtureTimestamps()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEXBAR_HOME"] ?? NSTemporaryDirectory())
        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        let sessionDirectory = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sessionURL = sessionDirectory.appendingPathComponent("cost-zero-cache.jsonl")
        let content = [
            #"{"payload":{"type":"session_meta","id":"cost-zero-cache","timestamp":"\#(fixture.sessionStartedAt)"}}"#,
            #"{"payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            #"{"timestamp":"\#(fixture.firstUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":20}}}}"#,
            #"{"timestamp":"\#(fixture.secondUsageAt)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":30,"output_tokens":30},"last_token_usage":{"input_tokens":70,"cached_input_tokens":10,"output_tokens":10}}}}"#,
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
        XCTAssertEqual(store.localCostSummary.last30DaysTokens, 200)
        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 200)
        XCTAssertEqual(store.localCostSummary.dailyEntries.count, 1)
        XCTAssertEqual(store.localCostSummary.dailyEntries[0].totalTokens, 200)
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
                manualActivationBehavior: .launchNewInstance,
                remoteConnectionAccountID: nil,
                hybridTargetSelection: nil
            )
        )

        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_beta", "acct_alpha"])
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .manual)
        XCTAssertEqual(store.config.openAI.manualActivationBehavior, .updateConfigOnly)
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
                manualActivationBehavior: .launchNewInstance,
                remoteConnectionAccountID: nil,
                hybridTargetSelection: nil
            )
        )

        try store.saveOpenAIUsageSettings(
            OpenAIUsageSettingsUpdate(
                usageDisplayMode: .remaining,
                showsMenuBarUsageText: true,
                plusRelativeWeight: 6,
                proRelativeToPlusMultiplier: 14,
                teamRelativeToPlusMultiplier: 2
            )
        )

        XCTAssertEqual(store.config.openAI.usageDisplayMode, .remaining)
        XCTAssertTrue(store.config.openAI.showsMenuBarUsageText)
        XCTAssertEqual(store.config.openAI.quotaSort.plusRelativeWeight, 6)
        XCTAssertEqual(store.config.openAI.quotaSort.proRelativeToPlusMultiplier, 14)
        XCTAssertEqual(store.config.openAI.quotaSort.teamRelativeToPlusMultiplier, 2)
        XCTAssertEqual(store.config.openAI.accountOrder, ["acct_alpha"])
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .manual)
        XCTAssertEqual(store.config.openAI.manualActivationBehavior, .updateConfigOnly)
    }

    func testSaveDesktopSettingsOnlyTouchesPreferredPath() throws {
        let store = TokenStore.shared
        store.load()
        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: [],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .quotaSort,
                manualActivationBehavior: .launchNewInstance,
                remoteConnectionAccountID: nil,
                hybridTargetSelection: nil
            )
        )

        let validAppURL = try self.makeValidCodexApp(named: "Test/Codex.app")
        try store.saveDesktopSettings(
            DesktopSettingsUpdate(preferredCodexAppPath: validAppURL.path)
        )

        XCTAssertEqual(store.config.desktop.preferredCodexAppPath, validAppURL.path)
        XCTAssertEqual(store.config.openAI.accountOrderingMode, .quotaSort)
        XCTAssertEqual(store.config.openAI.manualActivationBehavior, .updateConfigOnly)
    }

    func testSaveOpenAIAccountSettingsPersistsRemoteConnectionAccountID() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_beta", email: "beta@example.com"))

        try store.saveOpenAIAccountSettings(
            OpenAIAccountSettingsUpdate(
                accountOrder: ["acct_alpha", "acct_beta"],
                accountUsageMode: .switchAccount,
                accountOrderingMode: .quotaSort,
                manualActivationBehavior: .updateConfigOnly,
                remoteConnectionAccountID: "acct_beta",
                hybridTargetSelection: nil
            )
        )

        XCTAssertEqual(store.config.openAI.remoteConnectionAccountID, "acct_beta")
        XCTAssertEqual(store.remoteConnectionAccount?.accountId, "acct_beta")

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.openAI.remoteConnectionAccountID, "acct_beta")
    }

    func testImportRemoteConnectionAccountPersistsTokensWithoutAddingMainAccount() throws {
        let store = TokenStore.shared
        store.load()
        store.addOrUpdate(try self.makeOAuthAccount(accountID: "acct_alpha", email: "alpha@example.com"))
        let remoteOnly = try self.makeOAuthAccount(
            accountID: "remote_only_local",
            email: "remote@example.com",
            refreshToken: "refresh-remote-only",
            remoteAccountID: "remote_openai_account"
        )

        let stored = try store.importRemoteConnectionAccount(remoteOnly)

        XCTAssertEqual(stored.accountId, "remote_only_local")
        XCTAssertEqual(store.config.openAI.remoteConnectionAccountID, "remote_only_local")
        XCTAssertEqual(store.remoteConnectionAccount?.remoteAccountId, "remote_openai_account")
        XCTAssertEqual(store.remoteConnectionAccounts.map(\.accountId), ["remote_only_local"])
        XCTAssertEqual(store.config.oauthTokenAccounts().map(\.accountId), ["acct_alpha"])

        let reloaded = try CodexBarConfigStore().loadOrMigrate()
        XCTAssertEqual(reloaded.openAI.remoteConnectionAccountID, "remote_only_local")
        XCTAssertEqual(reloaded.remoteConnectionAccount()?.openAIAccountId, "remote_openai_account")
        XCTAssertEqual(reloaded.remoteConnectionTokenAccounts().map(\.accountId), ["remote_only_local"])
        XCTAssertEqual(reloaded.oauthTokenAccounts().map(\.accountId), ["acct_alpha"])
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

    private func writeCostSummaryCache(schemaVersion: Int?, updatedAt: String?) throws {
        var summary: [String: Any] = [
            "todayCostUSD": 659.0,
            "todayTokens": 3_710_000,
            "last30DaysCostUSD": 19_906.99,
            "last30DaysTokens": 20_190_000_000,
            "lifetimeCostUSD": 22_684.09,
            "lifetimeTokens": 23_290_000_000,
            "dailyEntries": [[
                "id": "2026-06-01T00:00:00Z",
                "date": "2026-06-01T00:00:00Z",
                "costUSD": 17_329.25,
                "totalTokens": 17_970_000_000,
            ]],
        ]
        if let schemaVersion {
            summary["schemaVersion"] = schemaVersion
        }
        if let updatedAt {
            summary["updatedAt"] = updatedAt
        }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        try CodexPaths.writeSecureFile(data, to: CodexPaths.costCacheURL)
    }

    private func writeOAuthConfig(
        accountID: String,
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double,
        lastChecked: Date?
    ) throws {
        var account = try self.makeOAuthAccount(
            accountID: accountID,
            email: "quota-cache@example.com"
        )
        account.planType = "team"
        account.primaryUsedPercent = primaryUsedPercent
        account.secondaryUsedPercent = secondaryUsedPercent
        let resetAnchor = lastChecked ?? Date(timeIntervalSince1970: 1_800_000_000)
        account.primaryResetAt = resetAnchor.addingTimeInterval(18_000)
        account.secondaryResetAt = resetAnchor.addingTimeInterval(604_800)
        account.primaryLimitWindowSeconds = 18_000
        account.secondaryLimitWindowSeconds = 604_800
        account.lastChecked = lastChecked
        let stored = CodexBarProviderAccount.fromTokenAccount(account, existingID: accountID)
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: accountID,
            accounts: [stored]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: accountID),
                providers: [provider]
            )
        )
    }

    private static func recentCostFixtureTimestamps() -> (
        sessionStartedAt: String,
        firstUsageAt: String,
        secondUsageAt: String
    ) {
        let calendar = Calendar.current
        let yesterdayStart = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: Date())
        ) ?? Date().addingTimeInterval(-86_400)
        let formatter = ISO8601DateFormatter()
        return (
            formatter.string(from: yesterdayStart.addingTimeInterval(8 * 60 * 60)),
            formatter.string(from: yesterdayStart.addingTimeInterval(8 * 60 * 60 + 5 * 60)),
            formatter.string(from: yesterdayStart.addingTimeInterval(9 * 60 * 60 + 10 * 60))
        )
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
        defaultProxy _: OpenAIAccountGatewayConfiguredProxy?,
        proxyByAccountID _: [String: OpenAIAccountGatewayConfiguredProxy]
    ) {}

    func currentRoutedAccountID() -> String? { nil }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { [] }
    func clearStickyBinding(threadID _: String) -> Bool { false }
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
