import Foundation

struct OAuthAccountMutationResult {
    let account: TokenAccount
    let active: Bool
    let synchronized: Bool
}

struct OAuthAccountInteropMetadata: Equatable {
    let proxyKey: String?
    let notes: String?
    let concurrency: Int?
    let priority: Int?
    let rateMultiplier: Double?
    let autoPauseOnExpired: Bool?
    let credentialsJSON: String?
    let extraJSON: String?

    static let empty = OAuthAccountInteropMetadata(
        proxyKey: nil,
        notes: nil,
        concurrency: nil,
        priority: nil,
        rateMultiplier: nil,
        autoPauseOnExpired: nil,
        credentialsJSON: nil,
        extraJSON: nil
    )

    var isEmpty: Bool {
        self == .empty
    }
}

struct OAuthAccountImportInterchangeContext: Equatable {
    let accountMetadataByID: [String: OAuthAccountInteropMetadata]
    let proxiesJSON: String?

    static let empty = OAuthAccountImportInterchangeContext(
        accountMetadataByID: [:],
        proxiesJSON: nil
    )

    var isEmpty: Bool {
        self.accountMetadataByID.isEmpty && (self.proxiesJSON?.isEmpty != false)
    }
}

struct OAuthAccountExportSnapshot {
    let accounts: [TokenAccount]
    let metadataByAccountID: [String: OAuthAccountInteropMetadata]
    let proxiesJSON: String?
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

    func exportAccountsForInterchange() throws -> OAuthAccountExportSnapshot {
        let config = try self.configStore.loadOrMigrate()
        let metadataEntries: [(String, OAuthAccountInteropMetadata)] = (config.oauthProvider()?.accounts ?? []).compactMap { stored in
            guard stored.kind == .oauthTokens else {
                return nil
            }
            let metadata = OAuthAccountInteropMetadata(
                proxyKey: stored.interopProxyKey,
                notes: stored.interopNotes,
                concurrency: stored.interopConcurrency,
                priority: stored.interopPriority,
                rateMultiplier: stored.interopRateMultiplier,
                autoPauseOnExpired: stored.interopAutoPauseOnExpired,
                credentialsJSON: stored.interopCredentialsJSON,
                extraJSON: stored.interopExtraJSON
            )
            return metadata.isEmpty ? nil : (stored.id, metadata)
        }
        let metadataByAccountID = Dictionary(uniqueKeysWithValues: metadataEntries)

        return OAuthAccountExportSnapshot(
            accounts: config.oauthTokenAccounts(),
            metadataByAccountID: metadataByAccountID,
            proxiesJSON: config.openAI.interopProxiesJSON
        )
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

        let oauthProvider = config.oauthProvider()
        let isActive = config.active.providerId == oauthProvider?.id && config.active.accountId == result.storedAccount.id
        let stored = result.storedAccount.asTokenAccount(isActive: isActive) ?? account
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

        let oauthProvider = config.oauthProvider()
        let isActive = config.active.providerId == oauthProvider?.id && config.active.accountId == stored.id
        guard let tokenAccount = stored.asTokenAccount(isActive: isActive) else {
            throw TokenStoreError.accountNotFound
        }
        return OAuthAccountMutationResult(account: tokenAccount, active: true, synchronized: true)
    }

    func importAccounts(
        _ accounts: [TokenAccount],
        activeAccountID: String?,
        interopContext: OAuthAccountImportInterchangeContext = .empty
    ) throws -> OAuthAccountBatchImportResult {
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

        self.applyInteropContext(interopContext, to: &config)

        var preservedCompatibleProvider = false
        if let activeAccountID {
            if previousProviderKind == .openAICompatible {
                preservedCompatibleProvider = true
                try config.setOAuthPreferredAccount(accountID: activeAccountID)
            } else {
                _ = try config.activateOAuthAccount(accountID: activeAccountID)
            }
        }

        let syncDecision =
            (try? RustPortableCoreAdapter.shared.decideOAuthAccountSync(
                PortableCoreOAuthAccountSyncRequest(
                    activeProviderKind: config.activeProvider()?.kind.rawValue,
                    hasActiveAccount: config.activeAccount() != nil
                ),
                buildIfNeeded: false
            )) ?? PortableCoreOAuthAccountSyncResult.failClosed(
                request: PortableCoreOAuthAccountSyncRequest(
                    activeProviderKind: config.activeProvider()?.kind.rawValue,
                    hasActiveAccount: config.activeAccount() != nil
                )
            )
        try self.persist(
            config: config,
            previousConfig: previousConfig,
            synchronizeCodex: syncDecision.shouldSyncCodex
        )

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
            synchronized: syncDecision.shouldSyncCodex,
            importedAccountIDs: accounts.map(\.accountId)
        )
    }

    private func applyInteropContext(
        _ interopContext: OAuthAccountImportInterchangeContext,
        to config: inout CodexBarConfig
    ) {
        guard interopContext.isEmpty == false else {
            return
        }

        guard let providerIndex = config.providers.firstIndex(where: { $0.kind == .openAIOAuth }) else {
            return
        }

        let request = PortableCoreOAuthInteropContextApplyRequest(
            accounts: config.providers[providerIndex].accounts.map(PortableCoreOAuthStoredAccountInput.legacy(from:)),
            metadataEntries: interopContext.accountMetadataByID.map { accountID, metadata in
                PortableCoreOAuthInteropMetadataEntry(
                    accountId: accountID,
                    proxyKey: metadata.proxyKey,
                    notes: metadata.notes,
                    concurrency: metadata.concurrency,
                    priority: metadata.priority,
                    rateMultiplier: metadata.rateMultiplier,
                    autoPauseOnExpired: metadata.autoPauseOnExpired,
                    credentialsJSON: metadata.credentialsJSON,
                    extraJSON: metadata.extraJSON
                )
            },
            existingJSON: config.openAI.interopProxiesJSON,
            incomingJSON: interopContext.proxiesJSON
        )
        let result =
            (try? RustPortableCoreAdapter.shared.applyOAuthInteropContext(
                request,
                buildIfNeeded: true
            )) ?? PortableCoreOAuthInteropContextApplyResult.failClosed(request: request)

        config.providers[providerIndex].accounts = result.accounts.map { $0.providerAccount() }
        config.openAI.interopProxiesJSON = result.mergedJSON
    }

    private func persist(
        config: CodexBarConfig,
        previousConfig: CodexBarConfig,
        synchronizeCodex: Bool
    ) throws {
        let finalConfig: CodexBarConfig
        if synchronizeCodex,
           config.activeProvider()?.kind == .openAIOAuth {
            finalConfig = self.configStore.reconcileAuthJSON(
                in: config,
                onlyAccountIDs: config.active.accountId.map { Set([$0]) }
            ).config
        } else {
            finalConfig = config
        }

        try self.configStore.save(finalConfig)
        guard synchronizeCodex else { return }

        do {
            try self.syncService.synchronize(config: finalConfig)
        } catch {
            try? self.configStore.save(previousConfig)
            throw error
        }
    }

}
