import Foundation
import XCTest

@MainActor
final class TokenStoreGatewayLifecycleTests: CodexBarTestCase {
    func testOpenRouterInitializationKeepsGatewayStoppedWhenInactive() {
        let openAIGateway = OpenAIAccountGatewayControllerSpy()
        let openRouterGateway = OpenRouterGatewayControllerSpy()

        _ = TokenStore(
            openAIAccountGatewayService: openAIGateway,
            openRouterGatewayService: openRouterGateway,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(openRouterGateway.startCount, 0)
        XCTAssertEqual(openRouterGateway.stopCount, 1)
    }

    func testOpenRouterInitializationStartsGatewayWhenActiveProviderIsOpenRouter() throws {
        let account = CodexBarProviderAccount(
            id: "acct-openrouter",
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-primary"
        )
        let provider = CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            selectedModelID: "openai/gpt-4.1",
            activeAccountId: account.id,
            accounts: [account]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
                providers: [provider]
            )
        )

        let openAIGateway = OpenAIAccountGatewayControllerSpy()
        let openRouterGateway = OpenRouterGatewayControllerSpy()

        _ = TokenStore(
            openAIAccountGatewayService: openAIGateway,
            openRouterGatewayService: openRouterGateway,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(openRouterGateway.startCount, 1)
        XCTAssertEqual(openRouterGateway.stopCount, 0)
    }

