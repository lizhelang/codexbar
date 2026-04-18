import AppKit
import Combine
import Foundation

struct OpenAIAccountSettingsUpdate: Equatable {
    var accountOrder: [String]
    var accountUsageMode: CodexBarOpenAIAccountUsageMode
    var accountOrderingMode: CodexBarOpenAIAccountOrderingMode
    var manualActivationBehavior: CodexBarOpenAIManualActivationBehavior
}

struct OpenAIUsageSettingsUpdate: Equatable {
    var usageDisplayMode: CodexBarUsageDisplayMode
    var plusRelativeWeight: Double
    var proRelativeToPlusMultiplier: Double
    var teamRelativeToPlusMultiplier: Double
}

struct DesktopSettingsUpdate: Equatable {
    var preferredCodexAppPath: String?
}

struct SettingsSaveRequests: Equatable {
    var openAIAccount: OpenAIAccountSettingsUpdate?
    var openAIUsage: OpenAIUsageSettingsUpdate?
    var desktop: DesktopSettingsUpdate?

    init(
        openAIAccount: OpenAIAccountSettingsUpdate? = nil,
        openAIUsage: OpenAIUsageSettingsUpdate? = nil,
        desktop: DesktopSettingsUpdate? = nil
    ) {
        self.openAIAccount = openAIAccount
        self.openAIUsage = openAIUsage
        self.desktop = desktop
    }

    var isEmpty: Bool {
        self.openAIAccount == nil &&
        self.openAIUsage == nil &&
        self.desktop == nil
    }
}

final class TokenStore: ObservableObject {
    static let shared = TokenStore()

    @Published var accounts: [TokenAccount] = []
    @Published private(set) var config: CodexBarConfig
    @Published private(set) var localCostSummary: LocalCostSummary = .empty
    @Published private(set) var aggregateRoutedAccountID: String?

    private let configStore: CodexBarConfigStore
    private let syncService: any CodexSynchronizing
    private let switchJournalStore = SwitchJournalStore()
    private let costSummaryService = LocalCostSummaryService()
    private let openAIAccountGatewayService: OpenAIAccountGatewayControlling
    private let openRouterGatewayService: OpenRouterGatewayControlling
    private let aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoring
    private let aggregateRouteJournalStore: OpenAIAggregateRouteJournalStoring
    private let codexRunningProcessIDs: () -> Set<pid_t>
    private let refreshStateQueue = DispatchQueue(label: "lzl.codexbar.refresh-state")
    private let usageRefreshStateQueue = DispatchQueue(label: "lzl.codexbar.usage-refresh-state")
    private var isRefreshingLocalCostSummary = false
    private var isRefreshingAllUsage = false
    private var refreshingUsageAccountIDs: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private var aggregateGatewayLeaseProcessIDs: Set<pid_t>
    private var aggregateGatewayLeaseTimer: Timer?

