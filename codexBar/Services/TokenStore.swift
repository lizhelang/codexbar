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
        guard let rawJsonText = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let result =
            (try? RustPortableCoreAdapter.shared.parseOpenRouterModelCatalog(
                PortableCoreOpenRouterModelCatalogParseRequest(rawJsonText: rawJsonText),
                buildIfNeeded: false
            )) ?? PortableCoreOpenRouterModelCatalogParseResult.failClosed()
        guard result.parsed else {
            throw URLError(.cannotDecodeRawData)
        }
        let models = result.models.map { $0.openRouterModel() }

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
        self.historicalModels = Self.mergedHistoricalModels(
            preferredHistoricalModels: [],
            fallbackHistoricalModels: Array(initialConfig.modelPricing.keys)
        )
        self.lastPublishedOpenRouterSelected = self.config.activeProvider()?.kind == .openRouter

        NotificationCenter.default.publisher(for: .openAIAccountGatewayDidRouteAccount)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.aggregateRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
            }
            .store(in: &self.cancellables)

        self.publishState()
        if let data = try? Data(contentsOf: CodexPaths.costCacheURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cachedSummary = (try? decoder.decode(LocalCostSummary.self, from: data)) ?? .empty

            let ledgerFileSizeBytes: Int64
            if let attributes = try? FileManager.default.attributesOfItem(
                atPath: CodexPaths.costEventLedgerURL.path
            ),
            let fileSize = attributes[.size] as? NSNumber {
                ledgerFileSizeBytes = fileSize.int64Value
            } else {
                ledgerFileSizeBytes = 0
            }

            let cachePolicyRequest = PortableCoreLocalCostCachePolicyRequest(
                updatedAt: cachedSummary.updatedAt?.timeIntervalSince1970,
                todayTokens: cachedSummary.todayTokens,
                last30DaysTokens: cachedSummary.last30DaysTokens,
                lifetimeTokens: cachedSummary.lifetimeTokens,
                dailyEntryCount: cachedSummary.dailyEntries.count,
                ledgerFileSizeBytes: ledgerFileSizeBytes
            )
            let cachePolicy = (try? RustPortableCoreAdapter.shared.resolveLocalCostCachePolicy(
                cachePolicyRequest,
                buildIfNeeded: false
            )) ?? PortableCoreLocalCostCachePolicyResult(
                summaryIsEffectivelyEmpty: cachedSummary.todayTokens == 0 &&
                    cachedSummary.last30DaysTokens == 0 &&
                    cachedSummary.lifetimeTokens == 0 &&
                    cachedSummary.dailyEntries.isEmpty,
                shouldInvalidateCachedSummary: cachedSummary.updatedAt != nil &&
                    cachedSummary.todayTokens == 0 &&
                    cachedSummary.last30DaysTokens == 0 &&
                    cachedSummary.lifetimeTokens == 0 &&
                    cachedSummary.dailyEntries.isEmpty &&
                    ledgerFileSizeBytes > 0,
                rustOwner: "swift.failClosedLocalCostCachePolicy"
            )
            if cachePolicy.shouldInvalidateCachedSummary {
                self.localCostSummary = .empty
            } else {
                self.localCostSummary = cachedSummary
            }
        } else {
            self.localCostSummary = .empty
        }
        if self.localCostSummary.updatedAt == nil {
            self.refreshLocalCostSummary(
                force: true,
                minimumInterval: 0,
                refreshSessionCache: false
            )
        }
        let historicalModelService = self.costSummaryService
        let initialHistoricalModelFallback = Array(self.config.modelPricing.keys)
        DispatchQueue.global(qos: .utility).async {
            let fetchedHistoricalModels = historicalModelService.historicalModels()
            let mergedHistoricalModels = Self.mergedHistoricalModels(
                preferredHistoricalModels: fetchedHistoricalModels,
                fallbackHistoricalModels: initialHistoricalModelFallback
            )

            DispatchQueue.main.async {
                self.historicalModels = mergedHistoricalModels
            }
        }
        if FileManager.default.fileExists(atPath: CodexPaths.switchJournalURL.path) == false,
           self.config.active.providerId != nil {
            try? self.appendSwitchJournal(previousAccountID: nil)
        }
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
            if let data = try? Data(contentsOf: CodexPaths.costCacheURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let cachedSummary = (try? decoder.decode(LocalCostSummary.self, from: data)) ?? .empty

                let ledgerFileSizeBytes: Int64
                if let attributes = try? FileManager.default.attributesOfItem(
                    atPath: CodexPaths.costEventLedgerURL.path
                ),
                let fileSize = attributes[.size] as? NSNumber {
                    ledgerFileSizeBytes = fileSize.int64Value
                } else {
                    ledgerFileSizeBytes = 0
                }

                let cachePolicyRequest = PortableCoreLocalCostCachePolicyRequest(
                    updatedAt: cachedSummary.updatedAt?.timeIntervalSince1970,
                    todayTokens: cachedSummary.todayTokens,
                    last30DaysTokens: cachedSummary.last30DaysTokens,
                    lifetimeTokens: cachedSummary.lifetimeTokens,
                    dailyEntryCount: cachedSummary.dailyEntries.count,
                    ledgerFileSizeBytes: ledgerFileSizeBytes
                )
                let cachePolicy = (try? RustPortableCoreAdapter.shared.resolveLocalCostCachePolicy(
                    cachePolicyRequest,
                    buildIfNeeded: false
                )) ?? PortableCoreLocalCostCachePolicyResult(
                    summaryIsEffectivelyEmpty: cachedSummary.todayTokens == 0 &&
                        cachedSummary.last30DaysTokens == 0 &&
                        cachedSummary.lifetimeTokens == 0 &&
                        cachedSummary.dailyEntries.isEmpty,
                    shouldInvalidateCachedSummary: cachedSummary.updatedAt != nil &&
                        cachedSummary.todayTokens == 0 &&
                        cachedSummary.last30DaysTokens == 0 &&
                        cachedSummary.lifetimeTokens == 0 &&
                        cachedSummary.dailyEntries.isEmpty &&
                        ledgerFileSizeBytes > 0,
                    rustOwner: "swift.failClosedLocalCostCachePolicy"
                )
                if cachePolicy.shouldInvalidateCachedSummary {
                    self.localCostSummary = .empty
                } else {
                    self.localCostSummary = cachedSummary
                }
            } else {
                self.localCostSummary = .empty
            }
            self.historicalModels = Self.mergedHistoricalModels(
                preferredHistoricalModels: self.historicalModels,
                fallbackHistoricalModels: Array(self.config.modelPricing.keys)
            )
            if self.localCostSummary.updatedAt == nil {
                self.refreshLocalCostSummary(
                    force: true,
                    minimumInterval: 0,
                    refreshSessionCache: false
                )
            }
            let historicalModelService = self.costSummaryService
            let reloadedHistoricalModelFallback = Array(self.config.modelPricing.keys)
            DispatchQueue.global(qos: .utility).async {
                let fetchedHistoricalModels = historicalModelService.historicalModels()
                let mergedHistoricalModels = Self.mergedHistoricalModels(
                    preferredHistoricalModels: fetchedHistoricalModels,
                    fallbackHistoricalModels: reloadedHistoricalModelFallback
                )

                DispatchQueue.main.async {
                    self.historicalModels = mergedHistoricalModels
                }
            }
        }
    }

    func addOrUpdate(_ account: TokenAccount) {
        let result = self.config.upsertOAuthAccount(account, activate: false)
        do {
            try self.persist(syncCodex: result.syncCodex)
        } catch {
            self.publishState()
        }
    }

    func remove(_ account: TokenAccount) {
        guard var provider = self.config.oauthProvider() else { return }
        let currentActiveProviderID = self.config.active.providerId
        let currentActiveAccountID = self.config.active.accountId
        provider.accounts.removeAll { $0.id == account.accountId }
        self.config.removeOpenAIAccountOrder(accountID: account.accountId)

        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == provider.id }
        } else {
            if provider.activeAccountId == account.accountId {
                provider.activeAccountId = provider.accounts.first?.id
            }
            self.upsertProvider(provider)
        }

        self.config.normalizeOpenAIAccountOrder()
        let result = self.resolveProviderRemovalTransition(
            currentActiveProviderID: currentActiveProviderID,
            currentActiveAccountID: currentActiveAccountID,
            removedProviderID: provider.id,
            removedAccountID: account.accountId,
            providerStillExists: provider.accounts.isEmpty == false,
            nextProviderActiveAccountID: provider.activeAccountId,
            fallbackCandidates: [Self.activeSelectionCandidate(provider: self.config.providers.first)]
        )
        self.config.active.providerId = result.nextActiveProviderId
        self.config.active.accountId = result.nextActiveAccountId
        do {
            try self.persist(syncCodex: result.shouldSyncCodex)
        } catch {
            self.publishState()
        }
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
        let request = PortableCoreCompatibleProviderCreationRequest(
            label: label,
            baseURL: baseURL,
            accountLabel: accountLabel,
            apiKey: apiKey,
            fallbackProviderID: "provider-\(UUID().uuidString.lowercased())"
        )
        let result =
            (try? RustPortableCoreAdapter.shared.planCompatibleProviderCreation(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreCompatibleProviderCreationResult.failClosed(
                request: request
            )
        guard result.valid,
              let providerID = result.providerID,
              let providerLabel = result.providerLabel,
              let normalizedBaseURL = result.normalizedBaseURL,
              let normalizedAccountLabel = result.accountLabel,
              let normalizedAPIKey = result.apiKey else {
            throw TokenStoreError.invalidInput
        }
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: normalizedAccountLabel,
            apiKey: normalizedAPIKey,
            addedAt: Date()
        )
        let provider = CodexBarProvider(
            id: providerID,
            kind: .openAICompatible,
            label: providerLabel,
            enabled: true,
            baseURL: normalizedBaseURL,
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
        let request = PortableCoreCompatibleProviderAccountCreationRequest(
            label: label,
            apiKey: apiKey,
            nextAccountNumber: provider.accounts.count + 1
        )
        let result =
            (try? RustPortableCoreAdapter.shared.planCompatibleProviderAccountCreation(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreCompatibleProviderAccountCreationResult.failClosed(
                request: request
            )
        guard result.valid,
              let accountLabel = result.accountLabel,
              let normalizedAPIKey = result.apiKey else {
            throw TokenStoreError.invalidInput
        }
        let account = CodexBarProviderAccount(
            kind: .apiKey,
            label: accountLabel,
            apiKey: normalizedAPIKey,
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
        let currentActiveProviderID = self.config.active.providerId
        let currentActiveAccountID = self.config.active.accountId
        provider.accounts.removeAll { $0.id == accountID }
        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == providerID }
        } else {
            if provider.activeAccountId == accountID {
                provider.activeAccountId = provider.accounts.first?.id
            }
            self.upsertProvider(provider)
        }
        let result = self.resolveProviderRemovalTransition(
            currentActiveProviderID: currentActiveProviderID,
            currentActiveAccountID: currentActiveAccountID,
            removedProviderID: providerID,
            removedAccountID: accountID,
            providerStillExists: provider.accounts.isEmpty == false,
            nextProviderActiveAccountID: provider.activeAccountId,
            fallbackCandidates: [Self.activeSelectionCandidate(provider: self.config.providers.first)]
        )
        self.config.active.providerId = result.nextActiveProviderId
        self.config.active.accountId = result.nextActiveAccountId
        try self.persist(syncCodex: result.shouldSyncCodex)
    }

    func removeCustomProvider(providerID: String) throws {
        let currentActiveProviderID = self.config.active.providerId
        let currentActiveAccountID = self.config.active.accountId
        self.config.providers.removeAll { $0.id == providerID }
        let result = self.resolveProviderRemovalTransition(
            currentActiveProviderID: currentActiveProviderID,
            currentActiveAccountID: currentActiveAccountID,
            removedProviderID: providerID,
            removedAccountID: nil,
            providerStillExists: false,
            nextProviderActiveAccountID: nil,
            fallbackCandidates: [
                Self.activeSelectionCandidate(provider: self.config.oauthProvider()),
                Self.activeSelectionCandidate(provider: self.openRouterProvider),
                Self.activeSelectionCandidate(provider: self.customProviders.first),
            ]
        )
        self.config.active.providerId = result.nextActiveProviderId
        self.config.active.accountId = result.nextActiveAccountId
        try self.persist(syncCodex: result.shouldSyncCodex)
    }

    func removeOpenRouterProviderAccount(accountID: String) throws {
        guard var provider = self.openRouterProvider else {
            throw TokenStoreError.providerNotFound
        }
        let currentActiveProviderID = self.config.active.providerId
        let currentActiveAccountID = self.config.active.accountId

        provider.accounts.removeAll { $0.id == accountID }
        if provider.accounts.isEmpty {
            self.config.providers.removeAll { $0.id == provider.id }
        } else {
            if provider.activeAccountId == accountID {
                provider.activeAccountId = provider.accounts.first?.id
            }
            self.upsertProvider(provider)
        }
        let result = self.resolveProviderRemovalTransition(
            currentActiveProviderID: currentActiveProviderID,
            currentActiveAccountID: currentActiveAccountID,
            removedProviderID: provider.id,
            removedAccountID: accountID,
            providerStillExists: provider.accounts.isEmpty == false,
            nextProviderActiveAccountID: provider.activeAccountId,
            fallbackCandidates: [
                Self.activeSelectionCandidate(provider: self.config.oauthProvider()),
                Self.activeSelectionCandidate(provider: self.customProviders.first),
            ]
        )
        self.config.active.providerId = result.nextActiveProviderId
        self.config.active.accountId = result.nextActiveAccountId
        try self.persist(syncCodex: result.shouldSyncCodex)
    }

    func markActiveAccount() {
        self.publishState()
    }

    func updateOpenAIAccountUsageMode(_ mode: CodexBarOpenAIAccountUsageMode) throws {
        guard self.config.openAI.accountUsageMode != mode else { return }

        let previousMode = self.config.openAI.accountUsageMode
        let currentLeasedProcessIDs = self.aggregateGatewayLeaseProcessIDs.map(Int.init).sorted()
        let runningCodexProcessIDs = self.codexRunningProcessIDs().map(Int.init).sorted()
        let aggregateLeasePlan =
            (try? RustPortableCoreAdapter.shared.planAggregateGatewayLeaseTransition(
                PortableCoreAggregateGatewayLeaseTransitionPlanRequest(
                    previousOpenAIUsageMode: previousMode.rawValue,
                    nextOpenAIUsageMode: mode.rawValue,
                    currentLeasedProcessIDs: currentLeasedProcessIDs,
                    runningCodexProcessIDs: runningCodexProcessIDs
                ),
                buildIfNeeded: false
            )) ?? PortableCoreAggregateGatewayLeaseTransitionPlanResult.failClosed(
                previousOpenAIUsageMode: previousMode.rawValue,
                nextOpenAIUsageMode: mode.rawValue,
                currentLeasedProcessIDs: currentLeasedProcessIDs,
                runningCodexProcessIDs: runningCodexProcessIDs
            )
        let nextLeasedProcessIDs = Set(aggregateLeasePlan.nextLeasedProcessIDs.map(pid_t.init))
        if aggregateLeasePlan.leaseChanged {
            self.aggregateGatewayLeaseProcessIDs = nextLeasedProcessIDs
            if self.aggregateGatewayLeaseProcessIDs.isEmpty {
                self.aggregateGatewayLeaseStore.clear()
            } else {
                self.aggregateGatewayLeaseStore.saveProcessIDs(self.aggregateGatewayLeaseProcessIDs)
            }
        }
        if aggregateLeasePlan.shouldPoll {
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
        } else {
            self.aggregateGatewayLeaseTimer?.invalidate()
            self.aggregateGatewayLeaseTimer = nil
        }
        let request = PortableCoreUsageModeTransitionRequest(
            currentMode: previousMode.rawValue,
            targetMode: mode.rawValue,
            activeProviderId: self.config.active.providerId,
            activeAccountId: self.config.active.accountId,
            switchModeSelectionProviderId: self.config.openAI.switchModeSelection?.providerId,
            switchModeSelectionAccountId: self.config.openAI.switchModeSelection?.accountId,
            oauthProviderId: self.config.oauthProvider()?.id,
            oauthActiveAccountId: self.config.oauthProvider()?.activeAccountId,
            providers: self.config.providers.map(PortableCoreUsageModeTransitionProviderInput.legacy(from:))
        )
        let transition =
            (try? RustPortableCoreAdapter.shared.resolveUsageModeTransition(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreUsageModeTransitionResult.failClosed(request: request)

        if let providerID = transition.nextSwitchModeSelectionProviderId,
           let accountID = transition.nextSwitchModeSelectionAccountId {
            self.config.openAI.switchModeSelection = CodexBarActiveSelection(
                providerId: providerID,
                accountId: accountID
            )
        } else {
            self.config.openAI.switchModeSelection = nil
        }
        self.config.setOpenAIAccountUsageMode(
            CodexBarOpenAIAccountUsageMode(rawValue: transition.nextMode) ?? mode
        )
        self.config.active.providerId = transition.nextActiveProviderId
        self.config.active.accountId = transition.nextActiveAccountId
        try self.persist(syncCodex: transition.shouldSyncCodex)
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

    func saveSettings(_ requests: SettingsSaveRequests) throws {
        guard requests.isEmpty == false else { return }

        let previousUsageMode = self.config.openAI.accountUsageMode
        var updatedConfig = self.config
        try SettingsSaveRequestApplier.apply(requests, to: &updatedConfig)

        self.config = updatedConfig
        let syncDecision =
            (try? RustPortableCoreAdapter.shared.decideSettingsSaveSync(
                PortableCoreSettingsSaveSyncRequest(
                    previousUsageMode: previousUsageMode.rawValue,
                    requestedUsageMode: requests.openAIAccount?.accountUsageMode.rawValue,
                    activeProviderId: updatedConfig.active.providerId,
                    oauthProviderId: updatedConfig.oauthProvider()?.id
                ),
                buildIfNeeded: false
            )) ?? PortableCoreSettingsSaveSyncResult.failClosed(
                request: PortableCoreSettingsSaveSyncRequest(
                    previousUsageMode: previousUsageMode.rawValue,
                    requestedUsageMode: requests.openAIAccount?.accountUsageMode.rawValue,
                    activeProviderId: updatedConfig.active.providerId,
                    oauthProviderId: updatedConfig.oauthProvider()?.id
                )
            )
        try self.persist(syncCodex: syncDecision.shouldSyncCodex)
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
        let reconciled = self.configStore.reconcileAuthJSON(
            in: self.config,
            onlyAccountIDs: accountID.map { Set([$0]) }
        )
        guard reconciled.changed else { return false }
        self.config = reconciled.config
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
        let recentActivityWindow = runningThreadAttribution.recentActivityWindow
        let routeInput = PortableCoreRouteRuntimeInput(
            configuredMode: self.config.openAI.accountUsageMode.rawValue,
            effectiveMode: CodexBarOpenAIAccountUsageMode(
                rawValue: self.gatewayLifecyclePlan().effectiveOpenAIUsageMode
            )?.rawValue ?? CodexBarOpenAIAccountUsageMode.switchAccount.rawValue,
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
                recentActivityWindowSeconds: recentActivityWindow,
                summaryIsUnavailable: runningThreadAttribution.summary.isUnavailable,
                threads: runningThreadAttribution.threads.map {
                    .init(threadID: $0.threadID)
                }
            ),
            now: now.timeIntervalSince1970
        )
        let snapshotDTO =
            (try? RustPortableCoreAdapter.shared.computeRouteRuntimeSnapshot(
                routeInput,
                buildIfNeeded: false
            )) ?? PortableCoreRouteRuntimeSnapshotDTO.failClosed(from: routeInput)

        return snapshotDTO.runtimeRouteSnapshot()
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

    private static func activeSelectionCandidate(
        provider: CodexBarProvider?
    ) -> PortableCoreActiveSelectionCandidateInput {
        PortableCoreActiveSelectionCandidateInput(
            providerId: provider?.id,
            accountId: provider?.activeAccount?.id
        )
    }

    private func resolveProviderRemovalTransition(
        currentActiveProviderID: String?,
        currentActiveAccountID: String?,
        removedProviderID: String,
        removedAccountID: String?,
        providerStillExists: Bool,
        nextProviderActiveAccountID: String?,
        fallbackCandidates: [PortableCoreActiveSelectionCandidateInput]
    ) -> PortableCoreProviderRemovalTransitionResult {
        let request = PortableCoreProviderRemovalTransitionRequest(
            currentActiveProviderId: currentActiveProviderID,
            currentActiveAccountId: currentActiveAccountID,
            removedProviderId: removedProviderID,
            removedAccountId: removedAccountID,
            providerStillExists: providerStillExists,
            nextProviderActiveAccountId: nextProviderActiveAccountID,
            fallbackCandidates: fallbackCandidates
        )
        return (try? RustPortableCoreAdapter.shared.resolveProviderRemovalTransition(
            request,
            buildIfNeeded: false
        )) ?? PortableCoreProviderRemovalTransitionResult.failClosed(request: request)
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
            let reconciled = self.configStore.reconcileAuthJSON(
                in: self.config,
                onlyAccountIDs: self.config.active.accountId.map { Set([$0]) }
            )
            if reconciled.changed {
                self.config = reconciled.config
            }
        }
        try self.configStore.save(self.config)
        if syncCodex {
            try self.syncService.synchronize(config: self.config)
        }
        self.publishState()
    }

    private func publishState() {
        _ = self.refreshAggregateGatewayLeaseState()
        _ = self.refreshOpenRouterGatewayLeaseState()
        self.pushPublishedState()
    }

    private func pushPublishedState() {
        self.accounts = self.config.oauthTokenAccounts()
        let gatewayLifecyclePlan = self.gatewayLifecyclePlan()
        let effectiveGatewayMode =
            CodexBarOpenAIAccountUsageMode(
                rawValue: gatewayLifecyclePlan.effectiveOpenAIUsageMode
            ) ?? .switchAccount
        self.openAIAccountGatewayService.updateState(
            accounts: self.accounts,
            quotaSortSettings: self.config.openAI.quotaSort,
            accountUsageMode: effectiveGatewayMode
        )
        self.openRouterGatewayService.updateState(
            provider: self.config.openRouterProvider(),
            isActiveProvider: self.config.activeProvider()?.kind == .openRouter
        )
        if effectiveGatewayMode == .aggregateGateway {
            self.openAIAccountGatewayService.startIfNeeded()
        } else {
            self.openAIAccountGatewayService.stop()
        }
        if gatewayLifecyclePlan.shouldRunOpenrouterGateway {
            self.openRouterGatewayService.startIfNeeded()
        } else {
            self.openRouterGatewayService.stop()
        }
        self.aggregateRoutedAccountID = self.openAIAccountGatewayService.currentRoutedAccountID()
        self.lastPublishedOpenRouterSelected = self.config.activeProvider()?.kind == .openRouter
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
            ?? PortableCoreGatewayLifecyclePlanResult.failClosed(
                configuredOpenAIUsageMode: request.configuredOpenAIUsageMode,
                existingOpenrouterLease: request.existingOpenrouterLease
            )
    }

    private func refreshOpenRouterGatewayLeaseState() -> Bool {
        let plan = self.gatewayLifecyclePlan()
        let nextLease = plan.nextOpenrouterLease?.openRouterGatewayLeaseSnapshot()
        if plan.openrouterLeaseChanged {
            self.openRouterGatewayLeaseSnapshot = nextLease
            if let lease = self.openRouterGatewayLeaseSnapshot,
               lease.leasedProcessIDs.isEmpty == false {
                self.openRouterGatewayLeaseStore.saveLease(lease)
            } else {
                self.openRouterGatewayLeaseStore.clear()
            }
        }
        if plan.openrouterLeaseShouldPoll {
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
        } else {
            self.openRouterGatewayLeaseTimer?.invalidate()
            self.openRouterGatewayLeaseTimer = nil
        }
        return plan.openrouterLeaseChanged
    }

    private func refreshAggregateGatewayLeaseState() -> Bool {
        let currentLeasedProcessIDs = self.aggregateGatewayLeaseProcessIDs.map(Int.init).sorted()
        let runningCodexProcessIDs = self.codexRunningProcessIDs().map(Int.init).sorted()
        let plan =
            (try? RustPortableCoreAdapter.shared.planAggregateGatewayLeaseRefresh(
                PortableCoreAggregateGatewayLeaseRefreshPlanRequest(
                    currentOpenAIUsageMode: self.config.openAI.accountUsageMode.rawValue,
                    currentLeasedProcessIDs: currentLeasedProcessIDs,
                    runningCodexProcessIDs: runningCodexProcessIDs
                ),
                buildIfNeeded: false
            )) ?? PortableCoreAggregateGatewayLeaseRefreshPlanResult.failClosed(
                currentOpenAIUsageMode: self.config.openAI.accountUsageMode.rawValue,
                currentLeasedProcessIDs: currentLeasedProcessIDs,
                runningCodexProcessIDs: runningCodexProcessIDs
            )

        if plan.leaseChanged {
            self.aggregateGatewayLeaseProcessIDs = Set(plan.nextLeasedProcessIDs.map(pid_t.init))
            if self.aggregateGatewayLeaseProcessIDs.isEmpty {
                self.aggregateGatewayLeaseStore.clear()
            } else {
                self.aggregateGatewayLeaseStore.saveProcessIDs(self.aggregateGatewayLeaseProcessIDs)
            }
        }
        if plan.shouldPoll {
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
        } else {
            self.aggregateGatewayLeaseTimer?.invalidate()
            self.aggregateGatewayLeaseTimer = nil
        }
        return plan.leaseChanged
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
            let cachePolicyRequest = PortableCoreLocalCostCachePolicyRequest(
                updatedAt: summary.updatedAt?.timeIntervalSince1970,
                todayTokens: summary.todayTokens,
                last30DaysTokens: summary.last30DaysTokens,
                lifetimeTokens: summary.lifetimeTokens,
                dailyEntryCount: summary.dailyEntries.count,
                ledgerFileSizeBytes: 0
            )
            let cachePolicy = (try? RustPortableCoreAdapter.shared.resolveLocalCostCachePolicy(
                cachePolicyRequest,
                buildIfNeeded: false
            )) ?? PortableCoreLocalCostCachePolicyResult(
                summaryIsEffectivelyEmpty: summary.todayTokens == 0 &&
                    summary.last30DaysTokens == 0 &&
                    summary.lifetimeTokens == 0 &&
                    summary.dailyEntries.isEmpty,
                shouldInvalidateCachedSummary: summary.updatedAt != nil &&
                    summary.todayTokens == 0 &&
                    summary.last30DaysTokens == 0 &&
                    summary.lifetimeTokens == 0 &&
                    summary.dailyEntries.isEmpty,
                rustOwner: "swift.failClosedLocalCostCachePolicy"
            )
            if refreshSessionCache == false,
               cachePolicy.summaryIsEffectivelyEmpty {
                summary = service.load(
                    modelPricingOverrides: modelPricing,
                    refreshSessionCache: true
                )
            }
            DispatchQueue.main.async {
                self.localCostSummary = summary
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(summary) {
                    try? CodexPaths.writeSecureFile(data, to: CodexPaths.costCacheURL)
                }
                self.refreshStateQueue.async {
                    self.isRefreshingLocalCostSummary = false
                }
            }
        }
    }

    private static func mergedHistoricalModels(
        preferredHistoricalModels: [String],
        fallbackHistoricalModels: [String]
    ) -> [String] {
        let request = PortableCoreHistoricalModelsMergeRequest(
            preferredHistoricalModels: preferredHistoricalModels,
            fallbackHistoricalModels: fallbackHistoricalModels
        )
        let result =
            (try? RustPortableCoreAdapter.shared.mergeHistoricalModels(
                request,
                buildIfNeeded: false
            )) ?? PortableCoreHistoricalModelsMergeResult.failClosed(
                request: request
            )
        return result.models
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

    deinit {
        self.openRouterGatewayLeaseTimer?.invalidate()
        self.aggregateGatewayLeaseTimer?.invalidate()
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
