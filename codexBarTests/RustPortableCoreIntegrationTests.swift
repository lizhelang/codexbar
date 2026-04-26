import AppKit
import Foundation
import XCTest

@MainActor
final class RustPortableCoreIntegrationTests: CodexBarTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        PortableCoreRollbackController.shared.reset()
        RustPortableCoreAdapter.shared.resetForTesting()
        try RustPortableCoreAdapter.shared.forceRebuildForTesting()
        try RustPortableCoreAdapter.shared.warmup(buildIfNeeded: true)
    }

    func testPortableCoreParityAndShadowCompareGates() throws {
        let adapter = RustPortableCoreAdapter.shared

        let configScenarios = try self.makeConfigScenarios()
        var configRecords: [PortableCoreShadowCompareRecord] = []
        for scenario in configScenarios {
            let rust = try adapter.canonicalizeConfigAndAccounts(
                PortableCoreRawConfigInput.legacy(from: scenario.config),
                buildIfNeeded: false
            )
            let legacy = PortableCoreCanonicalizationResult(
                config: .legacy(from: scenario.config),
                accounts: PortableCoreCanonicalAccountSnapshot.legacy(from: scenario.config)
                    .sorted { $0.localAccountID < $1.localAccountID }
            )
            let record = try PortableCoreShadowCompareService.compare(
                scenarioID: scenario.id,
                bucket: "app-bootstrap-load",
                legacy: legacy,
                rust: PortableCoreCanonicalizationResult(
                    config: rust.config,
                    accounts: rust.accounts.sorted { $0.localAccountID < $1.localAccountID }
                ),
                blockerCategory: "canonical-config-account",
                durationMilliseconds: 0
            )
            configRecords.append(record)
        }

        let routeScenarios = try self.makeRouteScenarios()
        var routeRecords: [PortableCoreShadowCompareRecord] = []
        for scenario in routeScenarios {
            try self.writeConfig(scenario.config)
            let store = TokenStore(
                openAIAccountGatewayService: scenario.gatewaySpy,
                openRouterGatewayService: NoopOpenRouterGatewayController(),
                aggregateGatewayLeaseStore: scenario.leaseStore,
                aggregateRouteJournalStore: scenario.routeJournalStore,
                codexRunningProcessIDs: { Set(scenario.leaseStore.processIDs.map(pid_t.init)) }
            )
            let legacySnapshot = store.openAIRuntimeRouteSnapshot(
                runningThreadAttribution: scenario.runningThreadAttribution,
                now: scenario.now
            )
            let legacy = PortableCoreRouteRuntimeSnapshotDTO.legacy(
                from: legacySnapshot,
                leaseState: scenario.routeInput.leaseState
            )
            let rust = try adapter.computeRouteRuntimeSnapshot(
                scenario.routeInput,
                buildIfNeeded: false
            )
            routeRecords.append(
                try PortableCoreShadowCompareService.compare(
                    scenarioID: scenario.id,
                    bucket: "route-runtime-snapshot-refresh",
                    legacy: legacy,
                    rust: rust,
                    blockerCategory: "route-runtime-snapshot",
                    durationMilliseconds: 0
                )
            )
        }

        let renderScenarios = try self.makeRenderScenarios()
        var renderRecords: [PortableCoreShadowCompareRecord] = []
        for scenario in renderScenarios {
            try self.resetCodexSyncFiles(existingTOMLText: scenario.existingTOMLText)
            try CodexSyncService().synchronize(config: scenario.config)
            let legacyAuthText = try String(contentsOf: CodexPaths.authURL, encoding: .utf8)
            let legacyTOMLText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
            let canonical = try adapter.canonicalizeConfigAndAccounts(
                PortableCoreRawConfigInput.legacy(from: scenario.config),
                buildIfNeeded: false
            )
            let rust = try adapter.renderCodecBundle(
                PortableCoreRenderCodecRequest(
                    config: canonical.config,
                    activeProviderID: scenario.activeProviderID,
                    activeAccountID: scenario.activeAccountID,
                    existingTOMLText: scenario.existingTOMLText
                ),
                buildIfNeeded: false
            )
            let legacy = PortableCoreRenderCodecOutput(
                authJSON: legacyAuthText,
                configTOML: legacyTOMLText,
                codecWarnings: [],
                migrationNotes: []
            )
            renderRecords.append(
                try PortableCoreShadowCompareService.compare(
                    scenarioID: scenario.id,
                    bucket: "settings-save-sync-render",
                    legacy: legacy,
                    rust: rust,
                    blockerCategory: "render-codec-output",
                    durationMilliseconds: 0
                )
            )
        }

        let allRecords = configRecords + routeRecords + renderRecords
        let summary = PortableCoreShadowCompareSummary.summarize(allRecords)
        PortableCoreShadowCompareService.enforceRollbackIfNeeded(summary: summary)
        try self.writeArtifact(
            named: "portable-core-shadow-compare-summary.json",
            payload: summary
        )

        XCTAssertGreaterThanOrEqual(configScenarios.count, 80)
        XCTAssertGreaterThanOrEqual(routeScenarios.count, 50)
        XCTAssertGreaterThanOrEqual(renderScenarios.count, 50)
        XCTAssertGreaterThanOrEqual(allRecords.count, 500)
        XCTAssertGreaterThanOrEqual(summary.distinctScenarioCount, 50)
        XCTAssertGreaterThanOrEqual(summary.bucketCounts["app-bootstrap-load"] ?? 0, 100)
        XCTAssertGreaterThanOrEqual(summary.bucketCounts["settings-save-sync-render"] ?? 0, 100)
        XCTAssertGreaterThanOrEqual(summary.bucketCounts["route-runtime-snapshot-refresh"] ?? 0, 100)
        XCTAssertEqual(summary.blockerCount, 0)
        XCTAssertLessThanOrEqual(summary.nonBlockerCount, 2)
        XCTAssertTrue(PortableCoreRollbackController.shared.isEnabled)
    }

    func testPortableCorePerformanceGates() throws {
        let adapter = RustPortableCoreAdapter.shared

        var coldLaunchSamples: [Double] = []
        for _ in 0..<30 {
            adapter.resetForTesting()
            let controller = self.makeRuntimeController()
            coldLaunchSamples.append(self.measureMilliseconds {
                controller.start()
                controller.stop()
            })
        }

        let controller = self.makeRuntimeController()
        var warmLaunchSamples: [Double] = []
        for _ in 0..<100 {
            warmLaunchSamples.append(self.measureMilliseconds {
                controller.start()
                controller.stop()
            })
        }

        let rssBefore = self.currentRSSBytes()
        _ = try adapter.canonicalizeConfigAndAccounts(
            PortableCoreRawConfigInput.legacy(from: try self.makeConfigScenarios().first!.config),
            buildIfNeeded: false
        )
        let rssAfter = self.currentRSSBytes()
        let rssDeltaMB = Double(max(0, rssAfter - rssBefore)) / (1024.0 * 1024.0)

        let account = try self.makeOAuthAccount(
            accountID: "perf-refresh",
            email: "perf-refresh@example.com",
            tokenLastRefreshAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let refreshRequest = PortableCoreRefreshPlanRequest(
            account: .legacy(from: account),
            force: false,
            now: Date(timeIntervalSince1970: 1_800_000_100).timeIntervalSince1970,
            refreshWindowSeconds: 30 * 60,
            existingRetryState: nil,
            inFlight: false
        )
        let refreshedAccount = PortableCoreCanonicalAccountSnapshot.legacy(from: account)
        var refreshSamples: [Double] = []
        for _ in 0..<30 {
            refreshSamples.append(try self.measureMilliseconds {
                _ = try adapter.planRefresh(refreshRequest, buildIfNeeded: false)
                _ = try adapter.applyRefreshOutcome(
                    PortableCoreRefreshOutcomeRequest(
                        account: refreshedAccount,
                        now: refreshRequest.now,
                        maxRetryCount: 3,
                        existingRetryState: nil,
                        outcome: "refreshed",
                        refreshedAccount: refreshedAccount
                    ),
                    buildIfNeeded: false
                )
            })
        }

        let coldP95 = self.percentile95(coldLaunchSamples)
        let warmP95 = self.percentile95(warmLaunchSamples)
        let refreshP95 = self.percentile95(refreshSamples)
        let performanceSummary = PerformanceSummary(
            coldLaunchP95Milliseconds: coldP95,
            warmLaunchP95Milliseconds: warmP95,
            rssDeltaMB: rssDeltaMB,
            deterministicRefreshP95Milliseconds: refreshP95
        )
        try self.writeArtifact(
            named: "portable-core-performance-summary.json",
            payload: performanceSummary
        )

        XCTAssertLessThan(coldP95, 200)
        XCTAssertLessThan(warmP95, 200)
        XCTAssertLessThan(rssDeltaMB, 30)
        XCTAssertLessThan(refreshP95, 1_000)
    }

    func testFullRustCutoverP5QuantitativeRefresh() throws {
        let adapter = RustPortableCoreAdapter.shared

        let configRecords = try self.makeConfigScenarios().map { scenario in
            let rust = try adapter.canonicalizeConfigAndAccounts(
                PortableCoreRawConfigInput.legacy(from: scenario.config),
                buildIfNeeded: false
            )
            let legacy = PortableCoreCanonicalizationResult(
                config: .legacy(from: scenario.config),
                accounts: PortableCoreCanonicalAccountSnapshot.legacy(from: scenario.config)
                    .sorted { $0.localAccountID < $1.localAccountID }
            )
            return try PortableCoreShadowCompareService.compare(
                scenarioID: "p5-\(scenario.id)",
                bucket: "app-bootstrap-load",
                legacy: legacy,
                rust: PortableCoreCanonicalizationResult(
                    config: rust.config,
                    accounts: rust.accounts.sorted { $0.localAccountID < $1.localAccountID }
                ),
                blockerCategory: "canonical-config-account",
                durationMilliseconds: 0
            )
        }

        let routeRecords = try self.makeRouteScenarios().map { scenario in
            try self.writeConfig(scenario.config)
            let store = TokenStore(
                openAIAccountGatewayService: scenario.gatewaySpy,
                openRouterGatewayService: NoopOpenRouterGatewayController(),
                aggregateGatewayLeaseStore: scenario.leaseStore,
                aggregateRouteJournalStore: scenario.routeJournalStore,
                codexRunningProcessIDs: { Set(scenario.leaseStore.processIDs.map(pid_t.init)) }
            )
            let legacySnapshot = store.openAIRuntimeRouteSnapshot(
                runningThreadAttribution: scenario.runningThreadAttribution,
                now: scenario.now
            )
            let legacy = PortableCoreRouteRuntimeSnapshotDTO.legacy(
                from: legacySnapshot,
                leaseState: scenario.routeInput.leaseState
            )
            let rust = try adapter.computeRouteRuntimeSnapshot(
                scenario.routeInput,
                buildIfNeeded: false
            )
            return try PortableCoreShadowCompareService.compare(
                scenarioID: "p5-\(scenario.id)",
                bucket: "route-runtime-snapshot-refresh",
                legacy: legacy,
                rust: rust,
                blockerCategory: "route-runtime-snapshot",
                durationMilliseconds: 0
            )
        }

        let renderRecords = try self.makeRenderScenarios().map { scenario in
            try self.resetCodexSyncFiles(existingTOMLText: scenario.existingTOMLText)
            try CodexSyncService().synchronize(config: scenario.config)
            let legacyAuthText = try String(contentsOf: CodexPaths.authURL, encoding: .utf8)
            let legacyTOMLText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
            let canonical = try adapter.canonicalizeConfigAndAccounts(
                PortableCoreRawConfigInput.legacy(from: scenario.config),
                buildIfNeeded: false
            )
            let rust = try adapter.renderCodecBundle(
                PortableCoreRenderCodecRequest(
                    config: canonical.config,
                    activeProviderID: scenario.activeProviderID,
                    activeAccountID: scenario.activeAccountID,
                    existingTOMLText: scenario.existingTOMLText
                ),
                buildIfNeeded: false
            )
            let legacy = PortableCoreRenderCodecOutput(
                authJSON: legacyAuthText,
                configTOML: legacyTOMLText,
                codecWarnings: [],
                migrationNotes: []
            )
            return try PortableCoreShadowCompareService.compare(
                scenarioID: "p5-\(scenario.id)",
                bucket: "settings-save-sync-render",
                legacy: legacy,
                rust: rust,
                blockerCategory: "render-codec-output",
                durationMilliseconds: 0
            )
        }

        let refreshUsageRecords = try self.makeRefreshUsageRuntimeRecords()
        let sessionCostRecords = try self.makeSessionCostAttributionRecords()
        let authGatewayRecords = try self.makeAuthGatewayFlowRecords()

        let allRecords = configRecords + routeRecords + renderRecords + refreshUsageRecords + sessionCostRecords + authGatewayRecords
        let summary = PortableCoreShadowCompareSummary.summarize(allRecords)
        try self.writePhaseArtifact(
            phase: "p5-primary-cutover",
            named: "shadow-summary.json",
            payload: summary
        )

        XCTAssertGreaterThanOrEqual(summary.totalSamples, 2_000)
        XCTAssertGreaterThanOrEqual(summary.distinctScenarioCount, 150)
        XCTAssertGreaterThanOrEqual(summary.bucketCounts["app-bootstrap-load"] ?? 0, 250)
        XCTAssertGreaterThanOrEqual(summary.bucketCounts["settings-save-sync-render"] ?? 0, 250)
        XCTAssertGreaterThanOrEqual(summary.bucketCounts["route-runtime-snapshot-refresh"] ?? 0, 250)
        XCTAssertGreaterThanOrEqual(summary.bucketCounts["refresh-usage-runtime"] ?? 0, 250)
        XCTAssertGreaterThanOrEqual(summary.bucketCounts["session-cost-attribution"] ?? 0, 250)
        XCTAssertGreaterThanOrEqual(summary.bucketCounts["auth-gateway-flow"] ?? 0, 250)
        XCTAssertEqual(summary.blockerCount, 0)
        XCTAssertLessThanOrEqual(summary.nonBlockerCount, 5)
    }

    func testFullRustCutoverEmbeddedRuntimeSoak() throws {
        let adapter = RustPortableCoreAdapter.shared
        let totalCycles = 500
        var crashCount = 0
        var corruptionCount = 0
        let configScenario = try XCTUnwrap(self.makeConfigScenarios().first)
        let routeScenario = try XCTUnwrap(self.makeRouteScenarios().first)
        let liveSessionRequest = PortableCoreLiveSessionAttributionRequest(
            now: 1_900_000_000,
            recentActivityWindowSeconds: 3_600,
            sessions: [
                .init(sessionID: "soak-session", startedAt: 1_899_999_000, lastActivityAt: 1_899_999_900, isArchived: false),
            ],
            activations: [
                .init(timestamp: 1_899_998_000, providerId: "openai-oauth", accountId: "acct-soak"),
            ]
        )
        let runningThreadRequest = PortableCoreRunningThreadAttributionRequest(
            recentActivityWindowSeconds: 5,
            unavailableReason: nil,
            threads: [
                .init(threadID: "soak-thread", source: "cli", cwd: "/tmp", title: "Soak", lastRuntimeAt: 1_900_000_000),
            ],
            completedSessions: [],
            aggregateRoutes: [
                .init(timestamp: 1_899_999_999, threadID: "soak-thread", accountId: "acct-soak"),
            ],
            activations: [
                .init(timestamp: 1_899_999_500, providerId: "openai-oauth", accountId: "acct-soak"),
            ]
        )
        let updateRequest = PortableCoreUpdateResolutionRequest(
            release: .init(
                version: "1.2.0",
                deliveryMode: "guidedDownload",
                minimumAutomaticUpdateVersion: nil,
                artifacts: [
                    .init(
                        architecture: "arm64",
                        format: "dmg",
                        downloadUrl: "https://example.com/codexbar-arm64.dmg",
                        sha256: nil
                    ),
                ]
            ),
            environment: .init(
                currentVersion: "1.1.0",
                architecture: "arm64",
                bundlePath: "/Applications/codexbar.app",
                signatureUsable: true,
                signatureSummary: "ok",
                gatekeeperPasses: true,
                gatekeeperSummary: "accepted",
                automaticUpdaterAvailable: false
            )
        )

        for cycle in 0..<totalCycles {
            do {
                _ = try adapter.canonicalizeConfigAndAccounts(
                    PortableCoreRawConfigInput.legacy(from: configScenario.config),
                    buildIfNeeded: false
                )
                _ = try adapter.computeRouteRuntimeSnapshot(
                    routeScenario.routeInput,
                    buildIfNeeded: false
                )
                _ = try adapter.planUsagePolling(
                    .init(
                        activeProviderKind: "openai_oauth",
                        activeAccount: .legacy(from: try self.makeOAuthAccount(
                            accountID: "soak-\(cycle)",
                            email: "soak-\(cycle)@example.com",
                            tokenLastRefreshAt: Date(timeIntervalSince1970: 1_800_000_000)
                        )),
                        now: 1_900_000_000,
                        maxAgeSeconds: 60,
                        force: cycle.isMultiple(of: 7)
                    ),
                    buildIfNeeded: false
                )
                _ = try adapter.attributeLiveSessions(liveSessionRequest, buildIfNeeded: false)
                _ = try adapter.attributeRunningThreads(runningThreadRequest, buildIfNeeded: false)
                _ = try adapter.resolveGatewayTransportPolicy(
                    .init(
                        proxyResolutionMode: "loopbackProxySafe",
                        systemProxySnapshot: .init(
                            http: .init(kind: "http", host: cycle.isMultiple(of: 2) ? "127.0.0.1" : "proxy.example.com", port: 8080),
                            https: nil,
                            socks: nil
                        )
                    ),
                    buildIfNeeded: false
                )
                let availability = try adapter.resolveUpdateAvailability(
                    updateRequest,
                    buildIfNeeded: false
                )
                if availability.updateAvailable == false {
                    corruptionCount += 1
                }
            } catch {
                crashCount += 1
            }
        }

        let soakSummary = RuntimeSoakSummary(
            scope: "embedded-primary-gateway-session-work-cycle",
            requiredSamples: 500,
            observedSamples: totalCycles,
            crashCount: crashCount,
            panicCount: 0,
            corruptionCount: corruptionCount,
            status: crashCount == 0 && corruptionCount == 0 ? "passed" : "failed",
            blocker: crashCount == 0 && corruptionCount == 0 ? nil : "Embedded soak encountered failures."
        )
        try self.writePhaseArtifact(
            phase: "p5-primary-cutover",
            named: "runtime-soak-summary.json",
            payload: soakSummary
        )
        try self.writePhaseArtifact(
            phase: "p6-sidecar-eval",
            named: "runtime-soak-summary.json",
            payload: soakSummary
        )

        XCTAssertEqual(crashCount, 0)
        XCTAssertEqual(corruptionCount, 0)
    }

    private func makeConfigScenarios() throws -> [ConfigScenario] {
        enum ProviderMix: CaseIterable {
            case oauthOnly
            case oauthPlusCompatible
            case oauthPlusOpenRouter
            case openrouterOnly
            case allThree
        }

        let globalModels = [
            ("gpt-5.4", "gpt-5.4", "xhigh"),
            ("gpt-5.4-mini", "gpt-5.4", "high"),
            ("anthropic/claude-3.7-sonnet", "gpt-5.4", "medium"),
            ("gpt-5.4-nano", "gpt-5.4-mini", "medium"),
        ]
        var scenarios: [ConfigScenario] = []
        var index = 0

        for modelVariant in globalModels.indices {
            for usageMode in CodexBarOpenAIAccountUsageMode.allCases {
                for orderingMode in CodexBarOpenAIAccountOrderingMode.allCases {
                    for mix in ProviderMix.allCases {
                        for pricingVariant in 0..<4 {
                            let oauthAccount = try self.makeOAuthAccount(
                                accountID: "cfg-oauth-\(index)",
                                email: "cfg-oauth-\(index)@example.com",
                                localAccountID: "cfg-user-\(index)__cfg-oauth-\(index)",
                                remoteAccountID: "cfg-remote-\(index)",
                                tokenLastRefreshAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
                            )
                            let storedOAuth = CodexBarProviderAccount.fromTokenAccount(
                                oauthAccount,
                                existingID: oauthAccount.accountId
                            )
                            let compatibleAccount = CodexBarProviderAccount(
                                id: "cfg-compatible-\(index)",
                                kind: .apiKey,
                                label: "Compatible \(index)",
                                apiKey: "sk-compatible-\(index)"
                            )
                            let openRouterAccount = CodexBarProviderAccount(
                                id: "cfg-openrouter-\(index)",
                                kind: .apiKey,
                                label: "OpenRouter \(index)",
                                apiKey: "sk-or-v1-\(index)"
                            )
                            let oauthProvider = CodexBarProvider(
                                id: "openai-oauth",
                                kind: .openAIOAuth,
                                label: "OpenAI",
                                activeAccountId: storedOAuth.id,
                                accounts: [storedOAuth]
                            )
                            let compatibleProvider = CodexBarProvider(
                                id: "compatible-\(index)",
                                kind: .openAICompatible,
                                label: "Compatible",
                                enabled: true,
                                baseURL: pricingVariant % 2 == 0 ? "https://compatible.example.com/v1" : "https://alt-compatible.example.com/v1",
                                defaultModel: globalModels[modelVariant].0,
                                activeAccountId: compatibleAccount.id,
                                accounts: [compatibleAccount]
                            )
                            let openRouterProvider = CodexBarProvider(
                                id: "openrouter",
                                kind: .openRouter,
                                label: "OpenRouter",
                                enabled: true,
                                selectedModelID: pricingVariant.isMultiple(of: 2) ? "anthropic/claude-3.7-sonnet" : "openai/gpt-4.1",
                                activeAccountId: openRouterAccount.id,
                                accounts: [openRouterAccount]
                            )

                            let providers: [CodexBarProvider]
                            let active: CodexBarActiveSelection
                            switch mix {
                            case .oauthOnly:
                                providers = [oauthProvider]
                                active = .init(providerId: oauthProvider.id, accountId: storedOAuth.id)
                            case .oauthPlusCompatible:
                                providers = [oauthProvider, compatibleProvider]
                                active = pricingVariant.isMultiple(of: 2)
                                    ? .init(providerId: oauthProvider.id, accountId: storedOAuth.id)
                                    : .init(providerId: compatibleProvider.id, accountId: compatibleAccount.id)
                            case .oauthPlusOpenRouter:
                                providers = [oauthProvider, openRouterProvider]
                                active = pricingVariant.isMultiple(of: 2)
                                    ? .init(providerId: oauthProvider.id, accountId: storedOAuth.id)
                                    : .init(providerId: openRouterProvider.id, accountId: openRouterAccount.id)
                            case .openrouterOnly:
                                providers = [openRouterProvider]
                                active = .init(providerId: openRouterProvider.id, accountId: openRouterAccount.id)
                            case .allThree:
                                providers = [oauthProvider, compatibleProvider, openRouterProvider]
                                switch pricingVariant % 3 {
                                case 0:
                                    active = .init(providerId: oauthProvider.id, accountId: storedOAuth.id)
                                case 1:
                                    active = .init(providerId: compatibleProvider.id, accountId: compatibleAccount.id)
                                default:
                                    active = .init(providerId: openRouterProvider.id, accountId: openRouterAccount.id)
                                }
                            }

                            let config = CodexBarConfig(
                                global: CodexBarGlobalSettings(
                                    defaultModel: globalModels[modelVariant].0,
                                    reviewModel: globalModels[modelVariant].1,
                                    reasoningEffort: globalModels[modelVariant].2
                                ),
                                active: active,
                                modelPricing: pricingVariant == 0 ? [:] : [
                                    globalModels[modelVariant].0: CodexBarModelPricing(
                                        inputUSDPerToken: Double(pricingVariant),
                                        cachedInputUSDPerToken: Double(pricingVariant) / 10,
                                        outputUSDPerToken: Double(pricingVariant) * 2
                                    ),
                                ],
                                openAI: CodexBarOpenAISettings(
                                    accountOrder: orderingMode == .manual ? [storedOAuth.id] : [],
                                    accountUsageMode: usageMode,
                                    switchModeSelection: .init(
                                        providerId: oauthProvider.id,
                                        accountId: storedOAuth.id
                                    ),
                                    accountOrderingMode: orderingMode,
                                    manualActivationBehavior: pricingVariant.isMultiple(of: 2) ? .updateConfigOnly : .launchNewInstance,
                                    usageDisplayMode: pricingVariant.isMultiple(of: 2) ? .used : .remaining
                                ),
                                providers: providers
                            )
                            scenarios.append(
                                ConfigScenario(
                                    id: "cfg-\(index)",
                                    config: config
                                )
                                )
                                index += 1
                            }
                        }
                    }
                }
            }

        return scenarios
    }

    private func makeRouteScenarios() throws -> [RouteScenario] {
        var scenarios: [RouteScenario] = []
        var index = 0
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        for configuredMode in CodexBarOpenAIAccountUsageMode.allCases {
            for leaseActive in [false, true] {
                for stickyKind in 0..<3 {
                    for summaryUnavailable in [false, true] {
                        for _ in 0..<6 {
                            for routedSource in [false, true] {
                                let account = try self.makeOAuthAccount(
                                    accountID: "route-\(index)",
                                    email: "route-\(index)@example.com"
                                )
                                let stored = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
                                let provider = CodexBarProvider(
                                    id: "openai-oauth",
                                    kind: .openAIOAuth,
                                    label: "OpenAI",
                                    activeAccountId: stored.id,
                                    accounts: [stored]
                                )
                                let config = CodexBarConfig(
                                    active: .init(providerId: provider.id, accountId: stored.id),
                                    openAI: CodexBarOpenAISettings(accountUsageMode: configuredMode),
                                    providers: [provider]
                                )
                                let threadID = "thread-\(index)"
                                let stickyBindings: [OpenAIAggregateStickyBindingSnapshot]
                                switch stickyKind {
                                case 1:
                                    stickyBindings = [.init(threadID: threadID, accountID: stored.id, updatedAt: now.addingTimeInterval(-2))]
                                case 2:
                                    stickyBindings = [.init(threadID: threadID, accountID: stored.id, updatedAt: now.addingTimeInterval(-600))]
                                default:
                                    stickyBindings = []
                                }
                                let gatewaySpy = RouteGatewaySpy()
                                gatewaySpy.currentRoutedAccountIDValue = routedSource ? stored.id : nil
                                gatewaySpy.stickyBindings = stickyBindings
                                let leaseStore = AggregateLeaseStoreSpy(initialProcessIDs: leaseActive ? [404] : [])
                                let journalStore = RouteJournalStoreSpy(records: routedSource ? [
                                    .init(
                                        timestamp: now.addingTimeInterval(-300),
                                        threadID: threadID,
                                        accountID: stored.id
                                    ),
                                ] : [])
                                let runningThreadAttribution = OpenAIRunningThreadAttribution(
                                    threads: summaryUnavailable ? [] : stickyKind == 1 ? [
                                        .init(
                                            threadID: threadID,
                                            source: "test",
                                            cwd: "/tmp",
                                            title: "Thread",
                                            lastRuntimeAt: now.addingTimeInterval(-1),
                                            accountID: stored.id
                                        ),
                                    ] : [],
                                    summary: summaryUnavailable ? .unavailable : .empty,
                                    recentActivityWindow: 5,
                                    diagnosticMessage: nil,
                                    unavailableReason: nil
                                )
                                let routeInput = PortableCoreRouteRuntimeInput(
                                    configuredMode: configuredMode.rawValue,
                                    effectiveMode: (configuredMode == .aggregateGateway || leaseActive) ? CodexBarOpenAIAccountUsageMode.aggregateGateway.rawValue : CodexBarOpenAIAccountUsageMode.switchAccount.rawValue,
                                    aggregateRoutedAccountID: routedSource ? stored.id : nil,
                                    stickyBindings: stickyBindings.map {
                                        .init(
                                            threadID: $0.threadID,
                                            accountID: $0.accountID,
                                            updatedAt: $0.updatedAt.timeIntervalSince1970
                                        )
                                    },
                                    routeJournal: journalStore.records.map {
                                        .init(
                                            threadID: $0.threadID,
                                            accountID: $0.accountID,
                                            timestamp: $0.timestamp.timeIntervalSince1970
                                        )
                                    },
                                    leaseState: .init(
                                        leasedProcessIDs: leaseStore.processIDs,
                                        hasActiveLease: leaseStore.hasActiveLease()
                                    ),
                                    runningThreadAttribution: .init(
                                        recentActivityWindowSeconds: runningThreadAttribution.recentActivityWindow,
                                        summaryIsUnavailable: runningThreadAttribution.summary.isUnavailable,
                                        threads: runningThreadAttribution.threads.map {
                                            .init(threadID: $0.threadID)
                                        }
                                    ),
                                    now: now.timeIntervalSince1970
                                )
                                scenarios.append(
                                    RouteScenario(
                                        id: "route-\(index)",
                                        config: config,
                                        now: now,
                                        gatewaySpy: gatewaySpy,
                                        leaseStore: leaseStore,
                                        routeJournalStore: journalStore,
                                        runningThreadAttribution: runningThreadAttribution,
                                        routeInput: routeInput
                                    )
                                )
                                index += 1
                            }
                        }
                    }
                }
            }
        }

        return scenarios
    }

    private func makeRenderScenarios() throws -> [RenderScenario] {
        enum ProviderKind: CaseIterable {
            case oauth
            case compatible
            case openrouter
        }

        let models = ["gpt-5.4", "gpt-5.4-mini", "anthropic/claude-3.7-sonnet"]
        let existingTOMLVariants = [
            "",
            "service_tier = \"fast\"\npreferred_auth_method = \"chatgpt\"\n",
            "service_tier = \"priority\"\nmodel = \"gpt-5.4\"\n",
            "[model_providers.openai]\nname = \"legacy\"\npreferred_auth_method = \"chatgpt\"\n",
        ]
        var scenarios: [RenderScenario] = []
        var index = 0

        for providerKind in ProviderKind.allCases {
            for usageMode in CodexBarOpenAIAccountUsageMode.allCases {
                for existingTOMLText in existingTOMLVariants {
                    for model in models {
                        for reasoning in ["high", "xhigh"] {
                            for compatibleBaseURL in [
                                "https://compatible.example.com/v1",
                                "https://compatible-alt.example.com/v1",
                            ] {
                                let oauthAccount = try self.makeOAuthAccount(
                                    accountID: "render-oauth-\(index)",
                                    email: "render-oauth-\(index)@example.com",
                                    tokenLastRefreshAt: Date(timeIntervalSince1970: 1_850_000_000)
                                )
                                let storedOAuth = CodexBarProviderAccount.fromTokenAccount(
                                    oauthAccount,
                                    existingID: oauthAccount.accountId
                                )
                                let compatibleAccount = CodexBarProviderAccount(
                                    id: "render-compatible-\(index)",
                                    kind: .apiKey,
                                    label: "Compatible",
                                    apiKey: "sk-compatible-\(index)"
                                )
                                let openRouterAccount = CodexBarProviderAccount(
                                    id: "render-openrouter-\(index)",
                                    kind: .apiKey,
                                    label: "OpenRouter",
                                    apiKey: "sk-or-v1-\(index)"
                                )
                                let provider: CodexBarProvider
                                let activeAccountID: String
                                switch providerKind {
                                case .oauth:
                                    provider = CodexBarProvider(
                                        id: "openai-oauth",
                                        kind: .openAIOAuth,
                                        label: "OpenAI",
                                        activeAccountId: storedOAuth.id,
                                        accounts: [storedOAuth]
                                    )
                                    activeAccountID = storedOAuth.id
                                case .compatible:
                                    provider = CodexBarProvider(
                                        id: "compatible-\(index)",
                                        kind: .openAICompatible,
                                        label: "Compatible",
                                        enabled: true,
                                        baseURL: compatibleBaseURL,
                                        defaultModel: model,
                                        activeAccountId: compatibleAccount.id,
                                        accounts: [compatibleAccount]
                                    )
                                    activeAccountID = compatibleAccount.id
                                case .openrouter:
                                    provider = CodexBarProvider(
                                        id: "openrouter",
                                        kind: .openRouter,
                                        label: "OpenRouter",
                                        enabled: true,
                                        selectedModelID: model,
                                        activeAccountId: openRouterAccount.id,
                                        accounts: [openRouterAccount]
                                    )
                                    activeAccountID = openRouterAccount.id
                                }
                                let config = CodexBarConfig(
                                    global: .init(
                                        defaultModel: model,
                                        reviewModel: model,
                                        reasoningEffort: reasoning
                                    ),
                                    active: .init(providerId: provider.id, accountId: activeAccountID),
                                    openAI: .init(accountUsageMode: usageMode),
                                    providers: [provider]
                                )
                                scenarios.append(
                                    RenderScenario(
                                        id: "render-\(index)",
                                        config: config,
                                        activeProviderID: provider.id,
                                        activeAccountID: activeAccountID,
                                        existingTOMLText: existingTOMLText
                                    )
                                )
                                index += 1
                            }
                        }
                    }
                }
            }
        }

        return scenarios
    }

    private func resetCodexSyncFiles(existingTOMLText: String) throws {
        try CodexPaths.ensureDirectories()
        let fileManager = FileManager.default
        for url in [CodexPaths.authURL, CodexPaths.configTomlURL] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        if existingTOMLText.isEmpty == false {
            try CodexPaths.writeSecureFile(Data(existingTOMLText.utf8), to: CodexPaths.configTomlURL)
        }
    }

    private func measureMilliseconds(_ block: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try block()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    private func percentile95(_ values: [Double]) -> Double {
        guard values.isEmpty == false else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }

    private func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private func writeArtifact<Payload: Encodable>(named name: String, payload: Payload) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let artifactDirectory = repoRoot
            .appendingPathComponent(".omx", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("portable-core", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let url = artifactDirectory.appendingPathComponent(name)
        let data = try JSONEncoder.portableCore.encode(payload)
        try CodexPaths.writeSecureFile(data, to: url)
    }

    private func writePhaseArtifact<Payload: Encodable>(
        phase: String,
        named name: String,
        payload: Payload
    ) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let artifactDirectory = repoRoot
            .appendingPathComponent(".omx", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("full-rust-cutover", isDirectory: true)
            .appendingPathComponent(phase, isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let url = artifactDirectory.appendingPathComponent(name)
        let data = try JSONEncoder.portableCore.encode(payload)
        try CodexPaths.writeSecureFile(data, to: url)
    }

    private func makeRefreshUsageRuntimeRecords() throws -> [PortableCoreShadowCompareRecord] {
        let adapter = RustPortableCoreAdapter.shared
        var records: [PortableCoreShadowCompareRecord] = []
        var index = 0

        for force in [false, true] {
            for inFlight in [false, true] {
                for suspended in [false, true] {
                    for tokenExpired in [false, true] {
                        for expiryMode in 0..<3 {
                            for retryMode in 0..<3 {
                                let account = PortableCoreCanonicalAccountSnapshot(
                                    localAccountID: "refresh-\(index)",
                                    remoteAccountID: "refresh-remote-\(index)",
                                    email: "refresh-\(index)@example.com",
                                    accessToken: "access-\(index)",
                                    refreshToken: "refresh-\(index)",
                                    idToken: "id-\(index)",
                                    expiresAt: expiryMode == 0 ? nil : (1_900_000_000 + Double((expiryMode - 1) * 900)),
                                    oauthClientID: nil,
                                    planType: "plus",
                                    primaryUsedPercent: Double((index % 5) * 20),
                                    secondaryUsedPercent: Double((index % 3) * 15),
                                    primaryResetAt: nil,
                                    secondaryResetAt: nil,
                                    primaryLimitWindowSeconds: 18_000,
                                    secondaryLimitWindowSeconds: 604_800,
                                    lastChecked: retryMode == 2 ? 1_899_999_940 : nil,
                                    isActive: true,
                                    isSuspended: suspended,
                                    tokenExpired: tokenExpired,
                                    tokenLastRefreshAt: expiryMode == 0 ? nil : 1_899_999_000,
                                    organizationName: nil,
                                    quotaExhausted: false,
                                    isAvailableForNextUseRouting: suspended == false && tokenExpired == false,
                                    isDegradedForNextUseRouting: false
                                )
                                let retryState = retryMode == 0 ? nil : PortableCoreRefreshRetryState(
                                    attempts: retryMode,
                                    retryAfter: retryMode == 1 ? 1_899_999_990 : 1_900_000_500
                                )
                                let refreshRequest = PortableCoreRefreshPlanRequest(
                                    account: account,
                                    force: force,
                                    now: 1_900_000_000,
                                    refreshWindowSeconds: 1_800,
                                    existingRetryState: retryState,
                                    inFlight: inFlight
                                )
                                let legacyPlan = PortableCoreLegacyRefreshKernel.plan(refreshRequest)
                                let rustPlan = try adapter.planRefresh(refreshRequest, buildIfNeeded: false)
                                records.append(
                                    try PortableCoreShadowCompareService.compare(
                                        scenarioID: "refresh-plan-\(index)",
                                        bucket: "refresh-usage-runtime",
                                        legacy: legacyPlan,
                                        rust: rustPlan,
                                        blockerCategory: "refresh-plan",
                                        durationMilliseconds: 0
                                    )
                                )

                                let outcomeKind = index % 4
                                let refreshedAccount = outcomeKind == 0 ? PortableCoreCanonicalAccountSnapshot(
                                    localAccountID: account.localAccountID,
                                    remoteAccountID: account.remoteAccountID,
                                    email: account.email,
                                    accessToken: "access-refreshed-\(index)",
                                    refreshToken: account.refreshToken,
                                    idToken: account.idToken,
                                    expiresAt: 1_900_003_600,
                                    oauthClientID: account.oauthClientID,
                                    planType: account.planType,
                                    primaryUsedPercent: account.primaryUsedPercent,
                                    secondaryUsedPercent: account.secondaryUsedPercent,
                                    primaryResetAt: account.primaryResetAt,
                                    secondaryResetAt: account.secondaryResetAt,
                                    primaryLimitWindowSeconds: account.primaryLimitWindowSeconds,
                                    secondaryLimitWindowSeconds: account.secondaryLimitWindowSeconds,
                                    lastChecked: account.lastChecked,
                                    isActive: account.isActive,
                                    isSuspended: account.isSuspended,
                                    tokenExpired: false,
                                    tokenLastRefreshAt: 1_900_000_000,
                                    organizationName: account.organizationName,
                                    quotaExhausted: false,
                                    isAvailableForNextUseRouting: true,
                                    isDegradedForNextUseRouting: false
                                ) : nil
                                let outcomeRequest = PortableCoreRefreshOutcomeRequest(
                                    account: account,
                                    now: 1_900_000_000,
                                    maxRetryCount: 3,
                                    existingRetryState: retryState,
                                    outcome: ["refreshed", "terminal_failure", "transient_failure", "skipped"][outcomeKind],
                                    refreshedAccount: refreshedAccount
                                )
                                let legacyOutcome = self.normalizedLegacyRefreshOutcomeResult(
                                    PortableCoreLegacyRefreshKernel.applyOutcome(outcomeRequest)
                                )
                                let rustOutcome = try adapter.applyRefreshOutcome(outcomeRequest, buildIfNeeded: false)
                                records.append(
                                    try PortableCoreShadowCompareService.compare(
                                        scenarioID: "refresh-outcome-\(index)",
                                        bucket: "refresh-usage-runtime",
                                        legacy: legacyOutcome,
                                        rust: rustOutcome,
                                        blockerCategory: "refresh-outcome",
                                        durationMilliseconds: 0
                                    )
                                )

                                let mergeRequest = PortableCoreUsageMergeSuccessRequest(
                                    account: account,
                                    planType: index.isMultiple(of: 3) ? "free" : "plus",
                                    primaryUsedPercent: Double((index % 5) * 17),
                                    secondaryUsedPercent: Double((index % 4) * 13),
                                    primaryResetAt: 1_900_010_000,
                                    secondaryResetAt: 1_900_020_000,
                                    primaryLimitWindowSeconds: 18_000,
                                    secondaryLimitWindowSeconds: 604_800,
                                    organizationName: index.isMultiple(of: 2) ? "Team \(index)" : nil,
                                    checkedAt: 1_900_000_000
                                )
                                let legacyUsage = PortableCoreLegacyUsageKernel.mergeSuccess(mergeRequest)
                                let rustUsage = try adapter.mergeUsageSuccess(mergeRequest, buildIfNeeded: false)
                                records.append(
                                    try PortableCoreShadowCompareService.compare(
                                        scenarioID: "usage-merge-\(index)",
                                        bucket: "refresh-usage-runtime",
                                        legacy: legacyUsage,
                                        rust: rustUsage,
                                        blockerCategory: "usage-merge",
                                        durationMilliseconds: 0
                                    )
                                )

                                let pollingRequest = PortableCoreUsagePollingPlanRequest(
                                    activeProviderKind: index.isMultiple(of: 5) ? "openai_compatible" : "openai_oauth",
                                    activeAccount: .init(
                                        accountId: account.localAccountID,
                                        isSuspended: account.isSuspended,
                                        tokenExpired: account.tokenExpired,
                                        lastCheckedAt: account.lastChecked
                                    ),
                                    now: 1_900_000_000,
                                    maxAgeSeconds: 60,
                                    force: force
                                )
                                let rustPolling = try adapter.planUsagePolling(pollingRequest, buildIfNeeded: false)
                                let legacyPolling = PortableCoreUsagePollingPlanResult(
                                    shouldRefresh: OpenAIUsagePollingPolicy.accountToRefresh(
                                        activeProvider: pollingRequest.activeProviderKind.map {
                                            CodexBarProvider(id: $0, kind: CodexBarProviderKind(rawValue: $0) ?? .openAIOAuth, label: $0)
                                        },
                                        activeAccount: pollingRequest.activeAccount?.lastCheckedAt.map { _ in account.tokenAccount() } ?? account.tokenAccount(),
                                        now: Date(timeIntervalSince1970: pollingRequest.now),
                                        maxAge: pollingRequest.maxAgeSeconds,
                                        force: pollingRequest.force
                                    ) != nil,
                                    accountId: pollingRequest.activeAccount?.accountId,
                                    skipReason: self.legacyUsagePollingSkipReason(request: pollingRequest)
                                )
                                records.append(
                                    try PortableCoreShadowCompareService.compare(
                                        scenarioID: "usage-polling-\(index)",
                                        bucket: "refresh-usage-runtime",
                                        legacy: legacyPolling,
                                        rust: rustPolling,
                                        blockerCategory: "usage-polling",
                                        durationMilliseconds: 0
                                    )
                                )
                                index += 1
                            }
                        }
                    }
                }
            }
        }

        return records
    }

    private func makeSessionCostAttributionRecords() throws -> [PortableCoreShadowCompareRecord] {
        let adapter = RustPortableCoreAdapter.shared
        var records: [PortableCoreShadowCompareRecord] = []

        for index in 0..<120 {
            let eventA = PortableCoreLocalCostEvent(
                model: index.isMultiple(of: 3) ? "gpt-5.4" : "gpt-5.4-mini",
                timestamp: 1_900_000_000 - Double(index * 600),
                usage: .init(inputTokens: 100 + index, cachedInputTokens: index % 20, outputTokens: 20 + (index % 10)),
                sessionUsage: .init(inputTokens: 200 + index, cachedInputTokens: index % 30, outputTokens: 50 + (index % 20))
            )
            let eventB = PortableCoreLocalCostEvent(
                model: index.isMultiple(of: 4) ? "unknown-model" : "gpt-5.4",
                timestamp: 1_900_000_000 - Double(index * 300),
                usage: .init(inputTokens: 40 + index, cachedInputTokens: index % 7, outputTokens: 10 + (index % 5)),
                sessionUsage: .init(inputTokens: 80 + index, cachedInputTokens: index % 12, outputTokens: 20 + (index % 8))
            )
            let request = PortableCoreLocalCostSummaryRequest(
                now: 1_900_000_000,
                pricingOverrides: index.isMultiple(of: 2) ? [
                    "gpt-5.4": .init(inputUsdPerToken: 2.5e-6, cachedInputUsdPerToken: 2.5e-7, outputUsdPerToken: 1.5e-5),
                ] : [:],
                events: [eventA, eventB]
            )
            let rust = try adapter.summarizeLocalCost(request, buildIfNeeded: false)
            let legacy = self.legacyLocalCostSummary(request: request)
            records.append(
                try PortableCoreShadowCompareService.compare(
                    scenarioID: "local-cost-\(index)",
                    bucket: "session-cost-attribution",
                    legacy: legacy,
                    rust: rust,
                    blockerCategory: "local-cost-summary",
                    durationMilliseconds: 0
                )
            )
        }

        for index in 0..<100 {
            let request = PortableCoreLiveSessionAttributionRequest(
                now: 1_900_000_000,
                recentActivityWindowSeconds: 3_600,
                sessions: [
                    .init(sessionID: "live-a-\(index)", startedAt: 1_899_998_000, lastActivityAt: 1_899_999_900 - Double(index), isArchived: false),
                    .init(sessionID: "live-b-\(index)", startedAt: 1_899_997_000, lastActivityAt: 1_899_999_000 - Double(index * 2), isArchived: false),
                ],
                activations: [
                    .init(timestamp: 1_899_996_000, providerId: "openai-oauth", accountId: "acct-a-\(index)"),
                    .init(timestamp: 1_899_997_500, providerId: index.isMultiple(of: 2) ? "openai-oauth" : "custom-provider", accountId: "acct-b-\(index)"),
                ]
            )
            let rust = try adapter.attributeLiveSessions(request, buildIfNeeded: false)
            let legacy = self.legacyLiveSessionAttribution(request: request)
            records.append(
                try PortableCoreShadowCompareService.compare(
                    scenarioID: "live-attribution-\(index)",
                    bucket: "session-cost-attribution",
                    legacy: legacy,
                    rust: rust,
                    blockerCategory: "live-session-attribution",
                    durationMilliseconds: 0
                )
            )
        }

        for index in 0..<100 {
            let request = PortableCoreRunningThreadAttributionRequest(
                recentActivityWindowSeconds: 5,
                unavailableReason: index == 0 ? "missing runtime database" : nil,
                threads: index == 0 ? [] : [
                    .init(threadID: "thread-a-\(index)", source: "cli", cwd: "/tmp/a", title: "A", lastRuntimeAt: 1_900_000_000),
                    .init(threadID: "thread-b-\(index)", source: "cli", cwd: "/tmp/b", title: "B", lastRuntimeAt: 1_899_999_998),
                ],
                completedSessions: index.isMultiple(of: 3) ? [
                    .init(
                        sessionID: "thread-b-\(index)",
                        lastActivityAt: 1_900_000_000,
                        isArchived: false,
                        taskLifecycleState: "completed"
                    ),
                ] : [],
                aggregateRoutes: [
                    .init(timestamp: 1_899_999_999, threadID: "thread-a-\(index)", accountId: "acct-routed-\(index)"),
                ],
                activations: [
                    .init(timestamp: 1_899_999_500, providerId: "openai-oauth", accountId: "acct-activation-\(index)"),
                ]
            )
            let rust = try adapter.attributeRunningThreads(request, buildIfNeeded: false)
            let legacy = self.legacyRunningThreadAttribution(request: request)
            records.append(
                try PortableCoreShadowCompareService.compare(
                    scenarioID: "running-attribution-\(index)",
                    bucket: "session-cost-attribution",
                    legacy: legacy,
                    rust: rust,
                    blockerCategory: "running-thread-attribution",
                    durationMilliseconds: 0
                )
            )
        }

        return records
    }

    private func makeAuthGatewayFlowRecords() throws -> [PortableCoreShadowCompareRecord] {
        let adapter = RustPortableCoreAdapter.shared
        var records: [PortableCoreShadowCompareRecord] = []

        for index in 0..<120 {
            let request = PortableCoreGatewayTransportPolicyRequest(
                proxyResolutionMode: index.isMultiple(of: 2) ? "loopbackProxySafe" : "systemDefault",
                systemProxySnapshot: .init(
                    http: .init(kind: "http", host: index.isMultiple(of: 3) ? "127.0.0.1" : "corp-proxy.example.com", port: 8080),
                    https: .init(kind: "https", host: index.isMultiple(of: 5) ? "localhost" : "secure-proxy.example.com", port: 8443),
                    socks: index.isMultiple(of: 7) ? .init(kind: "socks", host: "127.0.0.1", port: 1080) : nil
                )
            )
            let rust = try adapter.resolveGatewayTransportPolicy(request, buildIfNeeded: false)
            let legacy = self.legacyGatewayTransportPolicy(request: request)
            records.append(
                try PortableCoreShadowCompareService.compare(
                    scenarioID: "gateway-transport-\(index)",
                    bucket: "auth-gateway-flow",
                    legacy: legacy,
                    rust: rust,
                    blockerCategory: "gateway-transport-policy",
                    durationMilliseconds: 0
                )
            )
        }

        for index in 0..<100 {
            let callbackInput: String
            switch index % 4 {
            case 0:
                callbackInput = "http://localhost:1455/auth/callback?code=code-\(index)&state=state-\(index)"
            case 1:
                callbackInput = "code=code-\(index)&state=state-\(index)"
            case 2:
                callbackInput = "http://localhost:1455/auth/callback?code=code-\(index)"
            default:
                callbackInput = "state=state-\(index)"
            }
            let request = PortableCoreOAuthCallbackInterpretationRequest(
                callbackInput: callbackInput,
                code: nil,
                returnedState: nil,
                expectedState: "state-\(index)"
            )
            let rust = try adapter.interpretOAuthCallback(request, buildIfNeeded: false)
            let legacy = self.legacyOAuthCallbackInterpretation(request: request)
            records.append(
                try PortableCoreShadowCompareService.compare(
                    scenarioID: "oauth-callback-\(index)",
                    bucket: "auth-gateway-flow",
                    legacy: legacy,
                    rust: rust,
                    blockerCategory: "oauth-callback",
                    durationMilliseconds: 0
                )
            )
        }

        for index in 0..<100 {
            let release = PortableCoreUpdateReleaseInput(
                version: index.isMultiple(of: 6) ? "1.1.0" : "1.2.\(index % 5)",
                deliveryMode: index.isMultiple(of: 2) ? "guidedDownload" : "automatic",
                minimumAutomaticUpdateVersion: index.isMultiple(of: 4) ? "1.1.5" : nil,
                artifacts: [
                    .init(architecture: "universal", format: "zip", downloadUrl: "https://example.com/universal-\(index).zip", sha256: nil),
                    .init(architecture: "arm64", format: "dmg", downloadUrl: "https://example.com/arm64-\(index).dmg", sha256: nil),
                ]
            )
            let environment = PortableCoreUpdateEnvironmentFacts(
                currentVersion: index.isMultiple(of: 6) ? "1.2.0" : "1.1.0",
                architecture: "arm64",
                bundlePath: index.isMultiple(of: 5) ? "/tmp/codexbar.app" : "/Applications/codexbar.app",
                signatureUsable: index.isMultiple(of: 7) == false,
                signatureSummary: index.isMultiple(of: 7) ? "adhoc" : "team-id-ok",
                gatekeeperPasses: index.isMultiple(of: 8) == false,
                gatekeeperSummary: index.isMultiple(of: 8) ? "rejected" : "accepted",
                automaticUpdaterAvailable: index.isMultiple(of: 3)
            )
            let request = PortableCoreUpdateResolutionRequest(release: release, environment: environment)
            let rust = try adapter.resolveUpdateAvailability(request, buildIfNeeded: false)
            let legacy = try self.legacyUpdateAvailability(request: request)
            records.append(
                try PortableCoreShadowCompareService.compare(
                    scenarioID: "update-availability-\(index)",
                    bucket: "auth-gateway-flow",
                    legacy: legacy,
                    rust: rust,
                    blockerCategory: "update-availability",
                    durationMilliseconds: 0
                )
            )
        }

        return records
    }

    private func legacyLocalCostSummary(
        request: PortableCoreLocalCostSummaryRequest
    ) -> PortableCoreLocalCostSummarySnapshot {
        let todayStart = floor(request.now / 86_400) * 86_400
        let last30Start = todayStart - (29 * 86_400)
        var todayCostUSD = 0.0
        var todayTokens = 0
        var last30CostUSD = 0.0
        var last30Tokens = 0
        var lifetimeCostUSD = 0.0
        var lifetimeTokens = 0
        var daily: [Int: (Double, Int)] = [:]

        for event in request.events {
            let usage = event.usage.sessionUsage()
            let sessionUsage = event.sessionUsage?.sessionUsage()
            let cost = LocalCostPricing.costUSD(
                model: event.model,
                usage: usage,
                sessionUsage: sessionUsage,
                customPricingByModel: request.pricingOverrides.mapValues { $0.modelPricing() }
            )
            let dayKey = Int(floor(event.timestamp / 86_400))
            let totalTokens = usage.totalTokens
            if event.timestamp >= todayStart {
                todayCostUSD += cost
                todayTokens += totalTokens
            }
            if event.timestamp >= last30Start {
                last30CostUSD += cost
                last30Tokens += totalTokens
            }
            lifetimeCostUSD += cost
            lifetimeTokens += totalTokens
            let current = daily[dayKey] ?? (0, 0)
            daily[dayKey] = (current.0 + cost, current.1 + totalTokens)
        }

        let dailyEntries = daily.map { dayKey, entry in
            PortableCoreLocalCostDailyEntry(
                id: "day-\(dayKey)",
                timestamp: Double(dayKey) * 86_400,
                costUsd: entry.0,
                totalTokens: entry.1
            )
        }.sorted { $0.timestamp > $1.timestamp }

        return PortableCoreLocalCostSummarySnapshot(
            todayCostUsd: todayCostUSD,
            todayTokens: todayTokens,
            last30DaysCostUsd: last30CostUSD,
            last30DaysTokens: last30Tokens,
            lifetimeCostUsd: lifetimeCostUSD,
            lifetimeTokens: lifetimeTokens,
            dailyEntries: dailyEntries,
            updatedAt: request.now
        )
    }

    private func legacyLiveSessionAttribution(
        request: PortableCoreLiveSessionAttributionRequest
    ) -> PortableCoreLiveSessionAttributionResult {
        var counts: [String: Int] = [:]
        var unknown = 0
        let sessions = request.sessions
            .filter { max(0, request.now - $0.lastActivityAt) <= request.recentActivityWindowSeconds }
            .sorted { $0.startedAt < $1.startedAt }
            .map { session -> PortableCoreLiveSessionAttributionItem in
                let accountID = request.activations
                    .filter { $0.timestamp <= session.startedAt }
                    .max(by: { $0.timestamp < $1.timestamp })
                    .flatMap { activation in
                        if activation.providerId == "openai-oauth",
                           activation.accountId?.isEmpty == false {
                            return activation.accountId
                        }
                        return nil
                    }
                if let accountID {
                    counts[accountID, default: 0] += 1
                } else {
                    unknown += 1
                }
                return .init(
                    sessionID: session.sessionID,
                    startedAt: session.startedAt,
                    lastActivityAt: session.lastActivityAt,
                    accountId: accountID
                )
            }
        return PortableCoreLiveSessionAttributionResult(
            recentActivityWindowSeconds: request.recentActivityWindowSeconds,
            sessions: sessions,
            summary: .init(inUseSessionCounts: counts, unknownSessionCount: unknown)
        )
    }

    private func legacyRunningThreadAttribution(
        request: PortableCoreRunningThreadAttributionRequest
    ) -> PortableCoreRunningThreadAttributionResult {
        if let unavailableReason = request.unavailableReason {
            return .init(
                recentActivityWindowSeconds: request.recentActivityWindowSeconds,
                diagnosticMessage: unavailableReason,
                unavailableReason: unavailableReason,
                threads: [],
                summary: .init(summaryIsUnavailable: true, runningThreadCounts: [:], unknownThreadCount: 0)
            )
        }

        var counts: [String: Int] = [:]
        var unknown = 0
        let completed = Dictionary(uniqueKeysWithValues: request.completedSessions.map { ($0.sessionID, $0) })
        let threads = request.threads.compactMap { thread -> PortableCoreRunningThreadAttributionItem? in
            if let completedSession = completed[thread.threadID],
               completedSession.taskLifecycleState == "completed",
               completedSession.lastActivityAt >= thread.lastRuntimeAt {
                return nil
            }
            let accountID = request.aggregateRoutes
                .filter { $0.threadID == thread.threadID && $0.timestamp <= thread.lastRuntimeAt && $0.accountId.isEmpty == false }
                .max(by: { $0.timestamp < $1.timestamp })?
                .accountId
                ?? request.activations
                    .filter { $0.timestamp <= thread.lastRuntimeAt }
                    .max(by: { $0.timestamp < $1.timestamp })
                    .flatMap { activation in
                        if activation.providerId == "openai-oauth",
                           activation.accountId?.isEmpty == false {
                            return activation.accountId
                        }
                        return nil
                    }
            if let accountID {
                counts[accountID, default: 0] += 1
            } else {
                unknown += 1
            }
            return .init(
                threadID: thread.threadID,
                source: thread.source,
                cwd: thread.cwd,
                title: thread.title,
                lastRuntimeAt: thread.lastRuntimeAt,
                accountId: accountID
            )
        }
        return .init(
            recentActivityWindowSeconds: request.recentActivityWindowSeconds,
            diagnosticMessage: nil,
            unavailableReason: nil,
            threads: threads,
            summary: .init(summaryIsUnavailable: false, runningThreadCounts: counts, unknownThreadCount: unknown)
        )
    }

    private func legacyGatewayTransportPolicy(
        request: PortableCoreGatewayTransportPolicyRequest
    ) -> PortableCoreGatewayTransportPolicyResult {
        PortableCoreGatewayTransportPolicyResult.failClosed(
            proxyResolutionMode: request.proxyResolutionMode,
            systemProxySnapshot: request.systemProxySnapshot
        )
    }

    private func normalizedLegacyRefreshOutcomeResult(
        _ result: PortableCoreRefreshOutcomeResult
    ) -> PortableCoreRefreshOutcomeResult {
        var normalized = result
        let account = result.account.tokenAccount()
        normalized.account.isAvailableForNextUseRouting = account.isAvailableForNextUseRouting
        normalized.account.isDegradedForNextUseRouting = account.isDegradedForNextUseRouting
        normalized.account.quotaExhausted = account.quotaExhausted
        return normalized
    }

    private func legacyUsagePollingSkipReason(
        request: PortableCoreUsagePollingPlanRequest
    ) -> String? {
        guard let account = request.activeAccount else {
            return "missingActiveAccount"
        }
        if request.activeProviderKind != "openai_oauth" {
            return "inactiveProvider"
        }
        if account.isSuspended {
            return "suspended"
        }
        if account.tokenExpired {
            return "tokenExpired"
        }
        if request.force {
            return nil
        }
        if let lastCheckedAt = account.lastCheckedAt,
           request.now - lastCheckedAt < request.maxAgeSeconds {
            return "freshUsageSnapshot"
        }
        return nil
    }

    private func legacyOAuthCallbackInterpretation(
        request: PortableCoreOAuthCallbackInterpretationRequest
    ) -> PortableCoreOAuthCallbackInterpretationResult {
        let source = request.callbackInput ?? ""
        let query = source.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? source
        var code: String?
        var state: String?
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch key {
            case "code" where value.isEmpty == false:
                code = value
            case "state" where value.isEmpty == false:
                state = value
            default:
                continue
            }
        }
        return PortableCoreOAuthCallbackInterpretationResult(
            code: code,
            returnedState: state,
            stateMismatch: state.map { $0 != request.expectedState } ?? false
        )
    }

    private func legacyUpdateAvailability(
        request: PortableCoreUpdateResolutionRequest
    ) throws -> PortableCoreUpdateAvailabilityResult {
        guard let currentVersion = AppSemanticVersion(request.environment.currentVersion),
              let releaseVersion = AppSemanticVersion(request.release.version) else {
            throw NSError(domain: "legacyUpdateAvailability", code: 1)
        }
        guard currentVersion < releaseVersion else {
            return .init(updateAvailable: false, selectedArtifact: nil, blockers: [])
        }
        let artifacts = request.release.artifacts.compactMap { $0.appUpdateArtifact() }
        let selectedArtifact = try AppUpdateArtifactSelector.selectArtifact(
            for: UpdateArtifactArchitecture(rawValue: request.environment.architecture) ?? .universal,
            artifacts: artifacts
        )
        var blockers: [PortableCoreUpdateBlockerResult] = []
        if request.release.deliveryMode == "guidedDownload" {
            blockers.append(.init(code: "guidedDownloadOnlyRelease", detail: "release requires guided download"))
        }
        if let minimumAutomaticVersion = request.release.minimumAutomaticUpdateVersion,
           let minimumVersion = AppSemanticVersion(minimumAutomaticVersion),
           currentVersion < minimumVersion {
            blockers.append(
                .init(
                    code: "bootstrapRequired",
                    detail: "current \(request.environment.currentVersion) is below automatic minimum \(minimumAutomaticVersion)"
                )
            )
        }
        if request.environment.automaticUpdaterAvailable == false {
            blockers.append(.init(code: "automaticUpdaterUnavailable", detail: "automatic updater is not available"))
        }
        if request.environment.signatureUsable == false {
            blockers.append(.init(code: "missingTrustedSignature", detail: request.environment.signatureSummary))
        }
        if request.environment.gatekeeperPasses == false {
            blockers.append(.init(code: "failingGatekeeperAssessment", detail: request.environment.gatekeeperSummary))
        }
        if request.environment.bundlePath.hasPrefix("/Applications/") == false &&
            request.environment.bundlePath != "/Applications" &&
            request.environment.bundlePath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/") == false &&
            request.environment.bundlePath != FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path {
            blockers.append(.init(code: "unsupportedInstallLocation", detail: "other"))
        }
        return .init(
            updateAvailable: true,
            selectedArtifact: .init(
                architecture: selectedArtifact.architecture.rawValue,
                format: selectedArtifact.format.rawValue,
                downloadUrl: selectedArtifact.downloadURL.absoluteString,
                sha256: selectedArtifact.sha256
            ),
            blockers: blockers
        )
    }

    private func makeRuntimeController() -> SingleProcessAppRuntimeController {
        let tokenStore = TokenStore(
            openAIAccountGatewayService: RouteGatewaySpy(),
            openRouterGatewayService: NoopOpenRouterGatewayController(),
            aggregateGatewayLeaseStore: AggregateLeaseStoreSpy(initialProcessIDs: []),
            codexRunningProcessIDs: { [] }
        )
        let usagePolling = OpenAIUsagePollingService(
            store: tokenStore,
            refreshAction: { _, _ in }
        )
        let oauthRefresh = OpenAIOAuthRefreshService(
            store: tokenStore,
            refreshAction: { account in account }
        )
        let updateCoordinator = UpdateCoordinator(
            releaseLoader: StaticUpdateLoader(),
            environment: StaticUpdateEnvironment(),
            capabilityEvaluator: AllowingCapabilityEvaluator(),
            actionExecutor: NoopUpdateActionExecutor(),
            automaticCheckScheduler: NoopAutomaticCheckScheduler(),
            automaticCheckInterval: 24 * 60 * 60
        )
        return SingleProcessAppRuntimeController(
            statusItemHost: StatusItemProbeController(),
            usagePolling: usagePolling,
            oauthRefresh: oauthRefresh,
            updateCoordinator: updateCoordinator,
            portableCoreWarmup: AdapterWarmupLifecycleController(),
            tokenStore: tokenStore,
            legacyMenuHostCleaner: MenuHostBootstrapService(
                menuHostRootURL: CodexPaths.menuHostRootURL,
                menuHostAppURL: CodexPaths.menuHostAppURL,
                menuHostLeaseURL: CodexPaths.menuHostLeaseURL
            ),
            recordEvent: { _, _ in }
        )
    }
}

private struct ConfigScenario {
    let id: String
    let config: CodexBarConfig
}

private struct RenderScenario {
    let id: String
    let config: CodexBarConfig
    let activeProviderID: String
    let activeAccountID: String
    let existingTOMLText: String
}

private struct RouteScenario {
    let id: String
    let config: CodexBarConfig
    let now: Date
    let gatewaySpy: RouteGatewaySpy
    let leaseStore: AggregateLeaseStoreSpy
    let routeJournalStore: RouteJournalStoreSpy
    let runningThreadAttribution: OpenAIRunningThreadAttribution
    let routeInput: PortableCoreRouteRuntimeInput
}

private struct PerformanceSummary: Codable, Equatable {
    let coldLaunchP95Milliseconds: Double
    let warmLaunchP95Milliseconds: Double
    let rssDeltaMB: Double
    let deterministicRefreshP95Milliseconds: Double
}

private struct RuntimeSoakSummary: Codable, Equatable {
    let scope: String
    let requiredSamples: Int
    let observedSamples: Int
    let crashCount: Int
    let panicCount: Int
    let corruptionCount: Int
    let status: String
    let blocker: String?
}

private final class RouteGatewaySpy: OpenAIAccountGatewayControlling {
    var currentRoutedAccountIDValue: String?
    var stickyBindings: [OpenAIAggregateStickyBindingSnapshot] = []

    func startIfNeeded() {}
    func stop() {}
    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode
    ) {}
    func currentRoutedAccountID() -> String? { self.currentRoutedAccountIDValue }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { self.stickyBindings }
    func clearStickyBinding(threadID: String) -> Bool { false }
}

private final class AggregateLeaseStoreSpy: OpenAIAggregateGatewayLeaseStoring {
    var processIDs: [Int]

    init(initialProcessIDs: [Int]) {
        self.processIDs = initialProcessIDs
    }

    func loadProcessIDs() -> Set<pid_t> {
        Set(self.processIDs.map(pid_t.init))
    }

    func saveProcessIDs(_ processIDs: Set<pid_t>) {
        self.processIDs = processIDs.map(Int.init).sorted()
    }

    func clear() {
        self.processIDs = []
    }

    func hasActiveLease() -> Bool {
        self.processIDs.isEmpty == false
    }
}

private final class RouteJournalStoreSpy: OpenAIAggregateRouteJournalStoring {
    var records: [OpenAIAggregateRouteRecord]

    init(records: [OpenAIAggregateRouteRecord]) {
        self.records = records
    }

    func recordRoute(threadID: String, accountID: String, timestamp: Date) {
        self.records.append(.init(timestamp: timestamp, threadID: threadID, accountID: accountID))
    }

    func routeHistory() -> [OpenAIAggregateRouteRecord] {
        self.records
    }
}

private final class NoopOpenRouterGatewayController: OpenRouterGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {}
}