    func testOpenRouterLeaseRestoreStartsGatewayWhenInactiveProviderStillHasServiceableState() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-restore")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: [404],
                leasedAt: Date(timeIntervalSince1970: 1_710_000_000),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        _ = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [404] }
        )

        XCTAssertEqual(openRouterGateway.startCount, 1)
        XCTAssertEqual(openRouterGateway.stopCount, 0)
        XCTAssertFalse(leaseStore.cleared)
        XCTAssertNil(leaseStore.lastSavedLease)
        XCTAssertEqual(openRouterGateway.lastProvider?.id, openRouterProvider.id)
        XCTAssertFalse(openRouterGateway.lastIsActiveProvider)
    }

    func testOpenRouterLeaseAcquireKeepsGatewayRunningAfterSwitchingAwayFromActiveProvider() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-acquire")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        let runningPIDs: Set<pid_t> = [101, 202]
        let leaseStore = OpenRouterGatewayLeaseStoreSpy()
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: openRouterProvider.id, accountId: openRouterAccount.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { runningPIDs }
        )

        try store.activateCustomProvider(providerID: custom.provider.id, accountID: custom.account.id)

        XCTAssertEqual(openRouterGateway.stopCount, 0)
        XCTAssertEqual(leaseStore.lastSavedLease?.processIDs, runningPIDs)
        XCTAssertEqual(leaseStore.lastSavedLease?.sourceProviderId, "openrouter")
        XCTAssertEqual(openRouterGateway.lastProvider?.id, openRouterProvider.id)
        XCTAssertFalse(openRouterGateway.lastIsActiveProvider)
    }

    func testOpenRouterLeaseRenewTracksNewRunningCodexProcesses() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-renew")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        var runningPIDs: Set<pid_t> = [101]
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: runningPIDs,
                leasedAt: Date(timeIntervalSince1970: 1_710_000_100),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { runningPIDs }
        )

        runningPIDs = [101, 202]
        store.markActiveAccount()

        XCTAssertEqual(openRouterGateway.stopCount, 0)
        XCTAssertEqual(leaseStore.lastSavedLease?.processIDs, runningPIDs)
        XCTAssertEqual(leaseStore.lastSavedLease?.sourceProviderId, "openrouter")
    }

    func testOpenRouterLeaseReleaseClearsPersistedLeaseWhenProviderBecomesActiveAgain() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-release")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: [303],
                leasedAt: Date(timeIntervalSince1970: 1_710_000_200),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [303] }
        )

        try store.activateOpenRouterProvider(accountID: openRouterAccount.id)

        XCTAssertTrue(leaseStore.cleared)
        XCTAssertNil(leaseStore.lastSavedLease)
        XCTAssertTrue(openRouterGateway.lastIsActiveProvider)
        XCTAssertEqual(openRouterGateway.lastProvider?.id, openRouterProvider.id)
    }

    func testOpenRouterLeaseStaleCleanupStopsGatewayAfterAllLeasedProcessesExit() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-stale")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        var runningPIDs: Set<pid_t> = [909]
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: runningPIDs,
                leasedAt: Date(timeIntervalSince1970: 1_710_000_300),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { runningPIDs }
        )

        runningPIDs = []
        store.markActiveAccount()

        XCTAssertTrue(leaseStore.cleared)
        XCTAssertEqual(openRouterGateway.stopCount, 1)
    }

    func testOpenRouterLeaseClearsWhenCanonicalProviderStopsBeingServiceable() throws {
        let openRouterAccount = self.makeOpenRouterAccount(id: "acct-openrouter-invalid")
        let openRouterProvider = self.makeOpenRouterProvider(account: openRouterAccount)
        let custom = self.makeCustomProvider()
        let leaseStore = OpenRouterGatewayLeaseStoreSpy(
            initialLease: OpenRouterGatewayLeaseSnapshot(
                processIDs: [808],
                leasedAt: Date(timeIntervalSince1970: 1_710_000_400),
                sourceProviderId: openRouterProvider.id
            )
        )
        let openRouterGateway = OpenRouterGatewayControllerSpy()
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: custom.provider.id, accountId: custom.account.id),
                providers: [openRouterProvider, custom.provider]
            )
        )

        let store = TokenStore(
            syncService: RecordingSyncService(),
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: openRouterGateway,
            openRouterGatewayLeaseStore: leaseStore,
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [808] }
        )

        try store.removeOpenRouterProviderAccount(accountID: openRouterAccount.id)

        XCTAssertTrue(leaseStore.cleared)
        XCTAssertEqual(openRouterGateway.stopCount, 1)
        XCTAssertNil(openRouterGateway.lastProvider)
    }

    func testSwitchModeInitializationKeepsGatewayStopped() {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()

        _ = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.startCount, 0)
        XCTAssertEqual(gateway.stopCount, 1)
        XCTAssertEqual(gateway.updatedModes, [.switchAccount])
    }

    func testAggregateModeInitializationStartsGateway() throws {
        var config = CodexBarConfig()
        config.openAI.accountUsageMode = .aggregateGateway
        try self.writeConfig(config)

        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()

        _ = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )

        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, 0)
        XCTAssertEqual(gateway.updatedModes, [.aggregateGateway])
    }

    func testAggregateLocalAPIKeyInitializationPublishesResolvedGatewayCredential() throws {
        let account = try self.makeOAuthAccount(
            accountID: "acct-local-api-key-runtime",
            email: "local-api-key-runtime@example.com"
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
                    gatewayCredentialMode: .localAPIKey
                ),
                providers: [provider]
            )
        )

        let gateway = OpenAIAccountGatewayControllerSpy()

        _ = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        let credentialData = try Data(contentsOf: CodexPaths.openAIGatewayCredentialURL)
        let credential = try JSONDecoder.iso8601.decode(OpenAIGatewayCredentialSnapshot.self, from: credentialData)

        XCTAssertEqual(gateway.updatedModes, [.aggregateGateway])
        XCTAssertEqual(gateway.updatedGatewayCredentials.last?.mode, .localAPIKey)
        XCTAssertEqual(gateway.updatedGatewayCredentials.last?.localAPIKey, credential.openAIAPIKey)
    }

    func testUpdatingUsageModeStartsAndStopsGateway() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()
        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )
        let account = try self.makeOAuthAccount(
            accountID: "acct-gateway",
            email: "gateway@example.com"
        )

        store.addOrUpdate(account)
        try store.activate(account)

        let initialStopCount = gateway.stopCount
        let initialUpdateCount = gateway.updatedModes.count

        try store.updateOpenAIAccountUsageMode(.aggregateGateway)
        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, initialStopCount)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .aggregateGateway)

        try store.updateOpenAIAccountUsageMode(.switchAccount)
        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, initialStopCount + 1)
        XCTAssertEqual(gateway.updatedModes.count, initialUpdateCount + 2)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .switchAccount)
    }

    func testAggregateLeaseKeepsGatewayRunningAfterSwitchModeChange() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()
        let runningPIDs: Set<pid_t> = [101, 202]
        let account = try self.makeOAuthAccount(
            accountID: "acct-lease",
            email: "lease@example.com"
        )
        let storedAccount = CodexBarProviderAccount.fromTokenAccount(account, existingID: account.accountId)
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedAccount.id,
            accounts: [storedAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: storedAccount.id),
            openAI: CodexBarOpenAISettings(accountUsageMode: .aggregateGateway),
            providers: [provider]
        )
        try self.writeConfig(config)

        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { runningPIDs }
        )

        try store.updateOpenAIAccountUsageMode(.switchAccount)

        XCTAssertEqual(store.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertEqual(leaseStore.savedProcessIDs, runningPIDs)
        XCTAssertEqual(gateway.stopCount, 0)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .aggregateGateway)
    }

    func testGatewayStopsOnceLeasedAggregateProcessesExit() {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy(initialProcessIDs: [404])
        var runningPIDs: Set<pid_t> = [404]

        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { runningPIDs }
        )

        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .aggregateGateway)

        runningPIDs = []
        store.markActiveAccount()

        XCTAssertTrue(leaseStore.cleared)
        XCTAssertEqual(gateway.updatedModes.suffix(1).first, .switchAccount)
        XCTAssertEqual(gateway.stopCount, 1)
    }

    func testPersistedAggregateLeaseRestoresGatewayAfterRestart() {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy(initialProcessIDs: [303])

        _ = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [303] }
        )

        XCTAssertEqual(gateway.startCount, 1)
        XCTAssertEqual(gateway.stopCount, 0)
        XCTAssertEqual(gateway.updatedModes, [.aggregateGateway])
    }

    func testGatewayRouteNotificationRefreshesAggregateRoutedAccount() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()
        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )
        let account = try self.makeOAuthAccount(
            accountID: "acct-routed",
            email: "routed@example.com"
        )

        store.addOrUpdate(account)
        gateway.currentRoutedAccountIDValue = account.accountId

        NotificationCenter.default.post(
            name: .openAIAccountGatewayDidRouteAccount,
            object: gateway,
            userInfo: ["accountID": account.accountId]
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(store.aggregateRoutedAccount?.accountId, account.accountId)
    }

    func testRuntimeRouteSnapshotShowsLeaseButNotFutureStickyAfterSwitchBack() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        gateway.currentRoutedAccountIDValue = "acct-lease"
        gateway.stickyBindings = [
            OpenAIAggregateStickyBindingSnapshot(
                threadID: "thread-lease",
                accountID: "acct-lease",
                updatedAt: Date().addingTimeInterval(-120)
            )
        ]
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy(initialProcessIDs: [404])
        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [404] }
        )
        let attribution = OpenAIRunningThreadAttribution(
            threads: [],
            summary: .empty,
            recentActivityWindow: 5,
            diagnosticMessage: nil,
            unavailableReason: nil
        )

        let snapshot = store.openAIRuntimeRouteSnapshot(
            runningThreadAttribution: attribution,
            now: Date()
        )

        XCTAssertEqual(snapshot.configuredMode, .switchAccount)
        XCTAssertEqual(snapshot.effectiveMode, .aggregateGateway)
        XCTAssertTrue(snapshot.aggregateRuntimeActive)
        XCTAssertTrue(snapshot.leaseActive)
        XCTAssertFalse(snapshot.stickyAffectsFutureRouting)
        XCTAssertFalse(snapshot.staleStickyEligible)
        XCTAssertEqual(snapshot.latestRoutedAccountID, "acct-lease")
        XCTAssertTrue(snapshot.latestRoutedAccountIsSummary)
    }

    func testClearStaleAggregateStickyOnlyClearsGatewayBinding() {
        let gateway = OpenAIAccountGatewayControllerSpy()
        gateway.stickyBindings = [
            OpenAIAggregateStickyBindingSnapshot(
                threadID: "thread-stale",
                accountID: "acct-stale",
                updatedAt: Date().addingTimeInterval(-120)
            )
        ]
        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )
        let snapshot = OpenAIRuntimeRouteSnapshot(
            configuredMode: .aggregateGateway,
            effectiveMode: .aggregateGateway,
            aggregateRuntimeActive: true,
            latestRoutedAccountID: "acct-stale",
            latestRoutedAccountIsSummary: true,
            stickyAffectsFutureRouting: true,
            leaseActive: false,
            staleStickyEligible: true,
            staleStickyThreadID: "thread-stale",
            latestRouteAt: Date().addingTimeInterval(-120)
        )

        XCTAssertTrue(store.clearStaleAggregateSticky(using: snapshot))
        XCTAssertEqual(gateway.clearedStickyThreadIDs, ["thread-stale"])
        XCTAssertTrue(gateway.stickyBindings.isEmpty)
    }

    func testAggregateModePreservesSwitchSelectionAndRestoresItWhenSwitchingBack() throws {
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()
        let oauthAccount = try self.makeOAuthAccount(
            accountID: "acct-oauth",
            email: "oauth@example.com"
        )
        let storedOAuthAccount = CodexBarProviderAccount.fromTokenAccount(
            oauthAccount,
            existingID: oauthAccount.accountId
        )
        let compatibleAccount = CodexBarProviderAccount(
            id: "acct-compatible",
            kind: .apiKey,
            label: "compatible",
            apiKey: "sk-compatible"
        )
        let oauthProvider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: storedOAuthAccount.id,
            accounts: [storedOAuthAccount]
        )
        let compatibleProvider = CodexBarProvider(
            id: "compatible-provider",
            kind: .openAICompatible,
            label: "Compatible",
            activeAccountId: compatibleAccount.id,
            accounts: [compatibleAccount]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(
                providerId: compatibleProvider.id,
                accountId: compatibleAccount.id
            ),
            openAI: CodexBarOpenAISettings(accountUsageMode: .switchAccount),
            providers: [oauthProvider, compatibleProvider]
        )
        try self.writeConfig(config)

        let store = TokenStore(
            openAIAccountGatewayService: gateway,
            openRouterGatewayService: OpenRouterGatewayControllerSpy(),
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )

        try store.updateOpenAIAccountUsageMode(.aggregateGateway)

        XCTAssertEqual(
            store.config.openAI.switchModeSelection,
            CodexBarActiveSelection(
                providerId: compatibleProvider.id,
                accountId: compatibleAccount.id
            )
        )
        XCTAssertEqual(store.config.active.providerId, oauthProvider.id)
        XCTAssertEqual(store.config.active.accountId, storedOAuthAccount.id)

        try store.updateOpenAIAccountUsageMode(.switchAccount)

        XCTAssertEqual(store.config.openAI.accountUsageMode, .switchAccount)
        XCTAssertEqual(store.config.active.providerId, compatibleProvider.id)
        XCTAssertEqual(store.config.active.accountId, compatibleAccount.id)
    }

    func testInitializationAbsorbsNewerAuthJSONSnapshot() throws {
        let olderRefreshAt = Date(timeIntervalSince1970: 1_760_000_000)
        let newerRefreshAt = Date(timeIntervalSince1970: 1_760_000_600)
        let localAccount = try self.makeOAuthAccount(
            accountID: "acct_load_reconcile",
            email: "load-reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_760_003_600),
            oauthClientID: "app_local_load",
            tokenLastRefreshAt: olderRefreshAt
        )
        let authAccount = try self.makeOAuthAccount(
            accountID: "acct_load_reconcile",
            email: "load-reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_760_007_200),
            oauthClientID: "app_auth_load",
            tokenLastRefreshAt: newerRefreshAt
        )
        let stored = CodexBarProviderAccount.fromTokenAccount(localAccount, existingID: localAccount.accountId)
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
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
            accessToken: authAccount.accessToken,
            refreshToken: authAccount.refreshToken,
            idToken: authAccount.idToken,
            remoteAccountID: authAccount.remoteAccountId,
            clientID: "app_auth_load",
            lastRefresh: newerRefreshAt
        )

        let store = TokenStore(
            openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
            codexRunningProcessIDs: { [] }
        )

        let resolved = try XCTUnwrap(store.oauthAccount(accountID: localAccount.accountId))
        XCTAssertEqual(resolved.accessToken, authAccount.accessToken)
        XCTAssertEqual(resolved.oauthClientID, "app_auth_load")
        XCTAssertEqual(resolved.tokenLastRefreshAt, newerRefreshAt)
    }

    func testActivateAbsorbsNewerAuthJSONBeforeSynchronizing() throws {
        let syncService = RecordingSyncService()
        let gateway = OpenAIAccountGatewayControllerSpy()
        let leaseStore = OpenAIAggregateGatewayLeaseStoreSpy()

        let activeOtherAccount = try self.makeOAuthAccount(
            accountID: "acct_active_other",
            email: "active-other@example.com"
        )
        let localAccount = try self.makeOAuthAccount(
            accountID: "acct_activate_reconcile",
            email: "activate-reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_770_003_600),
            oauthClientID: "app_activate_local",
            tokenLastRefreshAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let authAccount = try self.makeOAuthAccount(
            accountID: "acct_activate_reconcile",
            email: "activate-reconcile@example.com",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_770_007_200),
            oauthClientID: "app_activate_auth",
            tokenLastRefreshAt: Date(timeIntervalSince1970: 1_770_000_600)
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: activeOtherAccount.accountId,
            accounts: [
                CodexBarProviderAccount.fromTokenAccount(activeOtherAccount, existingID: activeOtherAccount.accountId),
                CodexBarProviderAccount.fromTokenAccount(localAccount, existingID: localAccount.accountId),
            ]
        )
        try self.writeConfig(
            CodexBarConfig(
                active: CodexBarActiveSelection(providerId: provider.id, accountId: activeOtherAccount.accountId),
                providers: [provider]
            )
        )
        try self.writeAuthJSON(
            accessToken: authAccount.accessToken,
            refreshToken: authAccount.refreshToken,
            idToken: authAccount.idToken,
            remoteAccountID: authAccount.remoteAccountId,
            clientID: "app_activate_auth",
            lastRefresh: Date(timeIntervalSince1970: 1_770_000_600)
        )

        let store = TokenStore(
            syncService: syncService,
            openAIAccountGatewayService: gateway,
            aggregateGatewayLeaseStore: leaseStore,
            codexRunningProcessIDs: { [] }
        )

        try store.activate(localAccount)

        let synchronizedAccount = try XCTUnwrap(syncService.lastConfig?.activeAccount())
        XCTAssertEqual(synchronizedAccount.accessToken, authAccount.accessToken)
        XCTAssertEqual(synchronizedAccount.oauthClientID, "app_activate_auth")
        XCTAssertEqual(store.activeAccount()?.accessToken, authAccount.accessToken)
    }
}

