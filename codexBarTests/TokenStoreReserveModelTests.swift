import Foundation
import XCTest

@MainActor
final class TokenStoreReserveModelTests: CodexBarTestCase {
    func testCurrentAccountReserveAppearsEvenWhenRegularQuotaIsExhausted() throws {
        var account = try self.makeAccount(id: "reserve")
        account.primaryUsedPercent = 100
        account.secondaryUsedPercent = 100
        account.primaryResetAt = Date(timeIntervalSinceNow: 3_600)
        account.secondaryResetAt = Date(timeIntervalSinceNow: 7_200)
        let fixture = try self.makeStore(accounts: [account])

        XCTAssertTrue(fixture.store.routeModelOptions(currentModel: fixture.store.activeModel).contains(ReserveModelPolicy.modelID))
        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)
        XCTAssertEqual(fixture.store.activeModel, ReserveModelPolicy.modelID)
        XCTAssertFalse(fixture.gateway.isRunning)
    }

    func testOtherAccountReserveDoesNotAppearForCurrentAccountWithoutReserve() throws {
        var current = try self.makeAccount(id: "current")
        current.lunaReserveUsedPercent = nil
        let other = try self.makeAccount(id: "other")
        let fixture = try self.makeStore(accounts: [current, other])
        let storedBefore = try Data(contentsOf: CodexPaths.barConfigURL)
        let syncCount = fixture.sync.configs.count

        XCTAssertFalse(fixture.store.routeModelOptions(currentModel: fixture.store.activeModel).contains(ReserveModelPolicy.modelID))
        XCTAssertThrowsError(try fixture.store.updateRouteModel(ReserveModelPolicy.modelID))
        XCTAssertEqual(fixture.store.config.active.accountId, current.accountId)
        XCTAssertEqual(try Data(contentsOf: CodexPaths.barConfigURL), storedBefore)
        XCTAssertEqual(fixture.sync.configs.count, syncCount)
    }

    func testReserveWithFutureResetAndExhaustedQuotaCannotBeSelected() throws {
        var account = try self.makeAccount(id: "exhausted")
        account.lunaReserveUsedPercent = 100
        let fixture = try self.makeStore(accounts: [account])
        let storedBefore = try Data(contentsOf: CodexPaths.barConfigURL)

        XCTAssertFalse(fixture.store.routeModelOptions(currentModel: fixture.store.activeModel).contains(ReserveModelPolicy.modelID))
        XCTAssertThrowsError(try fixture.store.updateRouteModel(ReserveModelPolicy.modelID))
        XCTAssertEqual(try Data(contentsOf: CodexPaths.barConfigURL), storedBefore)
        XCTAssertFalse(fixture.gateway.isRunning)
    }

    func testInvalidReserveQuotaCannotOfferOrSelectReserve() throws {
        let account = try self.makeAccount(id: "invalid-quota")
        let fixture = try self.makeStore(accounts: [account])
        let syncCount = fixture.sync.configs.count
        for invalidQuota in [-1.0, Double.nan, Double.infinity] {
            var invalid = account
            invalid.lunaReserveUsedPercent = invalidQuota
            fixture.store.addOrUpdate(invalid, reconcileActiveAuth: false)

            XCTAssertFalse(fixture.store.routeModelOptions(currentModel: fixture.store.activeModel).contains(ReserveModelPolicy.modelID))
            XCTAssertThrowsError(try fixture.store.updateRouteModel(ReserveModelPolicy.modelID))
            XCTAssertEqual(fixture.store.activeModel, "gpt-6-sol")
        }
        XCTAssertEqual(fixture.sync.configs.count, syncCount)
        XCTAssertFalse(fixture.gateway.isRunning)
    }

    func testExpiredAndBannedCurrentAccountsCannotOfferOrSelectReserve() throws {
        let current = try self.makeAccount(id: "current")
        let other = try self.makeAccount(id: "other")
        let fixture = try self.makeStore(accounts: [current, other])
        for isBanned in [false, true] {
            var unavailable = current
            unavailable.tokenExpired = !isBanned
            unavailable.isSuspended = isBanned
            // 模拟运行时刚收到的状态，避免初始化清除旧版本 suspension 的迁移路径。
            fixture.store.addOrUpdate(unavailable, reconcileActiveAuth: false)
            XCTAssertFalse(fixture.store.routeModelOptions(currentModel: fixture.store.activeModel).contains(ReserveModelPolicy.modelID))
            XCTAssertThrowsError(try fixture.store.updateRouteModel(ReserveModelPolicy.modelID))
            XCTAssertEqual(fixture.store.config.active.accountId, current.accountId)
        }
        XCTAssertFalse(fixture.gateway.isRunning)
    }

    func testReserveWithElapsedResetCanBeSelected() throws {
        var account = try self.makeAccount(id: "reset-reserve")
        account.lunaReserveUsedPercent = 100
        account.lunaReserveResetAt = Date(timeIntervalSinceNow: -60)
        let fixture = try self.makeStore(accounts: [account])

        XCTAssertTrue(fixture.store.routeModelOptions(currentModel: fixture.store.activeModel).contains(ReserveModelPolicy.modelID))
        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)
        XCTAssertEqual(fixture.store.activeModel, ReserveModelPolicy.modelID)
    }

    func testSelectingReservePreservesBaseSettingsAndUsesDirectAccountRoute() throws {
        let account = try self.makeAccount(id: "reserve")
        let fixture = try self.makeStore(accounts: [account])
        let original = fixture.store.config

        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)

        self.assertBaseSelection(fixture.store.config, matches: original)
        XCTAssertEqual(fixture.store.activeProviderAccount?.selectedModelID, ReserveModelPolicy.modelID)
        XCTAssertEqual(try CodexBarConfigStore().load().activeAccount()?.selectedModelID, ReserveModelPolicy.modelID)
        let route = try CodexRouteResolver.resolve(config: fixture.store.config)
        XCTAssertEqual(route.authAccount.id, account.accountId)
        XCTAssertEqual(route.targetAccount.id, account.accountId)
        XCTAssertEqual(route.effectiveModel, ReserveModelPolicy.modelID)
        XCTAssertFalse(route.routesOpenAITargetThroughGateway)
        XCTAssertFalse(route.usesFixedOAuthIdentity)
        XCTAssertFalse(fixture.gateway.isRunning)
        XCTAssertEqual(fixture.gateway.startCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
    }

    func testAccountModelPreferencesSurviveSwitchesAndRestart() throws {
        let first = try self.makeAccount(id: "first")
        let second = try self.makeAccount(id: "second")
        let fixture = try self.makeStore(accounts: [first, second])
        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)
        try fixture.store.activate(second)
        XCTAssertEqual(fixture.store.activeModel, "gpt-6-sol", "其他账号不能继承 Reserve 选择")
        try fixture.store.updateRouteModel("gpt-6-astra")
        try fixture.store.activate(first)
        XCTAssertEqual(fixture.store.activeModel, ReserveModelPolicy.modelID)

        let restarted = self.makeRuntime()
        XCTAssertEqual(restarted.store.activeModel, ReserveModelPolicy.modelID)
        try restarted.store.activate(second)
        XCTAssertEqual(restarted.store.activeModel, "gpt-6-astra")
        try restarted.store.activate(first)
        XCTAssertEqual(restarted.store.activeModel, ReserveModelPolicy.modelID)
        XCTAssertFalse(restarted.gateway.isRunning)
    }

    func testSelectingOrdinaryModelLeavesReserveThroughNormalMenuPath() throws {
        let fixture = try self.makeStore(accounts: [self.makeAccount(id: "reserve")])
        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)

        try fixture.store.updateRouteModel("gpt-6-astra")

        XCTAssertEqual(fixture.store.activeModel, "gpt-6-astra")
        XCTAssertEqual(fixture.store.activeProviderAccount?.selectedModelID, "gpt-6-astra")
        XCTAssertEqual(fixture.store.config.global.defaultModel, "gpt-6-astra")
        XCTAssertEqual(fixture.store.config.global.reviewModel, "gpt-6-astra")
        XCTAssertEqual(try CodexBarConfigStore().load().activeAccount()?.selectedModelID, "gpt-6-astra")
        XCTAssertFalse(fixture.gateway.isRunning)
    }

    func testFailedSelectionRollsBackModelInMemoryAndOnDisk() throws {
        let fixture = try self.makeStore(accounts: [self.makeAccount(id: "reserve")])
        let original = fixture.store.config
        let storedBefore = try Data(contentsOf: CodexPaths.barConfigURL)
        fixture.sync.shouldFail = true

        XCTAssertThrowsError(try fixture.store.updateRouteModel(ReserveModelPolicy.modelID))

        XCTAssertEqual(fixture.sync.persistedModelAtLastSync, ReserveModelPolicy.modelID, "同步时应已保存候选配置")
        XCTAssertNil(fixture.store.activeProviderAccount?.selectedModelID)
        XCTAssertEqual(fixture.store.activeModel, original.global.defaultModel)
        XCTAssertEqual(try Data(contentsOf: CodexPaths.barConfigURL), storedBefore)
        self.assertBaseSelection(fixture.store.config, matches: original)
        XCTAssertFalse(fixture.gateway.isRunning)
    }

    func testFailedExitKeepsReserveAndRestoresBaseSettingsOnDisk() throws {
        let fixture = try self.makeStore(accounts: [self.makeAccount(id: "reserve")])
        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)
        let original = fixture.store.config
        let storedBefore = try Data(contentsOf: CodexPaths.barConfigURL)
        fixture.sync.shouldFail = true

        XCTAssertThrowsError(try fixture.store.updateRouteModel("gpt-6-astra"))

        XCTAssertEqual(fixture.sync.persistedModelAtLastSync, "gpt-6-astra")
        XCTAssertEqual(fixture.store.activeModel, ReserveModelPolicy.modelID)
        XCTAssertEqual(try CodexBarConfigStore().load().activeAccount()?.selectedModelID, ReserveModelPolicy.modelID)
        XCTAssertEqual(try Data(contentsOf: CodexPaths.barConfigURL), storedBefore)
        self.assertBaseSelection(fixture.store.config, matches: original)
        XCTAssertFalse(fixture.gateway.isRunning)
    }

    func testQuotaRefreshPreservesSelectedReserveWithoutSilentFallback() throws {
        let account = try self.makeAccount(id: "reserve")
        let fixture = try self.makeStore(accounts: [account])
        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)
        let syncCount = fixture.sync.configs.count
        var refreshed = account
        refreshed.lunaReserveUsedPercent = 100
        refreshed.lastChecked = Date(timeIntervalSinceNow: 1)

        fixture.store.addOrUpdate(refreshed, reconcileActiveAuth: false)

        XCTAssertEqual(fixture.store.activeModel, ReserveModelPolicy.modelID)
        XCTAssertEqual(fixture.store.activeProviderAccount?.selectedModelID, ReserveModelPolicy.modelID)
        XCTAssertFalse(fixture.store.routeModelOptions(currentModel: fixture.store.activeModel).contains(ReserveModelPolicy.modelID))
        XCTAssertEqual(fixture.sync.configs.count, syncCount, "额度刷新不能擅自改写任务模型")
        let restarted = self.makeRuntime()
        XCTAssertEqual(restarted.store.activeModel, ReserveModelPolicy.modelID)
        XCTAssertEqual(restarted.store.activeProviderAccount?.lunaReserveUsedPercent, 100)
    }

    func testSelectingAndLeavingReservePreserveLiveCredentialRotationsWithUnchangedTimestamp() throws {
        let account = try self.makeAccount(id: "rotation")
        let fixture = try self.makeStore(accounts: [account])
        fixture.sync.writesLiveConfig = true
        try fixture.sync.synchronize(config: fixture.store.config)
        let beforeReserve = try self.rotateLiveCredentials(account, suffix: "before-reserve")

        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)
        XCTAssertEqual(fixture.store.oauthAccount(accountID: account.accountId)?.refreshToken, beforeReserve.refreshToken)
        let beforeLeaving = try self.rotateLiveCredentials(beforeReserve, suffix: "before-leaving")
        try fixture.store.updateRouteModel("gpt-6-sol")

        let live = try XCTUnwrap(try self.readAuthJSON()["tokens"] as? [String: Any])
        XCTAssertEqual(live["refresh_token"] as? String, beforeLeaving.refreshToken)
        XCTAssertEqual(fixture.store.oauthAccount(accountID: account.accountId)?.refreshToken, beforeLeaving.refreshToken)
        XCTAssertEqual(try CodexBarConfigStore().load().activeAccount()?.refreshToken, beforeLeaving.refreshToken)
        XCTAssertFalse(fixture.gateway.isRunning)
    }

    func testFailedExitRetainsActualCredentialRotationAndReserveSelection() throws {
        let account = try self.makeAccount(id: "rotation")
        let fixture = try self.makeStore(accounts: [account])
        fixture.sync.writesLiveConfig = true
        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)
        let rotated = try self.rotateLiveCredentials(account, suffix: "before-failed-exit")
        fixture.sync.shouldFail = true

        XCTAssertThrowsError(try fixture.store.updateRouteModel("gpt-6-astra"))

        XCTAssertEqual(fixture.store.activeModel, ReserveModelPolicy.modelID)
        XCTAssertEqual(fixture.store.oauthAccount(accountID: account.accountId)?.refreshToken, rotated.refreshToken)
        let stored = try CodexBarConfigStore().load()
        XCTAssertEqual(stored.activeAccount()?.selectedModelID, ReserveModelPolicy.modelID)
        XCTAssertEqual(stored.activeAccount()?.refreshToken, rotated.refreshToken)
        let live = try XCTUnwrap(try self.readAuthJSON()["tokens"] as? [String: Any])
        XCTAssertEqual(live["refresh_token"] as? String, rotated.refreshToken)
    }

    func testAggregateModeReserveIsDirectAndKeepsOldGatewayListener() throws {
        let account = try self.makeAccount(id: "aggregate")
        let fixture = try self.makeStore(accounts: [account], mode: .aggregateGateway)
        XCTAssertTrue(fixture.gateway.isRunning)

        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)

        let route = try CodexRouteResolver.resolve(config: fixture.store.config)
        XCTAssertEqual(route.mode, .aggregateGateway)
        XCTAssertEqual(route.authAccount.id, account.accountId)
        XCTAssertFalse(route.routesOpenAITargetThroughGateway)
        XCTAssertTrue(fixture.gateway.isRunning, "旧普通聚合任务仍需要已有监听器")
        XCTAssertEqual(fixture.gateway.lastMode, .aggregateGateway)
        try fixture.store.updateRouteModel("gpt-6-sol")
        XCTAssertTrue(try CodexRouteResolver.resolve(config: fixture.store.config).routesOpenAITargetThroughGateway)
        XCTAssertTrue(fixture.gateway.isRunning)
    }

    func testFixedIdentityReserveUsesTargetAccountDirectlyAndKeepsOldGatewayListener() throws {
        let target = try self.makeAccount(id: "target")
        let fixed = try self.makeAccount(id: "fixed")
        let fixture = try self.makeStore(accounts: [target, fixed], remoteAccountID: fixed.accountId)
        let original = try CodexRouteResolver.resolve(config: fixture.store.config)
        XCTAssertEqual(original.authAccount.id, fixed.accountId)
        XCTAssertTrue(original.routesOpenAITargetThroughGateway)

        try fixture.store.updateRouteModel(ReserveModelPolicy.modelID)

        let route = try CodexRouteResolver.resolve(config: fixture.store.config)
        XCTAssertEqual(route.authAccount.id, target.accountId)
        XCTAssertEqual(route.targetAccount.id, target.accountId)
        XCTAssertFalse(route.usesFixedOAuthIdentity)
        XCTAssertFalse(route.routesOpenAITargetThroughGateway)
        XCTAssertEqual(fixture.store.config.openAI.remoteConnectionAccountID, fixed.accountId)
        XCTAssertTrue(fixture.gateway.isRunning, "旧固定身份任务仍需要已有监听器")
        try fixture.store.updateRouteModel("gpt-6-sol")
        XCTAssertEqual(try CodexRouteResolver.resolve(config: fixture.store.config).authAccount.id, fixed.accountId)
        XCTAssertTrue(fixture.gateway.isRunning)
    }

    private func makeAccount(id: String) throws -> TokenAccount {
        var account = try self.makeOAuthAccount(accountID: id, email: "\(id)@example.com")
        account.tokenLastRefreshAt = Date(timeIntervalSince1970: 1_730_000_000)
        account.lunaReserveUsedPercent = 20
        account.lunaReserveResetAt = Date(timeIntervalSinceNow: 3_600)
        account.lunaReserveLimitWindowSeconds = 604_800
        account.lastChecked = Date()
        return account
    }

    private func rotateLiveCredentials(_ account: TokenAccount, suffix: String) throws -> TokenAccount {
        var rotated = account
        rotated.refreshToken = "synthetic-rotation-\(suffix)"
        try self.writeAuthJSON(
            accessToken: rotated.accessToken, refreshToken: rotated.refreshToken,
            idToken: rotated.idToken, remoteAccountID: rotated.remoteAccountId,
            lastRefresh: rotated.tokenLastRefreshAt
        )
        return rotated
    }

    private func makeStore(
        accounts: [TokenAccount],
        mode: CodexBarOpenAIAccountUsageMode = .switchAccount,
        remoteAccountID: String? = nil
    ) throws -> (store: TokenStore, gateway: ReserveModelGatewaySpy, sync: ReserveModelSyncSpy) {
        let storedAccounts = accounts.map { CodexBarProviderAccount.fromTokenAccount($0, existingID: $0.accountId) }
        let provider = CodexBarProvider(
            id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI",
            activeAccountId: storedAccounts.first?.id,
            accounts: storedAccounts
        )
        var settings = CodexBarOpenAISettings(accountUsageMode: mode)
        settings.remoteConnectionAccountID = remoteAccountID
        try self.writeConfig(CodexBarConfig(
            global: CodexBarGlobalSettings(
                defaultModel: "gpt-6-sol", reviewModel: "gpt-6-astra",
                reasoningEffort: "ultra", serviceTier: "fast"
            ),
            active: CodexBarActiveSelection(providerId: provider.id, accountId: storedAccounts.first?.id),
            openAI: settings,
            providers: [provider]
        ))
        return self.makeRuntime()
    }

    private func makeRuntime() -> (store: TokenStore, gateway: ReserveModelGatewaySpy, sync: ReserveModelSyncSpy) {
        let gateway = ReserveModelGatewaySpy()
        let sync = ReserveModelSyncSpy()
        let providerGateway = ReserveModelProviderGatewayStub()
        let store = TokenStore(
            syncService: sync,
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: providerGateway,
            chatCompletionsGatewayService: providerGateway,
            aggregateGatewayLeaseStore: ReserveModelAggregateLeaseStub(),
            localCostRefreshWorker: { _, _, _ in
                LocalCostRefreshOutcome(
                    summary: nil, isComplete: true, mayReplaceLastKnownGood: true,
                    warningCount: 0, lastRawSessionScanAt: nil, latestUsageEventAt: nil,
                    progress: .zero, errorMessage: nil
                )
            },
            codexRunningProcessIDs: { [] },
            loadServiceTierCatalog: { nil }
        )
        return (store, gateway, sync)
    }

    private func assertBaseSelection(
        _ actual: CodexBarConfig,
        matches expected: CodexBarConfig,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.active.providerId, expected.active.providerId, file: file, line: line)
        XCTAssertEqual(actual.active.accountId, expected.active.accountId, file: file, line: line)
        XCTAssertEqual(actual.global.defaultModel, expected.global.defaultModel, file: file, line: line)
        XCTAssertEqual(actual.global.reviewModel, expected.global.reviewModel, file: file, line: line)
        XCTAssertEqual(actual.global.reasoningEffort, expected.global.reasoningEffort, file: file, line: line)
        XCTAssertEqual(actual.global.serviceTier, expected.global.serviceTier, file: file, line: line)
        XCTAssertEqual(actual.openAI.accountUsageMode, expected.openAI.accountUsageMode, file: file, line: line)
        XCTAssertEqual(actual.openAI.remoteConnectionAccountID, expected.openAI.remoteConnectionAccountID, file: file, line: line)
    }
}