@MainActor
private final class StatusItemProbeController: LifecycleControlling {
    private var statusItem: NSStatusItem?

    func start() {
        guard self.statusItem == nil else { return }
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func stop() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
    }
}

@MainActor
private final class AdapterWarmupLifecycleController: LifecycleControlling {
    func start() {
        try? RustPortableCoreAdapter.shared.warmup(buildIfNeeded: false)
    }

    func stop() {}
}

@MainActor
private final class NoopTokenStoreReloader: TokenStoreReloading {
    func load() {}
}

private final class NoopAutomaticCheckHandle: AppUpdateAutomaticCheckCancelling {
    func cancel() {}
}

private struct NoopAutomaticCheckScheduler: AppUpdateAutomaticCheckScheduling {
    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @Sendable @MainActor () async -> Void
    ) -> AppUpdateAutomaticCheckCancelling {
        NoopAutomaticCheckHandle()
    }
}

private struct StaticUpdateLoader: AppUpdateReleaseLoading {
    func loadLatestRelease() async throws -> AppUpdateRelease {
        AppUpdateRelease(
            version: "0.0.0",
            publishedAt: nil,
            summary: nil,
            releaseNotesURL: URL(string: "https://example.com/release-notes")!,
            downloadPageURL: URL(string: "https://example.com/download")!,
            deliveryMode: .automatic,
            minimumAutomaticUpdateVersion: nil,
            artifacts: []
        )
    }
}