private final class OpenAIAccountGatewayControllerSpy: OpenAIAccountGatewayControlling {
    var startCount = 0
    var stopCount = 0
    var updatedModes: [CodexBarOpenAIAccountUsageMode] = []
    var updatedGatewayCredentials: [OpenAIAccountGatewayResolvedCredential] = []
    var currentRoutedAccountIDValue: String?
    var stickyBindings: [OpenAIAggregateStickyBindingSnapshot] = []
    private(set) var clearedStickyThreadIDs: [String] = []

    func startIfNeeded() {
        self.startCount += 1
    }

    func stop() {
        self.stopCount += 1
    }

    func updateState(
        accounts: [TokenAccount],
        quotaSortSettings: CodexBarOpenAISettings.QuotaSortSettings,
        accountUsageMode: CodexBarOpenAIAccountUsageMode,
        gatewayCredential: OpenAIAccountGatewayResolvedCredential
    ) {
        self.updatedModes.append(accountUsageMode)
        self.updatedGatewayCredentials.append(gatewayCredential)
    }

    func currentRoutedAccountID() -> String? {
        self.currentRoutedAccountIDValue
    }

    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] {
        self.stickyBindings
    }

    func clearStickyBinding(threadID: String) -> Bool {
        self.clearedStickyThreadIDs.append(threadID)
        let before = self.stickyBindings.count
        self.stickyBindings.removeAll { $0.threadID == threadID }
        return self.stickyBindings.count != before
    }
}