    init(
        configStore: CodexBarConfigStore = CodexBarConfigStore(),
        syncService: any CodexSynchronizing = CodexSyncService(),
        openAIAccountGatewayService: OpenAIAccountGatewayControlling = OpenAIAccountGatewayService.shared,
        openRouterGatewayService: OpenRouterGatewayControlling = OpenRouterGatewayService(),
        aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoring = OpenAIAggregateGatewayLeaseStore(),
        aggregateRouteJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore(),
        codexRunningProcessIDs: @escaping () -> Set<pid_t> = {
            Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier))
        }
    ) {
        self.configStore = configStore
        self.syncService = syncService
        self.openAIAccountGatewayService = openAIAccountGatewayService
        self.openRouterGatewayService = openRouterGatewayService
        self.aggregateGatewayLeaseStore = aggregateGatewayLeaseStore
        self.aggregateRouteJournalStore = aggregateRouteJournalStore
        self.codexRunningProcessIDs = codexRunningProcessIDs
        self.aggregateGatewayLeaseProcessIDs = aggregateGatewayLeaseStore.loadProcessIDs()

        if let loaded = try? self.configStore.loadOrMigrate() {
            self.config = loaded
        } else {
            self.config = CodexBarConfig()
        }

        NotificationCenter.default.publisher(for: .openAIAccountGatewayDidRouteAccount)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.aggregateRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
            }
            .store(in: &self.cancellables)

        self.publishState()
        self.localCostSummary = self.loadCachedLocalCostSummary()
        self.seedSwitchJournalIfNeeded()
        try? self.syncService.synchronize(config: self.config)
    }

    var customProviders: [CodexBarProvider] {
        self.config.providers.filter { $0.kind == .openAICompatible }
    }

    var openRouterProvider: CodexBarProvider? {
        self.config.openRouterProvider()
    }

    var activeProvider: CodexBarProvider? {
        self.config.activeProvider()
    }

    var activeProviderAccount: CodexBarProviderAccount? {
        self.config.activeAccount()
    }

    var activeModel: String {
        if let activeProvider = self.config.activeProvider(),
           activeProvider.kind == .openRouter,
           let defaultModel = activeProvider.defaultModel {
            return defaultModel
        }
        return self.config.global.defaultModel
    }

    var aggregateRoutedAccount: TokenAccount? {
        guard let aggregateRoutedAccountID else { return nil }
        return self.accounts.first(where: { $0.accountId == aggregateRoutedAccountID })
    }

    func load() {
        if let loaded = try? self.configStore.loadOrMigrate() {
            self.config = loaded
            self.publishState()
            self.localCostSummary = self.loadCachedLocalCostSummary()
        }
    }

    func addOrUpdate(_ account: TokenAccount) {
        let result = self.config.upsertOAuthAccount(account, activate: false)
        self.persistIgnoringErrors(syncCodex: result.syncCodex)
    }

    func remove(_ account: TokenAccount) {
        guard var provider = self.oauthProvider() else { return }
        provider.accounts.removeAll { $0.id == account.accountId }
        self.config.removeOpenAIAccountOrder(accountID: account.accountId)

        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == provider.id }
            if self.config.active.providerId == provider.id {
                let fallback = self.config.providers.first
                self.config.active.providerId = fallback?.id
                self.config.active.accountId = fallback?.activeAccount?.id
            }
        } else {
            if provider.activeAccountId == account.accountId {
                provider.activeAccountId = provider.accounts.first?.id
            }
            if self.config.active.providerId == provider.id && self.config.active.accountId == account.accountId {
                self.config.active.accountId = provider.activeAccountId
            }
            self.upsertProvider(provider)
        }

        self.config.normalizeOpenAIAccountOrder()
        self.persistIgnoringErrors(syncCodex: self.config.active.providerId == provider.id)
    }

    func activate(
        _ account: TokenAccount,
        reason: AutoRoutingSwitchReason = .manual,
        automatic: Bool = false,
        forced: Bool = false,
        protectedByManualGrace: Bool = false
    ) throws {
        _ = try self.reconcileAuthJSONIfNeeded(accountID: account.accountId)
        let previousAccountID = self.activeAccount()?.accountId
        _ = try self.config.activateOAuthAccount(accountID: account.accountId)
        try self.persist(syncCodex: true)
        try self.appendSwitchJournal(
            previousAccountID: previousAccountID,
            reason: reason,
            automatic: automatic,
            forced: forced,
            protectedByManualGrace: protectedByManualGrace
        )
    }

    func activeAccount() -> TokenAccount? {
        self.accounts.first(where: { $0.isActive })
    }

    func activateCustomProvider(providerID: String, accountID: String) throws {
        let previousAccountID = self.config.active.accountId
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }
        guard provider.accounts.contains(where: { $0.id == accountID }) else {
            throw TokenStoreError.accountNotFound
        }

        provider.activeAccountId = accountID
        self.upsertProvider(provider)
        self.config.active.providerId = provider.id
        self.config.active.accountId = accountID

        try self.persist(syncCodex: true)
        try self.appendSwitchJournal(previousAccountID: previousAccountID)
    }

    func activateOpenRouterProvider(accountID: String) throws {
        let previousAccountID = self.config.active.accountId
        _ = try self.config.activateOpenRouterAccount(accountID: accountID)
        try self.persist(syncCodex: true)
        try self.appendSwitchJournal(previousAccountID: previousAccountID)
    }

    func addCustomProvider(label: String, baseURL: String, accountLabel: String, apiKey: String) throws {
        let previousAccountID = self.config.active.accountId
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLabel.isEmpty == false,
              trimmedBaseURL.isEmpty == false,
              trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        let providerID = self.slug(from: trimmedLabel)
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: trimmedAccountLabel.isEmpty ? "Default" : trimmedAccountLabel,
            apiKey: trimmedAPIKey,
            addedAt: Date()
        )
        let provider = CodexBarProvider(
            id: providerID,
            kind: .openAICompatible,
            label: trimmedLabel,
            enabled: true,
            baseURL: trimmedBaseURL,
            activeAccountId: account.id,
            accounts: [account]
        )

        self.config.providers.removeAll { $0.id == provider.id }
        self.config.providers.append(provider)
        self.config.active.providerId = provider.id
        self.config.active.accountId = account.id

        try self.persist(syncCodex: true)
        try self.appendSwitchJournal(previousAccountID: previousAccountID)
    }

    func addOpenRouterProvider(defaultModel: String?, accountLabel: String, apiKey: String) throws {
        guard defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TokenStoreError.invalidInput
        }
        let previousAccountID = self.config.active.accountId
        _ = try self.config.upsertOpenRouterProvider(
            defaultModel: defaultModel,
            accountLabel: accountLabel,
            apiKey: apiKey,
            activate: true
        )
        try self.persist(syncCodex: true)
        try self.appendSwitchJournal(previousAccountID: previousAccountID)
    }

    func addOpenRouterProviderAccount(label: String, apiKey: String, defaultModel: String? = nil) throws {
        let resolvedDefaultModel = defaultModel ?? self.config.openRouterProvider()?.defaultModel
        _ = try self.config.upsertOpenRouterProvider(
            defaultModel: resolvedDefaultModel,
            accountLabel: label,
            apiKey: apiKey,
            activate: false
        )
        try self.persist(syncCodex: false)
    }

    func updateOpenRouterDefaultModel(_ value: String?) throws {
        guard value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TokenStoreError.invalidInput
        }
        try self.config.setOpenRouterDefaultModel(value)
        let shouldSyncCodex = self.config.activeProvider()?.kind == .openRouter
        try self.persist(syncCodex: shouldSyncCodex)
    }

    func addCustomProviderAccount(providerID: String, label: String, apiKey: String) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { throw TokenStoreError.invalidInput }

        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Account \(provider.accounts.count + 1)" : label.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: trimmedAPIKey,
            addedAt: Date()
        )
        provider.accounts.append(account)
        if provider.activeAccountId == nil {
            provider.activeAccountId = account.id
        }
        self.upsertProvider(provider)
        try self.persist(syncCodex: false)
    }

    func removeCustomProviderAccount(providerID: String, accountID: String) throws {
        guard var provider = self.config.providers.first(where: { $0.id == providerID && $0.kind == .openAICompatible }) else {
            throw TokenStoreError.providerNotFound
        }
        provider.accounts.removeAll { $0.id == accountID }
        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == providerID }
            if self.config.active.providerId == providerID {
                let fallback = self.config.providers.first
                self.config.active.providerId = fallback?.id
                self.config.active.accountId = fallback?.activeAccount?.id
                try self.persist(syncCodex: fallback != nil)
                return
            }
        } else {
            if provider.activeAccountId == accountID {
                provider.activeAccountId = provider.accounts.first?.id
            }
            if self.config.active.providerId == providerID && self.config.active.accountId == accountID {
                self.upsertProvider(provider)
                self.config.active.accountId = provider.activeAccountId
                try self.persist(syncCodex: true)
                return
            }
            self.upsertProvider(provider)
        }
        try self.persist(syncCodex: false)
    }

    func removeCustomProvider(providerID: String) throws {
        self.config.providers.removeAll { $0.id == providerID }
        if self.config.active.providerId == providerID {
            let fallback = self.oauthProvider() ?? self.openRouterProvider ?? self.customProviders.first
            self.config.active.providerId = fallback?.id
            self.config.active.accountId = fallback?.activeAccount?.id
            try self.persist(syncCodex: fallback != nil)
            return
        }
        try self.persist(syncCodex: false)
    }

    func removeOpenRouterProviderAccount(accountID: String) throws {
        guard var provider = self.openRouterProvider else {
            throw TokenStoreError.providerNotFound
        }

        provider.accounts.removeAll { $0.id == accountID }
        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == provider.id }
            if self.config.active.providerId == provider.id {
                let fallback = self.oauthProvider() ?? self.customProviders.first
                self.config.active.providerId = fallback?.id
                self.config.active.accountId = fallback?.activeAccount?.id
                try self.persist(syncCodex: fallback != nil)
                return
            }
        } else {
            if provider.activeAccountId == accountID {
                provider.activeAccountId = provider.accounts.first?.id
            }
            if self.config.active.providerId == provider.id && self.config.active.accountId == accountID {
                self.upsertProvider(provider)
                self.config.active.accountId = provider.activeAccountId
                try self.persist(syncCodex: true)
                return
            }
            self.upsertProvider(provider)
        }

        try self.persist(syncCodex: false)
    }

    func markActiveAccount() {
        self.publishState()
    }

    func saveOpenAIAccountSettings(_ request: OpenAIAccountSettingsUpdate) throws {
        try self.saveSettings(
            SettingsSaveRequests(openAIAccount: request)
        )
    }

    func updateOpenAIAccountUsageMode(_ mode: CodexBarOpenAIAccountUsageMode) throws {
        guard self.config.openAI.accountUsageMode != mode else { return }

        self.captureAggregateGatewayLeasesIfNeeded(
            previousMode: self.config.openAI.accountUsageMode,
            newMode: mode
        )
        if mode == .aggregateGateway {
            self.config.captureSwitchModeSelection()
        }
        self.config.setOpenAIAccountUsageMode(mode)
        if mode == .aggregateGateway,
           let provider = self.oauthProvider() {
            self.config.active.providerId = provider.id
            self.config.active.accountId = provider.activeAccountId
        } else if mode == .switchAccount {
            self.config.restoreSwitchModeSelectionIfAvailable()
        }

        try self.persist(syncCodex: mode == .aggregateGateway || self.config.active.providerId == self.oauthProvider()?.id)
    }

    func restoreOpenAIAccountUsageMode(
        _ mode: CodexBarOpenAIAccountUsageMode,
        activeProviderID: String?,
        activeAccountID: String?
    ) throws {
        self.config.setOpenAIAccountUsageMode(mode)
        self.config.active.providerId = activeProviderID
        self.config.active.accountId = activeAccountID
        try self.persist(syncCodex: activeProviderID != nil)
    }

    func restoreActiveSelection(
        activeProviderID: String?,
        activeAccountID: String?
    ) throws {
        self.config.active.providerId = activeProviderID
        self.config.active.accountId = activeAccountID
        try self.persist(syncCodex: activeProviderID != nil)
    }

    func saveOpenAIUsageSettings(_ request: OpenAIUsageSettingsUpdate) throws {
        try self.saveSettings(
            SettingsSaveRequests(openAIUsage: request)
        )
    }

    func saveDesktopSettings(_ request: DesktopSettingsUpdate) throws {
        try self.saveSettings(
            SettingsSaveRequests(desktop: request)
        )
    }

    func saveSettings(_ requests: SettingsSaveRequests) throws {
        guard requests.isEmpty == false else { return }

        let previousUsageMode = self.config.openAI.accountUsageMode
        var updatedConfig = self.config
        try SettingsSaveRequestApplier.apply(requests, to: &updatedConfig)

        self.config = updatedConfig
        let shouldSyncCodex = self.shouldSyncCodexAfterSavingSettings(
            requests: requests,
            previousUsageMode: previousUsageMode,
            updatedConfig: updatedConfig
        )
        try self.persist(syncCodex: shouldSyncCodex)
    }

    func hasStaleOAuthUsageSnapshot(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        self.accounts.contains {
            $0.isSuspended == false &&
            $0.tokenExpired == false &&
            $0.isUsageSnapshotStale(maxAge: maxAge, now: now)
        }
    }

    func beginUsageRefresh(accountID: String) -> Bool {
        self.usageRefreshStateQueue.sync {
            self.refreshingUsageAccountIDs.insert(accountID).inserted
        }
    }

    func endUsageRefresh(accountID: String) {
        _ = self.usageRefreshStateQueue.sync {
            self.refreshingUsageAccountIDs.remove(accountID)
        }
    }

    func beginAllUsageRefresh() -> Bool {
        self.usageRefreshStateQueue.sync {
            guard self.isRefreshingAllUsage == false else { return false }
            self.isRefreshingAllUsage = true
            return true
        }
    }

    func reconcileAuthJSONIfNeeded(accountID: String? = nil) throws -> Bool {
        let changed = self.absorbNewerAuthJSONIfNeeded(accountID: accountID)
        guard changed else { return false }
        try self.configStore.save(self.config)
        self.publishState()
        CodexBarInterprocess.postReloadState()
        return true
    }

    func oauthAccount(accountID: String) -> TokenAccount? {
        self.accounts.first(where: { $0.accountId == accountID })
    }

    func openAIRuntimeRouteSnapshot(
        runningThreadAttribution: OpenAIRunningThreadAttribution,
        now: Date = Date()
    ) -> OpenAIRuntimeRouteSnapshot {
        let stickyBindings = self.openAIAccountGatewayService.stickyBindingsSnapshot()
        let latestStickyBinding = stickyBindings.first
        let latestRouteRecord = self.aggregateRouteJournalStore.routeHistory().last
        let latestRouteAt = latestStickyBinding?.updatedAt ?? latestRouteRecord?.timestamp
        let latestRoutedAccountID = self.aggregateRoutedAccountID
            ?? latestStickyBinding?.accountID
            ?? latestRouteRecord?.accountID
        let runningThreadIDs = runningThreadAttribution.activeThreadIDs
        let leaseActive = self.aggregateGatewayLeaseProcessIDs.isEmpty == false ||
            self.aggregateGatewayLeaseStore.hasActiveLease()
        let recentActivityWindow = runningThreadAttribution.recentActivityWindow

        let staleStickyEligible: Bool
        if let latestStickyBinding,
           runningThreadAttribution.summary.isUnavailable == false,
           runningThreadIDs.contains(latestStickyBinding.threadID) == false,
           leaseActive == false,
           now.timeIntervalSince(latestStickyBinding.updatedAt) > recentActivityWindow {
            staleStickyEligible = true
        } else {
            staleStickyEligible = false
        }

        return OpenAIRuntimeRouteSnapshot(
            configuredMode: self.config.openAI.accountUsageMode,
            effectiveMode: self.effectiveGatewayMode,
            aggregateRuntimeActive: self.effectiveGatewayMode == .aggregateGateway,
            latestRoutedAccountID: latestRoutedAccountID,
            latestRoutedAccountIsSummary: latestRoutedAccountID != nil,
            stickyAffectsFutureRouting: latestStickyBinding != nil && self.config.openAI.accountUsageMode == .aggregateGateway,
            leaseActive: leaseActive,
            staleStickyEligible: staleStickyEligible,
            staleStickyThreadID: staleStickyEligible ? latestStickyBinding?.threadID : nil,
            latestRouteAt: latestRouteAt
        )
    }

    @discardableResult
    func clearStaleAggregateSticky(using snapshot: OpenAIRuntimeRouteSnapshot) -> Bool {
        guard snapshot.staleStickyEligible,
              let threadID = snapshot.staleStickyThreadID else {
            return false
        }
        return self.openAIAccountGatewayService.clearStickyBinding(threadID: threadID)
    }

    func endAllUsageRefresh() {
        self.usageRefreshStateQueue.sync {
            self.isRefreshingAllUsage = false
        }
    }

    // MARK: - Private

    private func oauthProvider() -> CodexBarProvider? {
        self.config.providers.first(where: { $0.kind == .openAIOAuth })
    }

    private func upsertProvider(_ provider: CodexBarProvider) {
        if let index = self.config.providers.firstIndex(where: { $0.id == provider.id }) {
            self.config.providers[index] = provider
        } else {
            self.config.providers.append(provider)
        }
    }

    private func persist(syncCodex: Bool) throws {
        if syncCodex,
           self.config.activeProvider()?.kind == .openAIOAuth {
            _ = self.absorbNewerAuthJSONIfNeeded(accountID: self.config.active.accountId)
        }
        try self.configStore.save(self.config)
        if syncCodex {
            try self.syncService.synchronize(config: self.config)
        }
        self.publishState()
        CodexBarInterprocess.postReloadState()
    }

    private func persistIgnoringErrors(syncCodex: Bool) {
        do {
            try self.persist(syncCodex: syncCodex)
        } catch {
            self.publishState()
            CodexBarInterprocess.postReloadState()
        }
    }

    private func publishState() {
        _ = self.refreshAggregateGatewayLeaseState()
        self.pushPublishedState()
    }

    private func absorbNewerAuthJSONIfNeeded(accountID: String? = nil) -> Bool {
        let reconciled = self.configStore.reconcileAuthJSON(
            in: self.config,
            onlyAccountIDs: accountID.map { Set([$0]) }
        )
        guard reconciled.changed else { return false }
        self.config = reconciled.config
        return true
    }

    private func pushPublishedState() {
        self.accounts = self.config.oauthTokenAccounts()
        let effectiveGatewayMode = self.effectiveGatewayMode
        self.openAIAccountGatewayService.updateState(
            accounts: self.accounts,
            quotaSortSettings: self.config.openAI.quotaSort,
            accountUsageMode: effectiveGatewayMode
        )
        self.openRouterGatewayService.updateState(
            provider: self.config.openRouterProvider(),
            isActiveProvider: self.config.activeProvider()?.kind == .openRouter
        )
        self.reconcileOpenAIAccountGatewayLifecycle(effectiveMode: effectiveGatewayMode)
        self.reconcileOpenRouterGatewayLifecycle()
        self.aggregateRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
    }

    private var effectiveGatewayMode: CodexBarOpenAIAccountUsageMode {
        if self.config.openAI.accountUsageMode == .aggregateGateway ||
            self.aggregateGatewayLeaseProcessIDs.isEmpty == false {
            return .aggregateGateway
        }
        return .switchAccount
    }

    private func reconcileOpenAIAccountGatewayLifecycle(
        effectiveMode: CodexBarOpenAIAccountUsageMode
    ) {
        if effectiveMode == .aggregateGateway {
            self.openAIAccountGatewayService.startIfNeeded()
        } else {
            self.openAIAccountGatewayService.stop()
        }
    }

    private func reconcileOpenRouterGatewayLifecycle() {
        if self.config.activeProvider()?.kind == .openRouter {
            self.openRouterGatewayService.startIfNeeded()
        } else {
            self.openRouterGatewayService.stop()
        }
    }

    private func captureAggregateGatewayLeasesIfNeeded(
        previousMode: CodexBarOpenAIAccountUsageMode,
        newMode: CodexBarOpenAIAccountUsageMode
    ) {
        if previousMode == .aggregateGateway, newMode != .aggregateGateway {
            self.aggregateGatewayLeaseProcessIDs = self.codexRunningProcessIDs()
            self.persistAggregateGatewayLeaseState()
            self.configureAggregateGatewayLeaseTimer()
            return
        }

        if newMode == .aggregateGateway, self.aggregateGatewayLeaseProcessIDs.isEmpty == false {
            self.aggregateGatewayLeaseProcessIDs.removeAll()
            self.persistAggregateGatewayLeaseState()
            self.configureAggregateGatewayLeaseTimer()
        }
    }

    private func refreshAggregateGatewayLeaseState() -> Bool {
        if self.config.openAI.accountUsageMode == .aggregateGateway {
            let changed = self.aggregateGatewayLeaseProcessIDs.isEmpty == false
            if changed {
                self.aggregateGatewayLeaseProcessIDs.removeAll()
                self.persistAggregateGatewayLeaseState()
            }
            self.configureAggregateGatewayLeaseTimer()
            return changed
        }

        let runningProcessIDs = self.codexRunningProcessIDs()
        let prunedProcessIDs = self.aggregateGatewayLeaseProcessIDs.intersection(runningProcessIDs)
        let changed = prunedProcessIDs != self.aggregateGatewayLeaseProcessIDs
        if changed {
            self.aggregateGatewayLeaseProcessIDs = prunedProcessIDs
            self.persistAggregateGatewayLeaseState()
        }
        self.configureAggregateGatewayLeaseTimer()
        return changed
    }

    private func persistAggregateGatewayLeaseState() {
        if self.aggregateGatewayLeaseProcessIDs.isEmpty {
            self.aggregateGatewayLeaseStore.clear()
        } else {
            self.aggregateGatewayLeaseStore.saveProcessIDs(self.aggregateGatewayLeaseProcessIDs)
        }
    }

    private func configureAggregateGatewayLeaseTimer() {
        let shouldPoll = self.config.openAI.accountUsageMode != .aggregateGateway &&
            self.aggregateGatewayLeaseProcessIDs.isEmpty == false

        if shouldPoll {
            if self.aggregateGatewayLeaseTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.refreshAggregateGatewayLeaseState() {
                        self.pushPublishedState()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.aggregateGatewayLeaseTimer = timer
            }
            return
        }

        self.aggregateGatewayLeaseTimer?.invalidate()
        self.aggregateGatewayLeaseTimer = nil
    }

    func refreshLocalCostSummary() {
        let service = self.costSummaryService
        let shouldStart = self.refreshStateQueue.sync { () -> Bool in
            guard self.isRefreshingLocalCostSummary == false else { return false }
            self.isRefreshingLocalCostSummary = true
            return true
        }
        guard shouldStart else { return }

        DispatchQueue.global(qos: .utility).async {
            let summary = service.load()
            DispatchQueue.main.async {
                self.localCostSummary = summary
                self.saveCachedLocalCostSummary(summary)
                self.refreshStateQueue.async {
                    self.isRefreshingLocalCostSummary = false
                }
            }
        }
    }

    private func appendSwitchJournal() throws {
        try self.appendSwitchJournal(previousAccountID: nil)
    }

    private func appendSwitchJournal(
        previousAccountID: String?,
        reason: AutoRoutingSwitchReason = .manual,
        automatic: Bool = false,
        forced: Bool = false,
        protectedByManualGrace: Bool = false
    ) throws {
        try self.switchJournalStore.appendActivation(
            providerID: self.config.active.providerId,
            accountID: self.config.active.accountId,
            previousAccountID: previousAccountID,
            reason: reason,
            automatic: automatic,
            forced: forced,
            protectedByManualGrace: protectedByManualGrace
        )
    }

    private func seedSwitchJournalIfNeeded() {
        guard FileManager.default.fileExists(atPath: CodexPaths.switchJournalURL.path) == false,
              self.config.active.providerId != nil else { return }
        try? self.appendSwitchJournal()
    }

    private func loadCachedLocalCostSummary() -> LocalCostSummary {
        guard let data = try? Data(contentsOf: CodexPaths.costCacheURL) else {
            return .empty
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LocalCostSummary.self, from: data)) ?? .empty
    }

    private func saveCachedLocalCostSummary(_ summary: LocalCostSummary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(summary) else { return }
        try? CodexPaths.writeSecureFile(data, to: CodexPaths.costCacheURL)
    }

    deinit {
        self.aggregateGatewayLeaseTimer?.invalidate()
    }

    private func slug(from label: String) -> String {
        let lowered = label.lowercased()
        let slug = lowered.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let resolved = slug.isEmpty ? "provider-\(UUID().uuidString.lowercased())" : slug
        if resolved == "openrouter" {
            return "openrouter-custom"
        }
        return resolved
    }

    private func shouldSyncCodexAfterSavingSettings(
        requests: SettingsSaveRequests,
        previousUsageMode: CodexBarOpenAIAccountUsageMode,
        updatedConfig: CodexBarConfig
    ) -> Bool {
        guard let openAIAccountRequest = requests.openAIAccount else { return false }
        let oauthProviderID = updatedConfig.oauthProvider()?.id
        let openAIIsSelected = updatedConfig.active.providerId == oauthProviderID
        if openAIAccountRequest.accountUsageMode != previousUsageMode {
            return openAIIsSelected || openAIAccountRequest.accountUsageMode == .aggregateGateway
        }
        return false
    }
}

enum TokenStoreError: LocalizedError {
    case accountNotFound
    case providerNotFound
    case invalidInput
    case invalidCodexAppPath

    var errorDescription: String? {
        switch self {
        case .accountNotFound: return "未找到账号"
        case .providerNotFound: return "未找到 provider"
        case .invalidInput: return "输入无效"
        case .invalidCodexAppPath: return L.codexAppPathInvalidSelection
        }
    }
}