private final class ReserveModelSyncSpy: CodexSynchronizing {
    var shouldFail = false
    var writesLiveConfig = false
    private(set) var configs: [CodexBarConfig] = []
    private(set) var persistedModelAtLastSync: String?

    func synchronize(config: CodexBarConfig) throws {
        self.configs.append(config)
        self.persistedModelAtLastSync = try CodexRouteResolver.resolve(config: CodexBarConfigStore().load()).effectiveModel
        if self.shouldFail { throw CocoaError(.fileWriteUnknown) }
        if self.writesLiveConfig {
            try CodexSyncService(loadServiceTierCatalog: { nil }).synchronize(config: config)
        }
    }
}

private final class ReserveModelGatewaySpy: OpenAIAccountGatewayControlling {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var lastMode: CodexBarOpenAIAccountUsageMode?

    func startIfNeeded() { self.isRunning = true; self.startCount += 1 }
    func stop() { self.isRunning = false }
    func currentRoutedAccountID() -> String? { nil }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { [] }
    func clearStickyBinding(threadID: String) -> Bool { false }

    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        reserveActiveAccountQuota: Bool,
        reserveActiveAccountQuotaPercent: Int,
        defaultProxy: OpenAIAccountGatewayConfiguredProxy?,
        proxyByAccountID: [String: OpenAIAccountGatewayConfiguredProxy]
    ) { self.lastMode = accountUsageMode }
}

private final class ReserveModelProviderGatewayStub: OpenRouterGatewayControlling, ChatCompletionsGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {}
}

private final class ReserveModelAggregateLeaseStub: OpenAIAggregateGatewayLeaseStoring {
    func loadProcessIDs() -> Set<pid_t> { [] }
    func saveProcessIDs(_ processIDs: Set<pid_t>) {}
    func clear() {}
}