private final class OpenRouterGatewayControllerSpy: OpenRouterGatewayControlling {
    var startCount = 0
    var stopCount = 0
    private(set) var lastProvider: CodexBarProvider?
    private(set) var lastIsActiveProvider = false

    func startIfNeeded() {
        self.startCount += 1
    }

    func stop() {
        self.stopCount += 1
    }

    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {
        self.lastProvider = provider
        self.lastIsActiveProvider = isActiveProvider
    }
}

private final class OpenRouterGatewayLeaseStoreSpy: OpenRouterGatewayLeaseStoring {
    private var currentLease: OpenRouterGatewayLeaseSnapshot?
    private(set) var lastSavedLease: OpenRouterGatewayLeaseSnapshot?
    private(set) var cleared = false

    init(initialLease: OpenRouterGatewayLeaseSnapshot? = nil) {
        self.currentLease = initialLease
    }

    func loadLease() -> OpenRouterGatewayLeaseSnapshot? {
        self.currentLease
    }

    func saveLease(_ lease: OpenRouterGatewayLeaseSnapshot) {
        self.currentLease = lease
        self.lastSavedLease = lease
        self.cleared = false
    }

    func clear() {
        self.currentLease = nil
        self.lastSavedLease = nil
        self.cleared = true
    }
}