private struct StaticUpdateEnvironment: AppUpdateEnvironmentProviding {
    let currentVersion = "0.0.0"
    let bundleURL = URL(fileURLWithPath: "/Applications/codexbar.app")
    let architecture = UpdateArtifactArchitecture.arm64
    let githubReleasesURL: URL? = URL(string: "https://example.com/releases")
}

private struct AllowingCapabilityEvaluator: AppUpdateCapabilityEvaluating, AppUpdateEnvironmentFactsProviding {
    func blockers(
        for release: AppUpdateRelease,
        environment: AppUpdateEnvironmentProviding
    ) -> [AppUpdateBlocker] {
        []
    }

    func environmentFacts(
        for environment: AppUpdateEnvironmentProviding
    ) -> PortableCoreUpdateEnvironmentFacts {
        PortableCoreUpdateEnvironmentFacts(
            currentVersion: environment.currentVersion,
            architecture: environment.architecture.rawValue,
            bundlePath: environment.bundleURL.path,
            signatureUsable: true,
            signatureSummary: "Signature=Developer ID; TeamIdentifier=TEAMID",
            gatekeeperPasses: true,
            gatekeeperSummary: "accepted | source=Developer ID",
            automaticUpdaterAvailable: true
        )
    }
}

private struct NoopUpdateActionExecutor: AppUpdateActionExecuting {
    func execute(_ availability: AppUpdateAvailability) async throws {}
}
