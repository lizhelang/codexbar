import Foundation

struct OAuthAccountMutationResult {
    let account: TokenAccount
    let active: Bool
    let synchronized: Bool
}

struct OAuthAccountSummary: Codable, Equatable {
    let accountID: String
    let email: String
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case email
        case active
    }
}

struct OAuthAccountBatchImportResult: Equatable {
    let addedCount: Int
    let updatedCount: Int
    let activeChanged: Bool
    let providerChanged: Bool
    let preservedCompatibleProvider: Bool
    let synchronized: Bool
    let importedAccountIDs: [String]
}

struct CodexBarOAuthAccountService {
    private let configStore: CodexBarConfigStore
    private let syncService: any CodexSynchronizing
    private let switchJournalStore: SwitchJournalStore

    init(
        configStore: CodexBarConfigStore = CodexBarConfigStore(),
        syncService: any CodexSynchronizing = CodexSyncService(),
        switchJournalStore: SwitchJournalStore = SwitchJournalStore()
    ) {
        self.configStore = configStore
        self.syncService = syncService
        self.switchJournalStore = switchJournalStore
    }

    func listAccounts() throws -> [OAuthAccountSummary] {
        let config = try self.configStore.loadOrMigrate()
        return config.oauthTokenAccounts().map {
            OAuthAccountSummary(
                accountID: $0.accountId,
                email: $0.email,
                active: $0.isActive
            )
        }
    }

    func exportAccounts() throws -> [TokenAccount] {
        try self.configStore.loadOrMigrate().oauthTokenAccounts()
    }

    func importAccount(_ account: TokenAccount, activate: Bool) throws -> OAuthAccountMutationResult {
        let previousConfig = try self.configStore.loadOrMigrate()
        var config = previousConfig
        let previousAccountID = config.active.accountId
        let result = config.upsertOAuthAccount(account, activate: activate)

        try self.persist(config: config, previousConfig: previousConfig, synchronizeCodex: result.syncCodex)
        if activate {
            try self.switchJournalStore.appendActivation(
                providerID: config.active.providerId,
                accountID: config.active.accountId,
                previousAccountID: previousAccountID
            )
        }

        let stored = self.makeTokenAccount(from: result.storedAccount, config: config) ?? account
        return OAuthAccountMutationResult(
            account: stored,
            active: stored.isActive,
            synchronized: result.syncCodex
        )
    }

    func activateAccount(accountID: String) throws -> OAuthAccountMutationResult {
        let previousConfig = try self.configStore.loadOrMigrate()
        var config = previousConfig
        let previousAccountID = config.active.accountId
        let stored = try config.activateOAuthAccount(accountID: accountID)

        try self.persist(config: config, previousConfig: previousConfig, synchronizeCodex: true)
        try self.switchJournalStore.appendActivation(
            providerID: config.active.providerId,
            accountID: config.active.accountId,
            previousAccountID: previousAccountID
        )

        guard let tokenAccount = self.makeTokenAccount(from: stored, config: config) else {
            throw TokenStoreError.accountNotFound
        }
        return OAuthAccountMutationResult(account: tokenAccount, active: true, synchronized: true)
    }

    func importAccounts(_ accounts: [TokenAccount], activeAccountID: String?) throws -> OAuthAccountBatchImportResult {
        guard activeAccountID == nil || accounts.contains(where: { $0.accountId == activeAccountID }) else {
            throw TokenStoreError.accountNotFound
        }

        let previousConfig = try self.configStore.loadOrMigrate()
        var config = previousConfig
        let previousProviderID = config.active.providerId
        let previousAccountID = config.active.accountId
        let previousProviderKind = config.activeProvider()?.kind
        let existingAccountIDs = Set(config.oauthProvider()?.accounts.map(\.id) ?? [])
        let addedCount = accounts.reduce(into: 0) { partialResult, account in
            if existingAccountIDs.contains(account.accountId) == false {
                partialResult += 1
            }
        }

        for account in accounts {
            _ = config.upsertOAuthAccount(account, activate: false)
        }

        var preservedCompatibleProvider = false
        if let activeAccountID {
            if previousProviderKind == .openAICompatible {
                preservedCompatibleProvider = true
                try config.setOAuthPreferredAccount(accountID: activeAccountID)
            } else {
                _ = try config.activateOAuthAccount(accountID: activeAccountID)
            }
        }

        let synchronized = self.shouldSynchronize(config: config)
        try self.persist(config: config, previousConfig: previousConfig, synchronizeCodex: synchronized)

        let providerChanged = previousProviderID != config.active.providerId
        let activeChanged = previousAccountID != config.active.accountId
        if providerChanged || activeChanged {
            try self.switchJournalStore.appendActivation(
                providerID: config.active.providerId,
                accountID: config.active.accountId,
                previousAccountID: previousAccountID
            )
        }

        return OAuthAccountBatchImportResult(
            addedCount: addedCount,
            updatedCount: accounts.count - addedCount,
            activeChanged: activeChanged,
            providerChanged: providerChanged,
            preservedCompatibleProvider: preservedCompatibleProvider,
            synchronized: synchronized,
            importedAccountIDs: accounts.map(\.accountId)
        )
    }

    private func makeTokenAccount(from stored: CodexBarProviderAccount, config: CodexBarConfig) -> TokenAccount? {
        let provider = config.oauthProvider()
        let isActive = config.active.providerId == provider?.id && config.active.accountId == stored.id
        return stored.asTokenAccount(isActive: isActive)
    }

    private func shouldSynchronize(config: CodexBarConfig) -> Bool {
        guard let provider = config.activeProvider(),
              provider.kind == .openAIOAuth,
              config.activeAccount() != nil else {
            return false
        }
        return true
    }

    private func persist(
        config: CodexBarConfig,
        previousConfig: CodexBarConfig,
        synchronizeCodex: Bool
    ) throws {
        try self.configStore.save(config)
        guard synchronizeCodex else { return }

        do {
            try self.syncService.synchronize(config: config)
            CodexBarInterprocess.postReloadState()
        } catch {
            try? self.configStore.save(previousConfig)
            throw error
        }
    }
}