private final class OpenAIAggregateGatewayLeaseStoreSpy: OpenAIAggregateGatewayLeaseStoring {
    private(set) var savedProcessIDs: Set<pid_t> = []
    private(set) var cleared = false
    private let initialProcessIDs: Set<pid_t>

    init(initialProcessIDs: Set<pid_t> = []) {
        self.initialProcessIDs = initialProcessIDs
    }

    func loadProcessIDs() -> Set<pid_t> {
        self.initialProcessIDs
    }

    func saveProcessIDs(_ processIDs: Set<pid_t>) {
        self.savedProcessIDs = processIDs
        self.cleared = false
    }

    func clear() {
        self.savedProcessIDs = []
        self.cleared = true
    }
}

private final class RecordingSyncService: CodexSynchronizing {
    private(set) var callCount = 0
    private(set) var lastConfig: CodexBarConfig?

    func synchronize(config: CodexBarConfig) throws {
        self.callCount += 1
        self.lastConfig = config
    }
}

private extension TokenStoreGatewayLifecycleTests {
    func makeOpenRouterAccount(id: String) -> CodexBarProviderAccount {
        CodexBarProviderAccount(
            id: id,
            kind: .apiKey,
            label: "Primary",
            apiKey: "sk-or-v1-\(id)"
        )
    }

    func makeOpenRouterProvider(account: CodexBarProviderAccount) -> CodexBarProvider {
        CodexBarProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            selectedModelID: "openai/gpt-4.1",
            activeAccountId: account.id,
            accounts: [account]
        )
    }

    func makeCustomProvider() -> (provider: CodexBarProvider, account: CodexBarProviderAccount) {
        let account = CodexBarProviderAccount(
            id: "acct-compatible",
            kind: .apiKey,
            label: "Compatible",
            apiKey: "sk-compatible"
        )
        let provider = CodexBarProvider(
            id: "compatible-provider",
            kind: .openAICompatible,
            label: "Compatible",
            enabled: true,
            baseURL: "https://example.invalid/v1",
            activeAccountId: account.id,
            accounts: [account]
        )
        return (provider, account)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
