import AppKit
import Foundation
import XCTest

@MainActor
final class RustPortableCoreIntegrationTests: CodexBarTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        PortableCoreRollbackController.shared.reset()
        RustPortableCoreAdapter.shared.resetForTesting()
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
                leaseState: scenario.routeInput.leaseState,
                runtimeBlockState: scenario.runtimeBlockState,
                runningThreadAttribution: scenario.runningThreadAttribution,
                liveSessionAttribution: scenario.liveSessionAttribution
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
                        for runtimeBlockKind in 0..<3 {
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
                                let liveSessionAttribution = OpenAILiveSessionAttribution(
                                    sessions: routedSource ? [
                                        .init(
                                            sessionID: "session-\(index)",
                                            startedAt: now.addingTimeInterval(-30),
                                            lastActivityAt: now.addingTimeInterval(-10),
                                            accountID: stored.id
                                        ),
                                    ] : [],
                                    inUseSessionCounts: routedSource ? [stored.id: 1] : [:],
                                    unknownSessionCount: 0,
                                    recentActivityWindow: 60
                                )
                                let runtimeBlockState: PortableCoreRouteRuntimeInput.RuntimeBlockState
                                switch runtimeBlockKind {
                                case 1:
                                    runtimeBlockState = .init(blockedAccountIDs: [], retryAt: now.addingTimeInterval(60).timeIntervalSince1970, resetAt: nil)
                                case 2:
                                    runtimeBlockState = .init(blockedAccountIDs: [stored.id], retryAt: nil, resetAt: now.addingTimeInterval(120).timeIntervalSince1970)
                                default:
                                    runtimeBlockState = .init(blockedAccountIDs: [], retryAt: nil, resetAt: nil)
                                }
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
                                        activeThreadIDs: Array(runningThreadAttribution.activeThreadIDs).sorted(),
                                        recentActivityWindowSeconds: runningThreadAttribution.recentActivityWindow,
                                        summaryIsUnavailable: runningThreadAttribution.summary.isUnavailable,
                                        inUseAccountIDs: runningThreadAttribution.summary.runningThreadCounts.keys.sorted()
                                    ),
                                    liveSessionAttribution: .init(
                                        summaryIsUnavailable: false,
                                        activeSessionIDs: liveSessionAttribution.sessions.map(\.sessionID).sorted(),
                                        attributedAccountIDs: liveSessionAttribution.inUseSessionCounts.keys.sorted()
                                    ),
                                    runtimeBlockState: runtimeBlockState,
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
                                        liveSessionAttribution: liveSessionAttribution,
                                        runtimeBlockState: runtimeBlockState,
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
    let liveSessionAttribution: OpenAILiveSessionAttribution
    let runtimeBlockState: PortableCoreRouteRuntimeInput.RuntimeBlockState
    let routeInput: PortableCoreRouteRuntimeInput
}

private struct PerformanceSummary: Codable, Equatable {
    let coldLaunchP95Milliseconds: Double
    let warmLaunchP95Milliseconds: Double
    let rssDeltaMB: Double
    let deterministicRefreshP95Milliseconds: Double
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

private struct AllowingCapabilityEvaluator: AppUpdateCapabilityEvaluating {
    func blockers(
        for release: AppUpdateRelease,
        environment: AppUpdateEnvironmentProviding
    ) -> [AppUpdateBlocker] {
        []
    }
}

private struct NoopUpdateActionExecutor: AppUpdateActionExecuting {
    func execute(_ availability: AppUpdateAvailability) async throws {}
}
