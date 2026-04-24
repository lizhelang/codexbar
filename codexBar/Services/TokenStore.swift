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

struct ModelPricingSettingsUpdate: Equatable {
    var upserts: [String: CodexBarModelPricing]
    var removals: [String]
}

struct DesktopSettingsUpdate: Equatable {
    var preferredCodexAppPath: String?
}

struct SettingsSaveRequests: Equatable {
    var openAIAccount: OpenAIAccountSettingsUpdate?
    var openAIUsage: OpenAIUsageSettingsUpdate?
    var modelPricing: ModelPricingSettingsUpdate?
    var desktop: DesktopSettingsUpdate?

    init(
        openAIAccount: OpenAIAccountSettingsUpdate? = nil,
        openAIUsage: OpenAIUsageSettingsUpdate? = nil,
        modelPricing: ModelPricingSettingsUpdate? = nil,
        desktop: DesktopSettingsUpdate? = nil
    ) {
        self.openAIAccount = openAIAccount
        self.openAIUsage = openAIUsage
        self.modelPricing = modelPricing
        self.desktop = desktop
    }

    var isEmpty: Bool {
        self.openAIAccount == nil &&
        self.openAIUsage == nil &&
        self.modelPricing == nil &&
        self.desktop == nil
    }
}

struct OpenRouterModelCatalogSnapshot: Equatable {
    var models: [CodexBarOpenRouterModel]
    var fetchedAt: Date
}

protocol OpenRouterModelCatalogFetching {
    func fetchCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot
}

struct OpenRouterModelCatalogService: OpenRouterModelCatalogFetching {
    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let name: String?
        }

        let data: [Model]
    }

    private let urlSession: URLSession
    private let now: () -> Date

    init(
        urlSession: URLSession? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.urlSession = urlSession ?? URLSession(configuration: .ephemeral)
        self.now = now
    }

    func fetchCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else {
            throw TokenStoreError.invalidInput
        }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        let models = decoded.data
            .map { CodexBarOpenRouterModel(id: $0.id, name: $0.name) }
            .filter { $0.id.isEmpty == false }
            .sorted { lhs, rhs in
                let left = lhs.name.lowercased()
                let right = rhs.name.lowercased()
                if left == right {
                    return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
                }
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }

        return OpenRouterModelCatalogSnapshot(models: models, fetchedAt: self.now())
    }
}

final class TokenStore: ObservableObject {
    static let shared = TokenStore()

    @Published var accounts: [TokenAccount] = []
    @Published private(set) var config: CodexBarConfig
    @Published private(set) var localCostSummary: LocalCostSummary = .empty
    @Published private(set) var historicalModels: [String]
    @Published private(set) var aggregateRoutedAccountID: String?

    private let configStore: CodexBarConfigStore
    private let syncService: any CodexSynchronizing
    private let switchJournalStore = SwitchJournalStore()
    private let costSummaryService: LocalCostSummaryService
    private let openAIAccountGatewayService: OpenAIAccountGatewayControlling
    private let openRouterGatewayService: OpenRouterGatewayControlling
    private let openRouterModelCatalogService: any OpenRouterModelCatalogFetching
    private let openRouterGatewayLeaseStore: OpenRouterGatewayLeaseStoring
    private let aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoring
    private let aggregateRouteJournalStore: OpenAIAggregateRouteJournalStoring
    private let codexRunningProcessIDs: () -> Set<pid_t>
    private let refreshStateQueue = DispatchQueue(label: "lzl.codexbar.refresh-state")
    private let usageRefreshStateQueue = DispatchQueue(label: "lzl.codexbar.usage-refresh-state")
    private var isRefreshingLocalCostSummary = false
    private var isRefreshingAllUsage = false
    private var refreshingUsageAccountIDs: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private var openRouterGatewayLeaseSnapshot: OpenRouterGatewayLeaseSnapshot?
    private var openRouterGatewayLeaseTimer: Timer?
    private var aggregateGatewayLeaseProcessIDs: Set<pid_t>
    private var aggregateGatewayLeaseTimer: Timer?
    private var lastPublishedOpenRouterSelected = false

