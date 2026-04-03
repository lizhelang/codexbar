import Combine
import Foundation

final class TokenStore: ObservableObject {
    static let shared = TokenStore()

    @Published var accounts: [TokenAccount] = []
    @Published private(set) var config: CodexBarConfig
    @Published private(set) var localCostSummary: LocalCostSummary = .empty

    private let configStore = CodexBarConfigStore()
    private let syncService = CodexSyncService()
    private let switchJournalStore = SwitchJournalStore()
    private let costSummaryService = LocalCostSummaryService()
    private let refreshStateQueue = DispatchQueue(label: "lzl.codexbar.refresh-state")
    private let usageRefreshStateQueue = DispatchQueue(label: "lzl.codexbar.usage-refresh-state")
    private var isRefreshingLocalCostSummary = false
    private var isRefreshingAllUsage = false
    private var refreshingUsageAccountIDs: Set<String> = []

    private init() {
        if let loaded = try? self.configStore.loadOrMigrate() {
            self.config = loaded
        } else {
            self.config = CodexBarConfig()
        }

        self.publishState()
        self.localCostSummary = self.loadCachedLocalCostSummary()
        self.seedSwitchJournalIfNeeded()
        try? self.syncService.synchronize(config: self.config)
    }

    var customProviders: [CodexBarProvider] {
        self.config.providers.filter { $0.kind == .openAICompatible }
    }

    var activeProvider: CodexBarProvider? {
        self.config.activeProvider()
    }

    var activeProviderAccount: CodexBarProviderAccount? {
        self.config.activeAccount()
    }

    var activeModel: String {
        self.config.global.defaultModel
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
        provider.accounts.removeAll { $0.openAIAccountId == account.accountId }

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

        self.persistIgnoringErrors(syncCodex: self.config.active.providerId == provider.id)
    }

    func activate(_ account: TokenAccount) throws {
        _ = try self.config.activateOAuthAccount(accountID: account.accountId)
        try self.persist(syncCodex: true)
        try self.appendSwitchJournal()
    }

    func activeAccount() -> TokenAccount? {
        self.accounts.first(where: { $0.isActive })
    }

    func activateCustomProvider(providerID: String, accountID: String) throws {
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
        try self.appendSwitchJournal()
    }

    func addCustomProvider(label: String, baseURL: String, accountLabel: String, apiKey: String) throws {
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
        try self.appendSwitchJournal()
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
            let fallback = self.oauthProvider() ?? self.customProviders.first
            self.config.active.providerId = fallback?.id
            self.config.active.accountId = fallback?.activeAccount?.id
            try self.persist(syncCodex: fallback != nil)
            return
        }
        try self.persist(syncCodex: false)
    }

    func markActiveAccount() {
        self.publishState()
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

    func endAllUsageRefresh() {
        self.usageRefreshStateQueue.sync {
            self.isRefreshingAllUsage = false
        }
    }

    // MARK: - Private

    private func oauthProvider() -> CodexBarProvider? {
        self.config.providers.first(where: { $0.kind == .openAIOAuth })
    }

    private func ensureOAuthProvider() -> CodexBarProvider {
        if let provider = self.oauthProvider() {
            return provider
        }
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            enabled: true,
            baseURL: nil
        )
        self.config.providers.append(provider)
        return provider
    }

    private func upsertProvider(_ provider: CodexBarProvider) {
        if let index = self.config.providers.firstIndex(where: { $0.id == provider.id }) {
            self.config.providers[index] = provider
        } else {
            self.config.providers.append(provider)
        }
    }

    private func persist(syncCodex: Bool) throws {
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
        self.accounts = self.config.oauthTokenAccounts()
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
        try self.switchJournalStore.appendActivation(
            providerID: self.config.active.providerId,
            accountID: self.config.active.accountId
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

    private func slug(from label: String) -> String {
        let lowered = label.lowercased()
        let slug = lowered.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "provider-\(UUID().uuidString.lowercased())" : slug
    }
}

enum TokenStoreError: LocalizedError {
    case accountNotFound
    case providerNotFound
    case invalidInput

    var errorDescription: String? {
        switch self {
        case .accountNotFound: return "未找到账号"
        case .providerNotFound: return "未找到 provider"
        case .invalidInput: return "输入无效"
        }
    }
}
