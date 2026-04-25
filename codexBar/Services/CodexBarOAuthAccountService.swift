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

    private func makeTokenAccount(from stored: CodexBarProviderAccount, config: CodexBarConfig) -> TokenAccount? {
        let provider = config.oauthProvider()
        let isActive = config.active.providerId == provider?.id && config.active.accountId == stored.id
        return stored.asTokenAccount(isActive: isActive)
    }

    private func applyInteropContext(
        _ interopContext: OAuthAccountImportInterchangeContext,
        to config: inout CodexBarConfig
    ) {
        guard interopContext.isEmpty == false else {
            return
        }

        if let providerIndex = config.providers.firstIndex(where: { $0.kind == .openAIOAuth }) {
            var provider = config.providers[providerIndex]
            for index in provider.accounts.indices {
                let accountID = provider.accounts[index].id
                guard let metadata = interopContext.accountMetadataByID[accountID] else {
                    continue
                }
                provider.accounts[index].interopProxyKey = metadata.proxyKey
                provider.accounts[index].interopNotes = metadata.notes
                provider.accounts[index].interopConcurrency = metadata.concurrency
                provider.accounts[index].interopPriority = metadata.priority
                provider.accounts[index].interopRateMultiplier = metadata.rateMultiplier
                provider.accounts[index].interopAutoPauseOnExpired = metadata.autoPauseOnExpired
                provider.accounts[index].interopCredentialsJSON = metadata.credentialsJSON
                provider.accounts[index].interopExtraJSON = metadata.extraJSON
            }
            config.providers[providerIndex] = provider
        }

        config.openAI.interopProxiesJSON = self.mergeInteropProxiesJSON(
            existing: config.openAI.interopProxiesJSON,
            incoming: interopContext.proxiesJSON
        )
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

    private func mergeInteropProxiesJSON(existing: String?, incoming: String?) -> String? {
        let existingItems = self.decodeInteropProxyJSONArray(existing)
        let incomingItems = self.decodeInteropProxyJSONArray(incoming)
        guard existingItems.isEmpty == false || incomingItems.isEmpty == false else {
            return existing
        }

        var merged: [[String: Any]] = []
        var indexByProxyKey: [String: Int] = [:]

        func appendOrReplace(_ item: [String: Any]) {
            let proxyKey = (item["proxy_key"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let proxyKey, proxyKey.isEmpty == false else {
                merged.append(item)
                return
            }

            if let existingIndex = indexByProxyKey[proxyKey] {
                merged[existingIndex] = item
            } else {
                indexByProxyKey[proxyKey] = merged.count
                merged.append(item)
            }
        }

        existingItems.forEach(appendOrReplace)
        incomingItems.forEach(appendOrReplace)

        return self.encodeJSONObjectString(merged) ?? incoming ?? existing
    }

    private func decodeInteropProxyJSONArray(_ json: String?) -> [[String: Any]] {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [[String: Any]] else {
            return []
        }
        return array
    }

    private func encodeJSONObjectString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