    init(
        configStore: CodexBarConfigStore = CodexBarConfigStore(),
        syncService: any CodexSynchronizing = CodexSyncService(),
        costSummaryService: LocalCostSummaryService = LocalCostSummaryService(),
        openAIAccountGatewayService: OpenAIAccountGatewayControlling = OpenAIAccountGatewayService.shared,
        openRouterGatewayService: OpenRouterGatewayControlling = OpenRouterGatewayService(),
        openRouterModelCatalogService: any OpenRouterModelCatalogFetching = OpenRouterModelCatalogService(),
        openRouterGatewayLeaseStore: OpenRouterGatewayLeaseStoring = OpenRouterGatewayLeaseStore(),
        aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoring = OpenAIAggregateGatewayLeaseStore(),
        aggregateRouteJournalStore: OpenAIAggregateRouteJournalStoring = OpenAIAggregateRouteJournalStore(),
        codexRunningProcessIDs: @escaping () -> Set<pid_t> = {
            Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier))
        }
    ) {
        self.configStore = configStore
        self.syncService = syncService
        self.costSummaryService = costSummaryService
        self.openAIAccountGatewayService = openAIAccountGatewayService
        self.openRouterGatewayService = openRouterGatewayService
        self.openRouterModelCatalogService = openRouterModelCatalogService
        self.openRouterGatewayLeaseStore = openRouterGatewayLeaseStore
        self.aggregateGatewayLeaseStore = aggregateGatewayLeaseStore
        self.aggregateRouteJournalStore = aggregateRouteJournalStore
        self.codexRunningProcessIDs = codexRunningProcessIDs
        self.openRouterGatewayLeaseSnapshot = openRouterGatewayLeaseStore.loadLease()
        self.aggregateGatewayLeaseProcessIDs = aggregateGatewayLeaseStore.loadProcessIDs()

        let initialConfig: CodexBarConfig
        if let loaded = try? self.configStore.loadOrMigrate() {
            initialConfig = loaded
        } else {
            initialConfig = CodexBarConfig()
        }
        self.config = initialConfig
        self.historicalModels = Self.normalizedHistoricalModels(Array(initialConfig.modelPricing.keys))
        self.lastPublishedOpenRouterSelected = self.config.activeProvider()?.kind == .openRouter

        NotificationCenter.default.publisher(for: .openAIAccountGatewayDidRouteAccount)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.aggregateRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
            }
            .store(in: &self.cancellables)

        self.publishState()
        self.localCostSummary = self.loadCachedLocalCostSummary()
        self.refreshLocalCostSummaryIfNeeded()
        self.refreshHistoricalModels()
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
           let selectedModelID = activeProvider.openRouterEffectiveModelID {
            return selectedModelID
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
            self.historicalModels = Self.mergedHistoricalModels(
                preferredHistoricalModels: self.historicalModels,
                fallbackHistoricalModels: Array(self.config.modelPricing.keys)
            )
            self.refreshLocalCostSummaryIfNeeded()
            self.refreshHistoricalModels()
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

    func addOpenRouterProvider(
        accountLabel: String = "",
        apiKey: String,
        selectedModelID: String? = nil,
        pinnedModelIDs: [String] = [],
        cachedModelCatalog: [CodexBarOpenRouterModel] = [],
        fetchedAt: Date? = nil
    ) throws {
        _ = try self.config.upsertOpenRouterProvider(
            accountLabel: accountLabel,
            apiKey: apiKey,
            activate: false
        )
        if selectedModelID != nil ||
            pinnedModelIDs.isEmpty == false ||
            cachedModelCatalog.isEmpty == false ||
            fetchedAt != nil {
            try self.config.setOpenRouterModelSelection(
                selectedModelID: selectedModelID,
                pinnedModelIDs: pinnedModelIDs,
                cachedModelCatalog: cachedModelCatalog,
                fetchedAt: fetchedAt
            )
        }
        try self.persist(syncCodex: false)
    }

    func addOpenRouterProviderAccount(
        label: String = "",
        apiKey: String,
        selectedModelID: String? = nil,
        pinnedModelIDs: [String] = [],
        cachedModelCatalog: [CodexBarOpenRouterModel] = [],
        fetchedAt: Date? = nil
    ) throws {
        _ = try self.config.upsertOpenRouterProvider(
            accountLabel: label,
            apiKey: apiKey,
            activate: false
        )
        if selectedModelID != nil ||
            pinnedModelIDs.isEmpty == false ||
            cachedModelCatalog.isEmpty == false ||
            fetchedAt != nil {
            try self.config.setOpenRouterModelSelection(
                selectedModelID: selectedModelID,
                pinnedModelIDs: pinnedModelIDs,
                cachedModelCatalog: cachedModelCatalog,
                fetchedAt: fetchedAt
            )
        }
        try self.persist(syncCodex: false)
    }

    func updateOpenRouterDefaultModel(_ value: String?) throws {
        try self.updateOpenRouterSelectedModel(value)
    }

    func updateOpenRouterSelectedModel(_ value: String?) throws {
        guard value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TokenStoreError.invalidInput
        }
        try self.config.setOpenRouterSelectedModel(value)
        let shouldSyncCodex = self.config.activeProvider()?.kind == .openRouter
        try self.persist(syncCodex: shouldSyncCodex)
    }

    func updateOpenRouterModelSelection(
        selectedModelID: String?,
        pinnedModelIDs: [String],
        cachedModelCatalog: [CodexBarOpenRouterModel],
        fetchedAt: Date?
    ) throws {
        try self.config.setOpenRouterModelSelection(
            selectedModelID: selectedModelID,
            pinnedModelIDs: pinnedModelIDs,
            cachedModelCatalog: cachedModelCatalog,
            fetchedAt: fetchedAt
        )
        let shouldSyncCodex = self.config.activeProvider()?.kind == .openRouter
        try self.persist(syncCodex: shouldSyncCodex)
    }

    func refreshOpenRouterModelCatalog() async throws {
        guard let provider = self.openRouterProvider,
              let account = provider.activeAccount,
              let apiKey = account.apiKey else {
            throw TokenStoreError.accountNotFound
        }

        let snapshot = try await self.openRouterModelCatalogService.fetchCatalog(apiKey: apiKey)
        try self.config.updateOpenRouterModelCatalog(snapshot.models, fetchedAt: snapshot.fetchedAt)
        try self.persist(syncCodex: false)
    }

    func previewOpenRouterModelCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot {
        try await self.openRouterModelCatalogService.fetchCatalog(apiKey: apiKey)
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

        let previousMode = self.config.openAI.accountUsageMode
        self.captureAggregateGatewayLeasesIfNeeded(
            previousMode: previousMode,
            newMode: mode
        )
        if let transition = try? RustPortableCoreAdapter.shared.resolveUsageModeTransition(
            PortableCoreUsageModeTransitionRequest(
                currentMode: previousMode.rawValue,
                targetMode: mode.rawValue,
                activeProviderId: self.config.active.providerId,
                activeAccountId: self.config.active.accountId,
                switchModeSelectionProviderId: self.config.openAI.switchModeSelection?.providerId,
                switchModeSelectionAccountId: self.config.openAI.switchModeSelection?.accountId,
                oauthProviderId: self.oauthProvider()?.id,
                oauthActiveAccountId: self.oauthProvider()?.activeAccountId,
                providers: self.config.providers.map(PortableCoreUsageModeTransitionProviderInput.legacy(from:))
            ),
            buildIfNeeded: false
        ) {
            self.config.openAI.switchModeSelection = Self.activeSelection(
                providerID: transition.nextSwitchModeSelectionProviderId,
                accountID: transition.nextSwitchModeSelectionAccountId
            )
            self.config.setOpenAIAccountUsageMode(
                CodexBarOpenAIAccountUsageMode(rawValue: transition.nextMode) ?? mode
            )
            self.config.active.providerId = transition.nextActiveProviderId
            self.config.active.accountId = transition.nextActiveAccountId
            try self.persist(syncCodex: transition.shouldSyncCodex)
            return
        }

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

    func saveModelPricingSettings(_ request: ModelPricingSettingsUpdate) throws {
        try self.saveSettings(
            SettingsSaveRequests(modelPricing: request)
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
        self.historicalModels = Self.mergedHistoricalModels(
            preferredHistoricalModels: self.historicalModels,
            fallbackHistoricalModels: Array(self.config.modelPricing.keys)
        )
        if requests.modelPricing != nil {
            self.refreshLocalCostSummary(force: true, minimumInterval: 0)
        }
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

        let liveSessionAttribution = OpenAILiveSessionAttributionService.shared.load(now: now)
        let concreteGatewayService = self.openAIAccountGatewayService as? OpenAIAccountGatewayService
        let blockedAccounts = self.accounts.compactMap { account -> (accountID: String, retryAt: Date)? in
            guard let retryAt = concreteGatewayService?.runtimeBlockedUntilForTesting(accountID: account.accountId) else {
                return nil
            }
            return (account.accountId, retryAt)
        }
        let blockedAccountIDs = blockedAccounts.map(\.accountID)
        let nextRetryAt = blockedAccounts.map(\.retryAt).min()
        let routeInput = PortableCoreRouteRuntimeInput(
            configuredMode: self.config.openAI.accountUsageMode.rawValue,
            effectiveMode: self.effectiveGatewayMode.rawValue,
            aggregateRoutedAccountID: self.aggregateRoutedAccountID,
            stickyBindings: stickyBindings.map {
                .init(
                    threadID: $0.threadID,
                    accountID: $0.accountID,
                    updatedAt: $0.updatedAt.timeIntervalSince1970
                )
            },
            routeJournal: self.aggregateRouteJournalStore.routeHistory().map {
                .init(
                    threadID: $0.threadID,
                    accountID: $0.accountID,
                    timestamp: $0.timestamp.timeIntervalSince1970
                )
            },
            leaseState: .init(
                leasedProcessIDs: self.aggregateGatewayLeaseProcessIDs.map(Int.init).sorted(),
                hasActiveLease: self.aggregateGatewayLeaseStore.hasActiveLease()
            ),
            runningThreadAttribution: .init(
                activeThreadIDs: Array(runningThreadAttribution.activeThreadIDs).sorted(),
                recentActivityWindowSeconds: recentActivityWindow,
                summaryIsUnavailable: runningThreadAttribution.summary.isUnavailable,
                inUseAccountIDs: runningThreadAttribution.summary.runningThreadCounts.keys.sorted()
            ),
            liveSessionAttribution: .init(
                summaryIsUnavailable: false,
                activeSessionIDs: liveSessionAttribution.sessions.map(\.sessionID).sorted(),
                attributedAccountIDs: liveSessionAttribution.inUseSessionCounts.keys.sorted()
            ),
            runtimeBlockState: .init(
                blockedAccountIDs: blockedAccountIDs,
                retryAt: nextRetryAt?.timeIntervalSince1970,
                resetAt: nil
            ),
            now: now.timeIntervalSince1970
        )
        if let rustSnapshot = try? RustPortableCoreAdapter.shared.computeRouteRuntimeSnapshot(
            routeInput,
            buildIfNeeded: false
        ) {
            return OpenAIRuntimeRouteSnapshot(
                configuredMode: CodexBarOpenAIAccountUsageMode(rawValue: rustSnapshot.configuredMode) ?? .switchAccount,
                effectiveMode: CodexBarOpenAIAccountUsageMode(rawValue: rustSnapshot.effectiveMode) ?? .switchAccount,
                aggregateRuntimeActive: rustSnapshot.aggregateRuntimeActive,
                latestRoutedAccountID: rustSnapshot.latestRoutedAccountID,
                latestRoutedAccountIsSummary: rustSnapshot.latestRoutedAccountIsSummary,
                stickyAffectsFutureRouting: rustSnapshot.stickyAffectsFutureRouting,
                leaseActive: rustSnapshot.leaseActive,
                staleStickyEligible: rustSnapshot.staleStickyEligible,
                staleStickyThreadID: rustSnapshot.staleStickyThreadID,
                latestRouteAt: rustSnapshot.latestRouteAt.map(Date.init(timeIntervalSince1970:))
            )
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

    private static func activeSelection(
        providerID: String?,
        accountID: String?
    ) -> CodexBarActiveSelection? {
        guard let providerID, let accountID else { return nil }
        return CodexBarActiveSelection(providerId: providerID, accountId: accountID)
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
    }

    private func persistIgnoringErrors(syncCodex: Bool) {
        do {
            try self.persist(syncCodex: syncCodex)
        } catch {
            self.publishState()
        }
    }

    private func publishState() {
        _ = self.refreshAggregateGatewayLeaseState()
        _ = self.refreshOpenRouterGatewayLeaseState()
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
        let gatewayLifecyclePlan = self.gatewayLifecyclePlan()
        let effectiveGatewayMode = Self.gatewayUsageMode(
            from: gatewayLifecyclePlan.effectiveOpenAIUsageMode
        )
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
        self.reconcileOpenRouterGatewayLifecycle(plan: gatewayLifecyclePlan)
        self.aggregateRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
        self.lastPublishedOpenRouterSelected = self.config.activeProvider()?.kind == .openRouter
    }

    private var effectiveGatewayMode: CodexBarOpenAIAccountUsageMode {
        Self.gatewayUsageMode(from: self.gatewayLifecyclePlan().effectiveOpenAIUsageMode)
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

    private func reconcileOpenRouterGatewayLifecycle(
        plan: PortableCoreGatewayLifecyclePlanResult? = nil
    ) {
        let plan = plan ?? self.gatewayLifecyclePlan()
        if plan.shouldRunOpenrouterGateway {
            self.openRouterGatewayService.startIfNeeded()
        } else {
            self.openRouterGatewayService.stop()
        }
    }

    private func gatewayLifecyclePlan() -> PortableCoreGatewayLifecyclePlanResult {
        let openRouterServiceableProvider = self.config.openRouterProvider().flatMap { provider in
            provider.openRouterServiceableSelection != nil ? provider : nil
        }
        let request = PortableCoreGatewayLifecyclePlanRequest(
            configuredOpenAIUsageMode: self.config.openAI.accountUsageMode.rawValue,
            aggregateLeasedProcessIDs: self.aggregateGatewayLeaseProcessIDs.map(Int.init).sorted(),
            activeProviderKind: self.config.activeProvider()?.kind.rawValue,
            openrouterServiceableProviderId: openRouterServiceableProvider?.id,
            lastPublishedOpenrouterSelected: self.lastPublishedOpenRouterSelected,
            runningCodexProcessIDs: self.codexRunningProcessIDs().map(Int.init).sorted(),
            existingOpenrouterLease: PortableCoreGatewayLeaseSnapshotInput.legacy(
                from: self.openRouterGatewayLeaseSnapshot
            )
        )
        return (try? RustPortableCoreAdapter.shared.planGatewayLifecycle(request))
            ?? PortableCoreGatewayLifecyclePlanResult(
                effectiveOpenAIUsageMode: self.config.openAI.accountUsageMode.rawValue,
                shouldRunOpenAIGateway: false,
                shouldRunOpenrouterGateway: false,
                nextOpenrouterLease: nil,
                openrouterLeaseChanged: self.openRouterGatewayLeaseSnapshot != nil,
                openrouterLeaseShouldPoll: false,
                rustOwner: "swift.failClosedGatewayLifecyclePlan"
            )
    }

    private static func gatewayUsageMode(from rawValue: String) -> CodexBarOpenAIAccountUsageMode {
        CodexBarOpenAIAccountUsageMode(rawValue: rawValue) ?? .switchAccount
    }

    private func refreshOpenRouterGatewayLeaseState() -> Bool {
        let plan = self.gatewayLifecyclePlan()
        let nextLease = plan.nextOpenrouterLease?.openRouterGatewayLeaseSnapshot()
        if plan.openrouterLeaseChanged {
            self.openRouterGatewayLeaseSnapshot = nextLease
            self.persistOpenRouterGatewayLeaseState()
        }
        self.configureOpenRouterGatewayLeaseTimer(shouldPoll: plan.openrouterLeaseShouldPoll)
        return plan.openrouterLeaseChanged
    }

    private func persistOpenRouterGatewayLeaseState() {
        guard let lease = self.openRouterGatewayLeaseSnapshot,
              lease.leasedProcessIDs.isEmpty == false else {
            self.openRouterGatewayLeaseStore.clear()
            return
        }
        self.openRouterGatewayLeaseStore.saveLease(lease)
    }

    private func configureOpenRouterGatewayLeaseTimer(shouldPoll: Bool? = nil) {
        let shouldPoll = shouldPoll ?? self.gatewayLifecyclePlan().openrouterLeaseShouldPoll
        if shouldPoll {
            if self.openRouterGatewayLeaseTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.refreshOpenRouterGatewayLeaseState() {
                        self.pushPublishedState()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.openRouterGatewayLeaseTimer = timer
            }
            return
        }

        self.openRouterGatewayLeaseTimer?.invalidate()
        self.openRouterGatewayLeaseTimer = nil
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

    func refreshLocalCostSummary(
        force: Bool = false,
        minimumInterval: TimeInterval = 5 * 60,
        refreshSessionCache: Bool = false
    ) {
        guard force || self.localCostSummary.updatedAt == nil else { return }
        if force == false,
           let updatedAt = self.localCostSummary.updatedAt,
           Date().timeIntervalSince(updatedAt) < minimumInterval {
            return
        }

        let service = self.costSummaryService
        let modelPricing = self.config.modelPricing
        let shouldStart = self.refreshStateQueue.sync { () -> Bool in
            guard self.isRefreshingLocalCostSummary == false else { return false }
            self.isRefreshingLocalCostSummary = true
            return true
        }
        guard shouldStart else { return }

        DispatchQueue.global(qos: .utility).async {
            var summary = service.load(
                modelPricingOverrides: modelPricing,
                refreshSessionCache: refreshSessionCache
            )
            if refreshSessionCache == false,
               self.isEffectivelyEmptyLocalCostSummary(summary) {
                summary = service.load(
                    modelPricingOverrides: modelPricing,
                    refreshSessionCache: true
                )
            }
            DispatchQueue.main.async {
                self.localCostSummary = summary
                self.saveCachedLocalCostSummary(summary)
                self.refreshStateQueue.async {
                    self.isRefreshingLocalCostSummary = false
                }
            }
        }
    }

    private func refreshLocalCostSummaryIfNeeded() {
        guard self.localCostSummary.updatedAt == nil else { return }
        self.refreshLocalCostSummary(
            force: true,
            minimumInterval: 0,
            refreshSessionCache: false
        )
    }

    private func refreshHistoricalModels() {
        let service = self.costSummaryService
        let fallbackHistoricalModels = Array(self.config.modelPricing.keys)

        DispatchQueue.global(qos: .utility).async {
            let fetchedHistoricalModels = service.historicalModels()
            let mergedHistoricalModels = Self.mergedHistoricalModels(
                preferredHistoricalModels: fetchedHistoricalModels,
                fallbackHistoricalModels: fallbackHistoricalModels
            )

            DispatchQueue.main.async {
                self.historicalModels = mergedHistoricalModels
            }
        }
    }

    private static func normalizedHistoricalModels(_ historicalModels: [String]) -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []

        for model in historicalModels {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  seen.insert(trimmed).inserted else {
                continue
            }
            normalized.append(trimmed)
        }

        return normalized.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func mergedHistoricalModels(
        preferredHistoricalModels: [String],
        fallbackHistoricalModels: [String]
    ) -> [String] {
        self.normalizedHistoricalModels(
            preferredHistoricalModels + fallbackHistoricalModels
        )
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
        let summary = (try? decoder.decode(LocalCostSummary.self, from: data)) ?? .empty

        if self.shouldInvalidateCachedLocalCostSummary(summary) {
            return .empty
        }

        return summary
    }

    private func saveCachedLocalCostSummary(_ summary: LocalCostSummary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(summary) else { return }
        try? CodexPaths.writeSecureFile(data, to: CodexPaths.costCacheURL)
    }

    private func shouldInvalidateCachedLocalCostSummary(_ summary: LocalCostSummary) -> Bool {
        guard summary.updatedAt != nil,
              self.isEffectivelyEmptyLocalCostSummary(summary) else {
            return false
        }

        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: CodexPaths.costEventLedgerURL.path
        ),
        let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        return fileSize.int64Value > 0
    }

    private func isEffectivelyEmptyLocalCostSummary(_ summary: LocalCostSummary) -> Bool {
        summary.todayTokens == 0 &&
        summary.last30DaysTokens == 0 &&
        summary.lifetimeTokens == 0 &&
        summary.dailyEntries.isEmpty
    }

    deinit {
        self.openRouterGatewayLeaseTimer?.invalidate()
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
